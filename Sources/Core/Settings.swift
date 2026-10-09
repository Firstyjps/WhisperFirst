import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    let shortcuts: ShortcutsModel
    var onIslandChange: (() -> Void)?
    init(engine: ShortcutEngine) { shortcuts = ShortcutsModel(engine: engine) }

    /// ชื่อ: บันทึกหลังหยุดพิมพ์ 0.5 วิ (ไม่เขียนไฟล์ทุกตัวอักษร)
    @Published var displayName = Store.config.displayName { didSet { debounce { [displayName] in Store.update { $0.displayName = displayName } } } }
    private var pendingSave: DispatchWorkItem?
    private func debounce(_ f: @escaping () -> Void) {
        pendingSave?.cancel()
        let w = DispatchWorkItem(block: f)
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    @Published var keepHistory = Store.config.keepHistory { didSet { Store.update { $0.keepHistory = keepHistory } } }
    @Published var historyDays = Store.config.historyDays { didSet { Store.update { $0.historyDays = historyDays }; History.prune() } }
    @Published var useSystemElevenLabsKey = Store.config.useSystemElevenLabsKey { didSet { Store.update { $0.useSystemElevenLabsKey = useSystemElevenLabsKey } } }
    @Published var historyCleared = false
    @Published var loginNeedsApproval = false
    @Published var sounds = Store.config.sounds { didSet { Store.update { $0.sounds = sounds } } }
    @Published var islandTop = Store.config.islandTop { didSet { Store.update { $0.islandTop = islandTop }; onIslandChange?() } }
    @Published var islandIdle = Store.config.islandIdle { didSet { Store.update { $0.islandIdle = islandIdle }; onIslandChange?() } }
    @Published var liveTranscript = Store.config.liveTranscript { didSet { Store.update { $0.liveTranscript = liveTranscript } } }
    @Published var fastText = Store.config.fastText { didSet { Store.update { $0.fastText = fastText } } }
    @Published var learnFromEdits = Store.config.learnFromEdits { didSet { Store.update { $0.learnFromEdits = learnFromEdits } } }
    @Published var useContext = Store.config.useContext { didSet { Store.update { $0.useContext = useContext } } }
    @Published var restoreClipboard = Store.config.restoreClipboard { didSet { Store.update { $0.restoreClipboard = restoreClipboard } } }
    @Published var noiseReduction = Store.config.noiseReduction { didSet { Store.update { $0.noiseReduction = noiseReduction } } }
    @Published var muteWhileTalking = Store.config.muteWhileTalking { didSet { Store.update { $0.muteWhileTalking = muteWhileTalking } } }
    @Published var privateMode = Store.config.privateMode {
        didSet { Store.update { $0.privateMode = privateMode }; if privateMode { LocalWhisper.shared.prewarm() } }
    }
    @Published var offlineFallback = Store.config.offlineFallback { didSet { Store.update { $0.offlineFallback = offlineFallback } } }
    @Published var elevenLabsFallback = Store.config.elevenLabsFallback { didSet { Store.update { $0.elevenLabsFallback = elevenLabsFallback } } }
    /// เปิดตอนเข้าสู่ระบบ (SMAppService — ตัวเดียวกับในเมนู)
    @Published var loginItem = SMAppService.mainApp.status == .enabled {
        didSet {
            guard loginItem != (SMAppService.mainApp.status == .enabled) else { return }
            do { if loginItem { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.write("login item: \(error.localizedDescription)") }
            refreshLogin()   // สวิตช์ต้องตรงกับสถานะจริงเสมอ (ล้มเหลว → เด้งกลับ)
        }
    }

    /// อ่านสถานะจริงจากระบบ (อาจถูกเปลี่ยนจากเมนูบาร์หรือ System Settings)
    func refreshLogin() {
        let st = SMAppService.mainApp.status
        if loginItem != (st == .enabled) { loginItem = st == .enabled }
        loginNeedsApproval = st == .requiresApproval
    }

    func clearHistory() {
        History.clear()
        historyCleared = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.historyCleared = false }
    }
    @Published var advancedOpen = false
    @Published var showKey = false
    @Published var models = Store.config.models.joined(separator: ", ")
    @Published var geminiKey = Keys.gemini ?? ""
    @Published var elevenKey = Keys.savedElevenLabs
    @Published var saved = false
    let aboutMe = TextFileModel(url: Paths.aboutMe)

    func saveAdvanced() {
        let list = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !list.isEmpty { Store.update { $0.models = list } }
        Keys.save(gemini: geminiKey, elevenLabs: elevenKey)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.saved = false }
    }
}

@MainActor
final class TextFileModel: ObservableObject {
    let url: URL
    @Published var text = ""
    @Published var saved = false
    /// เนื้อหาบนดิสก์ตอนโหลดล่าสุด — ไว้รู้ว่าผู้ใช้แก้ค้างไว้ไหม และมีใครเขียนไฟล์เพิ่มระหว่างนั้นไหม (ระบบเรียนรู้คำ)
    private var loaded = ""
    private var pending: DispatchWorkItem?
    var dirty: Bool { text != loaded }
    init(url: URL) { self.url = url }

    /// ไม่ทับสิ่งที่ผู้ใช้แก้ค้างไว้ (ออกจากหน้าแล้วกลับมา)
    func load() {
        guard !dirty else { return }
        loaded = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = loaded
    }

    /// บันทึกหลังหยุดพิมพ์ครู่หนึ่ง
    func saveSoon() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func save() {
        pending?.cancel(); pending = nil
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard disk != text else { loaded = text; return }
        // ไฟล์ถูกเขียนเพิ่มจากที่อื่นระหว่างแก้ → เก็บบรรทัดใหม่นั้นไว้ด้วย ไม่ทับหาย
        if disk != loaded {
            let before = Set(loaded.components(separatedBy: "\n")), mine = Set(text.components(separatedBy: "\n"))
            let added = disk.components(separatedBy: "\n").filter { !$0.isEmpty && !before.contains($0) && !mine.contains($0) }
            if !added.isEmpty { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + added.joined(separator: "\n") + "\n" }
        }
        Files.writeSecure(Data(text.utf8), to: url)
        loaded = text
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.saved = false }
    }
}

// MARK: - หน้า Settings

struct SettingsPage: View {
    @ObservedObject var s: SettingsModel
    @ObservedObject var checkup: CheckupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: "Settings")
            checkupCard
            section("General") {
                row("Your name") {
                    TextField("", text: $s.displayName).textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 10).frame(width: 200, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chip))
                }
                divider
                row("Open when I log in", s.loginNeedsApproval ? "Waiting for your approval in System Settings → Login Items" : nil) {
                    HStack(spacing: 8) {
                        if s.loginNeedsApproval {
                            Button("Open") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(PillButtonStyle())
                        }
                        toggle("Open when I log in", $s.loginItem)
                    }
                }
                divider
                row("Play a sound when I start and stop") { toggle("Play a sound when I start and stop", $s.sounds) }
                divider
                row("Reduce background noise", "Cleans up a quiet or noisy mic") {
                    toggle("Reduce background noise", $s.noiseReduction)
                }
                divider
                row("Music and videos while I talk", "Back when you let go · monitor speakers pause instead") {
                    Segmented(items: [(AudioDucker.Mode.off, "Leave"), (.mute, "Mute")],
                              selection: s.muteWhileTalking, capsule: false, fontSize: 12.5) { s.muteWhileTalking = $0 }
                }
            }
            section("Dynamic Island") {
                row("Where it appears", "Top blends into the notch on MacBooks") {
                    Segmented(items: [(true, "Top"), (false, "Bottom")], selection: s.islandTop, capsule: false, fontSize: 12.5) { s.islandTop = $0 }
                }
                divider
                row("Show a small island when idle", "Hover it for tips, click it to start talking") { toggle("Show a small island when idle", $s.islandIdle) }
                divider
                row("Show my words while I talk", "See what you're saying, live") { toggle("Show my words while I talk", $s.liveTranscript) }
                divider
                row("Speed", s.fastText ? "Short phrases are ready in about 1.5 seconds" : "Always listens to the full audio · about 2–3 seconds") {
                    Segmented(items: [(true, "Faster"), (false, "More accurate")], selection: s.fastText, capsule: false, fontSize: 12.5) { s.fastText = $0 }
                }
                .opacity(s.liveTranscript ? 1 : 0.45)
                .disabled(!s.liveTranscript)
            }
            privacy
            section("Smart helpers") {
                row("Learn from my corrections", "If you fix a word after it's typed, it'll spell it that way next time") { toggle("Learn from my corrections", $s.learnFromEdits) }
                divider
                row("Look at nearby text for better spelling", "Never reads password fields") { toggle("Look at nearby text for better spelling", $s.useContext) }
                divider
                row("Put my clipboard back after pasting") { toggle("Put my clipboard back after pasting", $s.restoreClipboard) }
            }
            advanced
        }
        .onAppear { checkup.runIfStale(); s.refreshLogin() }
    }

    // MARK: check-up

    private var checkupCard: some View {
        let checking = checkup.state != .done
        let ok = !checking && checkup.allGood
        let secs = max(1, Int(checkup.seconds.rounded()))
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(checking ? Theme.chip : ok ? Theme.successBg : Theme.warnBg)
                    if checking { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(ok ? Theme.successText : Theme.warnText)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(checking ? "Checking…" : ok ? "Everything is working" : "Something needs attention").font(Theme.rounded(17, .semibold))
                    Text(checking ? "Looking at your microphone, typing access and connection"
                         : ok ? "Microphone, typing access and connection all look good · checked just now"
                         : "Fix the item below, then check again")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Check again") { checkup.run() }.buttonStyle(PillButtonStyle()).disabled(checking)
            }
            HStack(spacing: 10) {
                tile("Microphone", checkup.mic ? "WhisperFirst can hear you" : "Microphone access is off", checkup.mic, checking) {
                    // ยังไม่เคยขอ → ขอเลย (ถ้าเปิด System Settings ตอนนี้ แอปจะยังไม่อยู่ในรายการ)
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { checkup.runIfStale() } }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
                tile("Typing access", checkup.typing ? "Allowed to type into other apps (Accessibility)" : "Not allowed to type into other apps yet",
                     checkup.typing, checking) {
                    AX.prompt()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                tile("Connection", checkup.online ? "Online · replies in about \(secs) \(secs == 1 ? "second" : "seconds")"
                                                  : "Can't reach the AI — check the internet or your API key",
                     checkup.online, checking) { s.advancedOpen = true }
            }
        }
        .padding(20).wfCard()
    }

    private func tile(_ title: String, _ detail: String, _ ok: Bool, _ checking: Bool, fix: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: checking ? "circle.dashed" : ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundStyle(checking ? Theme.faint : ok ? Theme.successText : Theme.warnText)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if !checking && !ok { Button("Fix") { fix() }.buttonStyle(PillButtonStyle()).padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.tile))
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { s.advancedOpen.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(s.advancedOpen ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced").font(.system(size: 14, weight: .semibold))
                        Text("API keys, AI models and backup engine — you usually don't need these").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if s.advancedOpen {
                divider
                row("Gemini API key", "Needed to turn your voice into text") {
                    HStack(spacing: 6) {
                        Group {
                            if s.showKey { TextField("", text: $s.geminiKey) } else { SecureField("", text: $s.geminiKey) }
                        }
                        .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        Button(s.showKey ? "Hide" : "Show") { s.showKey.toggle() }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentText)
                    }
                    .padding(.horizontal, 10).frame(width: 280, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chip))
                }
                divider
                row("ElevenLabs API key", "Optional — only for the backup engine") { field(SecureField("Not set", text: $s.elevenKey)) }
                divider
                row("Use the backup engine if Gemini is down", "ElevenLabs Scribe") { toggle("Use the backup engine if Gemini is down", $s.elevenLabsFallback) }
                divider
                row("Use the ElevenLabs key from ~/.config/elevenlabs", "Another tool's key on this Mac — only if you allow it") {
                    toggle("Use the ElevenLabs key from another tool", $s.useSystemElevenLabsKey)
                }
                divider
                row("Models", "Tried in this order") { field(TextField("", text: $s.models)) }
                divider
                HStack(spacing: 12) {
                    Button { NSWorkspace.shared.open(Paths.support) } label: { Label("Show data folder", systemImage: "folder") }
                        .buttonStyle(PillButtonStyle())
                    Spacer()
                    if s.saved { Text("Saved ✓").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.successText) }
                    Button("Save") { s.saveAdvanced() }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
        }
        .wfCard()
    }

    // MARK: ชิ้นส่วน

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 20) }

    /// ป้ายซ่อนด้วยตา แต่ VoiceOver อ่านชื่อแถวได้
    private func toggle(_ label: String, _ b: Binding<Bool>) -> some View {
        Toggle(label, isOn: b).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
    }

    // MARK: Privacy

    private var privacy: some View {
        section("Privacy") {
            VStack(alignment: .leading, spacing: 6) {
                Text("What leaves your Mac").font(.system(size: 14, weight: .semibold))
                Text("While you hold the key (or until you end hands-free), your voice goes to Google Gemini to become text, along with your About-you note, your dictionary words, snippet triggers and the name of the app you're typing in. “Look at nearby text” adds up to 400 characters before your cursor. “Learn from my corrections” sends the short phrase you fixed. Never from password fields, terminals or password managers. If you added an ElevenLabs key, your audio goes there only when Gemini is down. Free Gemini keys: Google may use what you send to improve its products, and people may review it. With Private mode on, nothing is sent — Whisper runs on this Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            divider
            row("Private mode (advanced)", "Transcribe on this Mac only — nothing leaves it · needs whisper.cpp + a 3 GB model · slower, less polished · no Command mode") {
                toggle("Private mode", $s.privateMode)
            }
            .opacity(LocalWhisper.available ? 1 : 0.45).disabled(!LocalWhisper.available && !s.privateMode)
            divider
            row("Work offline", "No internet or the cloud is down → transcribe on this Mac") { toggle("Work offline", $s.offlineFallback) }
            .opacity(LocalWhisper.available ? 1 : 0.45).disabled(!LocalWhisper.available)
            HStack(spacing: 6) {
                Image(systemName: LocalWhisper.available ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 11.5))
                    .foregroundStyle(LocalWhisper.available ? Theme.successText : Theme.accentText)
                Text(LocalWhisper.status).font(.system(size: 12)).foregroundStyle(Theme.muted2)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            divider
            row("Keep a history on this Mac", "Shown in History · never uploaded") { toggle("Keep a history on this Mac", $s.keepHistory) }
            divider
            row("Keep history for") {
                Segmented(items: [(7, "7 days"), (30, "30 days"), (0, "Forever")], selection: s.historyDays, capsule: false, fontSize: 12.5) { s.historyDays = $0 }
            }
            .opacity(s.keepHistory ? 1 : 0.45).disabled(!s.keepHistory)
            divider
            HStack {
                Spacer()
                if s.historyCleared { Text("Cleared ✓").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.successText) }
                Button { s.clearHistory() } label: { Label("Clear history", systemImage: "trash") }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private func field<V: View>(_ v: V) -> some View {
        v.textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 10).frame(width: 280, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chip))
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title)
            VStack(spacing: 0) { content() }.wfCard()
        }
    }

    private func row<V: View>(_ title: String, _ note: String? = nil, @ViewBuilder _ control: () -> V) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
