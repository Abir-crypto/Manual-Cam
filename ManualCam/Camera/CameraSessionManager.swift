import AVFoundation
import Combine

/// Owns the `AVCaptureSession` lifecycle: device discovery, inputs/outputs, and
/// start/stop. All session mutation happens on `sessionQueue` — never on main.
///
/// Opts out of the module's default MainActor isolation: this type is background-queue
/// driven by design, and only hops to main explicitly to publish `@Published` state.
nonisolated final class CameraSessionManager: ObservableObject {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()
    /// Live depth stream for Portrait's depth-debug preview (`PORTRAIT_MODE.md` Task 3) and
    /// the face-detection subject indicator (Task 2). Both are added to the session only while
    /// Portrait is active and removed on the way out, per Task 1's "tear down Portrait-specific
    /// capture configuration cleanly".
    let depthDataOutput = AVCaptureDepthDataOutput()
    let metadataOutput = AVCaptureMetadataOutput()

    /// Serial queue all session and device configuration happens on.
    let sessionQueue = DispatchQueue(label: "com.manualcam.sessionQueue")
    private let videoDataOutputQueue = DispatchQueue(label: "com.manualcam.videoDataOutputQueue")
    private let depthDataOutputQueue = DispatchQueue(label: "com.manualcam.depthDataOutputQueue")

    @Published private(set) var isSessionRunning = false
    @Published private(set) var currentDevice: AVCaptureDevice?
    @Published private(set) var isRAWSupported = false
    /// Whether a RAW capture is actually possible on the *currently selected* lens preset — false on a
    /// sensor-crop preset (2×/8×) when the only RAW on offer is Bayer, which the SDK forbids while
    /// zoomed. Distinct from `isRAWSupported`, which only says the lens has some RAW format at all.
    /// Evaluated with the same `RAWPixelFormatRule` the capture path uses, so the two can't disagree.
    @Published private(set) var isRAWAvailableAtCurrentLens = false
    @Published private(set) var isAppleProRAWSupported = false
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentLens: CameraLens?
    /// Whether this iPhone has a virtual multi-camera device at all — the hardware gate on
    /// Portrait mode (`PORTRAIT_MODE.md`: "hide/disable the Portrait entry in the mode switcher
    /// on unsupported devices"). Depth and matte delivery come only from that device.
    @Published private(set) var isPortraitModeSupported = false
    /// Depth-capable lens/zoom points for Portrait mode, derived from the virtual device (empty in
    /// every other mode). See `buildPortraitZoomOptions(for:)`.
    @Published private(set) var portraitZoomOptions: [PortraitZoomOption] = []
    @Published private(set) var currentPortraitZoom: CGFloat?
    @Published var setupError: String?

    private var isConfigured = false
    /// Whether the session is currently wired for Portrait (virtual device input + depth and
    /// matte delivery + depth/metadata outputs). Tracked explicitly rather than inferred from
    /// the active device type, so teardown is unambiguous and idempotent.
    private var isPortraitConfigured = false
    /// Mirrors `currentDevice`, but readable from `sessionQueue` without crossing
    /// through the `@Published` copy (which is only ever written from main).
    private var activeDevice: AVCaptureDevice?
    private var activeDeviceType: AVCaptureDevice.DeviceType?
    /// The discrete-lens preset to return to when leaving Portrait mode. Mirrors `currentLens`
    /// but readable from `sessionQueue` (the published copy is main-only), and deliberately not
    /// overwritten while Portrait's virtual device is active.
    private var activeLens: CameraLens?

    /// The three individual back lenses. Deliberately never the virtual multi-camera
    /// device (`.builtInTripleCamera` etc.) — see `CameraLens`'s doc comment for why.
    private static let backLensDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
    ]

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isSessionRunning = running }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Must be called on `sessionQueue`. Whether RAW is possible with the device as currently zoomed —
    /// see `isRAWAvailableAtCurrentLens`. Re-evaluated on every lens switch and after a ProRAW toggle,
    /// because both change the answer: the available format list depends on `isAppleProRAWEnabled`, and
    /// Bayer RAW's legality depends on the zoom the preset applied.
    private func evaluateRAWAvailability(on device: AVCaptureDevice) -> Bool {
        RAWPixelFormatRule.isRAWAvailable(
            availableFormats: photoOutput.availableRawPhotoPixelFormatTypes,
            preferAppleProRAW: photoOutput.isAppleProRAWSupported && photoOutput.isAppleProRAWEnabled,
            videoZoomFactor: device.videoZoomFactor
        )
    }

    /// Enable/disable Apple ProRAW on the photo output, for Task 9's Settings toggle.
    ///
    /// On `sessionQueue` inside a configuration batch, like every other output change here:
    /// the property changes which formats `availableRawPhotoPixelFormatTypes` reports, so it
    /// has to be settled before the next capture builds its settings from that list. Guarded
    /// on `isAppleProRAWSupported` because setting it on hardware that doesn't support ProRAW
    /// raises `NSInvalidArgumentException` — and because before `configureSession()` has run,
    /// the output isn't attached yet and support always reads false (see
    /// `CameraCoordinator.handleDeviceAttached`, which re-applies once a device is live).
    func setAppleProRAWEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.photoOutput.isAppleProRAWSupported else { return }
            guard self.photoOutput.isAppleProRAWEnabled != enabled else { return }
            self.session.beginConfiguration()
            self.photoOutput.isAppleProRAWEnabled = enabled
            self.session.commitConfiguration()
            // Toggling ProRAW changes which formats the output offers, which changes whether RAW is
            // possible at the current zoom — a 2×/8× sensor-crop preset can go from "RAW works" to
            // "Bayer only, and Bayer is illegal while zoomed" purely from this switch.
            guard let device = self.activeDevice else { return }
            let rawAvailableHere = self.evaluateRAWAvailability(on: device)
            DispatchQueue.main.async { self.isRAWAvailableAtCurrentLens = rawAvailableHere }
        }
    }

    /// Attach the delegate that receives live frames for focus peaking (Task 7).
    func setVideoDataOutputDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate?) {
        sessionQueue.async { [weak self] in
            self?.videoDataOutput.setSampleBufferDelegate(delegate, queue: self?.videoDataOutputQueue)
        }
    }

    /// Attach the delegate for the live depth stream that feeds Portrait's depth-debug preview
    /// (`PORTRAIT_MODE.md` Task 3). Set once at startup; the output itself is only *in* the
    /// session while Portrait is active, so no frames arrive otherwise.
    func setDepthDataOutputDelegate(_ delegate: AVCaptureDepthDataOutputDelegate?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.depthDataOutput.setDelegate(delegate, callbackQueue: self.depthDataOutputQueue)
        }
    }

    /// Attach the delegate for face-detection metadata, Portrait's live subject indicator
    /// (`PORTRAIT_MODE.md` Task 2). Callbacks arrive on `sessionQueue` — the delegate hops to
    /// main before publishing.
    func setMetadataObjectsDelegate(_ delegate: AVCaptureMetadataOutputObjectsDelegate?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.metadataOutput.setMetadataObjectsDelegate(delegate, queue: self.sessionQueue)
        }
    }

    // MARK: - Shooting mode configuration

    /// Reconfigures the session for a shooting mode. Portrait swaps in the virtual
    /// multi-camera device and turns on depth/matte delivery; every other mode tears that back
    /// down and returns to a discrete physical lens (`PORTRAIT_MODE.md` Task 1).
    ///
    /// Idempotent: re-applying the current mode is a no-op, so callers don't have to track it.
    func configure(for mode: ShootingMode) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            if mode == .portrait {
                self.enterPortraitConfiguration()
            } else {
                self.exitPortraitConfiguration()
            }
        }
    }

    /// Must be called on `sessionQueue`.
    ///
    /// **This is the one place the app deliberately runs on the virtual multi-camera device**,
    /// which the rest of the app avoids on purpose: `isLockingFocusWithCustomLensPositionSupported`
    /// is false there, and calling `setFocusModeLocked(lensPosition:)` on it throws
    /// `NSInvalidArgumentException` (see `CameraLens`). That's safe here only because Portrait
    /// hides the manual controls and drives the device in continuous auto — the coordinator
    /// keeps `ManualControlEngine` detached and locked for the duration. Depth and portrait
    /// matte delivery are only available from this device, so there's no alternative.
    ///
    /// Expect a visible hitch entering the mode: the SDK notes that enabling depth, matte, or
    /// semantic-matte delivery "requires a lengthy reconfiguration of the capture render pipeline"
    /// and recommends setting them before `startRunning()`. That's not possible for a runtime mode
    /// toggle, and the cost is paid once per entry rather than imposed on Manual shooting.
    private func enterPortraitConfiguration() {
        guard !isPortraitConfigured else { return }
        guard let device = Self.discoverVirtualDevice() else {
            publishError("Portrait mode needs an iPhone with two or more rear cameras.")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            publishError("Unable to open the camera for Portrait mode.")
            return
        }

        session.beginConfiguration()
        swapInput(to: input)

        // Added after the input swap: the output's depth/matte support flags reflect the
        // *active* input, so querying them before this point would report the discrete lens's
        // (unsupported) capabilities.
        if !session.outputs.contains(where: { $0 === depthDataOutput }), session.canAddOutput(depthDataOutput) {
            session.addOutput(depthDataOutput)
        }
        // Filtering interpolates holes in the depth map — for a visualization meant to judge
        // subject separation, the smoothed version is far more readable than the raw one.
        depthDataOutput.isFilteringEnabled = true
        depthDataOutput.connection(with: .depthData)?.isEnabled = true

        if !session.outputs.contains(where: { $0 === metadataOutput }), session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
        }
        if metadataOutput.availableMetadataObjectTypes.contains(.face) {
            metadataOutput.metadataObjectTypes = [.face]
        }

        // Order and dependency both matter here, per the SDK header: "Portrait effects matte
        // generation requires depth to be present, so when enabling portrait effects matte
        // delivery, you must also set depthDataDeliveryEnabled to YES." Depth goes first and the
        // matte is gated on it actually being on — not merely on the matte being *supported* —
        // since a device could in principle report matte support while depth delivery is
        // unavailable in the current configuration.
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        photoOutput.isPortraitEffectsMatteDeliveryEnabled =
            photoOutput.isPortraitEffectsMatteDeliverySupported && photoOutput.isDepthDataDeliveryEnabled
        photoOutput.enabledSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes.filter { $0 == .skin }
        // Portrait's captures are auto-exposed, so the `.speed` rule that protects manual
        // exposure exactness doesn't apply here — and matte/depth generation is part of the
        // fuller processing pipeline. Restored to `.speed` on the way out (see
        // `exitPortraitConfiguration`), and note per-shot settings may not exceed this max or
        // the capture throws.
        photoOutput.maxPhotoQualityPrioritization = .quality

        applyRotation(to: videoDataOutput.connection(with: .video), for: device)
        applyRotation(to: depthDataOutput.connection(with: .depthData), for: device)
        session.commitConfiguration()

        applyContinuousAutoModes(on: device)

        isPortraitConfigured = true
        activeDevice = device
        activeDeviceType = device.deviceType

        // Built after the commit, so the depth-capable zoom ranges are read from the format that's
        // actually active with depth delivery enabled.
        let zoomOptions = buildPortraitZoomOptions(for: device)
        // Open on the main lens (1× as the user reads it) when it's depth-capable, otherwise the widest
        // option that is — never a factor that would throw. Matched on `displayMultiplier`, *not*
        // `zoomFactor`: a raw factor of 1.0 is the ultra-wide on these devices, which is not what
        // "open at 1×" means. Compared with a tolerance since these are derived floats.
        let initialZoom = zoomOptions.first(where: { abs($0.displayMultiplier - 1.0) < 0.05 })?.zoomFactor
            ?? zoomOptions.first?.zoomFactor
        if let initialZoom, isZoomFactorDepthCapable(initialZoom, on: device) {
            applyZoom(initialZoom, to: device)
        }

        let depthSupported = photoOutput.isDepthDataDeliveryEnabled
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !depthSupported {
                self.setupError = "This device didn't offer depth data for Portrait mode."
            }
            self.portraitZoomOptions = zoomOptions
            self.currentPortraitZoom = initialZoom
            self.currentDevice = device
        }
    }

    /// Must be called on `sessionQueue`. Returns the session to a discrete physical lens with
    /// depth/matte delivery off and Portrait's extra outputs removed, then republishes
    /// `currentDevice` — which is what makes the coordinator re-attach `ManualControlEngine`
    /// and restore the manual values. Without that republish, the manual controls would be
    /// pointed at a device no longer in the session.
    private func exitPortraitConfiguration() {
        guard isPortraitConfigured else { return }

        let lens = activeLens
        let deviceType = lens?.deviceType ?? .builtInWideAngleCamera
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            publishError("Unable to restore the camera after Portrait mode.")
            return
        }

        session.beginConfiguration()
        // Disabled *before* the input is swapped out, in both senses of order-dependence:
        // these properties can only be set to true while supported, and support disappears
        // with the virtual device — so clearing them last would be a no-op at best.
        photoOutput.isDepthDataDeliveryEnabled = false
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        photoOutput.enabledSemanticSegmentationMatteTypes = []
        // Back to the single-exposure priority manual mode requires — see
        // `configureSession`'s comment on why `.quality` undermines dialed-in exposure.
        photoOutput.maxPhotoQualityPrioritization = .speed

        if session.outputs.contains(where: { $0 === depthDataOutput }) {
            session.removeOutput(depthDataOutput)
        }
        if session.outputs.contains(where: { $0 === metadataOutput }) {
            metadataOutput.metadataObjectTypes = []
            session.removeOutput(metadataOutput)
        }

        swapInput(to: input)
        applyRotation(to: videoDataOutput.connection(with: .video), for: device)
        session.commitConfiguration()

        isPortraitConfigured = false
        activeDevice = device
        activeDeviceType = device.deviceType

        // Restore the zoom point the user was on before Portrait took over the input.
        if let lens {
            applyZoom(lens.ownZoomFactor, to: device)
        }

        DispatchQueue.main.async { [weak self] in
            // Cleared so a stale Portrait lens row can't linger into Manual, where zoom is driven by
            // discrete-lens presets instead.
            self?.portraitZoomOptions = []
            self?.currentPortraitZoom = nil
            self?.currentDevice = device
        }
    }

    /// Select a Portrait lens/zoom point. Only values the active format permits for depth delivery
    /// are accepted — anything else is dropped rather than risking the documented exception.
    ///
    /// Expect a brief stall: the SDK notes that changing zoom while depth delivery is enabled comes
    /// with "a disruptive reconfiguration of the capture render pipeline". That's unavoidable, and
    /// it's why these are discrete buttons rather than a continuous pinch or slider.
    func setPortraitZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, self.isPortraitConfigured, let device = self.activeDevice else { return }
            guard self.isZoomFactorDepthCapable(factor, on: device) else { return }
            // Belt-and-braces against `NSRangeException`: the depth ranges and the device's own
            // available zoom range are separate constraints, and `videoZoomFactor` throws on the latter.
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            self.applyZoom(clamped, to: device)
            DispatchQueue.main.async { self.currentPortraitZoom = clamped }
        }
    }

    /// Must be called on `sessionQueue`.
    ///
    /// Depth is only delivered over specific zoom ranges on a virtual device, and the SDK is explicit
    /// that with discrete ranges (e.g. `[2..2], [4..4]`) "any other zoom factor results in an
    /// exception". Membership is therefore checked, never assumed — no factor should reach
    /// `videoZoomFactor` in Portrait without passing through here.
    private func isZoomFactorDepthCapable(_ factor: CGFloat, on device: AVCaptureDevice) -> Bool {
        let depthRanges = device.activeFormat.supportedVideoZoomRangesForDepthDataDelivery
        guard !depthRanges.isEmpty else { return false }
        return depthRanges.contains { $0.contains(factor) }
    }

    /// Must be called on `sessionQueue`. Builds Portrait's lens row: the device's own **native** zoom
    /// points, filtered to those where depth is actually available.
    ///
    /// Native points come from the same places Manual mode's lens picker uses — the virtual device's
    /// `virtualDeviceSwitchOverVideoZoomFactors` (each constituent lens's true zoom, e.g. 2× and 5×)
    /// and the active format's `secondaryNativeResolutionZoomFactors` (a sensor-crop point, which is
    /// what surfaces "2×" on a 48MP main camera) — plus 1× and the device's minimum, which covers the
    /// ultra-wide. Nothing is hardcoded per device model.
    ///
    /// They're then intersected with `supportedVideoZoomRangesForDepthDataDelivery`, the authoritative
    /// answer to "which lenses can capture depth": a format with no depth formats returns an empty
    /// array, and the intersection is what keeps a non-depth-capable lens out of the row entirely.
    /// Sticking to native points also avoids digital upscaling — with depth delivery on, the SDK drops
    /// the upscale threshold to 1.0, so *any* non-native factor is a digital crop.
    private func buildPortraitZoomOptions(for device: AVCaptureDevice) -> [PortraitZoomOption] {
        let depthRanges = device.activeFormat.supportedVideoZoomRangesForDepthDataDelivery
        guard !depthRanges.isEmpty else { return [] }

        var candidates: [CGFloat] = [1.0, device.minAvailableVideoZoomFactor]
        candidates.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) })
        candidates.append(contentsOf: device.activeFormat.secondaryNativeResolutionZoomFactors)

        // Device-relative factors are normalized against the main lens for display — see
        // `wideAngleBaseZoomFactor(for:)`.
        let wideBase = wideAngleBaseZoomFactor(for: device)

        var options: [PortraitZoomOption] = []
        var used = Set<String>()
        for candidate in candidates.sorted() {
            guard depthRanges.contains(where: { $0.contains(candidate) }) else { continue }
            let option = PortraitZoomOption(zoomFactor: candidate, displayMultiplier: candidate / wideBase)
            // De-duplicated by displayed identity: a secondary-resolution factor can land on the same
            // visible value as a constituent lens's own, and two "2×" buttons would be nonsense. Same
            // problem `buildLensPresets` solves with `usedMillimeters`.
            guard used.insert(option.id).inserted else { continue }
            options.append(option)
        }

        // Safety net: if no native point falls inside a depth range, offer each range's minimum, so the
        // mode still has something selectable rather than an empty row.
        if options.isEmpty {
            for range in depthRanges {
                let option = PortraitZoomOption(zoomFactor: range.lowerBound, displayMultiplier: range.lowerBound / wideBase)
                if used.insert(option.id).inserted { options.append(option) }
            }
        }
        return options
    }

    /// The **device-relative** zoom factor at which the main wide-angle lens becomes active — the
    /// divisor that converts device zoom into the "1×" convention users expect.
    ///
    /// `videoZoomFactor` on a virtual device is measured from its *widest* constituent lens, so on a
    /// device with an ultra-wide, 1.0 is the ultra-wide and the 24mm main sits at 2.0. Labelling with
    /// the raw factor is what made the main lens read as "2×" and its 48mm crop as "4×".
    ///
    /// Derived, not hardcoded: the SDK guarantees `virtualDeviceSwitchOverVideoZoomFactors` has one
    /// fewer entry than `constituentDevices` and "the factors progress in the same order as the devices
    /// listed in that property" — so the lens at index *i* becomes active at switch-over factor
    /// *i − 1*, and the first constituent starts at 1.0. A device whose widest lens already *is* the
    /// wide-angle (e.g. `.builtInDualCamera`) therefore correctly yields 1.0 and needs no adjustment.
    private func wideAngleBaseZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        guard let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            return 1.0
        }
        guard wideIndex > 0 else { return 1.0 }
        let switchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors
        guard wideIndex - 1 < switchOverFactors.count else { return 1.0 }
        let base = CGFloat(truncating: switchOverFactors[wideIndex - 1])
        return base > 0 ? base : 1.0
    }

    /// Portrait deliberately hands focus/exposure/white balance back to the device: depth and
    /// matte generation are tuned around the camera's own auto behavior, and the manual engine
    /// stays out of the way for the duration (see `enterPortraitConfiguration`).
    private func applyContinuousAutoModes(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            // Configuration lock can fail transiently — the device keeps its current modes.
        }
    }

    /// The virtual multi-camera device, preferring the widest coverage available. Queried for
    /// *use* here (unlike `buildLensPresets`, which only reads its zoom numbers).
    private static func discoverVirtualDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: virtualDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices.first
    }

    /// Must be called on `sessionQueue`, within a begin/commit configuration batch.
    private func swapInput(to input: AVCaptureDeviceInput) {
        for existingInput in session.inputs {
            session.removeInput(existingInput)
        }
        if session.canAddInput(input) {
            session.addInput(input)
        }
    }

    private func applyZoom(_ factor: CGFloat, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            // Configuration lock can fail transiently — safe to drop.
        }
    }

    /// Switches to a different physical lens and/or zoom point. Swaps the session's
    /// `AVCaptureDeviceInput` only when the target is a different physical lens than
    /// the one currently active; either way, sets `videoZoomFactor` to the preset's
    /// own-device-relative value.
    func switchToLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Portrait owns the session input (the virtual device); lens presets are
            // meaningless there and swapping the input out from under it would silently break
            // depth delivery. The UI hides the lens row in Portrait — this is the backstop.
            guard !self.isPortraitConfigured else { return }

            let device: AVCaptureDevice
            let didSwitchDevice = self.activeDeviceType != lens.deviceType

            if didSwitchDevice {
                guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
                    self.publishError("That lens isn't available.")
                    return
                }
                guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                    self.publishError("Unable to switch lens.")
                    return
                }
                self.session.beginConfiguration()
                self.swapInput(to: newInput)
                // Swapping inputs recreates videoDataOutput's connection, resetting its
                // rotation angle — reapply within the same begin/commit batch.
                self.applyRotation(to: self.videoDataOutput.connection(with: .video), for: newDevice)
                self.session.commitConfiguration()
                device = newDevice
            } else if let existing = self.activeDevice {
                device = existing
            } else {
                return
            }

            self.applyZoom(lens.ownZoomFactor, to: device)

            self.activeDevice = device
            self.activeDeviceType = lens.deviceType
            self.activeLens = lens

            let rawSupported = !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
            let proRAWSupported = self.photoOutput.isAppleProRAWSupported
            let rawAvailableHere = self.evaluateRAWAvailability(on: device)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if didSwitchDevice { self.currentDevice = device }
                self.currentLens = lens
                self.isRAWSupported = rawSupported
                self.isAppleProRAWSupported = proRAWSupported
                self.isRAWAvailableAtCurrentLens = rawAvailableHere
            }
        }
    }

    /// Virtual multi-camera device types, queried *only* to read Apple's own exact
    /// per-lens zoom factors (never made the actual session input — see `CameraLens`'s
    /// doc comment for why).
    private static let virtualDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
    ]

    /// Must be called on `sessionQueue`. Discovers every back lens this device actually
    /// has (never hardcoded — a device without a telephoto simply won't offer one), plus
    /// any secondary native crop zoom points each individual lens supports
    /// (`AVCaptureDeviceFormat.secondaryNativeResolutionZoomFactors`) — e.g. a telephoto's
    /// own extra native zoom beyond its base optical magnification, which is what
    /// surfaces something like an "8×"/200mm option without guessing at any device's specs.
    private func buildLensPresets() -> [CameraLens] {
        let backLenses = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.backLensDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices

        // The virtual device reports each constituent lens's *exact* system-relative
        // zoom factor (e.g. 5.0 for a 5x tele) — far more precise than approximating via
        // a field-of-view ratio, which is what produced an imprecise "7.5x" for an "8x"
        // lens before.
        let virtualDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.virtualDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices.first
        let switchOverFactors = virtualDevice?.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) } ?? []
        let ultraWideSystemZoom = virtualDevice.map { CGFloat($0.minAvailableVideoZoomFactor) } ?? 1.0

        func systemBaseZoom(for deviceType: AVCaptureDevice.DeviceType) -> CGFloat {
            switch deviceType {
            case .builtInUltraWideCamera: return ultraWideSystemZoom
            case .builtInTelephotoCamera: return switchOverFactors.last ?? 1.0
            default: return 1.0
            }
        }

        var presets: [CameraLens] = []
        var usedMillimeters = Set<Int>()

        for device in backLenses {
            let baseZoom = systemBaseZoom(for: device.deviceType)
            let baseLens = CameraLens.make(deviceType: device.deviceType, ownZoomFactor: 1.0, systemZoom: baseZoom)
            presets.append(baseLens)
            usedMillimeters.insert(baseLens.millimeters)

            for factor in device.activeFormat.secondaryNativeResolutionZoomFactors {
                let ownZoom = CGFloat(truncating: factor as NSNumber)
                let lens = CameraLens.make(deviceType: device.deviceType, ownZoomFactor: ownZoom, systemZoom: baseZoom * ownZoom)
                guard !usedMillimeters.contains(lens.millimeters) else { continue }
                usedMillimeters.insert(lens.millimeters)
                presets.append(lens)
            }
        }
        return presets.sorted { $0 < $1 }
    }

    /// Must be called on `sessionQueue`.
    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            publishError("No back wide-angle camera available on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                publishError("Unable to add camera input.")
                return
            }
            session.addInput(input)
        } catch {
            publishError("Unable to open camera: \(error.localizedDescription)")
            return
        }

        // .quality explicitly opts into multi-frame fusion (Smart HDR/Deep Fusion-style
        // processing per Apple's own docs) — the fused output's EXIF can then reflect
        // whatever exposure the fusion pipeline actually blended, not the exact
        // ISO/shutter this app locked in. .speed forces a true single-exposure capture,
        // which is what a manual camera app's "what you dial in is what you get" needs.
        photoOutput.maxPhotoQualityPrioritization = .speed
        guard session.canAddOutput(photoOutput) else {
            publishError("Unable to add photo output.")
            return
        }
        session.addOutput(photoOutput)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        applyRotation(to: videoDataOutput.connection(with: .video), for: device)

        let rawSupported = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let proRAWSupported = photoOutput.isAppleProRAWSupported
        let rawAvailableHere = evaluateRAWAvailability(on: device)
        let lenses = buildLensPresets()
        let initialLens = lenses.first { $0.deviceType == device.deviceType && $0.ownZoomFactor == 1.0 } ?? lenses.first
        let portraitSupported = Self.discoverVirtualDevice() != nil

        isConfigured = true
        activeDevice = device
        activeDeviceType = device.deviceType
        activeLens = initialLens

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRAWSupported = rawSupported
            self.isAppleProRAWSupported = proRAWSupported
            self.isRAWAvailableAtCurrentLens = rawAvailableHere
            self.availableLenses = lenses
            self.currentLens = initialLens
            // Assigned before `currentDevice` on purpose: the coordinator's `$currentDevice`
            // subscription reads `isPortraitModeSupported` to decide whether a persisted
            // Portrait mode can actually be restored on this hardware.
            self.isPortraitModeSupported = portraitSupported
            self.currentDevice = device
        }
    }

    /// Must be called on `sessionQueue`, within a begin/commit configuration batch.
    /// `AVCaptureVideoDataOutput` delivers frames in the sensor's native (landscape)
    /// orientation by default — unlike `AVCaptureVideoPreviewLayer`, which auto-rotates
    /// its own contents, video data output buffers need an explicit rotation angle or
    /// FocusPeakingProcessor's overlay comes out sideways relative to the portrait
    /// preview it's composited over. Uses the modern `AVCaptureDevice.RotationCoordinator`
    /// (iOS 17+) rather than a hardcoded angle, since the correct value can differ by
    /// device/camera position.
    ///
    /// Also applied to the depth connection for the same reason — Portrait's depth overlay is
    /// composited over the same portrait preview. `isVideoRotationAngleSupported` is the guard:
    /// if a depth connection doesn't accept rotation, this no-ops rather than throwing, and the
    /// fallback would be to orient the `CIImage` in `DepthPreviewProcessor` instead.
    private func applyRotation(to connection: AVCaptureConnection?, for device: AVCaptureDevice) {
        guard let connection else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.setupError = message }
    }
}
