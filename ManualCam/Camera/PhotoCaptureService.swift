import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import Combine

/// Wraps `AVCapturePhotoOutput` capture: builds RAW+HEIC twin-capture settings,
/// saves both representations to the app's dedicated album, and publishes a
/// confirmation thumbnail for the UI (Task 5).
final class PhotoCaptureService: NSObject, ObservableObject {
    @Published private(set) var lastCaptureThumbnail: UIImage?
    @Published private(set) var lastCaptureError: String?

    private let photoOutput: AVCapturePhotoOutput
    private var appleProRAWEnabled = false

    /// Per-in-flight-capture accumulator, keyed by `uniqueID`, since RAW and processed
    /// representations arrive via separate `didFinishProcessingPhoto` calls.
    private struct InFlightCapture {
        var processedData: Data?
        var rawData: Data?
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
        var settings: AVCapturePhotoSettings

        if format.includesRAW,
           let rawFormat = preferredRawPixelFormatType(),
           let processedFormat = photoOutput.availablePhotoCodecTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: [AVVideoCodecKey: processedFormat])
        } else {
            settings = AVCapturePhotoSettings()
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

    nonisolated private func save(processedData: Data?, rawData: Data?) {
        PhotoAlbumManager.shared.fetchOrCreateAlbum { [weak self] result in
            guard let self else { return }
            let collection: PHAssetCollection
            switch result {
            case .success(let value):
                collection = value
            case .failure(let error):
                DispatchQueue.main.async { self.lastCaptureError = error.localizedDescription }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let processedData {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = UTType.heic.identifier
                    request.addResource(with: .photo, data: processedData, options: options)
                }
                if let rawData {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = UTType.dng.identifier
                    request.addResource(with: .alternatePhoto, data: rawData, options: options)
                }
                if let albumRequest = PHAssetCollectionChangeRequest(for: collection),
                   let placeholder = request.placeholderForCreatedAsset {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { [weak self] success, error in
                DispatchQueue.main.async {
                    if !success {
                        self?.lastCaptureError = error?.localizedDescription ?? "Failed to save photo."
                    }
                }
            }
        }

        if let processedData, let image = UIImage(data: processedData) {
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
        var context = inFlightCaptures[photo.resolvedSettings.uniqueID] ?? InFlightCapture()
        if photo.isRawPhoto {
            context.rawData = photo.fileDataRepresentation()
        } else {
            context.processedData = photo.fileDataRepresentation()
        }
        inFlightCaptures[photo.resolvedSettings.uniqueID] = context
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
        guard let context, context.processedData != nil || context.rawData != nil else { return }
        save(processedData: context.processedData, rawData: context.rawData)
    }
}
