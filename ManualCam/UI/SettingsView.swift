import SwiftUI

/// Settings sheet: default capture format, ProRAW toggle, persistence toggle, version footer (Task 9).
struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var sessionManager: CameraSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Default Format", selection: $settingsStore.defaultCaptureFormat) {
                        ForEach(CaptureFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    if sessionManager.isAppleProRAWSupported {
                        Toggle("Apple ProRAW", isOn: $settingsStore.appleProRAWEnabled)
                    }
                }

                Section {
                    Toggle("Persist Last-Used Values", isOn: $settingsStore.persistLastUsedValues)
                } footer: {
                    Text("When on, ManualCam restores your last ISO, shutter, focus, white balance, and exposure settings on launch.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(versionString)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
