import AVFoundation
import SwiftUI

/// Pre-permission explainer + post-denial recovery state (Task 1).
struct CameraPermissionExplainerView: View {
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Camera Access")
                .font(.title2.bold())
            Text("ManualCam needs your camera to show a live preview and take photos with full manual control.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Enable Camera", action: onRequestAccess)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.black)
        .foregroundStyle(.white)
    }
}

struct CameraAccessDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Camera Access Needed")
                .font(.title2.bold())
            Text("Camera access was denied. Enable it in Settings to use ManualCam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
