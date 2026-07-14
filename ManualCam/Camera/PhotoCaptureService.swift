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

    private let photoOutput: AVCapturePhotoOutput
    private var appleProRAWEnabled = false

    /// One capture in flight always yields exactly one `didFinishProcessingPhoto`
    /// callback now that HEIC and RAW are mutually exclusive (no more twin capture),
    /// but state still needs to survive until `didFinishCaptureFor` in case that ever
    /// changes, so it's still tracked per-`uniqueID` rather than a single shared var.
    private struct InFlightCapture {
        var data: Data?
        var isRAW = false
    }
    /// `AVCapturePhotoCaptureDelegate` callbacks land on an AVFoundation-internal queue,
    /// concurrent with `capturePhoto(format:)` calls from the main thread — all access
    /// to this state goes through `stateLock`, so it's exempted from actor isolation.
    nonisolated(unsafe) private var inFlightCaptures: [Int64: InFlightCapture] = [:]
    nonisolated(unsafe) private let stateLock = NSLock()

    init(photoOutput: AVCapturePhotoOutput) {
        self.photoOutput = photoOutput
    }

    func dismissError() {
        lastCaptureError = nil
    }

    func setAppleProRAWEnabled(_ enabled: Bool) {
        guard photoOutput.isAppleProRAWSupported else { return }
        photoOutput.isAppleProRAWEnabled = enabled
        appleProRAWEnabled = enabled
    }

    func capturePhoto(format: CaptureFormat) {
        let settings: AVCapturePhotoSettings

        switch format {
        case .heic:
            settings = AVCapturePhotoSettings()
        case .raw:
            if let rawFormat = preferredRawPixelFormatType() {
                // No processedFormat — a RAW-only capture, not a twin shot.
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            } else {
                // This lens doesn't support RAW — fall back to HEIC rather than fail.
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

    private func preferredRawPixelFormatType() -> OSType? {
        if appleProRAWEnabled, photoOutput.isAppleProRAWSupported {
            return photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                ?? photoOutput.availableRawPhotoPixelFormatTypes.first
        }
        return photoOutput.availableRawPhotoPixelFormatTypes.first
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
        stateLock.lock()
        inFlightCaptures[photo.resolvedSettings.uniqueID] = InFlightCapture(
            data: photo.fileDataRepresentation(),
            isRAW: photo.isRawPhoto
        )
        stateLock.unlock()
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
            DispatchQueue.main.async { [weak self] in self?.lastCaptureError = error.localizedDescription }
            return
        }
        guard let data = context?.data else { return }
        save(data: data, isRAW: context?.isRAW ?? false)
    }
}
