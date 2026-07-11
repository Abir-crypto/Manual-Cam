import Photos
import SwiftUI

/// Grid of photos from the app's dedicated album only (Task 10).
struct GalleryView: View {
    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Button {
                            selectedAsset = asset
                        } label: {
                            GalleryThumbnail(asset: asset)
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if assets.isEmpty {
                    Text("No photos yet")
                        .foregroundStyle(.secondary)
                }
            }
            .fullScreenCover(item: $selectedAsset) { asset in
                PhotoDetailView(asset: asset)
            }
            .onAppear(perform: loadAssets)
        }
    }

    private func loadAssets() {
        PhotoAlbumManager.shared.fetchOrCreateAlbum { result in
            guard case .success(let collection) = result else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetchResult = PHAsset.fetchAssets(in: collection, options: options)
            var fetched: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in fetched.append(asset) }
            assets = fetched
        }
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

private struct GalleryThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result { image = result }
        }
    }
}
