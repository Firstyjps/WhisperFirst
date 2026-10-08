import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    let shortcuts: ShortcutsModel
    var onIslandChange: (() -> Void)?
    init(engine: ShortcutEngine) { shortcuts = ShortcutsModel(engine: engine) }

    @Published var displayName = Store.config.displayName { didSet { Store.update { $0.displayName = displayName } } }
    @Published var sounds = Store.config.sounds { didSet { Store.update { $0.sounds = sounds } } }
    @Published var islandTop = Store.config.islandTop { didSet { Store.update { $0.islandTop = islandTop }; onIslandChange?() } }
    @Published var islandIdle = Store.config.islandIdle { didSet { Store.update { $0.islandIdle = islandIdle }; onIslandChange?() } }
    @Published var liveTranscript = Store.config.liveTranscript { didSet { Store.update { $0.liveTranscript = liveTranscript } } }
    @Published var fastText = Store.config.fastText { didSet { Store.update { $0.fastText = fastText } } }
    @Published var learnFromEdits = Store.config.learnFromEdits { didSet { Store.update { $0.learnFromEdits = learnFromEdits } } }
    @Published var useContext = Store.config.useContext { didSet { Store.update { $0.useContext = useContext } } }
    @Published var restoreClipboard = Store.config.restoreClipboard { didSet { Store.update { $0.restoreClipboard = restoreClipboard } } }
    @Published var elevenLabsFallback = Store.config.elevenLabsFallback { didSet { Store.update { $0.elevenLabsFallback = elevenLabsFallback } } }
    /// เปิดตอนเข้าสู่ระบบ (SMAppService — ตัวเดียวกับในเมนู)
    @Published var loginItem = SMAppService.mainApp.status == .enabled {
        didSet {
            guard loginItem != (SMAppService.mainApp.status == .enabled) else { return }
            do { if loginItem { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.write("login item: \(error.localizedDescription)") }
        }
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
    init(url: URL) { self.url = url }

    func load() { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func save() {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
                row("Open when I log in") { toggle($s.loginItem) }
                divider
                row("Play a sound when I start and stop") { toggle($s.sounds) }
            }
            section("Dynamic Island") {
                row("Where it appears", "Top blends into the notch on MacBooks") {
                    Segmented(items: [(true, "Top"), (false, "Bottom")], selection: s.islandTop, capsule: false, fontSize: 12.5) { s.islandTop = $0 }
                }
                divider
                row("Show a small island when idle", "Hover it for tips, click it to start talking") { toggle($s.islandIdle) }
                divider
                row("Show my words while I talk", "See what you're saying, live") { toggle($s.liveTranscript) }
                divider
                row("Speed", s.fastText ? "Short phrases are ready in about 1.5 seconds" : "Always listens to the full audio · about 2–3 seconds") {
                    Segmented(items: [(true, "Faster"), (false, "More accurate")], selection: s.fastText, capsule: false, fontSize: 12.5) { s.fastText = $0 }
                }
                .opacity(s.liveTranscript ? 1 : 0.45)
                .disabled(!s.liveTranscript)
            }
            section("Smart helpers") {
                row("Learn from my corrections", "If you fix a word after it's typed, it'll spell it that way next time") { toggle($s.learnFromEdits) }
                divider
                row("Look at nearby text for better spelling", "Never reads password fields") { toggle($s.useContext) }
                divider
                row("Put my clipboard back after pasting") { toggle($s.restoreClipboard) }
            }
            advanced
        }
        .onAppear { checkup.runIfStale() }
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
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
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
                row("Use the backup engine if Gemini is down", "ElevenLabs Scribe") { toggle($s.elevenLabsFallback) }
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

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
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
