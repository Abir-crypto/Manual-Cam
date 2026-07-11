import AVFoundation
import AVKit
import SwiftUI

/// Live camera preview, backed by `AVCaptureVideoPreviewLayer` (Task 6).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Camera Control hardware shutter/dial support attaches its `AVCaptureEventInteraction`
    /// here since it needs a real `UIView` (Task 12).
    var onLightPress: (() -> Void)?
    var onFullPress: (() -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.installCaptureEventInteractionIfAvailable(onLightPress: onLightPress, onFullPress: onFullPress)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.frame = uiView.bounds
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            videoPreviewLayer.frame = bounds
        }

        func installCaptureEventInteractionIfAvailable(
            onLightPress: (() -> Void)?,
            onFullPress: (() -> Void)?
        ) {
            if #available(iOS 18.0, *) {
                let interaction = AVCaptureEventInteraction(
                    primary: { event in
                        guard event.phase == .ended else { return }
                        onFullPress?()
                    },
                    secondary: { event in
                        guard event.phase == .began else { return }
                        onLightPress?()
                    }
                )
                addInteraction(interaction)
            }
        }
    }
}
