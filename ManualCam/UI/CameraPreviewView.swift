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
    /// Tap-to-focus: fires with the tap's point in this view's own local coordinates
    /// (for positioning the on-screen reticle) and the corresponding `AVCaptureDevice`
    /// point-of-interest-space point, already converted via
    /// `captureDevicePointConverted(fromLayerPoint:)`.
    var onTap: ((_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.installCaptureEventInteractionIfAvailable(onLightPress: onLightPress, onFullPress: onFullPress)
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.frame = uiView.bounds
        uiView.onTap = onTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        weak var view: PreviewUIView?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let viewPoint = recognizer.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            view.onTap?(viewPoint, devicePoint)
        }
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        var onTap: ((CGPoint, CGPoint) -> Void)?

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
