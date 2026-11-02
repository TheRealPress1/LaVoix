import AppKit
import QuartzCore

// The look and the motion of this cursor companion (blue triangle that trails the pointer, five-bar waveform while listening, spinner while
// thinking, an arc flight to a target with a small label) come from Clicky's OverlayWindow.swift:
//   https://github.com/farzaa/clicky  MIT License, Copyright (c) 2026 Farza (the notice is in docs/third-party-notices.md)
// Their constants and flight maths are kept (sizes, colours, offsets, spring, arc height, duration, scale pulse, label timing); the drawing is
// rewritten on Core Animation layers so the engine's main thread, which carries the dictation key tap, does no per-frame work: the pointer
// is followed from mouse events, a flight is handed to the render server as one keyframe animation, and the whole overlay only exists while a
// Look (or a pointing) is in progress.

/// Pure rules of the companion: where it sits, how a flight curves, how the bars move. Positions are AppKit global points (origin bottom-left
/// of the primary display, y up); callers holding Quartz points (origin top-left, as CGEvent and Accessibility give them) convert first.
nonisolated enum LookBuddyMath {
    /// Where the companion sits relative to the pointer: right of it and below it.
    static let followOffsetX: CGFloat = 35
    static let followOffsetY: CGFloat = -25
    /// Where it lands relative to a target: a little right of it and below it, so the tip of the resting triangle is on the target.
    static let landingOffsetX: CGFloat = 8
    static let landingOffsetY: CGFloat = -12
    /// The resting triangle leans 35 degrees to the left, like an arrow cursor.
    static let restRotation: CGFloat = 35 * .pi / 180
    static let framesPerSecond: Double = 60
    static let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
    static let maxLabelLength = 60

    /// Quartz (top-left origin) to AppKit (bottom-left origin) and back; the formula is its own inverse.
    static func flip(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static func followPosition(pointer: CGPoint) -> CGPoint { CGPoint(x: pointer.x + self.followOffsetX, y: pointer.y + self.followOffsetY) }

    /// Where the companion lands for a target: beside it, and kept at least 20 points inside the screen the target is on.
    static func landing(for target: CGPoint, in screen: CGRect) -> CGPoint {
        let beside = CGPoint(x: target.x + self.landingOffsetX, y: target.y + self.landingOffsetY)
        let minX = screen.minX + 20, maxX = max(screen.maxX - 20, minX)
        let minY = screen.minY + 20, maxY = max(screen.maxY - 20, minY)
        return CGPoint(x: min(max(beside.x, minX), maxX), y: min(max(beside.y, minY), maxY))
    }

    /// A flight lasts longer the further it goes: 0.6 s to 1.4 s.
    static func flightDuration(distance: CGFloat) -> TimeInterval { Double(min(max(distance / 800, 0.6), 1.4)) }

    static func arcHeight(distance: CGFloat) -> CGFloat { min(distance * 0.2, 80) }

    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// One moment of a flight, sampled for a keyframe animation.
    struct Frame { var position: CGPoint; var rotation: CGFloat; var scale: CGFloat; var glow: CGFloat }

    /// The flight from `from` to `to`: a quadratic arc that bows upward, eased with smoothstep, the triangle turned to face the way it is going
    /// (and eased from and back to its resting lean at the ends), growing to 1.3 times at the middle with its glow, then landing at 1.0.
    static func flight(from: CGPoint, to: CGPoint) -> (duration: TimeInterval, frames: [Frame]) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        let duration = self.flightDuration(distance: distance)
        let count = max(Int((duration * self.framesPerSecond).rounded()), 2)
        let control = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + self.arcHeight(distance: distance))
        let turns = distance >= 2
        var headings: [CGFloat] = []
        var frames: [Frame] = []
        for i in 0...count {
            let u = CGFloat(i) / CGFloat(count)
            let t = self.smoothstep(u)
            let m = 1 - t
            let position = CGPoint(x: m * m * from.x + 2 * m * t * control.x + t * t * to.x, y: m * m * from.y + 2 * m * t * control.y + t * t * to.y)
            // The way it is heading, taken from the curve's tangent B'(t); the triangle's tip points up at rotation 0.
            let tx = 2 * m * (control.x - from.x) + 2 * t * (to.x - control.x)
            let ty = 2 * m * (control.y - from.y) + 2 * t * (to.y - control.y)
            var heading = atan2(ty, tx) - .pi / 2
            if let last = headings.last { while heading - last > .pi { heading -= 2 * .pi }; while heading - last < -.pi { heading += 2 * .pi } }
            headings.append(heading)
            let pulse = sin(u * .pi)
            frames.append(Frame(position: position, rotation: 0, scale: 1 + pulse * 0.3, glow: 8 + pulse * 6))
        }
        guard turns, let firstHeading = headings.first, let lastHeading = headings.last else {
            for i in frames.indices { frames[i].rotation = self.restRotation }
            return (duration, frames)
        }
        // Ease the lean into the heading over the first tenth of the flight and back to the lean over the last eighth, by the shortest turn.
        let startRest = self.nearest(self.restRotation, to: firstHeading)
        let endRest = self.nearest(self.restRotation, to: lastHeading)
        for i in frames.indices {
            let u = CGFloat(i) / CGFloat(count)
            let into = self.smoothstep(u / 0.1)
            let out = self.smoothstep((1 - u) / 0.125)
            let facing = startRest + (headings[i] - startRest) * into
            frames[i].rotation = endRest + (facing - endRest) * out
        }
        return (duration, frames)
    }

    /// `angle` shifted by whole turns to be as near as possible to `reference`.
    static func nearest(_ angle: CGFloat, to reference: CGFloat) -> CGFloat {
        var a = angle
        while a - reference > .pi { a -= 2 * .pi }
        while a - reference < -.pi { a += 2 * .pi }
        return a
    }

    /// Heights of the five waveform bars for a microphone level (0 to 1, the dictation meter's scale) at a moment in time: 3 points when quiet,
    /// up to 14.5 for loud speech, with a gentle idle pulse so the bars never look dead.
    static func barHeights(level: CGFloat, time: TimeInterval) -> [CGFloat] {
        let speech = min(max((level - 0.2) / 0.7, 0), 1)
        let eased = pow(speech, 0.76)
        return self.barProfile.enumerated().map { index, profile in
            let phase = CGFloat(time * 3.6) + CGFloat(index) * 0.35
            let pulse = (sin(phase) + 1) / 2 * 1.5
            return 3 + eased * 10 * profile + pulse
        }
    }

    /// A label made safe to draw: one line, trimmed, at most 60 characters (cut with an ellipsis). Nil when nothing is left.
    static func cleanLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        if oneLine.count <= self.maxLabelLength { return oneLine }
        return String(oneLine.prefix(self.maxLabelLength - 1)) + "…"
    }

    static func clampHold(_ seconds: Double?) -> TimeInterval { min(max(seconds ?? 3, 0.5), 30) }
}

/// The cursor companion. Shown only while a Look is in progress (or while it points at something), one click-through window per display.
@MainActor
final class LookBuddy {
    static let shared = LookBuddy()

    enum Mode { case following, listening, thinking }

    /// The overlay is one window per display, drawn above everything including full-screen apps, and never takes a click or the focus.
    @MainActor private final class Screen {
        static let blue = CGColor(srgbRed: 0x33 / 255, green: 0x80 / 255, blue: 0xFF / 255, alpha: 1)
        let frame: CGRect
        let window: NSWindow
        let anchor = CALayer()
        let pointer = CALayer()
        let triangle = CAShapeLayer()
        let wave = CALayer()
        var bars: [CALayer] = []
        let spinner = CALayer()
        let bubble = CALayer()
        let text = CATextLayer()

        init(screen: NSScreen) {
            self.frame = screen.frame
            self.window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            self.window.isOpaque = false
            self.window.backgroundColor = .clear
            self.window.level = .screenSaver
            self.window.ignoresMouseEvents = true
            self.window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            self.window.isReleasedWhenClosed = false
            self.window.hasShadow = false
            self.window.hidesOnDeactivate = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            self.window.contentView = view
            guard let root = view.layer else { return }
            let scale = screen.backingScaleFactor

            // The anchor is the companion's centre; everything it draws is centred on (20, 20) inside it.
            self.anchor.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
            root.addSublayer(self.anchor)
            let centre = CGPoint(x: 20, y: 20)

            // The triangle (equilateral, 16 points, glowing), leaning 35 degrees.
            self.pointer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            self.pointer.position = centre
            let path = CGMutablePath()
            let half: CGFloat = 8, height = 16 * CGFloat(3).squareRoot() / 2
            path.move(to: CGPoint(x: half, y: half + height / 1.5))
            path.addLine(to: CGPoint(x: half - 8, y: half - height / 3))
            path.addLine(to: CGPoint(x: half + 8, y: half - height / 3))
            path.closeSubpath()
            self.triangle.path = path
            self.triangle.fillColor = Self.blue
            self.triangle.shadowColor = Self.blue
            self.triangle.shadowOpacity = 1
            self.triangle.shadowRadius = 8
            self.triangle.shadowOffset = .zero
            self.triangle.shadowPath = path
            self.triangle.frame = self.pointer.bounds
            self.pointer.addSublayer(self.triangle)
            self.pointer.transform = CATransform3DMakeRotation(LookBuddyMath.restRotation, 0, 0, 1)
            self.anchor.addSublayer(self.pointer)

            // The waveform: five rounded bars.
            self.wave.bounds = CGRect(x: 0, y: 0, width: 18, height: 16)
            self.wave.position = centre
            for index in 0..<5 {
                let bar = CALayer()
                bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 3)
                bar.position = CGPoint(x: CGFloat(index) * 4 + 1, y: 8)
                bar.cornerRadius = 1
                bar.backgroundColor = Self.blue
                bar.shadowColor = Self.blue
                bar.shadowOpacity = 0.6
                bar.shadowRadius = 6
                bar.shadowOffset = .zero
                self.wave.addSublayer(bar)
                self.bars.append(bar)
            }
            self.anchor.addSublayer(self.wave)

            // The spinner: a ring that fades in along its length, turning once every 0.8 s.
            self.spinner.bounds = CGRect(x: 0, y: 0, width: 17, height: 17)
            self.spinner.position = centre
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.frame = self.spinner.bounds
            gradient.colors = [CGColor(srgbRed: 0x33 / 255, green: 0x80 / 255, blue: 0xFF / 255, alpha: 0), Self.blue]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            let ring = CAShapeLayer()
            ring.frame = self.spinner.bounds
            ring.path = CGPath(ellipseIn: CGRect(x: 1.25, y: 1.25, width: 14.5, height: 14.5), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = CGColor(gray: 1, alpha: 1)
            ring.lineWidth = 2.5
            ring.lineCap = .round
            ring.strokeStart = 0.15
            ring.strokeEnd = 0.85
            gradient.mask = ring
            self.spinner.addSublayer(gradient)
            self.spinner.shadowColor = Self.blue
            self.spinner.shadowOpacity = 0.6
            self.spinner.shadowRadius = 6
            self.spinner.shadowOffset = .zero
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.8
            turn.repeatCount = .infinity
            self.spinner.add(turn, forKey: "turn")
            self.anchor.addSublayer(self.spinner)

            // The label: white 11-point text on a blue pill, drawn right of and below the companion.
            self.bubble.backgroundColor = Self.blue
            self.bubble.cornerRadius = 6
            self.bubble.shadowColor = Self.blue
            self.bubble.shadowOpacity = 0.5
            self.bubble.shadowRadius = 6
            self.bubble.shadowOffset = .zero
            self.text.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            self.text.fontSize = 11
            self.text.foregroundColor = CGColor(gray: 1, alpha: 1)
            self.text.alignmentMode = .left
            self.text.contentsScale = scale
            self.text.truncationMode = .none
            self.bubble.addSublayer(self.text)
            self.bubble.opacity = 0
            self.anchor.addSublayer(self.bubble)
            for layer in [self.triangle, ring, gradient] { layer.contentsScale = scale }
            self.pointer.opacity = 0
            self.wave.opacity = 0
            self.spinner.opacity = 0
        }

        func local(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - self.frame.origin.x, y: global.y - self.frame.origin.y) }

        func place(_ global: CGPoint) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.anchor.removeAnimation(forKey: "follow")
            self.anchor.position = self.local(global)
            CATransaction.commit()
        }

        /// Trails the pointer: a short ease from where the companion is drawn now to the new place.
        func follow(to global: CGPoint) {
            let target = self.local(global)
            let from = self.anchor.presentation()?.position ?? self.anchor.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.anchor.position = target
            CATransaction.commit()
            let ease = CABasicAnimation(keyPath: "position")
            ease.fromValue = NSValue(point: from)
            ease.toValue = NSValue(point: target)
            ease.duration = 0.11
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.anchor.add(ease, forKey: "follow")
        }

        func show(_ mode: Mode, seconds: Double) {
            let fade = { (layer: CALayer, on: Bool) in
                let from = layer.presentation()?.opacity ?? layer.opacity
                let to: Float = on ? 1 : 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = to
                CATransaction.commit()
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.toValue = to
                animation.duration = seconds
                layer.add(animation, forKey: "fade")
            }
            fade(self.pointer, mode == .following)
            fade(self.wave, mode == .listening)
            fade(self.spinner, mode == .thinking)
        }

        func setBars(_ heights: [CGFloat]) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            for (bar, height) in zip(self.bars, heights) { bar.bounds = CGRect(x: 0, y: 0, width: 2, height: height) }
            CATransaction.commit()
        }

        /// The label, sized to the text so far; it keeps its left edge beside the companion.
        func setLabel(_ string: String) {
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let size = (string as NSString).size(withAttributes: [.font: font])
            let width = ceil(size.width) + 16, height = ceil(size.height) + 8
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.bubble.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            self.bubble.position = CGPoint(x: 20 + 10 + width / 2, y: 20 - 18)
            self.text.frame = CGRect(x: 8, y: 4, width: ceil(size.width) + 2, height: ceil(size.height))
            self.text.string = string
            CATransaction.commit()
        }

        func popBubble() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.bubble.opacity = 1
            CATransaction.commit()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.5
            spring.toValue = 1
            spring.mass = 1
            spring.stiffness = 247
            spring.damping = 18.8
            spring.duration = spring.settlingDuration
            self.bubble.add(spring, forKey: "pop")
            let glow = CABasicAnimation(keyPath: "shadowRadius")
            glow.fromValue = 22
            glow.toValue = 6
            glow.duration = 0.5
            self.bubble.add(glow, forKey: "glow")
        }

        func hideBubble(seconds: Double) {
            let from = self.bubble.presentation()?.opacity ?? self.bubble.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.bubble.opacity = 0
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.duration = seconds
            self.bubble.add(fade, forKey: "fade")
        }

        /// Hands a whole flight to the render server: position, the triangle's turn, the swell and the glow.
        func fly(_ flight: (duration: TimeInterval, frames: [LookBuddyMath.Frame])) {
            let positions = flight.frames.map { NSValue(point: self.local($0.position)) }
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = positions
            move.calculationMode = .linear
            move.duration = flight.duration
            let swell = CAKeyframeAnimation(keyPath: "transform.scale")
            swell.values = flight.frames.map { $0.scale }
            swell.calculationMode = .linear
            swell.duration = flight.duration
            let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            turn.values = flight.frames.map { $0.rotation }
            turn.calculationMode = .linear
            turn.duration = flight.duration
            let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
            glow.values = flight.frames.map { $0.glow }
            glow.calculationMode = .linear
            glow.duration = flight.duration
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.anchor.removeAnimation(forKey: "follow")
            if let last = flight.frames.last { self.anchor.position = self.local(last.position) }
            self.pointer.transform = CATransform3DMakeRotation(LookBuddyMath.restRotation, 0, 0, 1)
            CATransaction.commit()
            self.anchor.add(move, forKey: "fly")
            self.anchor.add(swell, forKey: "swell")
            self.pointer.add(turn, forKey: "turn")
            self.triangle.add(glow, forKey: "glow")
        }

        /// Stops a flight where it is drawn and keeps it there.
        func stopFlight() {
            let drawn = self.anchor.presentation()?.position ?? self.anchor.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in ["fly", "swell"] { self.anchor.removeAnimation(forKey: key) }
            self.pointer.removeAnimation(forKey: "turn")
            self.triangle.removeAnimation(forKey: "glow")
            self.anchor.position = drawn
            CATransaction.commit()
        }
    }

    // MARK: State

    private var screens: [Screen] = []
    /// What the companion is asked to show; while it flies to a target it shows the triangle whatever this says.
    private var wanted: Mode = .following
    /// A Look (or a talk) is using the companion; when none is, it goes away once any pointing is over.
    private var inUse = false
    private var pointing = false
    private var returning = false
    private var position = CGPoint.zero
    private var level: CGFloat = 0
    private var barTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var lastFollow: TimeInterval = 0
    private var returnPointer = CGPoint.zero
    private var flightToken = 0
    private var guardTask: Task<Void, Never>?
    private var bubbleTask: Task<Void, Never>?

    /// The longest the companion stays when nobody asks for anything: a stuck state can never leave it on the screen.
    private static let guardSeconds: Double = 45

    var isShowing: Bool { !self.screens.isEmpty }
    /// Whether the companion trails the pointer. Off while it is parked, so a picture of it can be taken in a place that is not the screen.
    private var followsPointer = true

    // MARK: A Look uses it

    /// A Look began: the companion appears at the pointer in the given state.
    func begin(_ mode: Mode) {
        self.inUse = true
        self.followsPointer = true
        self.wanted = mode
        self.ensureScreens()
        self.applyMode()
        self.armGuard()
    }

    func setMode(_ mode: Mode) {
        guard self.inUse else { return }
        self.wanted = mode
        self.applyMode()
        self.armGuard()
    }

    /// The microphone level (0 to 1) the waveform follows.
    func setLevel(_ level: CGFloat) { self.level = level }

    /// The Look is over: the companion goes away, after any pointing in progress has finished.
    func end() {
        self.inUse = false
        if !self.pointing { self.teardown(fade: 0.25) }
    }

    /// Keeps the companion at an AppKit point and stops it following the pointer until the next `begin` (used to look at it in a known place).
    func park(at point: CGPoint) {
        self.followsPointer = false
        self.moveTo(point)
    }

    // MARK: Pointing

    /// Flies to a point (Quartz points, as Accessibility and the window list give them), says what it is in a few words if given, stays for
    /// `hold` seconds after the words are out, then flies back to the pointer. The pointer moving more than 100 points during the flight back
    /// cancels it. Pointing again while pointing starts over from where the companion is.
    func point(atQuartz target: CGPoint, label: String?, hold: Double?) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let there = LookBuddyMath.flip(target, primaryHeight: height)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(there) })?.frame ?? NSScreen.main?.frame ?? .zero
        let landing = LookBuddyMath.landing(for: there, in: screen)
        self.flightToken += 1
        let token = self.flightToken
        self.bubbleTask?.cancel()
        for s in self.screens { s.stopFlight(); s.hideBubble(seconds: 0.15) }
        self.pointing = true
        self.returning = false
        self.ensureScreens()
        self.applyMode()
        self.armGuard()
        self.fly(to: landing, token: token) { [weak self] in self?.arrive(token: token, label: LookBuddyMath.cleanLabel(label), hold: LookBuddyMath.clampHold(hold)) }
    }

    private func fly(to destination: CGPoint, token: Int, then done: @escaping () -> Void) {
        // From where it is drawn now, so a new flight starts without a jump.
        if let drawn = self.screens.first.flatMap({ s in s.anchor.presentation().map { CGPoint(x: $0.position.x + s.frame.origin.x, y: $0.position.y + s.frame.origin.y) } }) {
            self.position = drawn
        }
        let flight = LookBuddyMath.flight(from: self.position, to: destination)
        for s in self.screens { s.fly(flight) }
        self.position = destination
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(flight.duration * 1_000_000_000))
            guard let self, self.flightToken == token else { return }
            done()
        }
    }

    private func arrive(token: Int, label: String?, hold: TimeInterval) {
        self.bubbleTask = Task { @MainActor [weak self] in
            if let label {
                self?.showLabel("", pop: true)
                var shown = ""
                for character in label {
                    shown.append(character)
                    guard let self, !Task.isCancelled, self.flightToken == token else { return }
                    self.showLabel(shown, pop: false)
                    try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.03...0.06) * 1_000_000_000))
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self, !Task.isCancelled, self.flightToken == token else { return }
            for s in self.screens { s.hideBubble(seconds: 0.5) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, self.flightToken == token else { return }
            self.flyBack(token: token)
        }
    }

    private func showLabel(_ string: String, pop: Bool) {
        for s in self.screens {
            s.setLabel(string)
            if pop { s.popBubble() }
        }
    }

    private func flyBack(token: Int) {
        let pointer = NSEvent.mouseLocation
        self.returnPointer = pointer
        self.returning = true
        self.fly(to: LookBuddyMath.followPosition(pointer: pointer), token: token) { [weak self] in self?.finishPointing() }
    }

    private func finishPointing() {
        self.flightToken += 1
        self.pointing = false
        self.returning = false
        if self.inUse { self.applyMode() } else { self.teardown(fade: 0.25) }
    }

    // MARK: Following the pointer

    private func pointerMoved() {
        guard !self.screens.isEmpty else { return }
        let pointer = NSEvent.mouseLocation
        if self.returning {
            if hypot(pointer.x - self.returnPointer.x, pointer.y - self.returnPointer.y) > 100 {
                // The pointer moved on while the companion flew back: stop where it is drawn and carry on following from there.
                self.flightToken += 1
                self.bubbleTask?.cancel()
                for s in self.screens { s.stopFlight() }
                if let drawn = self.screens.first.flatMap({ s in s.anchor.presentation().map { CGPoint(x: $0.position.x + s.frame.origin.x, y: $0.position.y + s.frame.origin.y) } }) { self.position = drawn }
                self.finishPointing()
                self.moveTo(LookBuddyMath.followPosition(pointer: pointer))
            }
            return
        }
        guard !self.pointing, self.followsPointer else { return }
        let now = CACurrentMediaTime()
        guard now - self.lastFollow > 0.008 else { return }
        self.lastFollow = now
        self.moveTo(LookBuddyMath.followPosition(pointer: pointer))
    }

    private func moveTo(_ target: CGPoint) {
        self.position = target
        for s in self.screens { s.follow(to: target) }
    }

    // MARK: The windows

    private func ensureScreens() {
        if !self.screens.isEmpty {
            for s in self.screens { s.window.alphaValue = 1 }
            return
        }
        self.buildScreens()
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        self.screenObserver = observer
        let moved: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.pointerMoved() } }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: moved) { self.mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in moved(event); return event }) { self.mouseMonitors.append(local) }
    }

    private func buildScreens() {
        self.position = LookBuddyMath.followPosition(pointer: NSEvent.mouseLocation)
        self.screens = NSScreen.screens.map { Screen(screen: $0) }
        for s in self.screens {
            s.place(self.position)
            s.window.orderFrontRegardless()
        }
    }

    /// A display was added, removed or rearranged: the windows are rebuilt for the new layout and anything in flight is dropped.
    private func screensChanged() {
        guard !self.screens.isEmpty else { return }
        self.flightToken += 1
        self.bubbleTask?.cancel()
        self.pointing = false
        self.returning = false
        for s in self.screens { s.window.orderOut(nil); s.window.contentView = nil }
        self.screens = []
        self.buildScreens()
        self.applyMode()
    }

    private func teardown(fade: TimeInterval) {
        self.guardTask?.cancel()
        self.guardTask = nil
        self.bubbleTask?.cancel()
        self.flightToken += 1
        self.pointing = false
        self.returning = false
        self.stopBarTimer()
        for monitor in self.mouseMonitors { NSEvent.removeMonitor(monitor) }
        self.mouseMonitors = []
        if let observer = self.screenObserver { NotificationCenter.default.removeObserver(observer) }
        self.screenObserver = nil
        let leaving = self.screens
        self.screens = []
        guard !leaving.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for s in leaving { s.window.animator().alphaValue = 0 }
        }, completionHandler: {
            for s in leaving { s.window.orderOut(nil); s.window.contentView = nil }
        })
    }

    // MARK: The state shown

    private func applyMode() {
        let shown: Mode = self.pointing ? .following : self.wanted
        for s in self.screens { s.show(shown, seconds: shown == .listening ? 0.15 : 0.25) }
        if shown == .listening { self.startBarTimer() } else { self.stopBarTimer() }
    }

    private func startBarTimer() {
        guard self.barTimer == nil else { return }
        self.barTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let heights = LookBuddyMath.barHeights(level: self.level, time: Date().timeIntervalSinceReferenceDate)
                for s in self.screens { s.setBars(heights) }
            }
        }
    }

    private func stopBarTimer() {
        self.barTimer?.invalidate()
        self.barTimer = nil
    }

    private func armGuard() {
        self.guardTask?.cancel()
        self.guardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.guardSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.inUse = false
            self.teardown(fade: 0.25)
        }
    }
}
