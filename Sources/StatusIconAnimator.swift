import AppKit
import QuartzCore

/// Moves the menu bar glyph between states. Each bar is a spring: bars that
/// rise (the voice coming back) overshoot a little and settle, bars that fall
/// (muting) land without a bounce. Rising bars start from the center out,
/// falling ones from the edges in, so the change reads as one motion.
///
/// Every frame is a fresh template image, so the glyph keeps the menu bar's
/// own tinting. Reduce Motion skips straight to the new state.
@MainActor
final class StatusIconAnimator {
    private weak var button: NSStatusBarButton?
    private var state: StatusIcon.State?
    private var description = ""

    private var bars: [StatusIcon.Bar] = []
    private var target: [StatusIcon.Bar] = []
    private var velocity: [CGFloat] = []
    private var damping: [CGFloat] = []
    private var startAt: [CFTimeInterval] = []
    private var lastTick: CFTimeInterval = 0
    private var timer: Timer?

    /// Spring stiffness: roughly a 0.3s period.
    private static let stiffness: CGFloat = 420
    /// Damping ratio for rising bars (a small bounce, about 12%) and falling ones (none).
    private static let bounce: CGFloat = 0.55
    private static let settle: CGFloat = 1
    /// Delay between neighboring bars.
    private static let stagger: CFTimeInterval = 0.025

    init(button: NSStatusBarButton) {
        self.button = button
    }

    func show(_ state: StatusIcon.State, description: String) {
        guard state != self.state else {
            // Same glyph: redraw only for a new description.
            if description != self.description {
                self.description = description
                if timer == nil { render() }
            }
            return
        }
        self.description = description
        let first = self.state == nil
        self.state = state
        target = state.bars
        guard !first, bars.count == target.count,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            bars = target
            velocity = Array(repeating: 0, count: target.count)
            stop()
            render()
            return
        }
        let now = CACurrentMediaTime()
        let rising = zip(bars, target).map { $1.height > $0.height + 0.1 }
        damping = rising.map { $0 ? Self.bounce : Self.settle }
        // A bar already moving keeps its velocity, so a quick re-toggle
        // turns around smoothly instead of restarting.
        startAt = target.indices.map { i in
            if abs(velocity[i]) > 0.05 { return now }
            let fromCenter = abs(i - target.count / 2)
            let steps = rising[i] ? fromCenter : target.count / 2 - fromCenter
            return now + Double(steps) * Self.stagger
        }
        if timer == nil {
            lastTick = now
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30))
        lastTick = now
        var moving = false
        for i in bars.indices {
            guard now >= startAt[i] else {
                moving = true
                continue
            }
            // Semi-implicit Euler in small steps keeps the stiff spring stable.
            let k = Self.stiffness
            let c = 2 * damping[i] * k.squareRoot()
            let steps = 4
            let h = dt / CGFloat(steps)
            for _ in 0..<steps {
                let accel = -k * (bars[i].height - target[i].height) - c * velocity[i]
                velocity[i] += accel * h
                bars[i].height += velocity[i] * h
            }
            bars[i].alpha += (target[i].alpha - bars[i].alpha) * min(1, dt * 14)
            if abs(bars[i].height - target[i].height) > 0.01 || abs(velocity[i]) > 0.05
                || abs(bars[i].alpha - target[i].alpha) > 0.005 {
                moving = true
            }
        }
        if !moving {
            bars = target
            velocity = Array(repeating: 0, count: target.count)
            stop()
        }
        render()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        guard let button, let state else { return }
        button.image = StatusIcon.image(state, bars: bars, description: description)
    }
}
