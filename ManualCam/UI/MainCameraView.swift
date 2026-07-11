import CoreMedia
import Foundation
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
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                viewfinder
                Spacer(minLength: 8)
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

    // MARK: - Viewfinder

    /// Boxed to the sensor's actual 4:3 capture ratio (3:4 in portrait) — the rest of
    /// the screen stays black rather than cropping/stretching the preview full-bleed.
    private var viewfinder: some View {
        ZStack {
            CameraPreviewView(
                session: coordinator.sessionManager.session,
                onLightPress: { coordinator.controlEngine.setLensPosition(coordinator.controlEngine.lensPosition) },
                onFullPress: { capture() }
            )

            if coordinator.isPeakingEnabled, let overlay = coordinator.peakingProcessor.overlayImage {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
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
            // ISO is used in stops (50/100/200/400/800...) — a linear slider wastes most
            // of its length on one end, so the slider operates in log2 space (each tick
            // is an equal proportional step) and converts back to real ISO on change.
            WheelSlider(
                value: log2(Double(engine.iso)),
                range: log2(Double(engine.ranges.isoRange.lowerBound))...log2(Double(engine.ranges.isoRange.upperBound)),
                valueText: CameraValueFormatting.iso(engine.iso)
            ) { engine.setISO(Float(exp2($0))) }
        case .shutter:
            // Same reasoning as ISO: shutter speed is used in stops (1/8, 1/15, 1/30...),
            // so the slider operates in log2(seconds) space.
            WheelSlider(
                value: log2(engine.exposureDuration.seconds),
                range: log2(engine.ranges.exposureDurationRange.lowerBound.seconds)...log2(engine.ranges.exposureDurationRange.upperBound.seconds),
                valueText: CameraValueFormatting.shutter(engine.exposureDuration)
            ) { engine.setExposureDuration(CMTime(seconds: exp2($0), preferredTimescale: 1_000_000)) }
        case .focus:
            WheelSlider(
                value: Double(engine.lensPosition),
                range: Double(ManualControlRanges.lensPositionRange.lowerBound)...Double(ManualControlRanges.lensPositionRange.upperBound),
                valueText: CameraValueFormatting.focus(engine.lensPosition)
            ) { engine.setLensPosition(Float($0)) }
        case .whiteBalance:
            WheelSlider(
                value: engine.whiteBalanceKelvin,
                range: ManualControlRanges.kelvinRange,
                valueText: CameraValueFormatting.kelvin(engine.whiteBalanceKelvin)
            ) { engine.setWhiteBalanceKelvin($0) }
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

            lensSwitcher
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: - Lens switcher

    @ViewBuilder
    private var lensSwitcher: some View {
        let lenses = coordinator.sessionManager.availableLenses
        if lenses.count > 1 {
            Menu {
                ForEach(lenses) { lens in
                    Button {
                        coordinator.switchLens(lens)
                    } label: {
                        Label(lens.displayName, systemImage: lens.symbolName)
                        if lens == coordinator.sessionManager.currentLens {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Image(systemName: coordinator.sessionManager.currentLens?.symbolName ?? "camera")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}
