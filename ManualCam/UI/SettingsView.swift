import SwiftUI

/// Settings sheet: capture format, focus peaking, ProRAW toggle, persistence toggle,
/// version footer (Task 9). **Deviation from spec**: per user request, this is now also
/// where capture format and focus peaking live — there's no top-bar quick toggle for
/// either anymore, so this Form is the single, persisted source of truth for both.
struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var sessionManager: CameraSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // One three-way picker rather than a format picker plus a separate ProRAW toggle:
                    // the toggle only meant anything while RAW was selected, so in HEIC mode it was a
                    // control that changed nothing. ProRAW is omitted entirely on hardware that doesn't
                    // support it, exactly as the old toggle was hidden.
                    Picker("Format", selection: $settingsStore.defaultCaptureFormat) {
                        ForEach(availableFormats) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    Toggle("Focus Peaking", isOn: $settingsStore.isPeakingEnabled)
                } header: {
                    Text("Capture")
                } footer: {
                    Text(formatFooter)
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

    /// ProRAW is dropped on devices that don't support it, so the picker never offers a format that
    /// would silently fall back to something else.
    private var availableFormats: [CaptureFormat] {
        CaptureFormat.allCases.filter { format in
            guard format.prefersAppleProRAW else { return true }
            return sessionManager.isAppleProRAWSupported
        }
    }

    /// Explains the choice in place, since the difference between the two RAW flavours isn't guessable
    /// from their names — and one of them can't be used on the cropped zoom presets at all.
    private var formatFooter: String {
        switch settingsStore.defaultCaptureFormat {
        case .heic:
            return "Processed and compressed. Smallest files."
        case .raw:
            return "Undemosaiced sensor data — maximum editing latitude. Needs an uncropped sensor, so it isn't available on the cropped zoom lenses."
        case .appleProRAW:
            return "Demosaiced linear DNG with Apple's colour and lens corrections. Larger files, and the only RAW available on the cropped zoom lenses."
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
