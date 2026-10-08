import AppKit
import SwiftUI

/// Dynamic Island กลางขอบบนจอ (หรือขอบล่างแบบ Wispr) — ยืดหดตามสถานะด้วย spring
/// ว่าง: เล็ก/กลืนกับรอยบาก · ชี้เมาส์: บอกวิธีใช้ คลิกเพื่อเริ่ม · พูด: ไอคอนแอปปลายทาง + คลื่นเสียง + เวลา + คำที่พูดสดๆ
/// เกลา: ข้อความสดวิบวับ · เสร็จ: โชว์ข้อความที่วาง · error: ปุ่มลองใหม่ · เรียนรู้คำ: ปุ่มเลิกจำ
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case idle, hover, listening, thinking, done, message, error, learned }
    static let bars = 26

    @Published var phase: Phase = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.bars)
    @Published var command = false
    @Published var handsFree = false
    @Published var message = ""
    @Published var liveText = ""
    @Published var doneText = ""
    @Published var learnedWord = ""
    @Published var appIcon: NSImage?
    @Published var startedAt = Date()
    /// เรขาคณิตของจอปัจจุบัน (ตั้งโดย OverlayPanel)
    @Published var notchWidth: CGFloat = 0
    @Published var topInset: CGFloat = 0
    @Published var top = true
    @Published var showIdle = true
    var hint = ""

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onUndoLearned: () -> Void = {}
    var onPhase: ((Phase) -> Void)?
    private var hideWork: DispatchWorkItem?

    private func set(_ p: Phase, after seconds: Double? = nil) {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { phase = p }
        onPhase?(p)
        if let seconds {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }

    func listening(command: Bool, icon: NSImage? = nil) {
        levels = Array(repeating: 0, count: Self.bars)
        liveText = ""
        appIcon = icon
        startedAt = Date()
        self.command = command
        handsFree = false
        set(.listening)
    }

    func push(level: Float) {
        // เสียงพูดปกติ RMS ~0.02–0.2 → ขยายแบบ log ให้เห็นชัด
        let v = CGFloat(max(0, min(1, (log10(max(level, 0.0005)) + 3.0) / 2.3)))
        levels.removeFirst()
        levels.append(v)
    }

    func thinking(command: Bool) { self.command = command; set(.thinking) }
    func flash(_ text: String, seconds: Double = 2.2) { message = text; set(.message, after: seconds) }
    func done(_ text: String) { doneText = text.replacingOccurrences(of: "\n", with: " ⏎ "); set(.done, after: 1.6) }
    func error(_ text: String) { message = text; set(.error, after: 6) }
    func learned(_ word: String) { learnedWord = word; set(.learned, after: 4) }
    func hide() { set(.idle) }

    /// ตัวอย่างบนจอจริง (ไม่เปิดไมค์): พูด + คำสด → เกลา → วางแล้ว
    func demo() {
        guard phase == .idle || phase == .hover else { return }
        let words = ["พรุ่งนี้", "ประชุม", "กับ", "ทีม", "ตอน", "10:30", "น.", "นะ", "แล้วก็", "ฝาก", "เตรียม", "slide", "เรื่อง", "funding", "dashboard", "ด้วย"]
        listening(command: false, icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"))
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening else { t.invalidate(); return }
                tick += 1
                self.push(level: Float.random(in: 0.004...0.12) * Float(abs(sin(Double(tick) / 5)) + 0.3))
                if tick % 5 == 0, tick / 5 <= words.count {
                    self.liveText = words.prefix(tick / 5).joined(separator: " ")
                }
                if tick >= words.count * 5 + 14 {
                    t.invalidate()
                    self.thinking(command: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        self.done("พรุ่งนี้ประชุมกับทีมตอน 10 โมงครึ่งนะ แล้วก็ฝากเตรียม slide เรื่อง funding dashboard ด้วย")
                    }
                }
            }
        }
    }

    func hover(_ inside: Bool) {
        if inside && phase == .idle { set(.hover) } else if !inside && phase == .hover { set(.idle) }
    }

    /// ขนาดของเกาะ (ไม่รวมส่วนที่ซ่อนใต้รอยบาก)
    var size: CGSize {
        let notched = top && notchWidth > 0
        switch phase {
        case .idle: return notched ? CGSize(width: notchWidth, height: 0) : (top ? CGSize(width: 96, height: 9) : CGSize(width: 64, height: 9))
        case .hover: return CGSize(width: 360, height: 38)
        case .listening: return CGSize(width: liveText.isEmpty ? 330 : 470, height: liveText.isEmpty ? 44 : 72)
        case .thinking: return CGSize(width: liveText.isEmpty ? 250 : 470, height: liveText.isEmpty ? 40 : 66)
        case .done: return CGSize(width: 460, height: 40)
        case .message: return CGSize(width: 420, height: 40)
        case .error: return CGSize(width: 460, height: 44)
        case .learned: return CGSize(width: 400, height: 44)
        }
    }

    /// รวมส่วนบนที่ซ่อนใต้รอยบาก
    var outerSize: CGSize {
        let s = size
        let notched = top && notchWidth > 0
        if phase == .idle && !showIdle && !notched { return .zero }
        return CGSize(width: max(s.width, notched ? notchWidth : 0), height: s.height + (top ? topInset : 0))
    }
}

struct IslandView: View {
    @ObservedObject var m: OverlayModel
    static let canvas = CGSize(width: 640, height: 150)
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    var body: some View {
        let outer = m.outerSize
        let radius = min(22, max(outer.height / 2, 4))
        ZStack(alignment: m.top ? .top : .bottom) {
            Color.clear
            ZStack(alignment: m.top ? .bottom : .center) {
                shape(radius: radius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(m.phase == .idle ? 0 : 0.35), radius: 12, y: 4)
                shape(radius: radius)
                    .stroke(Color.white.opacity(m.phase == .idle || (m.top && m.notchWidth > 0 && m.topInset > 0 && m.phase == .idle) ? 0.08 : 0.1), lineWidth: 1)
                content
                    .frame(width: m.size.width, height: m.size.height)
                    .opacity(m.phase == .idle ? 0 : 1)
            }
            .frame(width: outer.width, height: outer.height)
            .contentShape(Rectangle())
            .onTapGesture { if m.phase == .idle || m.phase == .hover { m.onStart() } }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .animation(spring, value: m.phase)
        .animation(spring, value: m.liveText.isEmpty)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// บน: ขอบบนเรียบติดขอบจอ (เหมือนรอยบาก) · ล่าง: แคปซูลเต็ม
    private func shape(radius: CGFloat) -> UnevenRoundedRectangle {
        m.top
            ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
    }

    @ViewBuilder private var content: some View {
        switch m.phase {
        case .idle:
            EmptyView()
        case .hover:
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(gradient)
                Text(m.hint).font(.system(size: 12.5, weight: .medium)).lineLimit(1).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
        case .listening:
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    appBadge
                    Waveform(levels: m.levels, tint: m.command ? AnyShapeStyle(Color.orange) : AnyShapeStyle(gradient))
                        .frame(maxWidth: .infinity)
                    if m.command { badge("Command", .orange) }
                    if m.handsFree { badge("Hands-free", .blue) }
                    TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                        Text(clock(ctx.date.timeIntervalSince(m.startedAt)))
                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                    if m.handsFree {
                        iconButton("xmark", .white.opacity(0.18)) { m.onCancel() }
                        iconButton("checkmark", Color(red: 0.95, green: 0.35, blue: 0.4)) { m.onStop() }
                    }
                }
                if !m.liveText.isEmpty {
                    Text(m.liveText)
                        .font(.system(size: 13))
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
        case .thinking:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Spinner()
                    Text(m.command ? "Running command…" : "Polishing…").font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                if !m.liveText.isEmpty {
                    Shimmer(text: m.liveText).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(m.doneText).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        case .message:
            Text(m.message).font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.horizontal, 16)
        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(m.message).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 0)
                pill("Retry") { m.onRetry() }
            }
            .padding(.horizontal, 14)
        case .learned:
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill").foregroundStyle(gradient)
                Text("Learned: ").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    + Text(m.learnedWord).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                pill("Undo") { m.onUndoLearned(); m.hide() }
            }
            .padding(.horizontal, 14)
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1, green: 0.58, blue: 0.3), Color(red: 0.93, green: 0.25, blue: 0.55)], startPoint: .leading, endPoint: .trailing)
    }

    @ViewBuilder private var appBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon = m.appIcon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "text.cursor").frame(width: 20, height: 20)
            }
            Circle().fill(m.command ? Color.orange : Color.red).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        .help("Text will be pasted into this app")
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.85)))
    }

    private func iconButton(_ symbol: String, _ bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// คลื่นเสียงแบบแท่งกลางสมมาตร (ใหม่อยู่ขวา)
private struct Waveform: View {
    let levels: [CGFloat]
    let tint: AnyShapeStyle
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, v in
                let fade = 0.35 + 0.65 * Double(i) / Double(max(1, levels.count - 1))
                Capsule().fill(tint).frame(width: 3, height: 3 + v * 22).opacity(fade)
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5) {
                ForEach(0..<3) { i in
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.9)))
                }
            }
        }
    }
}

/// ข้อความดิบที่ได้ยิน วิบวับไล่แสง ระหว่างรอผลที่เกลาแล้ว
private struct Shimmer: View {
    let text: String
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = CGFloat(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
            Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.head)
                .foregroundStyle(.white.opacity(0.45))
                .overlay(
                    LinearGradient(stops: [.init(color: .clear, location: max(0, phase - 0.25)),
                                           .init(color: .white, location: phase),
                                           .init(color: .clear, location: min(1, phase + 0.25))],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.head))
                )
        }
    }
}

/// NSHostingView ที่รับคลิกแรกได้เลย (panel ไม่แย่งโฟกัสจากแอปที่ผู้ใช้พิมพ์อยู่)
private final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// หน้าต่างลอยของเกาะ: ไม่แย่งโฟกัส อยู่ทุก Space · เมาส์ทะลุได้ยกเว้นตรงตัวเกาะ
@MainActor
final class OverlayPanel {
    private let panel: IslandPanel
    private let model: OverlayModel
    private var monitors: [Any] = []
    private var timer: Timer?

    init(model: OverlayModel) {
        self.model = model
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: IslandView.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar            // เหนือ menu bar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = FirstClickHostingView(rootView: IslandView(m: model))
        model.onPhase = { [weak self] p in self?.phaseChanged(p) }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.trackMouse() }; return e }) { monitors.append(l) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // ตอนว่าง: ตามจอหลัก (จอที่มีหน้าต่างที่ใช้อยู่) ไปเรื่อยๆ
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.phase == .idle { self?.reposition() } }
        }
        applySettings()
    }

    func applySettings() {
        model.top = Store.config.islandTop
        model.showIdle = Store.config.islandIdle
        reposition()
    }

    private func phaseChanged(_ p: OverlayModel.Phase) {
        if p == .listening { reposition(screen: screenWithMouse()) }
        trackMouse()
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func reposition(screen: NSScreen? = nil) {
        guard let s = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let notch = s.safeAreaInsets.top > 0
            ? s.frame.width - (s.auxiliaryTopLeftArea?.width ?? 0) - (s.auxiliaryTopRightArea?.width ?? 0) : 0
        if model.notchWidth != notch { model.notchWidth = notch }
        let inset = model.top && notch > 0 ? s.safeAreaInsets.top : 0
        if model.topInset != inset { model.topInset = inset }
        let c = IslandView.canvas
        let y = model.top ? s.frame.maxY - c.height : s.visibleFrame.minY + 10
        panel.setFrame(NSRect(x: s.frame.midX - c.width / 2, y: y, width: c.width, height: c.height), display: true)
        panel.orderFrontRegardless()
    }

    /// เมาส์อยู่บนตัวเกาะ → รับคลิก + ขยายบอกวิธีใช้ · นอกเกาะ → คลิกทะลุไปแอปข้างหลัง
    private func trackMouse() {
        let o = model.outerSize
        guard o.width > 0 else { panel.ignoresMouseEvents = true; return }
        let f = panel.frame
        let rect = NSRect(x: f.midX - o.width / 2, y: model.top ? f.maxY - max(o.height, 12) : f.minY,
                          width: o.width, height: max(o.height, 12))
        let inside = NSMouseInRect(NSEvent.mouseLocation, rect.insetBy(dx: -6, dy: -4), false)
        let interactive = inside && model.phase != .thinking
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        model.hover(inside)
    }
}
