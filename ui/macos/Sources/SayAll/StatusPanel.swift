import AppKit

@MainActor
final class StatusPanel {
    private let panel: NSPanel
    private let hud = HUDView(frame: NSRect(x: 0, y: 0, width: 244, height: 48))
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

    func update(state: DictationState, message: String, audioLevel: Double, showTimer: Bool) {
        if state == .idle {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            return
        }
        hud.update(state: state, message: message, audioLevel: audioLevel, showTimer: showTimer)
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
final class HUDView: NSView {
    private static let waveformWidth: CGFloat = 138
    private static let recordingBarCount = 14
    private static let processingHeights: [CGFloat] = [6, 10, 16, 22, 14, 8, 18, 24, 14, 8]
    private var state: DictationState = .idle
    private var message = ""
    private var audioLevel = 0.0
    private var bars = [Double](repeating: 0, count: recordingBarCount)
    private var showTimer = true
    private var recordingStarted: Date?
    private var processingStarted: Date?

    func update(state: DictationState, message: String, audioLevel: Double, showTimer: Bool) {
        if state == .recording && self.state != .recording { recordingStarted = Date() }
        if state != .recording { recordingStarted = nil }
        let processingStates: [DictationState] = [.stopping, .processing, .delivering]
        if processingStates.contains(state) && !processingStates.contains(self.state) {
            processingStarted = Date()
        }
        if !processingStates.contains(state) { processingStarted = nil }
        self.state = state
        self.message = message
        self.audioLevel = min(max(audioLevel, 0), 1)
        self.showTimer = showTimer
        needsDisplay = true
    }

    func tick() {
        for index in bars.indices {
            let shape = 0.68 + 0.32 * abs(sin(Date().timeIntervalSinceReferenceDate * 5.4 + Double(index) * 1.37))
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

        switch state {
        case .recording: drawRecording()
        case .stopping, .processing, .delivering: drawProcessing()
        case .success: drawCenteredText("✓  Copied to clipboard", color: Self.success, size: 13)
        case .error: drawCenteredText(message, color: Self.error, size: message.count > 30 ? 11 : 13)
        case .cancelled: drawCenteredText("Cancelled", color: NSColor.white.withAlphaComponent(0.75), size: 13)
        case .idle: break
        }
    }

    private func drawRecording() {
        let contentWidth: CGFloat = 8 + 16 + Self.waveformWidth + (showTimer ? 16 + 34 : 0)
        let contentX = (bounds.width - contentWidth) / 2
        Self.recordingDot.setFill()
        NSBezierPath(ovalIn: NSRect(x: contentX, y: bounds.midY - 4, width: 8, height: 8)).fill()

        let startX = contentX + 24
        let barWidth: CGFloat = 4.5
        let gap = (Self.waveformWidth - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        Self.recordingWave.setFill()
        for (index, level) in bars.enumerated() {
            let height = 5 + CGFloat(level) * 19
            let rect = NSRect(x: startX + CGFloat(index) * (barWidth + gap), y: bounds.midY - height / 2,
                width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }

        guard showTimer else { return }
        let elapsed = Int(recordingStarted.map { Date().timeIntervalSince($0) } ?? 0)
        drawText(String(format: "%02d:%02d", elapsed / 60, elapsed % 60),
            in: NSRect(x: startX + Self.waveformWidth + 16, y: 16, width: 34, height: 16),
            color: NSColor.white.withAlphaComponent(0.82), alignment: .right, size: 12, tracking: 0.2)
    }

    private func drawProcessing() {
        let barWidth: CGFloat = 4.5
        let gap = (Self.waveformWidth - barWidth * CGFloat(Self.processingHeights.count)) /
            CGFloat(Self.processingHeights.count - 1)
        let startX = (bounds.width - Self.waveformWidth) / 2
        let elapsed = processingStarted.map { Date().timeIntervalSince($0) * 1_000 } ?? 0
        Self.processing.setFill()
        for (index, referenceHeight) in Self.processingHeights.enumerated() {
            let phase = (elapsed + Double(index) * 120).truncatingRemainder(dividingBy: 2_000)
            let activity = phase < 1_600 ? sin(.pi * phase / 1_600) : 0
            let height = 4 + CGFloat(activity) * (referenceHeight - 4)
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawCenteredText(_ text: String, color: NSColor, size: CGFloat) {
        drawText(text, in: NSRect(x: 16, y: 16, width: bounds.width - 32, height: 16),
            color: color, alignment: .center, size: size)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor,
                          alignment: NSTextAlignment = .left, size: CGFloat = 12, tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont(name: "Noto Sans Bold", size: size)
                ?? NSFont(name: "Helvetica Neue Bold", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking,
        ])
    }

    private static let recordingWave = NSColor(calibratedRed: 250 / 255, green: 87 / 255, blue: 122 / 255, alpha: 1)
    private static let recordingDot = NSColor(calibratedRed: 1, green: 64 / 255, blue: 82 / 255, alpha: 1)
    private static let processing = NSColor(calibratedRed: 76 / 255, green: 214 / 255, blue: 209 / 255, alpha: 1)
    private static let success = NSColor(calibratedRed: 107 / 255, green: 235 / 255, blue: 158 / 255, alpha: 1)
    private static let error = NSColor(calibratedRed: 1, green: 115 / 255, blue: 115 / 255, alpha: 1)
}
