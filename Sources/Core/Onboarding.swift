import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// ไกด์ครั้งแรก: ต้อนรับ → สิทธิ์ไมค์/Accessibility → Gemini key → ปุ่มลัด → ลองพูด → เสร็จ
/// เปิดเองตอนติดตั้งใหม่ (config.onboarded = false) · เปิดซ้ำได้จากเมนู/หน้า Help
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, permissions, apiKey, keys, tryIt, done }

    @Published var step: Step = .welcome
    /// ไปข้างหน้า = เลื่อนเข้าจากขวา · ย้อนกลับ = จากซ้าย
    @Published var forward = true
    @Published var mic = false
    @Published var micDenied = false
    @Published var ax = false
    @Published var geminiKey = Keys.gemini ?? ""
    @Published var keySaved = Keys.gemini != nil
    @Published var practice = ""
    @Published var tried = false
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    let shortcuts: ShortcutsModel
    let overlay: OverlayModel
    var onFinish: () -> Void = {}
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(shortcuts: ShortcutsModel, overlay: OverlayModel) {
        self.shortcuts = shortcuts
        self.overlay = overlay
        refresh()
        // ให้สิทธิ์ใน System Settings แล้วกลับมา → ติ๊กถูกเอง
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observer = NotificationCenter.default.addObserver(forName: History.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.step == .tryIt { self?.tried = true } }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        mic = s == .authorized
        micDenied = s == .denied || s == .restricted
        ax = AX.trusted
    }

    func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func requestAX() {
        AX.prompt()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func saveKey() {
        Keys.save(gemini: geminiKey, elevenLabs: Keys.savedElevenLabs)
        keySaved = Keys.gemini != nil
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { Log.write("login item: \(error.localizedDescription)") }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func next() {
        if step == .apiKey, geminiKey.trimmingCharacters(in: .whitespacesAndNewlines) != (Keys.gemini ?? "") { saveKey() }
        if let n = Step(rawValue: step.rawValue + 1) { go(n) } else { onFinish() }
    }

    func back() { if let p = Step(rawValue: step.rawValue - 1) { go(p) } }

    private func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.88)) { step = s }
    }

    var pushToTalk: KeyCombo? { shortcuts.combos(.pushToTalk).first }
    var pushToTalkText: String { pushToTalk.map(ShortcutsModel.display) ?? "the key" }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @ObservedObject var overlay: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    private var reduce: Bool { reduceMotion || still }

    init(m: OnboardingModel) { self.m = m; overlay = m.overlay }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                        Capsule().fill(s.rawValue <= m.step.rawValue ? Theme.accent : Theme.stroke)
                            .frame(width: s == m.step ? 22 : 7, height: 7)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: m.step)
                Spacer()
                if m.step != .done {
                    Button("Skip guide") { m.onFinish() }.buttonStyle(.plain)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 40).padding(.horizontal, 40)

            ZStack(alignment: .topLeading) {
                content.id(m.step).transition(stepTransition)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 40).padding(.top, 26)

            HStack {
                if m.step != .welcome {
                    Button("Back") { m.back() }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button(nextLabel) { m.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40).padding(.bottom, 28)
        }
        .frame(width: 720, height: 640)
        .background(Theme.contentBg)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .tint(Theme.accent)
    }

    private var stepTransition: AnyTransition {
        if reduce { return .opacity }
        let x: CGFloat = m.forward ? 36 : -36
        return .asymmetric(insertion: .modifier(active: SlideFade(x: x, opacity: 0), identity: SlideFade(x: 0, opacity: 1)),
                           removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    private var nextLabel: String {
        switch m.step {
        case .welcome: "Let's set it up"
        case .permissions: m.mic && m.ax ? "Continue" : "Continue anyway"
        case .apiKey:
            m.geminiKey.trimmingCharacters(in: .whitespaces).isEmpty ? "Skip for now"
                : m.geminiKey == (Keys.gemini ?? "") ? "Continue" : "Save and continue"
        case .keys: "Try it out"
        case .tryIt: m.tried || !m.practice.isEmpty ? "Continue" : "Skip"
        case .done: "Start using WhisperFirst"
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .welcome: welcome
        case .permissions: permissions
        case .apiKey: apiKey
        case .keys: keys
        case .tryIt: tryIt
        case .done: done
        }
    }

    // MARK: 1 ต้อนรับ

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                    .popIn().drift(y: -3, duration: 1.8)
                PageTitle(title: "Welcome to WhisperFirst", subtitle: "Talk instead of typing — in any app. Thai, English, or both.")
                    .reveal(0)
            }
            VStack(spacing: 0) {
                howRow("keyboard", 0xFBEADB, 0xC8641F, "Hold \(m.pushToTalkText)", "Wherever your cursor is — Line, Gmail, Notes, anywhere")
                Rectangle().fill(Theme.hairline).frame(height: 1)
                howRow("mic", 0xFDE7EA, 0xD9475A, "Just talk", "Pauses, “เอ่อ” and changing your mind are fine")
                Rectangle().fill(Theme.hairline).frame(height: 1)
                howRow("character.cursor.ibeam", 0xE6F4EA, 0x2E8B4E, "Let go", "Clean text is typed for you in about 2 seconds")
            }
            .wfCard()
            .reveal(1)
            HStack(alignment: .top, spacing: 12) {
                example("YOU SAY", "เอ่อ พรุ่งนี้ประชุมตอน 10 โมง เอ้ย ไม่ใช่ 10 โมงครึ่งนะ", Theme.muted)
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent).padding(.top, 30).drift(x: 4, duration: 0.9)
                example("IT TYPES", "พรุ่งนี้ประชุมตอน 10 โมงครึ่งนะ", Theme.accentText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .reveal(2)
            Text("Setup takes about a minute.").font(.system(size: 13)).foregroundStyle(Theme.muted).reveal(3)
        }
    }

    private func howRow(_ icon: String, _ bg: UInt32, _ fg: UInt32, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color(hex: fg))
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: bg)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func example(_ label: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(color)
            Text(text).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).wfCard()
    }

    // MARK: 2 สิทธิ์

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Two quick permissions", subtitle: "macOS asks once. You can change these later in System Settings → Privacy & Security.")
                .reveal(0)
            VStack(spacing: 0) {
                permRow(icon: "mic.fill", title: "Microphone", detail: "To hear you while you hold the key. Nothing is recorded otherwise.",
                        ok: m.mic, button: m.micDenied ? "Open Settings" : "Allow") { m.requestMic() }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                permRow(icon: "keyboard", title: "Accessibility", detail: "To notice your shortcut and type the text into other apps.",
                        ok: m.ax, button: "Open Settings") { m.requestAX() }
            }
            .wfCard()
            .reveal(1)
            if !m.ax {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(Theme.accentText)
                    Text("In System Settings, switch on **WhisperFirst** under Accessibility, then come back — this page updates by itself.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft.opacity(0.6)))
                .reveal(2)
            }
        }
    }

    private func permRow(icon: String, title: String, detail: String, ok: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.accentText)
                .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ZStack(alignment: .trailing) {
                if ok {
                    Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.successText)
                        .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(Theme.successBg))
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Button(button, action: action).buttonStyle(PrimaryButtonStyle()).transition(.opacity)
                }
            }
            .animation(reduce ? nil : .spring(response: 0.38, dampingFraction: 0.55), value: ok)   // ได้สิทธิ์ → ป้ายเด้งขึ้น
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // MARK: 3 API key

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Connect Google Gemini", subtitle: "WhisperFirst uses Gemini to understand you and tidy the text. A free key is enough for everyday use.")
                .reveal(0)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("1").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accentText)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.accentSoft))
                    Text("Get a free key from Google AI Studio").font(.system(size: 13.5))
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!) } label: {
                        Label("Open AI Studio", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(PillButtonStyle())
                }
                HStack(spacing: 10) {
                    Text("2").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accentText)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.accentSoft))
                    Text("Paste it here").font(.system(size: 13.5))
                }
                HStack(spacing: 10) {
                    SecureField("AIza…", text: $m.geminiKey).textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.windowBg))
                        .wfOutline(10)
                    if m.keySaved && m.geminiKey == (Keys.gemini ?? "") {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successText)
                    }
                }
                .padding(.leading, 32)
            }
            .padding(20).wfCard()
            .reveal(1)
            Text("Your key stays on this Mac (readable only by you). Change it anytime in Settings.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .reveal(2)
        }
    }

    // MARK: 4 ปุ่มลัด

    private var keys: some View {
        let sc = m.shortcuts
        let ptt = m.pushToTalk
        let hands = sc.combos(.handsFree), enter = sc.combos(.pressEnter)
        return VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Your keys", subtitle: "These are ready to go. Change any of them later on the Shortcuts page.")
                .reveal(0)
            VStack(spacing: 0) {
                keyRow("Talk", "Hold, speak, let go") { Keycaps(combo: ptt) }.reveal(1)
                divider
                keyRow("Hands-free", "Press to start, press again to finish — for longer thoughts") {
                    HStack(spacing: 4) {
                        Keycap(text: "2×"); Keycaps(combo: ptt)
                        ForEach(Array(hands.enumerated()), id: \.offset) { _, c in or; Keycaps(combo: c) }
                    }
                }.reveal(2)
                if !enter.isEmpty {
                    divider
                    keyRow("Press Enter", "Send the message without reaching for the keyboard") {
                        HStack(spacing: 4) { ForEach(Array(enter.enumerated()), id: \.offset) { i, c in if i > 0 { or }; Keycaps(combo: c) } }
                    }.reveal(3)
                }
                divider
                keyRow("Edit selected text", "Press ⇧ while talking, then say “translate to English”") { Keycap(text: "⇧") }.reveal(4)
                divider
                keyRow("Cancel", "While talking or waiting") { Keycap(text: "Esc") }.reveal(5)
                divider
                keyRow("Paste again", "Your most recent text") { Keycaps(combo: sc.combos(.pasteLast).first) }.reveal(6)
                divider
                keyRow("Teach a word", "Select a name or word in any app, then press") { Keycaps(combo: sc.combos(.addWord).first) }.reveal(7)
            }
            .wfCard()
            if hands.contains(where: { $0.contains { $0.hasPrefix("m:") } }) || enter.contains(where: { $0.contains { $0.hasPrefix("m:") } }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "computermouse").foregroundStyle(Theme.accentText)
                    Text("**Mouse 4 / Mouse 5** are the two side buttons on many mice. Using them for Back / Forward instead? Remove them on the Shortcuts page.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .reveal(8)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
    private var or: some View { Text("or").font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.horizontal, 2) }

    private func keyRow<K: View>(_ title: String, _ detail: String, @ViewBuilder _ k: () -> K) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            k()
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    // MARK: 5 ลองพูด

    private var tryIt: some View {
        let ok = m.tried || !m.practice.isEmpty
        let waiting = !ok && (overlay.phase == .idle || overlay.phase == .hover)
        return VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Give it a try", subtitle: "Click in the box, hold \(m.pushToTalkText), say something, then let go.")
                .reveal(0)
            HStack(spacing: 24) {
                // ปุ่มใหญ่แบบหน้า Home: ยุบตอนกดค้างพูด · ระหว่างรอมีวงแสงชวนกด
                BigKeycap(combo: m.pushToTalk, pressed: overlay.phase == .listening && !overlay.handsFree)
                    .background(PulseRing(active: waiting && !reduce))
                VStack(alignment: .leading, spacing: 8) {
                    Text(status).font(Theme.rounded(17, .semibold)).foregroundStyle(Theme.accentText)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: overlay.phase)
                    Text("Try: “สวัสดีครับ วันนี้อากาศดีมาก แล้วก็ฝากส่งอีเมลให้ทีมด้วยนะ”")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
            .reveal(1)
            TextEditor(text: $m.practice)
                .font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(12).frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .wfOutline(14, ok ? Theme.successText.opacity(0.5) : Theme.stroke, ok ? 1.5 : 1)
                .reveal(2)
            ZStack(alignment: .topLeading) {
                if ok {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("That's it — it works the same in every app.").font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Theme.successBanner)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.successBg))
                    .transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else if !m.ax || !m.mic || !m.keySaved {
                    Text(!m.ax || !m.mic ? "Permissions aren't on yet — go Back to allow them." : "No Gemini key yet — go Back to add one.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.warnText)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ok)
        }
    }

    private var status: String {
        switch overlay.phase {
        case .listening: overlay.handsFree ? "Listening… press again when you're done" : "Listening… let go when you're done"
        case .thinking: "Polishing…"
        case .done: "Done!"
        case .error: "Something went wrong — try again"
        default: "Hold to talk"
        }
    }

    // MARK: 6 เสร็จ

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                SuccessSeal(animated: !reduce)
                PageTitle(title: "You're all set 🎉", subtitle: "WhisperFirst lives in your menu bar and works in every app.")
                    .reveal(0)
            }
            VStack(spacing: 0) {
                tipRow("menubar.rectangle", "Look for the W in the menu bar", "Paste again, retry the last recording, settings — all there")
                divider
                tipRow("capsule.fill", "Watch the island at the top", "It shows when it's listening, polishing, and done")
                divider
                tipRow("character.book.closed", "Teach it your words", "Names and jargon in the Dictionary get spelled right")
            }
            .wfCard()
            .reveal(1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open WhisperFirst when I log in").font(.system(size: 13.5, weight: .semibold))
                    Text("Recommended — so it's always ready").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) })).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 18).padding(.vertical, 14).wfCard()
            .reveal(2)
            Text("You can open this guide again from Help.").font(.system(size: 12.5)).foregroundStyle(Theme.muted).reveal(3)
        }
    }

    private func tipRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.accentText).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

// MARK: - โมชั่น (ปิดเองเมื่อเปิด Reduce Motion ในเครื่อง)

/// true = ภาพนิ่ง (CLI เรนเดอร์ภาพ) → ข้ามโมชั่น แสดงสถานะสุดท้ายเลย
private struct StillKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var wfStill: Bool { get { self[StillKey.self] } set { self[StillKey.self] = newValue } }
}

/// ตัวกลางสำหรับ transition ของการเปลี่ยนขั้น: เลื่อนแนวนอน + จาง
private struct SlideFade: ViewModifier {
    let x: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity) }
}

private final class MotionFlag: ObservableObject { @Published var on = false }

/// โผล่ทีละชิ้นตามลำดับ (เลื่อนขึ้นนิด + จางเข้า)
private struct Reveal: ViewModifier {
    let order: Int
    @StateObject private var shown = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    private var reduce: Bool { reduceMotion || still }
    func body(content: Content) -> some View {
        let on = shown.on || reduce
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : 10)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.06 + Double(order) * 0.06)) { shown.on = true }
            }
    }
}

/// เด้งเข้า (ย่อ → ขยายเกินนิด → พอดี)
private struct PopIn: ViewModifier {
    @StateObject private var shown = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    private var reduce: Bool { reduceMotion || still }
    func body(content: Content) -> some View {
        let on = shown.on || reduce
        content.scaleEffect(on ? 1 : 0.6).opacity(on ? 1 : 0)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.05)) { shown.on = true }
            }
    }
}

/// ลอยไปมาเบาๆ ไม่รู้จบ
private struct Drift: ViewModifier {
    let x: CGFloat, y: CGFloat, duration: Double
    @StateObject private var moved = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    private var reduce: Bool { reduceMotion || still }
    func body(content: Content) -> some View {
        content.offset(x: moved.on ? x : 0, y: moved.on ? y : 0)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true).delay(0.6)) { moved.on = true }
            }
    }
}

extension View {
    fileprivate func reveal(_ order: Int) -> some View { modifier(Reveal(order: order)) }
    fileprivate func popIn() -> some View { modifier(PopIn()) }
    fileprivate func drift(x: CGFloat = 0, y: CGFloat = 0, duration: Double) -> some View { modifier(Drift(x: x, y: y, duration: duration)) }
}

/// วงแสงส้มกระจายออกรอบปุ่ม — ชวนให้กด
private struct PulseRing: View {
    let active: Bool
    @StateObject private var go = MotionFlag()
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Theme.accent, lineWidth: 2)
            .scaleEffect(go.on ? 1.18 : 1)
            .opacity(active ? (go.on ? 0 : 0.55) : 0)
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { go.on = true } }
    }
}

/// เครื่องหมายถูกสีเขียว เด้งเข้า + วงกระจายออกครั้งเดียว
private struct SuccessSeal: View {
    let animated: Bool
    @StateObject private var shown = MotionFlag()
    var body: some View {
        let on = shown.on || !animated
        ZStack {
            Circle().stroke(Theme.successText, lineWidth: 2)
                .scaleEffect(shown.on ? 1.7 : 1).opacity(shown.on ? 0 : (animated ? 0.6 : 0))
                .animation(.easeOut(duration: 0.9).delay(0.25), value: shown.on)
            Circle().fill(Theme.successBg)
            Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.successText)
                .scaleEffect(on ? 1 : 0.3)
                .animation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.15), value: shown.on)
        }
        .frame(width: 60, height: 60)
        .scaleEffect(on ? 1 : 0.5).opacity(on ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: shown.on)
        .onAppear { if animated { shown.on = true } }
    }
}
