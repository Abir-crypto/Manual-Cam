import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import Combine

/// Wraps `AVCapturePhotoOutput` capture: builds HEIC-or-RAW settings (mutually
/// exclusive, no twin capture — see `CaptureFormat`), and saves the result to the
/// app's dedicated album, publishing a confirmation thumbnail for the UI (Task 5).
final class PhotoCaptureService: NSObject, ObservableObject {
    @Published private(set) var lastCaptureThumbnail: UIImage?
    @Published private(set) var lastCaptureError: String?
    /// What the most recent Portrait capture delivered (`PORTRAIT_MODE.md` Task 2). Nil until
    /// the first Portrait shot of the session.
    @Published private(set) var lastPortraitDiagnostics: PortraitCaptureDiagnostics?
    /// True while a Portrait shot is being rendered (`PORTRAIT_MODE.md` Task 4: "there will be a
    /// brief 'processing' state on the thumbnail ... since this isn't instant like a normal HEIC
    /// capture"). The bokeh render is seconds of Core Image work on a full-resolution frame.
    @Published private(set) var isRenderingPortrait = false

    private let photoOutput: AVCapturePhotoOutput

    /// Supplies the gravity-relative angle that makes a capture horizon-level, or nil if it isn't
    /// known yet. Injected as a closure rather than reached for through a reference to
    /// `CameraSessionManager` so this type keeps depending on nothing but its own output — the angle
    /// is tracked in `CameraSessionManager.startTrackingHorizonLevelRotation(for:)`, which owns the
    /// device and the retained `AVCaptureDevice.RotationCoordinator`.
    private let horizonLevelRotationAngle: @MainActor () -> CGFloat?

    /// Portrait render settings, snapshotted per shot from the coordinator (see
    /// `capturePortraitPhoto(blurIntensity:style:)`) so a slider moved while a render is in flight
    /// can't change the frame already being processed.
    nonisolated(unsafe) private let renderer = PortraitRenderer()
    /// Bokeh rendering is heavy, full-resolution Core Image work — it runs here rather than on the
    /// delegate's own queue so it can't stall subsequent capture callbacks. No `nonisolated(unsafe)`
    /// needed despite being read from nonisolated delegate callbacks: an immutable `let` of a
    /// `Sendable` type is already reachable from any context.
    private let renderQueue = DispatchQueue(label: "com.manualcam.portraitRenderQueue", qos: .userInitiated)

    /// One capture in flight always yields exactly one `didFinishProcessingPhoto`
    /// callback now that HEIC and RAW are mutually exclusive (no more twin capture),
    /// but state still needs to survive until `didFinishCaptureFor` in case that ever
    /// changes, so it's still tracked per-`uniqueID` rather than a single shared var.
    private struct InFlightCapture {
        var data: Data?
        var isRAW = false
        /// Portrait captures report what depth/matte data actually arrived — see
        /// `PortraitCaptureDiagnostics`. Nil for ordinary Manual captures.
        var portraitDiagnostics: PortraitCaptureDiagnostics?
        /// Render settings snapshotted at shutter time and carried with the shot, so moving the
        /// blur slider or changing style during a multi-second render can't retroactively change
        /// the frame already being processed. Nil for ordinary Manual captures.
        var portraitBlurIntensity: Double?
        var portraitStyle: FilmStyle?
        /// Retained so the render can run in `didFinishCaptureFor`, after the capture pipeline has
        /// finished with the shot, rather than blocking the processing callback.
        var portraitPhoto: AVCapturePhoto?
    }
    /// `AVCapturePhotoCaptureDelegate` callbacks land on an AVFoundation-internal queue,
    /// concurrent with `capturePhoto(format:)` calls from the main thread — all access
    /// to this state goes through `stateLock`, so it's exempted from actor isolation.
    nonisolated(unsafe) private var inFlightCaptures: [Int64: InFlightCapture] = [:]
    nonisolated(unsafe) private let stateLock = NSLock()

    init(photoOutput: AVCapturePhotoOutput, horizonLevelRotationAngle: @escaping @MainActor () -> CGFloat?) {
        self.photoOutput = photoOutput
        self.horizonLevelRotationAngle = horizonLevelRotationAngle
    }

    /// Orients the next capture to gravity rather than to the interface.
    ///
    /// **Why this is needed at all:** the interface is locked to portrait, and a photo output
    /// connection does not track device rotation on its own — it keeps whatever angle it was last
    /// given (its default, which corresponds to the portrait interface). So every shot taken with the
    /// phone physically rotated was saved rotated, instead of upright the way the stock Camera app
    /// saves it. There is no per-shot rotation on `AVCapturePhotoSettings`; the connection is the only
    /// lever, which is why this is a mutation immediately before `capturePhoto(with:delegate:)` rather
    /// than part of the settings object.
    ///
    /// **Called from every capture entry point, which is every capture in the app.** Manual, Portrait,
    /// and the Multi-Shot Timer all funnel through the two methods below, and `ASTRO_MODE.md` has its
    /// stacking engine firing this same service sequentially, so Astro inherits this when it's built.
    /// A timer run re-reads the angle per shot on purpose: settings are frozen for a run, but how the
    /// phone is *held* isn't a setting, and a run can span minutes on a tripod being repositioned.
    ///
    /// Reading the angle here — synchronously, at shutter time — is the point. Sampling it on a
    /// rotation notification and storing it would reintroduce the same class of bug from the other
    /// side: the value applied would be whatever arrived last, not the orientation at the moment of
    /// the shot.
    ///
    /// `isVideoRotationAngleSupported` is a required guard, not defensiveness: assigning an
    /// unsupported angle throws `NSInvalidArgumentException`.
    private func applyHorizonLevelRotation() {
        guard let angle = horizonLevelRotationAngle(),
              let connection = photoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func dismissError() {
        lastCaptureError = nil
    }

    /// `videoZoomFactor` is the zoom currently applied to the active device — required, not optional,
    /// because Bayer RAW is only legal at 1.0 and requesting it while zoomed throws
    /// `NSInvalidArgumentException`. See `RAWPixelFormatRule`.
    func capturePhoto(format: CaptureFormat, videoZoomFactor: CGFloat) {
        applyHorizonLevelRotation()

        let settings: AVCapturePhotoSettings

        switch format {
        case .heic:
            settings = AVCapturePhotoSettings()
        case .raw, .appleProRAW:
            if let rawFormat = preferredRawPixelFormatType(
                videoZoomFactor: videoZoomFactor,
                preferAppleProRAW: format.prefersAppleProRAW
            ) {
                // No processedFormat — a RAW-only capture, not a twin shot.
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            } else {
                // No legal RAW format in the current configuration — fall back to HEIC rather than
                // fail. Reached either when the lens offers no RAW at all, or when the only RAW on
                // offer is Bayer and the device is zoomed (a sensor-crop preset like 2×/8× with
                // ProRAW off). `CameraSessionManager.isRAWAvailableAtCurrentLens` surfaces this in
                // the UI *before* the shutter, so the fallback isn't a silent surprise.
                settings = AVCapturePhotoSettings()
            }
        }

        // .speed forces a true single-exposure capture — .quality opts into multi-frame
        // fusion whose EXIF can drift from the exact manually-set ISO/shutter (see
        // CameraSessionManager.configureSession's maxPhotoQualityPrioritization comment).
        settings.photoQualityPrioritization = .speed
        stateLock.lock()
        inFlightCaptures[settings.uniqueID] = InFlightCapture()
        stateLock.unlock()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// A Portrait-mode capture (`PORTRAIT_MODE.md` Task 2): a normal HEIC, plus depth data, the
    /// portrait effects matte, and the `.skin` semantic segmentation matte requested alongside
    /// it. Task 5/6's bokeh render and Task 7's two-file save aren't built yet, so for now the
    /// capture is saved as a single HEIC with all of that **embedded** — which keeps the data
    /// inspectable in Photos and re-processable once the render pipeline lands.
    ///
    /// Every request is conditional on the output's matching `is…DeliveryEnabled` flag, which
    /// `CameraSessionManager.enterPortraitConfiguration()` sets: asking a settings object for
    /// delivery the output hasn't enabled throws `NSInvalidArgumentException`. Anything the
    /// device declines simply doesn't get requested, which is Task 2's graceful degradation.
    func capturePortraitPhoto(blurIntensity: Double, style: FilmStyle) {
        applyHorizonLevelRotation()

        let settings = AVCapturePhotoSettings()

        // Unlike Manual's `.speed` (which protects dialed-in exposure from multi-frame fusion),
        // Portrait is auto-exposed and wants the fuller pipeline that produces the mattes. The
        // output's `maxPhotoQualityPrioritization` is raised to match while Portrait is active —
        // exceeding that maximum throws.
        settings.photoQualityPrioritization = .quality

        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
        }
        if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
            settings.isPortraitEffectsMatteDeliveryEnabled = true
            settings.embedsPortraitEffectsMatteInPhoto = true
        }
        let skinMatteTypes = photoOutput.enabledSemanticSegmentationMatteTypes.filter { $0 == .skin }
        settings.enabledSemanticSegmentationMatteTypes = skinMatteTypes
        settings.embedsSemanticSegmentationMattesInPhoto = !skinMatteTypes.isEmpty

        stateLock.lock()
        inFlightCaptures[settings.uniqueID] = InFlightCapture(
            portraitDiagnostics: PortraitCaptureDiagnostics(),
            portraitBlurIntensity: blurIntensity,
            portraitStyle: style
        )
        stateLock.unlock()
        isRenderingPortrait = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func preferredRawPixelFormatType(videoZoomFactor: CGFloat, preferAppleProRAW: Bool) -> OSType? {
        RAWPixelFormatRule.preferredPixelFormat(
            availableFormats: photoOutput.availableRawPhotoPixelFormatTypes,
            preferAppleProRAW: preferAppleProRAW && photoOutput.isAppleProRAWSupported,
            videoZoomFactor: videoZoomFactor
        )
    }

    nonisolated private func save(data: Data, isRAW: Bool) {
        // RAW must be added to the asset via a file URL, not `data:` — the `data:`
        // overload of addResource(with:data:options:) is a documented-broken path for
        // RAW/DNG resources (confirmed via real-world reports: creation reliably fails
        // with PHPhotosErrorChangeNotSupported (3300) when added from Data, and
        // reliably succeeds when added from a file URL). HEIC is unaffected and stays
        // Data-based.
        var rawTempURL: URL?
        if isRAW {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
            do {
                try data.write(to: url)
                rawTempURL = url
            } catch {
                DispatchQueue.main.async { [weak self] in self?.lastCaptureError = "Couldn't stage RAW file: \(error.localizedDescription)" }
                return
            }
        }

        PhotoAlbumManager.shared.fetchOrCreateAlbum { [weak self] result in
            guard let self else { return }
            let collection: PHAssetCollection
            switch result {
            case .success(let value):
                collection = value
            case .failure(let error):
                if let rawTempURL { try? FileManager.default.removeItem(at: rawTempURL) }
                DispatchQueue.main.async { self.lastCaptureError = error.localizedDescription }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                if let rawTempURL {
                    options.uniformTypeIdentifier = UTType.dng.identifier
                    options.shouldMoveFile = true
                    request.addResource(with: .photo, fileURL: rawTempURL, options: options)
                } else {
                    options.uniformTypeIdentifier = UTType.heic.identifier
                    request.addResource(with: .photo, data: data, options: options)
                }
                if let albumRequest = PHAssetCollectionChangeRequest(for: collection),
                   let placeholder = request.placeholderForCreatedAsset {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { [weak self] success, error in
                // shouldMoveFile only consumes the temp file on success; clean up
                // ourselves on failure so it doesn't linger.
                if !success, let rawTempURL { try? FileManager.default.removeItem(at: rawTempURL) }
                DispatchQueue.main.async {
                    if !success {
                        self?.lastCaptureError = error?.localizedDescription ?? "Failed to save photo."
                    }
                }
            }
        }

        // ImageIO can read a DNG's embedded preview directly, so this works for both
        // HEIC and RAW captures as a confirmation thumbnail.
        if let image = UIImage(data: data) {
            DispatchQueue.main.async { [weak self] in self?.lastCaptureThumbnail = image }
        }
    }
}

extension PhotoCaptureService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil else { return }
        let uniqueID = photo.resolvedSettings.uniqueID

        // Whether this was a Portrait capture is only knowable from the entry `capturePortraitPhoto`
        // seeded — `AVCapturePhoto` itself doesn't say. Read under the lock, then do the actual
        // (potentially slow) data extraction outside it.
        stateLock.lock()
        let pending = inFlightCaptures[uniqueID]
        stateLock.unlock()

        let isPortraitCapture = pending?.portraitDiagnostics != nil
        let diagnostics: PortraitCaptureDiagnostics? = isPortraitCapture
            ? PortraitCaptureDiagnostics(
                hasDepthData: photo.depthData != nil,
                hasPortraitMatte: photo.portraitEffectsMatte != nil,
                hasSkinMatte: photo.semanticSegmentationMatte(for: .skin) != nil
            )
            : nil
        let data = photo.fileDataRepresentation()

        stateLock.lock()
        // The render settings from the shutter press are carried forward deliberately — this
        // callback replaces the whole entry, and dropping them would silently turn a styled
        // Portrait shot into a plain unprocessed save.
        inFlightCaptures[uniqueID] = InFlightCapture(
            data: data,
            isRAW: photo.isRawPhoto,
            portraitDiagnostics: diagnostics,
            portraitBlurIntensity: pending?.portraitBlurIntensity,
            portraitStyle: pending?.portraitStyle,
            portraitPhoto: isPortraitCapture ? photo : nil
        )
        stateLock.unlock()

        if let diagnostics {
            DispatchQueue.main.async { [weak self] in self?.lastPortraitDiagnostics = diagnostics }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        stateLock.lock()
        let context = inFlightCaptures.removeValue(forKey: resolvedSettings.uniqueID)
        stateLock.unlock()

        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.lastCaptureError = error.localizedDescription
                self?.isRenderingPortrait = false
            }
            return
        }
        guard let data = context?.data else {
            DispatchQueue.main.async { [weak self] in self?.isRenderingPortrait = false }
            return
        }

        if let photo = context?.portraitPhoto {
            renderPortrait(
                photo: photo,
                originalData: data,
                blurIntensity: context?.portraitBlurIntensity ?? 0.5,
                style: context?.portraitStyle ?? .natural
            )
            return
        }

        save(data: data, isRAW: context?.isRAW ?? false)
    }

    /// Renders the bokeh + style and saves **one** asset: the finished Portrait photo.
    ///
    /// **Deviation from `PORTRAIT_MODE.md` Task 7, per explicit user request (2026-08-11): "save one
    /// photo for portrait images. Only the portrait image."** The spec asks for two files per shot —
    /// the styled result plus the untouched original archived for later re-processing — and that's
    /// what this did until now. Don't reinstate the archive without asking; it doubles the album's
    /// asset count, which is the visible cost the user was reacting to.
    ///
    /// `originalData` is still carried in, but now only as the safety net: if the render fails the
    /// unprocessed capture is saved in its place, because a broken effect must never cost the shot.
    /// Either way exactly one photo reaches the album, and the thumbnail shows whatever was saved.
    nonisolated private func renderPortrait(
        photo: AVCapturePhoto,
        originalData: Data,
        blurIntensity: Double,
        style: FilmStyle
    ) {
        renderQueue.async { [weak self] in
            guard let self else { return }

            let rendered = self.renderer.render(photo: photo, blurIntensity: blurIntensity, style: style)
            if let rendered {
                self.save(data: rendered.data, isRAW: false)
                // Fold what the render managed into the shot's diagnostics, so "depth arrived but
                // no blur came out" is visible on screen instead of looking like a working render.
                DispatchQueue.main.async {
                    self.lastPortraitDiagnostics?.didApplyBokeh = rendered.didApplyBokeh
                }
            } else {
                // Render failed — keep the shot by saving the unprocessed frame, and say so rather
                // than leaving an unexplained ordinary-looking photo in the album.
                self.save(data: originalData, isRAW: false)
                DispatchQueue.main.async {
                    self.lastCaptureError = "Couldn't render the Portrait effect — saved the unprocessed photo instead."
                }
            }
            DispatchQueue.main.async { self.isRenderingPortrait = false }
        }
    }
}
