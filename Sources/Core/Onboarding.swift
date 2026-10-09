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
    /// ทดสอบ key ก่อนบันทึก — วาง key ผิดแล้วไม่รู้ตัวคือสาเหตุอันดับหนึ่งที่ "ติดตั้งแล้วใช้ไม่ได้"
    enum KeyCheck: Equatable { case idle, checking, bad(String) }
    @Published var keyCheck: KeyCheck = .idle
    private var rejectedKey = ""
    /// ลำโพงจอ (HDMI/DisplayPort) → หยุดเพลงแทนลดเสียง ต้องใช้สิทธิ์ System Audio Recording (ไม่บันทึกเสียง)
    let needsSystemAudio = AudioDucker.pausesInsteadOfLowering && Store.config.muteWhileTalking != .off
    @Published var systemAudioAsked = false
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

    func requestSystemAudio() {
        PlaybackProbe.requestPermission()
        systemAudioAsked = true
    }

    func next() {
        // ช่องว่าง = ข้าม (ไม่ลบ key เดิมทิ้ง)
        let k = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if step == .apiKey, !k.isEmpty, k != (Keys.gemini ?? "") {
            if keyCheck == .checking { return }
            // ทดสอบไม่ผ่านแล้วกดซ้ำ = "Save anyway" · Private mode ไม่ยิง cloud → บันทึกเลย
            if k == rejectedKey || Store.config.privateMode { saveKey(); keyCheck = .idle; advance(); return }
            keyCheck = .checking
            Task {
                do {
                    _ = try await Transcriber().complete(system: "Reply with OK only.", user: "ping", json: false, key: k)
                    guard self.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines) == k else { self.keyCheck = .idle; return }
                    self.saveKey()
                    self.keyCheck = .idle
                    if self.step == .apiKey { self.advance() }
                } catch {
                    self.rejectedKey = k
                    self.keyCheck = .bad(Transcriber.friendly(error))
                }
            }
            return
        }
        advance()
    }

    private func advance() {
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
                : m.geminiKey == (Keys.gemini ?? "") ? "Continue"
                : m.keyCheck == .checking ? "Checking key…"
                : m.keyCheck != .idle ? "Save anyway" : "Save and continue"
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
        // เรียบ สงบ: โลโก้ + หัวข้อ + ประโยคเดียว จางเข้าทีละชิ้นช้าๆ
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 104, height: 104)
                .softIn(0)
            Text("Welcome to WhisperFirst").font(Theme.rounded(32, .bold)).tracking(-0.4).foregroundStyle(Theme.ink)
                .padding(.top, 22).softIn(1)
            Text("Hold \(m.pushToTalkText), say what you want to write, let go.\nClean text appears wherever you're typing.")
                .font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
                .padding(.top, 10).softIn(2)
            Text("Thai, English, or both · Setup takes about a minute")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                .padding(.top, 26).softIn(3)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 2 สิทธิ์

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: m.needsSystemAudio ? "A few quick permissions" : "Two quick permissions",
                      subtitle: "macOS asks once. You can change these later in System Settings → Privacy & Security.")
                .zoomIn(0)
            VStack(spacing: 0) {
                permRow(icon: "mic.fill", title: "Microphone", detail: "To hear you while you hold the key, or in hands-free until you press again. Off the rest of the time.",
                        ok: m.mic, button: m.micDenied ? "Open Settings" : "Allow", ripple: true) { m.requestMic() }
                    .flipIn(1)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                permRow(icon: "keyboard", title: "Accessibility", detail: "To notice your shortcut and type the text into other apps.",
                        ok: m.ax, button: "Open Settings") { m.requestAX() }
                    .flipIn(2)
                if m.needsSystemAudio {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    permRow(icon: "speaker.wave.2", title: "System audio (for your monitor speakers)",
                            detail: "Your speakers can't be turned down, so WhisperFirst pauses music instead. It checks for a split second whether something is playing — nothing is recorded.",
                            ok: m.systemAudioAsked, okLabel: "Asked", button: "Allow") { m.requestSystemAudio() }
                        .flipIn(3)
                }
            }
            .wfCard()
            if !m.ax {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(Theme.accentText)
                    Text("In System Settings, switch on **WhisperFirst** under Accessibility, then come back — this page updates by itself.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft.opacity(0.6)))
                .slideIn(.bottom, 4)
            }
        }
    }

    private func permRow(icon: String, title: String, detail: String, ok: Bool, okLabel: String = "Allowed", button: String, ripple: Bool = false,
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.accentText)
                .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
                .background(Ripple(active: ripple && !reduce))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ZStack(alignment: .trailing) {
                if ok {
                    Label(okLabel, systemImage: "checkmark.circle.fill").font(.system(size: 12.5, weight: .semibold))
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

    /// หน้านี้เล่นช้ากว่าหน้าอื่น 1.5 เท่า (user อยากให้ค่อยๆ)
    private static let keyPace = 1.5

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.fill").font(.system(size: 20)).foregroundStyle(Theme.accentText)
                    .frame(width: 46, height: 46).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentSoft))
                    .swingIn(pace: Self.keyPace).keyTurn(pace: Self.keyPace)
                PageTitle(title: "Connect Google Gemini", subtitle: "WhisperFirst uses Gemini to understand you and tidy the text. A free key is enough for everyday use.")
                    .slideIn(.trailing, 0, pace: Self.keyPace)
            }
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
                    } else if m.keyCheck == .checking {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.leading, 32)
                .onChange(of: m.geminiKey) { if m.keyCheck != .checking { m.keyCheck = .idle } }
                if case .bad(let why) = m.keyCheck {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warnText)
                        Text("\(why). Copy the whole key from AI Studio and try again — or save it anyway.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.warnText).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warnBg))
                    .padding(.leading, 32)
                }
            }
            .padding(20).wfCard()
            .blurIn(1, radius: 22, pace: Self.keyPace)
            Text("Your key stays on this Mac (readable only by you). Change it anytime in Settings.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .blurIn(2, pace: Self.keyPace)
        }
    }

    // MARK: 4 ปุ่มลัด

    private var keys: some View {
        let sc = m.shortcuts
        let ptt = m.pushToTalk
        let hands = sc.combos(.handsFree), enter = sc.combos(.pressEnter)
        return VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Your keys", subtitle: "These are ready to go. Change any of them later on the Shortcuts page.")
                .slideIn(.leading, 0, distance: 70)   // หัวข้อมาจากซ้าย · แถวด้านล่างสวนมาจากขวา
            VStack(spacing: 0) {
                keyRow(order: 1, "Talk", "Hold, speak, let go") { Keycaps(combo: ptt) }
                divider
                keyRow(order: 2, "Hands-free", "Press to start, press again to finish — for longer thoughts") {
                    HStack(spacing: 4) {
                        Keycap(text: "2×"); Keycaps(combo: ptt)
                        ForEach(Array(hands.enumerated()), id: \.offset) { _, c in or; Keycaps(combo: c) }
                    }
                }
                if !enter.isEmpty {
                    divider
                    keyRow(order: 3, "Press Enter", "Send the message without reaching for the keyboard") {
                        HStack(spacing: 4) { ForEach(Array(enter.enumerated()), id: \.offset) { i, c in if i > 0 { or }; Keycaps(combo: c) } }
                    }
                }
                divider
                keyRow(order: 4, "Edit selected text", "Press ⇧ while talking, then say “translate to English”") { Keycap(text: "⇧") }
                divider
                keyRow(order: 5, "Cancel", "While talking or waiting") { Keycap(text: "Esc") }
                divider
                keyRow(order: 6, "Paste again", "Your most recent text") { Keycaps(combo: sc.combos(.pasteLast).first) }
                divider
                keyRow(order: 7, "Teach a word", "Select a name or word in any app, then press") { Keycaps(combo: sc.combos(.addWord).first) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))   // แถวที่เลื่อนเข้ามาไม่ล้นนอกการ์ด
            .wfCard()
            if hands.contains(where: { $0.contains { $0.hasPrefix("m:") } }) || enter.contains(where: { $0.contains { $0.hasPrefix("m:") } }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "computermouse").foregroundStyle(Theme.accentText)
                    Text("**Mouse 4 / Mouse 5** are the two side buttons on many mice. Using them for Back / Forward instead? Remove them on the Shortcuts page.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .blurIn(5)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
    private var or: some View { Text("or").font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.horizontal, 2) }

    private func keyRow<K: View>(order: Int, _ title: String, _ detail: String, @ViewBuilder _ k: () -> K) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            k().pressWave(order)   // ปุ่มยุบไล่ทีละแถว เหมือนมีคนกดให้ดู
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .slideIn(.trailing, order, distance: 140)
    }

    // MARK: 5 ลองพูด

    private var tryIt: some View {
        // เรียบง่าย: คำแนะนำบรรทัดเดียว + กล่องข้อความ + สถานะตัวหนังสือ
        let ok = m.tried || !m.practice.isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Give it a try", subtitle: "Click in the box, hold \(m.pushToTalkText) and say something, then let go.")
                .softIn(0)
            TextEditor(text: $m.practice)
                .font(.system(size: 16)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(14).frame(height: 210)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .wfOutline(16, ok ? Theme.successText.opacity(0.45) : Theme.stroke, 1)
                .animation(.easeOut(duration: 0.3), value: ok)
                .softIn(1)
            HStack(spacing: 8) {
                if ok {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successText)
                    Text("That's it — it works the same in every app.").foregroundStyle(Theme.successBanner)
                } else if !m.ax || !m.mic || !m.keySaved {
                    Text(!m.ax || !m.mic ? "Permissions aren't on yet — go Back to allow them." : "No Gemini key yet — go Back to add one.")
                        .foregroundStyle(Theme.warnText)
                } else {
                    Text(status).foregroundStyle(overlay.phase == .idle || overlay.phase == .hover ? Theme.muted : Theme.accentText)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .animation(.easeOut(duration: 0.25), value: overlay.phase)
            .animation(.easeOut(duration: 0.25), value: ok)
            .padding(.leading, 2)
            .softIn(2)
        }
    }

    private var status: String {
        switch overlay.phase {
        case .listening: overlay.handsFree ? "Listening… press again when you're done" : "Listening… let go when you're done"
        case .thinking: "Polishing…"
        case .done: "Done!"
        case .error: overlay.message.isEmpty ? "Something went wrong — try again" : overlay.message
        default: "Try: “สวัสดีครับ วันนี้อากาศดีมาก”"
        }
    }

    // MARK: 6 เสร็จ

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                SuccessSeal(animated: !reduce).background(Confetti(active: !reduce))
                PageTitle(title: "You're all set 🎉", subtitle: "WhisperFirst lives in your menu bar and works in every app.")
                    .popScale(1)
            }
            VStack(spacing: 0) {
                tipRow("menubar.rectangle", "Look for the W in the menu bar", "Paste again, retry the last recording, settings — all there")
                divider
                tipRow("capsule.fill", "Watch the island at the top", "It shows when it's listening, polishing, and done")
                divider
                tipRow("character.book.closed", "Teach it your words", "Names and jargon in the Dictionary get spelled right")
            }
            .wfCard()
            .reveal(3)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open WhisperFirst when I log in").font(.system(size: 13.5, weight: .semibold))
                    Text("Recommended — so it's always ready").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) })).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 18).padding(.vertical, 14).wfCard()
            .reveal(4)
            Text("You can open this guide again from Help.").font(.system(size: 12.5)).foregroundStyle(Theme.muted).reveal(5)
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

/// โผล่ครั้งเดียวตอนแสดง: สถานะก่อน → หลัง ด้วยแอนิเมชันที่กำหนด (ฐานของโมชั่นเข้าทุกแบบ)
private struct Entrance<Effect: ViewModifier>: ViewModifier {
    let animation: Animation
    let effect: (Bool) -> Effect
    @StateObject private var shown = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    func body(content: Content) -> some View {
        let reduce = reduceMotion || still
        content.modifier(effect(shown.on || reduce))
            .onAppear { if !reduce { withAnimation(animation) { shown.on = true } } }
    }
}

private struct Shift: ViewModifier {
    let x: CGFloat, y: CGFloat, opacity: Double, blur: CGFloat, scale: CGFloat, angle: Double, flip: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(flip), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
            .rotationEffect(.degrees(angle)).scaleEffect(scale).blur(radius: blur)
            .offset(x: x, y: y).opacity(opacity)
    }
    static func at(_ on: Bool, x: CGFloat = 0, y: CGFloat = 0, blur: CGFloat = 0, scale: CGFloat = 1, angle: Double = 0, flip: Double = 0) -> Shift {
        on ? Shift(x: 0, y: 0, opacity: 1, blur: 0, scale: 1, angle: 0, flip: 0)
           : Shift(x: x, y: y, opacity: 0, blur: blur, scale: scale, angle: angle, flip: flip)
    }
}

/// บิดไป-กลับครั้งเดียว (ไขกุญแจ)
private struct KeyTurn: ViewModifier {
    let pace: Double
    @StateObject private var turned = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(turned.on ? 55 : 0), axis: (x: 1, y: 0, z: 0))
            .onAppear {
                guard !(reduceMotion || still) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1 * pace) {
                    withAnimation(.easeInOut(duration: 0.22 * pace)) { turned.on = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26 * pace) {
                        withAnimation(.spring(response: 0.4 * pace, dampingFraction: 0.5)) { turned.on = false }
                    }
                }
            }
    }
}

/// ปุ่มยุบลงครั้งเดียวตามลำดับ (คลื่นกดไล่แถว)
private struct PressWave: ViewModifier {
    let order: Int
    @StateObject private var down = MotionFlag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wfStill) private var still
    func body(content: Content) -> some View {
        content.offset(y: down.on ? 4 : 0).scaleEffect(down.on ? 0.86 : 1)
            .shadow(color: Theme.accent.opacity(down.on ? 0.55 : 0), radius: 8)
            .onAppear {
                guard !(reduceMotion || still) else { return }
                let t = 0.9 + Double(order) * 0.14
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    withAnimation(.easeOut(duration: 0.07)) { down.on = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) { down.on = false }
                    }
                }
            }
    }
}

extension View {
    fileprivate func reveal(_ order: Int) -> some View { modifier(Reveal(order: order)) }
    /// เลื่อนเข้าจากขอบที่กำหนด
    fileprivate func slideIn(_ edge: Edge, _ order: Int, distance d: CGFloat = 44, pace: Double = 1) -> some View {
        modifier(Entrance(animation: .spring(response: 0.62 * pace, dampingFraction: 0.78).delay((0.05 + Double(order) * 0.09) * pace)) {
            Shift.at($0, x: edge == .leading ? -d : edge == .trailing ? d : 0, y: edge == .top ? -d : edge == .bottom ? d / 2 : 0)
        })
    }
    /// เบลอแล้วค่อยชัด
    fileprivate func blurIn(_ order: Int, radius: CGFloat = 12, pace: Double = 1) -> some View {
        modifier(Entrance(animation: .easeOut(duration: (radius > 12 ? 1.0 : 0.6) * pace).delay(Double(order) * 0.15 * pace)) { Shift.at($0, blur: radius, scale: 1.04) })
    }
    /// ซูมเข้าจากขนาดใหญ่ (เหมือนกล้องถอยออก)
    fileprivate func zoomIn(_ order: Int) -> some View {
        modifier(Entrance(animation: .spring(response: 0.75, dampingFraction: 0.82).delay(Double(order) * 0.1)) { Shift.at($0, blur: 4, scale: 1.25) })
    }
    /// เด้งขยายจากเล็ก (ฉลองจบ)
    fileprivate func popScale(_ order: Int) -> some View {
        modifier(Entrance(animation: .spring(response: 0.55, dampingFraction: 0.5).delay(0.2 + Double(order) * 0.1)) { Shift.at($0, scale: 0.6) })
    }
    /// บิดเหมือนไขกุญแจ หลังแกว่งเข้ามาเสร็จ
    fileprivate func keyTurn(pace: Double = 1) -> some View { modifier(KeyTurn(pace: pace)) }
    /// พลิกลงมาแบบ 3D (บานพับด้านบน)
    fileprivate func flipIn(_ order: Int) -> some View {
        modifier(Entrance(animation: .spring(response: 0.95, dampingFraction: 0.62).delay(0.15 + Double(order) * 0.3)) { Shift.at($0, flip: -100) })
    }
    /// จางเข้านุ่มๆ ช้าๆ (ขยับขึ้นนิดเดียว) — หน้าที่ต้องการความสงบ
    fileprivate func softIn(_ order: Int) -> some View {
        modifier(Entrance(animation: .easeOut(duration: 0.9).delay(0.1 + Double(order) * 0.18)) { Shift.at($0, y: 6, scale: 0.99) })
    }
    /// แกว่งเข้ามาเหมือนห้อยอยู่
    fileprivate func swingIn(pace: Double = 1) -> some View {
        modifier(Entrance(animation: .spring(response: 0.9 * pace, dampingFraction: 0.32).delay(0.1 * pace)) { Shift.at($0, y: -30, scale: 0.4, angle: -110) })
    }
    fileprivate func pressWave(_ order: Int) -> some View { modifier(PressWave(order: order)) }
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

/// คลื่นวงกลมกระจายออกจากไอคอนเป็นจังหวะ (ไมค์กำลังฟัง)
private struct Ripple: View {
    let active: Bool
    var body: some View {
        ZStack { ForEach(0..<2, id: \.self) { RippleRing(active: active, delay: Double($0) * 0.9) } }
    }
}

private struct RippleRing: View {
    let active: Bool
    let delay: Double
    @StateObject private var go = MotionFlag()
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Theme.accent.opacity(0.75), lineWidth: 2)
            .scaleEffect(go.on ? 2.1 : 1).opacity(active ? (go.on ? 0 : 0.85) : 0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay)) { go.on = true }
            }
    }
}

/// คอนเฟตติกระจายจากเครื่องหมายถูกครั้งเดียว (ตำแหน่ง/สีคงที่ตามลำดับ ไม่สุ่มทุก render)
private struct Confetti: View {
    let active: Bool
    @StateObject private var burst = MotionFlag()
    private static let colors: [UInt32] = [0xD9732F, 0x2E8B4E, 0x6A55C8, 0xD9475A, 0xE0A526, 0x2F7FF0]
    var body: some View {
        ZStack {
            ForEach(0..<40, id: \.self) { i in
                let angle = Double(i) / 40 * 2 * .pi + Double(i % 3) * 0.17
                let dist = 80 + Double((i * 37) % 95)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: Self.colors[i % Self.colors.count]))
                    .frame(width: i % 2 == 0 ? 7 : 5, height: i % 2 == 0 ? 3.5 : 5)
                    .rotationEffect(.degrees(burst.on ? Double(180 + i * 47) : 0))
                    .scaleEffect(burst.on ? 1 : 0.1)   // เริ่มเป็นจุดเล็กซ่อนหลังเครื่องหมายถูก
                    .offset(x: burst.on ? cos(angle) * dist : 0, y: burst.on ? sin(angle) * dist + 70 : 0)   // +70 = ร่วงลงตามแรงโน้มถ่วง
                    .opacity(burst.on ? 0 : (active ? 1 : 0))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard active else { return }
            withAnimation(.timingCurve(0.15, 0.7, 0.4, 1, duration: 1.7).delay(0.25)) { burst.on = true }
        }
    }
}
