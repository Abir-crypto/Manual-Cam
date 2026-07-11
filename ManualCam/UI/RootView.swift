import AVFoundation
import SwiftUI

/// Gates the app on camera permission (Task 1), then hosts the main camera screen.
struct RootView: View {
    @StateObject private var coordinator = CameraCoordinator()
    @State private var authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch authStatus {
            case .authorized:
                MainCameraView(coordinator: coordinator)
                    .onAppear { coordinator.start() }
            case .notDetermined:
                CameraPermissionExplainerView(onRequestAccess: requestAccess)
            case .denied, .restricted:
                CameraAccessDeniedView()
            @unknown default:
                CameraAccessDeniedView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.persistCurrentStateIfNeeded()
            } else if newPhase == .active, authStatus == .authorized {
                coordinator.start()
            }
        }
    }

    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                authStatus = granted ? .authorized : .denied
            }
        }
    }
}
