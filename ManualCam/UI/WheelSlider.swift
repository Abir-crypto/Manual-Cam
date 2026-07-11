import SwiftUI
import UIKit

/// A horizontal tick-ruler control for manual parameters. The red marker stays fixed at
/// center; the tick background scrolls beneath it as you drag, like pulling a physical
/// ruler strip — ticks move **with** your finger, so dragging right brings smaller
/// values (previously off-screen to the left) under the marker. Unlike an endless wheel,
/// the background's movement is bounded to the real `range`: ticks stop being drawn once
/// index 0 (`range.lowerBound`) or the last index (`range.upperBound`) reaches center, so
/// you can see/feel hitting the actual min/max instead of scrolling forever.
/// Selection-changes haptic on every tick crossed. `valueText` only appears as a floating
/// label while actively dragging, since most parameters are already shown continuously
/// in the value readout strip above and Focus (which isn't) still needs *some* numeric
/// feedback while adjusting it.
struct WheelSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let onChange: (Double) -> Void

    /// Points between adjacent minor ticks.
    private let tickSpacing: CGFloat = 9
    /// Every Nth tick is drawn taller.
    private let majorTickInterval = 5
    /// Total minor-tick steps spanning the full range — index 0 is `range.lowerBound`,
    /// `tickCount` is `range.upperBound`.
    private let tickCount = 40

    @State private var dragBaseValue: Double?
    @State private var lastHapticTickIndex: Int?
    /// `@State` so the same generator instance persists across the view re-renders that
    /// happen mid-drag (a plain `let` would recreate it every render, meaning
    /// `prepare()` would warm up an instance that a later render then discards).
    @State private var feedback = UISelectionFeedbackGenerator()

    private var tickValue: Double {
        max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude) / Double(tickCount)
    }

    var body: some View {
        ZStack {
            TickRuler(
                currentTickPosition: (value - range.lowerBound) / tickValue,
                tickCount: tickCount,
                tickSpacing: tickSpacing,
                majorTickInterval: majorTickInterval
            )

            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 20)

            if dragBaseValue != nil {
                Text(valueText)
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: -26)
                    .transition(.opacity)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .animation(.easeOut(duration: 0.12), value: dragBaseValue != nil)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let baseValue = dragBaseValue ?? value
                if dragBaseValue == nil {
                    dragBaseValue = baseValue
                    lastHapticTickIndex = tickIndex(for: baseValue)
                    feedback.prepare()
                }

                // Ticks move *with* the finger (dragging right shifts content right),
                // which means the value under the fixed center marker moves the
                // opposite way from the drag — negate here, not in the renderer.
                let deltaTicks = -Double(drag.translation.width / tickSpacing)
                let newValue = min(max(baseValue + deltaTicks * tickValue, range.lowerBound), range.upperBound)

                let newTickIndex = tickIndex(for: newValue)
                if newTickIndex != lastHapticTickIndex {
                    lastHapticTickIndex = newTickIndex
                    feedback.selectionChanged()
                }

                onChange(newValue)
            }
            .onEnded { _ in
                dragBaseValue = nil
                lastHapticTickIndex = nil
            }
    }

    private func tickIndex(for value: Double) -> Int {
        Int(((value - range.lowerBound) / tickValue).rounded())
    }
}

/// Draws the scrolling tick marks; `currentTickPosition` (in fractional tick units,
/// always within `0...tickCount`) is centered under the fixed marker. Only ticks with a
/// valid index (`0...tickCount`) are ever drawn, so the ruler visibly runs out at the
/// real min/max rather than scrolling endlessly.
private struct TickRuler: View {
    let currentTickPosition: Double
    let tickCount: Int
    let tickSpacing: CGFloat
    let majorTickInterval: Int

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let midY = size.height / 2
            let visibleTicks = Int(size.width / tickSpacing) + 2

            let lowestTick = max(Int(currentTickPosition) - visibleTicks, 0)
            let highestTick = min(Int(currentTickPosition) + visibleTicks, tickCount)
            guard lowestTick <= highestTick else { return }

            for tick in lowestTick...highestTick {
                let x = centerX + CGFloat(Double(tick) - currentTickPosition) * tickSpacing
                guard x >= 0, x <= size.width else { continue }

                let isMajor = tick % majorTickInterval == 0
                let height: CGFloat = isMajor ? 18 : 9
                var path = Path()
                path.move(to: CGPoint(x: x, y: midY - height / 2))
                path.addLine(to: CGPoint(x: x, y: midY + height / 2))
                context.stroke(
                    path,
                    with: .color(.white.opacity(isMajor ? 0.85 : 0.4)),
                    lineWidth: isMajor ? 1.5 : 1
                )
            }
        }
    }
}
