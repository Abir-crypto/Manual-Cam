import AVFoundation
import Combine

/// Single source of truth for manual camera controls (ISO, shutter, focus, white balance,
/// exposure bias) on the active `AVCaptureDevice`. Both on-screen sliders and the Camera
/// Control hardware dial (Task 12) drive their changes through this engine.
///
/// Opts out of the module's default MainActor isolation: device configuration is
/// dispatched onto the session queue, and only hops to main to publish UI-facing state.
nonisolated final class ManualControlEngine: ObservableObject {
    @Published private(set) var ranges = ManualControlRanges.fallback

    @Published var iso: Float = 100
    @Published var exposureDuration = CMTime(value: 1, timescale: 125)
    @Published var lensPosition: Float = 0.5
    @Published var whiteBalanceKelvin: Double = 5600

    /// Why the manual controls are currently frozen — see `isLocked`. Modeled as a *set* of
    /// independent reasons rather than one Bool because there are two unrelated owners, and a
    /// shared Bool would let either one clear the other's lock: a Multi-Shot Timer run ending
    /// would unfreeze the controls even if Portrait mode still needed them frozen.
    enum LockReason: Hashable {
        /// A Multi-Shot Timer sequence is running (`MULTI_SHOT_TIMER.md`, Task 1: "current
        /// manual settings are locked at the moment Start is tapped and used unchanged for
        /// every shot").
        case captureRun
        /// Portrait mode is active (`PORTRAIT_MODE.md`, Task 1: manual controls are hidden).
        /// Portrait runs on the virtual multi-camera device in continuous auto modes, and this
        /// engine must not fight that — nor call `setFocusModeLocked(lensPosition:)` on a
        /// device that doesn't support it (the documented crash — see `CameraLens`).
        case portraitMode
    }

    @Published private(set) var lockReasons: Set<LockReason> = []

    /// True while anything owns the controls. Every public setter no-ops while set, so the
    /// values in effect stay exactly what they were.
    ///
    /// This is enforced in the engine rather than the UI because the UI isn't the only input
    /// path: the Camera Control hardware bar (base spec Task 12) and its light-press handler
    /// drive these setters *directly*, bypassing any overlay or hidden view — on Camera
    /// Control hardware a nudge of the dial would otherwise change exposure mid-timer-run, or
    /// poke manual values at a Portrait session that has no business receiving them.
    var isLocked: Bool { !lockReasons.isEmpty }

    /// Center of the frame in `AVCaptureDevice` point-of-interest space (which is
    /// normalized 0...1, origin top-left of the *sensor* in landscape).
    static let centerPointOfInterest = CGPoint(x: 0.5, y: 0.5)

    private weak var device: AVCaptureDevice?
    private let queue: DispatchQueue

    /// KVO tokens for tap-to-reset's "wait for auto adjustments to settle" observation
    /// (see `tapToReset(at:)`). Retained here since `NSKeyValueObservation` invalidates
    /// on dealloc; guarded by `tapResetLock` since the change handlers can land on
    /// whatever internal AVFoundation thread fires the KVO notification, not necessarily
    /// `queue`.
    private var tapResetObservations: [NSKeyValueObservation] = []
    private let tapResetLock = NSLock()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Call whenever the active device changes — initial configure, app resume, or a
    /// lens switch (Task 12-adjacent lens picker). Re-queries ranges for the new device
    /// and re-applies the engine's *current* values (clamped) to it, so switching lenses
    /// doesn't silently drop back to that lens's own auto-exposure/auto-everything state.
    func attach(device: AVCaptureDevice) {
        self.device = device
        refreshRanges(for: device)
        applyCurrentValues(to: device)
    }

    func refreshRanges(for device: AVCaptureDevice) {
        let format = device.activeFormat
        ranges = ManualControlRanges(
            isoRange: format.minISO...format.maxISO,
            exposureDurationRange: format.minExposureDuration...format.maxExposureDuration,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain
        )
    }

    // MARK: - Setters

    /// Freeze (or release) the manual controls on behalf of one owner — see `isLocked`.
    /// Reasons are independent: the controls stay frozen until *every* owner has released.
    /// Call on main, like every other `@Published` mutation here.
    func setLocked(_ locked: Bool, for reason: LockReason) {
        if locked {
            lockReasons.insert(reason)
        } else {
            lockReasons.remove(reason)
        }
    }

    /// Sets ISO while preserving the device's current shutter duration.
    func setISO(_ iso: Float) {
        guard !isLocked else { return }
        let clamped = clampedISO(iso)
        self.iso = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyExposure(on: device, iso: clamped, duration: nil)
        }
    }

    /// Sets shutter speed while preserving the device's current ISO.
    func setExposureDuration(_ duration: CMTime) {
        guard !isLocked else { return }
        let clamped = clampedDuration(duration)
        self.exposureDuration = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyExposure(on: device, iso: nil, duration: clamped)
        }
    }

    func setLensPosition(_ position: Float) {
        guard !isLocked else { return }
        let clamped = min(max(position, ManualControlRanges.lensPositionRange.lowerBound), ManualControlRanges.lensPositionRange.upperBound)
        self.lensPosition = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.withLockedConfiguration(on: device) {
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                }
            }
        }
    }

    func setWhiteBalanceKelvin(_ kelvin: Double) {
        guard !isLocked else { return }
        let clamped = min(max(kelvin, ManualControlRanges.kelvinRange.lowerBound), ManualControlRanges.kelvinRange.upperBound)
        self.whiteBalanceKelvin = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let gains = WhiteBalanceConverter.gains(forKelvin: clamped, device: device)
            self.withLockedConfiguration(on: device) {
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }
        }
    }

    /// "Tap to auto-focus/expose/white-balance at a point, then keep it as the new
    /// manual baseline" — standard point-and-shoot behavior layered on top of this
    /// app's always-manual control model. `devicePoint` must already be in
    /// `AVCaptureDevice` point-of-interest space (`CameraPreviewView` converts the raw
    /// tap location via `captureDevicePointConverted(fromLayerPoint:)` before calling
    /// this). Switches focus/exposure/white balance to their one-shot auto modes
    /// pointed at `devicePoint`, waits for the device to finish adjusting, then reads
    /// back wherever it settled and re-locks those exact values as the new manual
    /// ISO/shutter/focus/white-balance — so the next slider drag continues from that
    /// point instead of the values from before the tap.
    func tapToReset(at devicePoint: CGPoint) {
        // A tap-to-reset would re-meter the scene mid-run and break the "same exposure for
        // every shot in the set" guarantee, so it's frozen along with the sliders.
        guard !isLocked else { return }
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }

            self.withLockedConfiguration(on: device) {
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                }
            }

            self.waitForAutoAdjustments(on: device) { [weak self] in
                self?.queue.async { self?.lockInSettledValues(on: device) }
            }
        }
    }

    /// Center-frame equivalent of `tapToReset(at:)`: let the device meter the scene with
    /// its own auto exposure/focus/white balance, then lock wherever it settled in as the
    /// manual starting point.
    ///
    /// This is SPEC.md Task 11's "if persistence is disabled, fall back to the device's
    /// auto-exposure/auto-focus defaults on launch, letting the user start from a metered
    /// baseline" — previously launch always began at this engine's hardcoded in-memory
    /// defaults (ISO 100 / 1÷125 / lens 0.5 / 5600K) no matter what the scene actually
    /// was, because `attach(device:)` applies those unconditionally.
    func resetToMeteredBaseline() {
        tapToReset(at: Self.centerPointOfInterest)
    }

    /// Reads back wherever auto focus/exposure/white balance settled after
    /// `tapToReset(at:)` and re-locks the device to those exact values (custom
    /// exposure, locked focus, locked white balance), then publishes them so sliders
    /// reflect the new baseline. Must run on `queue`.
    private func lockInSettledValues(on device: AVCaptureDevice) {
        let settledISO = clampedISO(device.iso)
        let settledDuration = clampedDuration(device.exposureDuration)
        let settledLensPosition = device.lensPosition
        let settledKelvin = WhiteBalanceConverter.kelvin(forGains: device.deviceWhiteBalanceGains, device: device)

        withLockedConfiguration(on: device) {
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: settledDuration, iso: settledISO, completionHandler: nil)
            }
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: settledLensPosition, completionHandler: nil)
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                let gains = WhiteBalanceConverter.gains(forKelvin: settledKelvin, device: device)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iso = settledISO
            self.exposureDuration = settledDuration
            self.lensPosition = settledLensPosition
            self.whiteBalanceKelvin = settledKelvin
        }
    }

    /// Observes `isAdjustingFocus`/`isAdjustingExposure`/`isAdjustingWhiteBalance` for a
    /// genuine adjusting → settled transition, then calls `completion` exactly once.
    ///
    /// Deliberately does *not* treat "not adjusting" as "already settled" the instant
    /// the observers attach — the hardware doesn't flip these flags to `true`
    /// synchronously when the auto modes are set in `tapToReset(at:)`, so an immediate
    /// settled-check almost always wins the race before any scan has even started,
    /// reading back the pre-tap values as if nothing needed to change (confirmed bug:
    /// this produced exactly that — a tap that showed the reticle but never actually
    /// moved focus/exposure/white balance or the sliders). Instead this waits for at
    /// least one of the three to report "adjusting" and then settle back to `false`. A
    /// 0.35s grace period covers the case where nothing ever needs to adjust (e.g.
    /// point-of-interest unsupported at this position, or the scene needs no
    /// correction), so the tap still resolves into a baseline instead of waiting for a
    /// transition that will never come. A 2s hard safety net covers a scan that starts
    /// but never fully settles (e.g. continuous low-light exposure hunting).
    private func waitForAutoAdjustments(on device: AVCaptureDevice, completion: @escaping () -> Void) {
        tapResetLock.lock()
        tapResetObservations.forEach { $0.invalidate() }
        tapResetObservations.removeAll()
        tapResetLock.unlock()

        var didComplete = false
        var hasSeenAdjusting = false

        func isAdjusting() -> Bool {
            device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance
        }

        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.tapResetLock.lock()
            let shouldRun = !didComplete
            didComplete = true
            if shouldRun {
                self.tapResetObservations.forEach { $0.invalidate() }
                self.tapResetObservations.removeAll()
            }
            self.tapResetLock.unlock()
            if shouldRun { completion() }
        }

        let handler: (AVCaptureDevice, NSKeyValueObservedChange<Bool>) -> Void = { _, _ in
            if isAdjusting() {
                hasSeenAdjusting = true
            } else if hasSeenAdjusting {
                finish()
            }
        }

        tapResetLock.lock()
        tapResetObservations = [
            device.observe(\.isAdjustingFocus, changeHandler: handler),
            device.observe(\.isAdjustingExposure, changeHandler: handler),
            device.observe(\.isAdjustingWhiteBalance, changeHandler: handler),
        ]
        tapResetLock.unlock()

        queue.asyncAfter(deadline: .now() + 0.35) {
            if !hasSeenAdjusting { finish() }
        }
        queue.asyncAfter(deadline: .now() + 2.0, execute: finish)
    }

    /// Restores a full set of persisted/default values in one pass (Task 11).
    func restore(_ state: PersistedCameraState) {
        iso = state.iso
        exposureDuration = state.exposureDuration
        lensPosition = state.lensPosition
        whiteBalanceKelvin = state.whiteBalanceKelvin
        guard let device else { return }
        applyCurrentValues(to: device)
    }

    var currentPersistedState: PersistedCameraState {
        PersistedCameraState(
            iso: iso,
            exposureDuration: exposureDuration,
            lensPosition: lensPosition,
            whiteBalanceKelvin: whiteBalanceKelvin
        )
    }

    // MARK: - Device application (must run on `queue`)

    /// Pushes the engine's current in-memory values onto `device` — used both to restore
    /// persisted values (Task 11) and to carry the current manual settings across a lens
    /// switch. Values are captured before dispatching so the closure doesn't read
    /// `@Published` state from the background queue.
    private func applyCurrentValues(to device: AVCaptureDevice) {
        let targetISO = iso
        let targetDuration = exposureDuration
        let targetLensPosition = lensPosition
        let targetKelvin = whiteBalanceKelvin
        queue.async { [weak self] in
            guard let self else { return }
            self.applyExposure(on: device, iso: targetISO, duration: targetDuration)
            let gains = WhiteBalanceConverter.gains(forKelvin: targetKelvin, device: device)
            self.withLockedConfiguration(on: device) {
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: targetLensPosition, completionHandler: nil)
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }
        }
    }

    /// ISO and shutter share one call — read the device's current value for whichever side isn't changing.
    private func applyExposure(on device: AVCaptureDevice, iso: Float?, duration: CMTime?) {
        guard device.isExposureModeSupported(.custom) else { return }
        let finalISO = clampedISO(iso ?? device.iso)
        let finalDuration = clampedDuration(duration ?? device.exposureDuration)
        withLockedConfiguration(on: device) {
            device.setExposureModeCustom(duration: finalDuration, iso: finalISO, completionHandler: nil)
        }
    }

    private func withLockedConfiguration(on device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            // Configuration lock can fail transiently (e.g. device mid-reconfiguration) — safe to drop.
        }
    }

    private func clampedISO(_ value: Float) -> Float {
        min(max(value, ranges.isoRange.lowerBound), ranges.isoRange.upperBound)
    }

    private func clampedDuration(_ value: CMTime) -> CMTime {
        if value < ranges.exposureDurationRange.lowerBound { return ranges.exposureDurationRange.lowerBound }
        if value > ranges.exposureDurationRange.upperBound { return ranges.exposureDurationRange.upperBound }
        return value
    }
}
