import AppKit

@MainActor
final class StatusPanel {
    private let panel: NSPanel
    private let hud = HUDView(frame: NSRect(x: 0, y: 0, width: 264, height: 48))
    private var timer: Timer?

    init() {
        panel = NSPanel(
            contentRect: hud.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hud
    }

    func update(state: DictationState, message: String, audioLevel: Double) {
        if state == .idle {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            return
        }
        hud.update(state: state, message: message, audioLevel: audioLevel)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
        if timer == nil {
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak hud] _ in
                MainActor.assumeIsolated { hud?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

@MainActor
private final class HUDView: NSView {
    private var state: DictationState = .idle
    private var message = ""
    private var audioLevel = 0.0
    private var bars = [Double](repeating: 0, count: 14)
    private var phase = 0.0
    private var recordingStarted: Date?

    func update(state: DictationState, message: String, audioLevel: Double) {
        if state == .recording && self.state != .recording { recordingStarted = Date() }
        if state != .recording { recordingStarted = nil }
        self.state = state
        self.message = message
        self.audioLevel = min(max(audioLevel, 0), 1)
        needsDisplay = true
    }

    func tick() {
        phase += 0.18
        for index in bars.indices {
            let shape = 0.68 + 0.32 * abs(sin(phase + Double(index) * 1.37))
            let target = state == .recording ? audioLevel * shape : 0
            bars[index] += (target - bars[index]) * (target > bars[index] ? 0.48 : 0.18)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outline = bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = NSBezierPath(roundedRect: outline, xRadius: 24, yRadius: 24)
        NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.075, alpha: 0.94).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        background.lineWidth = 1
        background.stroke()

        if state == .recording { drawRecording() } else { drawStatus() }
    }

    private func drawRecording() {
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: bounds.midY - 4, width: 8, height: 8)).fill()

        let startX = 39.0, gap = 3.0, barWidth = 3.0
        NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.48, alpha: 1).setFill()
        for (index, level) in bars.enumerated() {
            let height = 4 + level * 24
            let rect = NSRect(x: startX + Double(index) * (barWidth + gap), y: bounds.midY - height / 2,
                width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        let elapsed = Int(recordingStarted.map { Date().timeIntervalSince($0) } ?? 0)
        drawText(String(format: "%02d:%02d", elapsed / 60, elapsed % 60),
            in: NSRect(x: 204, y: 15, width: 44, height: 18), color: NSColor.white.withAlphaComponent(0.82), alignment: .right)
    }

    private func drawStatus() {
        let label: String
        let color: NSColor
        switch state {
        case .success: label = message; color = NSColor(calibratedRed: 0.42, green: 0.92, blue: 0.62, alpha: 1)
        case .error: label = message; color = NSColor(calibratedRed: 1, green: 0.45, blue: 0.45, alpha: 1)
        case .cancelled: label = "Cancelled"; color = NSColor.white.withAlphaComponent(0.75)
        case .stopping: label = "Finishing…"; color = NSColor.white.withAlphaComponent(0.92)
        case .processing: label = "Transcribing…"; color = NSColor.white.withAlphaComponent(0.92)
        case .delivering: label = "Pasting…"; color = NSColor.white.withAlphaComponent(0.92)
        default: label = message; color = NSColor.white.withAlphaComponent(0.92)
        }

        if state == .success {
            drawText("✓", in: NSRect(x: 49, y: 14, width: 18, height: 20), color: color, alignment: .center, size: 15)
        } else if [.stopping, .processing, .delivering].contains(state) {
            for index in 0..<3 {
                let alpha = 0.30 + 0.70 * (0.5 + 0.5 * sin(phase - Double(index) * 0.9))
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: 50 + Double(index) * 9, y: bounds.midY - 3, width: 6, height: 6)).fill()
            }
        }
        let textX = state == .error || state == .cancelled ? 20.0 : 78.0
        drawText(label, in: NSRect(x: textX, y: 14, width: 264 - textX - 18, height: 20), color: color)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, alignment: NSTextAlignment = .left, size: CGFloat = 12) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
