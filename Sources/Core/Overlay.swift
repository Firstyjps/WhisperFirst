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
    /// ระดับเสียงแยกเป็น object ของตัวเอง → อัปเดต 30 ครั้ง/วิ แต่มีแค่คลื่นเสียงที่วาดใหม่ (เกาะทั้งก้อน/หน้า Home ไม่วาดตาม)
    let meter = LevelMeter()
    @Published var command = false
    @Published var handsFree = false
    /// ถอดในเครื่อง (Private mode/ออฟไลน์) — โชว์ป้าย
    @Published var onDevice = false
    @Published var message = ""
    /// ข้อความสดทั้งหมด (ใช้คำนวณขนาดเกาะ) · ส่วนท้ายที่ยังเดาอยู่ (โชว์จางกว่า)
    @Published var liveText = ""
    @Published var livePending = ""

    func setLive(stable: String, pending: String) {
        let full = [stable, pending].filter { !$0.isEmpty }.joined(separator: " ")
        if livePending != pending { livePending = pending }
        if liveText != full { liveText = full }
    }
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

    private var demoToken = 0
    /// เวลาที่เริ่มชี้เมาส์ค้างบนเกาะ — คลิกได้เมื่อชี้ค้าง ≥0.3 วิ (กันคลิกโดนตอนจะกดเมนูบาร์)
    private(set) var hoverSince = Date.distantFuture

    func listening(command: Bool, icon: NSImage? = nil) {
        demoToken += 1   // การพูดจริงตัด demo ทิ้งเสมอ
        meter.reset()
        liveText = ""
        livePending = ""
        appIcon = icon
        startedAt = Date()
        self.command = command
        handsFree = false
        set(.listening)
    }

    func push(level: Float) { meter.push(level) }

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
        let token = demoToken
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening, self.demoToken == token else { t.invalidate(); return }
                tick += 1
                self.push(level: Float.random(in: 0.004...0.12) * Float(abs(sin(Double(tick) / 5)) + 0.3))
                if tick % 5 == 0, tick / 5 <= words.count {
                    let n = tick / 5   // คำล่าสุดยังจาง (กำลังเดา) เหมือนของจริง
                    self.setLive(stable: words.prefix(max(0, n - 1)).joined(separator: " "), pending: n > 0 ? words[n - 1] : "")
                }
                if tick >= words.count * 5 + 14 {
                    t.invalidate()
                    self.thinking(command: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        guard self.demoToken == token, self.phase == .thinking else { return }
                        self.done("พรุ่งนี้ประชุมกับทีมตอน 10 โมงครึ่งนะ แล้วก็ฝากเตรียม slide เรื่อง funding dashboard ด้วย")
                    }
                }
            }
        }
    }

    func hover(_ inside: Bool) {
        if inside && phase == .idle { hoverSince = Date(); set(.hover) }
        else if !inside && phase == .hover { hoverSince = .distantFuture; set(.idle) }
    }

    /// คลิกเกาะเพื่อเริ่มแฮนด์ฟรี — ต้องชี้ค้างให้เห็นคำแนะนำก่อน
    func clickToStart() {
        guard phase == .hover, Date().timeIntervalSince(hoverSince) >= 0.3 else { return }
        onStart()
    }

    /// ขนาดของเกาะ (ไม่รวมส่วนที่ซ่อนใต้รอยบาก)
    var size: CGSize {
        let notched = top && notchWidth > 0
        switch phase {
        case .idle: return notched ? CGSize(width: notchWidth, height: 0) : (top ? CGSize(width: 96, height: 9) : CGSize(width: 64, height: 9))
        case .hover: return CGSize(width: 360, height: 38)
        case .listening:
            // กว้างพอดีเนื้อหา (แฮนด์ฟรีมีป้าย + ปุ่ม ✕ ✓ · โหมดคำสั่งมีป้าย) — แก้ไอคอน/ปุ่มล้นขอบ
            let w = 330 + (handsFree ? 150 : 0) + (command ? 84 : 0)
            return CGSize(width: liveText.isEmpty ? CGFloat(w) : max(470, CGFloat(w)), height: liveText.isEmpty ? 44 : 72)
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
        if phase == .idle && !showIdle { return .zero }   // ปิดเกาะตอนว่าง = ไม่รับ hover/คลิกแม้บนรอยบาก
        return CGSize(width: max(s.width, notched ? notchWidth : 0), height: s.height + (top ? topInset : 0))
    }
}

struct IslandView: View {
    /// ส่วนที่นิ่งแล้วสีขาว · ส่วนที่ Live ยังเดาอยู่ (อาจเปลี่ยน) จางกว่า
    private var liveLine: Text {
        let p = m.livePending, full = m.liveText
        let stable = !p.isEmpty && full.hasSuffix(p) ? String(full.dropLast(p.count)) : full
        return Text(stable).foregroundColor(.white.opacity(0.9)) + Text(stable == full ? "" : p).foregroundColor(.white.opacity(0.5))
    }

    @ObservedObject var m: OverlayModel
    static let canvas = CGSize(width: 640, height: 150)
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    var body: some View {
        let outer = m.outerSize
        let radius = min(22, max(outer.height / 2, 4))
        let shoulder: CGFloat = m.top && outer.height > 0 ? min(10, outer.height) : 0
        let idle = m.phase == .idle
        let island = IslandShape(radius: radius, shoulder: shoulder, top: m.top)
        ZStack(alignment: m.top ? .top : .bottom) {
            Color.clear
            ZStack(alignment: m.top ? .bottom : .center) {
                island
                    .fill(Color.black)
                    .shadow(color: .black.opacity(idle ? 0 : 0.32), radius: 14, y: 10)
                    .shadow(color: .black.opacity(idle ? 0 : 0.18), radius: 3, y: 2)
                island
                    .stroke(Color.white.opacity(idle ? 0.05 : 0.08), lineWidth: 0.5)
                ZStack {
                    if !idle {
                        content
                            .id(m.phase)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94))
                                    .combined(with: .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))),
                                removal: .opacity.animation(.easeOut(duration: 0.12))))
                    }
                }
                .frame(width: m.size.width, height: m.size.height)
                .animation(spring.delay(0.09), value: m.phase)
            }
            .frame(width: outer.width + shoulder * 2, height: outer.height)
            .contentShape(Rectangle())
            .onTapGesture { m.clickToStart() }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .animation(spring, value: m.phase)
        .animation(spring, value: m.liveText.isEmpty)
        .animation(spring, value: m.handsFree)
        .animation(spring, value: m.command)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
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
                    Waveform(meter: m.meter, command: m.command)
                        .frame(maxWidth: .infinity)
                    if m.command { badge("Command", .orange) }
                    if m.handsFree { badge("Hands-free", .blue) }
                    if m.onDevice { badge("On-device", .green) }
                    TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                        Text(clock(ctx.date.timeIntervalSince(m.startedAt)))
                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                    if m.handsFree {
                        IslandButton(symbol: "xmark", label: "Cancel", fill: .white.opacity(0.16), hoverFill: .white.opacity(0.26)) { m.onCancel() }
                        IslandButton(symbol: "checkmark", label: "Done", fill: Color(red: 0.949, green: 0.349, blue: 0.4), hoverFill: Color(red: 1, green: 0.42, blue: 0.47)) { m.onStop() }
                    }
                }
                if !m.liveText.isEmpty {
                    liveLine
                        .font(.system(size: 13))
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(HStack(spacing: 0) {   // ข้อความยาวเกิน → จางขอบซ้าย 40pt
                            if m.liveText.count > 48 { LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 40) }
                            Color.black
                        })
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

/// ระดับเสียงสำหรับคลื่น — รับทุก ~21ms แต่ publish ไม่เกิน 30 ครั้ง/วิ
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.bars)
    private var last = Date.distantPast
    private var peak: CGFloat = 0

    func reset() { levels = Array(repeating: 0, count: OverlayModel.bars); peak = 0 }

    func push(_ level: Float) {
        // เสียงพูดปกติ RMS ~0.02–0.2 → ขยายแบบ log ให้เห็นชัด
        let target = CGFloat(max(0, min(1, (log10(max(level, 0.0005)) + 3.0) / 2.3)))
        peak = max(peak, target)
        guard Date().timeIntervalSince(last) >= 1.0 / 30 else { return }
        last = Date()
        var l = levels
        let v = (l.last ?? 0) * 0.35 + peak * 0.65   // นุ่มขึ้น ไม่กระตุก
        l.removeFirst()
        l.append(v)
        peak = 0
        levels = l
    }

    func set(_ l: [CGFloat]) { levels = l }   // ใช้ตอนเรนเดอร์ภาพทดสอบ
}

/// คลื่นเสียง: ไล่สีต่อเนื่องเส้นเดียวทั้งแถบ (#FF944D → #ED408C) · วาดด้วย Canvas (ไม่มี animation ซ้อนต่อแท่ง) · จางขอบซ้าย
private struct Waveform: View {
    @ObservedObject var meter: LevelMeter
    let command: Bool
    var body: some View {
        let levels = meter.levels
        Canvas { ctx, size in
            var path = Path()
            let step: CGFloat = 5.5
            for (i, v) in levels.enumerated() {
                let h = 3 + v * 22
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: 3, height: h),
                                    cornerSize: CGSize(width: 1.5, height: 1.5))
            }
            let shading: GraphicsContext.Shading = command
                ? .color(Color(red: 1, green: 0.62, blue: 0.04))
                : .linearGradient(Gradient(colors: [Color(red: 1, green: 0.58, blue: 0.30), Color(red: 0.93, green: 0.25, blue: 0.55)]),
                                  startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            ctx.fill(path, with: shading)
        }
        .mask(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .black, location: 0.55)],
                             startPoint: .leading, endPoint: .trailing))
        .frame(width: CGFloat(levels.count) * 5.5, height: 26)
        .accessibilityHidden(true)
    }
}

/// ไหล่เว้า 10pt ที่มุมบนสองข้าง (ไหลเข้าขอบจอแบบรอยบาก) · โหมดล่าง = มุมมนทุกด้าน
struct IslandShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat
    var top: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = shoulder, w = rect.width, h = rect.height
        let r = min(radius, (w - 2 * s) / 2, h)
        guard top else {
            return Path(roundedRect: rect, cornerRadius: min(radius, h / 2), style: .continuous)
        }
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: s, y: min(s, h)), control: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: s, y: h - r))
        p.addQuadCurve(to: CGPoint(x: s + r, y: h), control: CGPoint(x: s, y: h))
        p.addLine(to: CGPoint(x: w - s - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - s, y: h - r), control: CGPoint(x: w - s, y: h))
        p.addLine(to: CGPoint(x: w - s, y: min(s, h)))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - s, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// ปุ่มวงกลม 22pt บนเกาะ: hover สว่างขึ้น · กดยุบ 0.9
private struct IslandButton: View {
    let symbol: String
    let label: String
    let fill: Color
    let hoverFill: Color
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover.on ? hoverFill : fill))
        }
        .buttonStyle(PressScale())
        .onHover { hover.on = $0 }
        .accessibilityLabel(label)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
        let frame = NSRect(x: s.frame.midX - c.width / 2, y: y, width: c.width, height: c.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }   // ไม่วาดใหม่ทุก 2 วิถ้าไม่มีอะไรเปลี่ยน
        if !panel.isVisible { panel.orderFrontRegardless() }
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
