import CoreMedia
import SwiftUI

/// Primary camera screen composing preview, peaking overlay, value readout, manual
/// control tabs, and capture (Task 8).
struct MainCameraView: View {
    @ObservedObject var coordinator: CameraCoordinator
    @State private var activeParameter: ManualParameter = .iso
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showThumbnail = false

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: coordinator.sessionManager.session,
                onLightPress: { coordinator.controlEngine.setLensPosition(coordinator.controlEngine.lensPosition) },
                onFullPress: { capture() }
            )
            .ignoresSafeArea()

            if coordinator.isPeakingEnabled, let overlay = coordinator.peakingProcessor.overlayImage {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                valueReadoutStrip
                parameterTabBar
                parameterSlider
                    .padding(.top, 4)
                captureBar
            }
            .padding(.bottom, 12)
        }
        .statusBarHidden()
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsStore: coordinator.settingsStore, sessionManager: coordinator.sessionManager)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
        .onChange(of: coordinator.captureService.lastCaptureThumbnail) { _, newValue in
            guard newValue != nil else { return }
            showThumbnail = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showThumbnail = false }
        }
        .alert(
            "Couldn't Save Photo",
            isPresented: Binding(
                get: { coordinator.captureService.lastCaptureError != nil },
                set: { isPresented in if !isPresented { coordinator.captureService.dismissError() } }
            ),
            presenting: coordinator.captureService.lastCaptureError
        ) { errorMessage in
            Button("OK") { coordinator.captureService.dismissError() }
            if errorMessage.contains("Settings") {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        } message: { errorMessage in
            Text(errorMessage)
        }
    }

    private func capture() {
        coordinator.capturePhoto()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                coordinator.captureFormat = coordinator.captureFormat.includesRAW ? .heicOnly : .heicPlusRAW
            } label: {
                Text(coordinator.captureFormat.includesRAW ? "RAW+HEIC" : "HEIC")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Button {
                coordinator.isPeakingEnabled.toggle()
            } label: {
                Image(systemName: coordinator.isPeakingEnabled ? "bolt.fill" : "bolt.slash")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Value readout strip

    private var valueReadoutStrip: some View {
        HStack(spacing: 12) {
            Text(CameraValueFormatting.iso(coordinator.controlEngine.iso))
            Divider().frame(height: 12).overlay(.white.opacity(0.4))
            Text(CameraValueFormatting.shutter(coordinator.controlEngine.exposureDuration))
            Divider().frame(height: 12).overlay(.white.opacity(0.4))
            Text(CameraValueFormatting.kelvin(coordinator.controlEngine.whiteBalanceKelvin))
            Divider().frame(height: 12).overlay(.white.opacity(0.4))
            Text(CameraValueFormatting.exposureBias(coordinator.controlEngine.exposureTargetBias))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
    }

    // MARK: - Parameter tabs

    private var parameterTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ManualParameter.allCases) { parameter in
                Button {
                    activeParameter = parameter
                } label: {
                    Text(parameter.label)
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(activeParameter == parameter ? Color.white.opacity(0.25) : .clear)
                }
            }
        }
        .foregroundStyle(.white)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    // MARK: - Active parameter slider

    @ViewBuilder
    private var parameterSlider: some View {
        let engine = coordinator.controlEngine
        switch activeParameter {
        case .iso:
            RangeSliderRow(
                value: Double(engine.iso),
                range: Double(engine.ranges.isoRange.lowerBound)...Double(engine.ranges.isoRange.upperBound),
                valueText: CameraValueFormatting.iso(engine.iso)
            ) { engine.setISO(Float($0)) }
        case .shutter:
            RangeSliderRow(
                value: engine.exposureDuration.seconds,
                range: engine.ranges.exposureDurationRange.lowerBound.seconds...engine.ranges.exposureDurationRange.upperBound.seconds,
                valueText: CameraValueFormatting.shutter(engine.exposureDuration)
            ) { engine.setExposureDuration(CMTime(seconds: $0, preferredTimescale: 1_000_000)) }
        case .focus:
            RangeSliderRow(
                value: Double(engine.lensPosition),
                range: Double(ManualControlRanges.lensPositionRange.lowerBound)...Double(ManualControlRanges.lensPositionRange.upperBound),
                valueText: CameraValueFormatting.focus(engine.lensPosition)
            ) { engine.setLensPosition(Float($0)) }
        case .whiteBalance:
            RangeSliderRow(
                value: engine.whiteBalanceKelvin,
                range: ManualControlRanges.kelvinRange,
                valueText: CameraValueFormatting.kelvin(engine.whiteBalanceKelvin)
            ) { engine.setWhiteBalanceKelvin($0) }
        case .exposureBias:
            RangeSliderRow(
                value: Double(engine.exposureTargetBias),
                range: Double(engine.ranges.exposureTargetBiasRange.lowerBound)...Double(engine.ranges.exposureTargetBiasRange.upperBound),
                valueText: CameraValueFormatting.exposureBias(engine.exposureTargetBias)
            ) { engine.setExposureTargetBias(Float($0)) }
        }
    }

    // MARK: - Capture bar

    private var captureBar: some View {
        HStack {
            Button {
                showGallery = true
            } label: {
                if let thumbnail = coordinator.captureService.lastCaptureThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 1))
                        .opacity(showThumbnail ? 1 : 0.6)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.15))
                        .frame(width: 44, height: 44)
                }
            }

            Spacer()

            Button(action: capture) {
                Circle()
                    .fill(.white)
                    .frame(width: 70, height: 70)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 4).frame(width: 82, height: 82))
            }

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// Horizontal slider + numeric readout + filled range bar (Task 8).
private struct RangeSliderRow: View {
    let value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(valueText)
                    .font(.caption.monospacedDigit().bold())
                Spacer()
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
    }
}
