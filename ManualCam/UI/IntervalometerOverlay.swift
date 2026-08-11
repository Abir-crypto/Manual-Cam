import SwiftUI

/// Full-screen countdown shown over the camera during a Multi-Shot Timer run
/// (`MULTI_SHOT_TIMER.md`, Task 2/4): a big center numeral, "Shot X of N" progress, an
/// always-visible cancel, and a brief flash at the moment each shot fires.
///
/// A translucent scrim (the viewfinder still shows through) that also captures taps, so
/// the manual controls beneath are effectively locked for the duration of the run —
/// matching the spec's "settings frozen while the sequence runs".
struct IntervalometerOverlay: View {
    @ObservedObject var service: IntervalometerService

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 12) {
                Text("Shot \(service.currentShot) of \(service.totalShots)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))

                Text("\(service.secondsRemaining)")
                    .font(.system(size: 108, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: service.secondsRemaining)

                Button {
                    service.cancel()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, 28)
            }

            // Capture flash — a quick white pulse the instant each shot fires.
            Color.white
                .ignoresSafeArea()
                .opacity(service.isCapturing ? 0.85 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.18), value: service.isCapturing)
        }
    }
}
