import Photos
import SwiftUI

/// Basic zoomable full-screen viewer for a single gallery asset (Task 10).
struct PhotoDetailView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var currentZoom: CGFloat = 0
    @State private var totalZoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(currentZoom + totalZoom)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in currentZoom = value - 1 }
                            .onEnded { _ in
                                totalZoom = max(1, totalZoom + currentZoom)
                                currentZoom = 0
                            }
                    )
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear(perform: loadFullImage)
    }

    private func loadFullImage() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        manager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            if let result { image = result }
        }
    }
}
