import Photos

/// Creates/fetches the app's dedicated photo album — captures and the gallery (Task 10)
/// are both scoped to this collection, never the camera roll root.
///
/// Requests full read-write Photos access, prompted lazily on first use (there's no
/// separate pre-permission screen for this, unlike camera access, since it only matters
/// once the user takes a photo). SPEC.md calls for add-only access, but `.addOnly`
/// cannot reliably fetch `PHAssetCollection`/`PHAsset` — which both the cross-launch
/// album lookup here and the Gallery screen require — and is a documented source of
/// crashes (Apple Developer Forums, multiple third-party reports). `.readWrite` is
/// Apple's own recommended access level whenever fetching is required.
final class PhotoAlbumManager {
    static let shared = PhotoAlbumManager()

    static let albumName = "ManualCam"
    private static let identifierDefaultsKey = "PhotoAlbumManager.albumLocalIdentifier"

    private var cachedCollection: PHAssetCollection?

    private init() {}

    enum AlbumError: Error, LocalizedError {
        case accessDenied
        case creationFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Photo library access was denied. Enable it in Settings to save photos."
            case .creationFailed: "Couldn't create the ManualCam photo album."
            }
        }
    }

    func fetchOrCreateAlbum(completion: @escaping (Result<PHAssetCollection, AlbumError>) -> Void) {
        requestReadWriteAccessIfNeeded { [weak self] granted in
            guard granted else {
                completion(.failure(.accessDenied))
                return
            }
            self?.fetchOrCreateAlbumAssumingAccess(completion: completion)
        }
    }

    /// Photos never auto-prompts the way camera access is auto-prompted by AVFoundation
    /// — it must be requested explicitly, otherwise the very first Photos call can crash
    /// rather than show a permission dialog.
    private func requestReadWriteAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    completion(status == .authorized || status == .limited)
                }
            }
        default:
            completion(false)
        }
    }

    private func fetchOrCreateAlbumAssumingAccess(completion: @escaping (Result<PHAssetCollection, AlbumError>) -> Void) {
        if let cachedCollection {
            completion(.success(cachedCollection))
            return
        }

        if let identifier = UserDefaults.standard.string(forKey: Self.identifierDefaultsKey),
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject {
            cachedCollection = collection
            completion(.success(collection))
            return
        }

        var placeholderIdentifier: String?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumName)
            placeholderIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard success, let placeholderIdentifier,
                      let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderIdentifier], options: nil).firstObject else {
                    completion(.failure(.creationFailed))
                    return
                }
                self?.cachedCollection = collection
                UserDefaults.standard.set(placeholderIdentifier, forKey: Self.identifierDefaultsKey)
                completion(.success(collection))
            }
        }
    }
}
