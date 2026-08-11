import SwiftUI

/// Configuration sheet for the Multi-Shot Timer (`MULTI_SHOT_TIMER.md`, Task 1). Opened
/// from the Timer tile in the capture-options (⋯) sheet. Collects the three inputs and,
/// on Start, hands them back to the caller which freezes the current manual settings and
/// begins the run.
struct TimerSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: TimerConfiguration
    let onStart: (TimerConfiguration) -> Void

    init(config: TimerConfiguration, onStart: @escaping (TimerConfiguration) -> Void) {
        _config = State(initialValue: config)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stepperRow(
                        title: "Initial Delay",
                        value: $config.initialDelay,
                        range: TimerConfiguration.initialDelayRange,
                        format: { "\($0)s" }
                    )
                    stepperRow(
                        title: "Number of Shots",
                        value: $config.shotCount,
                        range: TimerConfiguration.shotCountRange,
                        format: { "\($0)" }
                    )
                    stepperRow(
                        title: "Interval",
                        value: $config.interval,
                        range: TimerConfiguration.intervalRange,
                        format: { "\($0)s" }
                    )
                } footer: {
                    Text("Countdown, then \(config.shotCount) \(config.shotCount == 1 ? "shot" : "shots") \(config.interval)s apart. Each is saved as its own photo using your current manual settings.")
                }

                Section {
                    Button {
                        onStart(config)
                        dismiss()
                    } label: {
                        Text("Start")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Multi-Shot Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func stepperRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        format: @escaping (Int) -> String
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
