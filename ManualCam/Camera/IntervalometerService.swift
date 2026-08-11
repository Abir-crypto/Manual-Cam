import Combine
import Foundation
import UIKit

/// Drives a Multi-Shot Timer run (`MULTI_SHOT_TIMER.md`, Task 2): an intervalometer that
/// fires N independent captures — an initial countdown, then one capture per interval.
///
/// State progression: `idle → counting down (shot 1) → capturing → counting down (shot 2)
/// → … → done`. Each shot uses the app's normal Manual-mode capture (passed in as a
/// closure); this service owns only the timing, on-screen countdown state, and audio
/// cues. Manual settings are effectively frozen for the run because the countdown overlay
/// covers the controls — there's no separate lock needed on the always-manual engine.
///
/// Runs on the main actor (project default): the countdown `Timer` fires on the main run
/// loop, so all `@Published` mutations already originate on main.
final class IntervalometerService: ObservableObject {
    /// True from the moment a run starts until it finishes or is cancelled.
    @Published private(set) var isRunning = false
    /// 1-based index of the shot currently being counted down to / captured.
    @Published private(set) var currentShot = 0
    @Published private(set) var totalShots = 0
    /// Seconds left before the next shot fires (drives the big on-screen numeral).
    @Published private(set) var secondsRemaining = 0
    /// Briefly true at the instant each shot fires — drives the capture flash.
    @Published private(set) var isCapturing = false

    private var config = TimerConfiguration.default
    private var capture: (() -> Void)?
    private var countdownTimer: Timer?
    private let audio = TimerAudioCuePlayer()

    /// Begin a run. `capture` is invoked once per shot; it's the same call the manual
    /// shutter button makes, so each shot respects the RAW/HEIC setting and album
    /// destination active when the run started.
    func start(config: TimerConfiguration, capture: @escaping () -> Void) {
        guard !isRunning else { return }
        self.config = config.clamped()
        self.capture = capture
        totalShots = self.config.shotCount
        currentShot = 1
        isCapturing = false
        isRunning = true
        audio.activate()
        UIApplication.shared.isIdleTimerDisabled = true
        beginCountdown(seconds: self.config.initialDelay)
    }

    /// Stop immediately. Shots already taken remain saved (they're independent captures);
    /// nothing in flight is cancelled beyond stopping further shots.
    func cancel() {
        guard isRunning else { return }
        finishRun()
    }

    // MARK: - Sequence

    private func beginCountdown(seconds: Int) {
        secondsRemaining = max(0, seconds)
        if secondsRemaining == 0 {
            // No delay before this shot (e.g. initial delay of 0) — fire right away.
            fireShot()
            return
        }
        // Beep now if we're already inside the last-3-seconds window (short intervals).
        maybeBeep()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        secondsRemaining -= 1
        if secondsRemaining <= 0 {
            stopCountdownTimer()
            fireShot()
        } else {
            maybeBeep()
        }
    }

    /// Rising get-ready beeps in the final 3 seconds before each capture; the last one
    /// (1s out) is the higher-pitched "final" beep.
    private func maybeBeep() {
        guard secondsRemaining >= 1, secondsRemaining <= 3 else { return }
        audio.playBeep(isFinal: secondsRemaining == 1)
    }

    private func fireShot() {
        audio.playShutter()
        capture?()
        flashCapture()

        if currentShot < totalShots {
            currentShot += 1
            beginCountdown(seconds: config.interval)
        } else {
            // Last shot: let the flash show briefly, then end the run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.isRunning else { return }
                self.finishRun()
            }
        }
    }

    /// Purely visual: pulse `isCapturing` so the overlay can flash. Independent of the
    /// sequence timing so the interval spacing stays accurate.
    private func flashCapture() {
        isCapturing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isRunning else { return }
            self.isCapturing = false
        }
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func finishRun() {
        stopCountdownTimer()
        isRunning = false
        isCapturing = false
        secondsRemaining = 0
        capture = nil
        audio.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
