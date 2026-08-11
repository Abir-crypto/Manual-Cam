import CoreMedia
import Foundation
import SwiftUI

/// Primary camera screen composing preview, peaking overlay, value readout, manual
/// control tabs, and capture (Task 8).
///
/// **Deviation from spec**: Task 8's top bar (format toggle, peaking toggle, settings
/// gear) is gone entirely per user request — the viewfinder is now the topmost element,
/// format + peaking live in the Settings sheet (both persisted via `AppSettingsStore`),
/// and the capture bar's lens picker was replaced by a settings button, with lens
/// switching promoted to its own always-visible tab row above the ISO/SHUTTER/FOCUS/WB
/// tabs.
struct MainCameraView: View {
    @ObservedObject var coordinator: CameraCoordinator
    @State private var activeParameter: ManualParameter = .iso
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showThumbnail = false
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorOpacity: Double = 0
    @State private var showCaptureOptions = false
    @State private var showTimerSetup = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                viewfinder
                Spacer(minLength: 8)
                valueReadoutStrip
                lensTabBar
                parameterTabBar
                parameterSlider
                    .padding(.top, 4)
                captureBar
            }
            .padding(.bottom, 12)

            if coordinator.intervalometer.isRunning {
                IntervalometerOverlay(service: coordinator.intervalometer)
            }
        }
        // Disabled per user request — kept for possible future use, not deleted.
        // .overlay(alignment: .top) {
        //     topCornerButtons
        // }
        .statusBarHidden()
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsStore: coordinator.settingsStore, sessionManager: coordinator.sessionManager)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
        .sheet(isPresented: $showCaptureOptions) {
            CaptureOptionsSheet(onTimer: {
                // Hand off from the ⋯ sheet to the timer setup sheet: dismiss this one
                // first, then present the next on the following runloop tick so the two
                // sheet transitions don't collide.
                showCaptureOptions = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showTimerSetup = true }
            })
                .presentationDetents([.height(150)])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showTimerSetup) {
            TimerSetupSheet(config: coordinator.settingsStore.timerConfiguration) { config in
                coordinator.startTimer(config: config)
            }
        }
        .onChange(of: coordinator.captureService.lastCaptureThumbnail) { _, newValue in
            guard newValue != nil else { return }
            // During a timer run, per-shot thumbnails are suppressed; the run's final
            // shot reveals its thumbnail once the run ends (see the isRunning onChange).
            guard !coordinator.intervalometer.isRunning else { return }
            showThumbnail = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showThumbnail = false }
        }
        .onChange(of: coordinator.intervalometer.isRunning) { _, isRunning in
            // Run just ended (finished or cancelled): reveal one thumbnail flash for the
            // last captured shot, if any.
            guard !isRunning, coordinator.captureService.lastCaptureThumbnail != nil else { return }
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

    // MARK: - Top corner buttons

    /// Demo placeholders in the empty space flanking the notch/Dynamic Island —
    /// functions to be wired up later. Deliberately an overlay on the outer `ZStack`,
    /// not part of the main `VStack`, so it doesn't push the viewfinder down; ignores
    /// the top safe area so it can actually sit level with the notch/island instead of
    /// being pushed below it.
    ///
    /// **Disabled per user request** (not deleted — may be needed again later): the
    /// `.overlay` that attaches this to `body` is commented out above. Left as dead
    /// code intentionally; expect an "unused" build warning until it's reattached.
    private var topCornerButtons: some View {
        HStack {
            topCornerButton(label: "1")
            Spacer()
            topCornerButton(label: "2")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .ignoresSafeArea(edges: .top)
    }

    private func topCornerButton(label: String) -> some View {
        Button {
            // Placeholder — behavior to be added later.
        } label: {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - Viewfinder

    /// Boxed to the sensor's actual 4:3 capture ratio (3:4 in portrait) — the rest of
    /// the screen stays black rather than cropping/stretching the preview full-bleed.
    /// Now the topmost element on screen — there's no top bar above it anymore.
    private var viewfinder: some View {
        ZStack {
            CameraPreviewView(
                session: coordinator.sessionManager.session,
                onLightPress: { coordinator.controlEngine.setLensPosition(coordinator.controlEngine.lensPosition) },
                onFullPress: { capture() },
                onTap: { viewPoint, devicePoint in handleTapToFocus(viewPoint: viewPoint, devicePoint: devicePoint) }
            )

            if coordinator.settingsStore.isPeakingEnabled, let overlay = coordinator.peakingProcessor.overlayImage {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            }

            if let point = focusIndicatorPoint {
                FocusReticle()
                    .position(point)
                    .opacity(focusIndicatorOpacity)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Point-and-shoot tap-to-focus: resets focus/ISO/shutter/white-balance to
    /// auto-metered values at the tapped point (`ManualControlEngine.tapToReset(at:)`),
    /// which then become the new baseline for further manual slider adjustment. Shows a
    /// brief reticle at the tap location purely as UI feedback — `viewPoint` (view-local)
    /// positions it, `devicePoint` (already converted to `AVCaptureDevice`
    /// point-of-interest space by `CameraPreviewView`) drives the actual device call.
    private func handleTapToFocus(viewPoint: CGPoint, devicePoint: CGPoint) {
        coordinator.tapToFocus(at: devicePoint)

        focusIndicatorPoint = viewPoint
        focusIndicatorOpacity = 1
        withAnimation(.easeOut(duration: 0.5).delay(0.5)) {
            focusIndicatorOpacity = 0
        }
    }

    // MARK: - Value readout strip

    /// Left-aligned value capsule + a right-aligned options button in one row,
    /// rather than the capsule alone centered — per user request.
    private var valueReadoutStrip: some View {
        HStack {
            valueReadoutCapsule
            Spacer()
            captureOptionsButton
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var valueReadoutCapsule: some View {
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
    }

    /// Pulls up `CaptureOptionsSheet` — Timer/Portrait/Astro/etc. — as a small
    /// bottom sheet rather than a full-height one. Wider than tall (a capsule, not a
    /// circle) per user request, to stand apart from the circular gear/thumbnail
    /// buttons elsewhere on screen.
    private var captureOptionsButton: some View {
        Button {
            showCaptureOptions = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 64, height: 36)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Lens tabs

    /// Styled identically to `parameterTabBar`, directly above it, so switching lenses
    /// feels like just another parameter tab rather than a separate menu. Collapses to
    /// nothing on single-lens devices rather than showing a redundant one-item row.
    @ViewBuilder
    private var lensTabBar: some View {
        let lenses = coordinator.sessionManager.availableLenses
        if lenses.count > 1 {
            HStack(spacing: 0) {
                ForEach(lenses) { lens in
                    Button {
                        coordinator.switchLens(lens)
                    } label: {
                        Text(lens.displayName)
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(lens == coordinator.sessionManager.currentLens ? Color.white.opacity(0.25) : .clear)
                    }
                }
            }
            .foregroundStyle(.white)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
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

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// Tap-to-focus reticle — brief visual feedback only, purely cosmetic (the actual
/// focus/exposure/white-balance reset happens via `ManualControlEngine.tapToReset(at:)`
/// regardless of whether this is ever seen).
private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
    }
}

/// Small bottom sheet pulled up by the capture options button (⋯) next to the value
/// readout strip. Tiles are currently no-op placeholders — capture modes (Timer,
/// Portrait, Astro, etc.) to be wired up later, same as `topCornerButtons`. A plain
/// centered `HStack` rather than a full-width grid, and no `maxHeight: .infinity`/
/// trailing `Spacer` — both per user request, so the sheet hugs the tiles' own
/// height instead of stretching to fill a taller sheet, and the tile row sits
/// centered in the middle of the sheet rather than spread edge-to-edge.
private struct CaptureOptionsSheet: View {
    /// Called when the Timer tile is tapped. Portrait/Astro stay no-op placeholders until
    /// those modes are built (see PORTRAIT_MODE.md / ASTRO_MODE.md).
    let onTimer: () -> Void

    private var options: [(icon: String, label: String, action: () -> Void)] {
        [
            ("timer", "Timer", onTimer),
            ("person.crop.rectangle", "Portrait", {}),
            ("moon.stars.fill", "Astro", {}),
        ]
    }

    var body: some View {
        HStack(spacing: 20) {
            ForEach(options, id: \.label) { option in
                Button(action: option.action) {
                    VStack(spacing: 8) {
                        Image(systemName: option.icon)
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        Text(option.label)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(white: 0.1))
    }
}
