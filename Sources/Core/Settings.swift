import AppKit
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    let shortcuts: ShortcutsModel
    var onIslandChange: (() -> Void)?
    @Published var islandTop = Store.config.islandTop { didSet { Store.update { $0.islandTop = islandTop }; onIslandChange?() } }
    @Published var islandIdle = Store.config.islandIdle { didSet { Store.update { $0.islandIdle = islandIdle }; onIslandChange?() } }
    @Published var liveTranscript = Store.config.liveTranscript { didSet { Store.update { $0.liveTranscript = liveTranscript } } }
    @Published var fastText = Store.config.fastText { didSet { Store.update { $0.fastText = fastText } } }
    init(engine: ShortcutEngine) { shortcuts = ShortcutsModel(engine: engine) }

    @Published var displayName = Store.config.displayName { didSet { Store.update { $0.displayName = displayName } } }
    @Published var sounds = Store.config.sounds { didSet { Store.update { $0.sounds = sounds } } }
    @Published var speculative = Store.config.speculative { didSet { Store.update { $0.speculative = speculative } } }
    @Published var learnFromEdits = Store.config.learnFromEdits { didSet { Store.update { $0.learnFromEdits = learnFromEdits } } }
    @Published var useContext = Store.config.useContext { didSet { Store.update { $0.useContext = useContext } } }
    @Published var restoreClipboard = Store.config.restoreClipboard { didSet { Store.update { $0.restoreClipboard = restoreClipboard } } }
    @Published var elevenLabsFallback = Store.config.elevenLabsFallback { didSet { Store.update { $0.elevenLabsFallback = elevenLabsFallback } } }
    @Published var models = Store.config.models.joined(separator: ", ")
    @Published var geminiKey = Keys.gemini ?? ""
    @Published var elevenKey = Keys.savedElevenLabs
    @Published var saved = false
    let dictionary = TextFileModel(url: Paths.dictionary)
    let aboutMe = TextFileModel(url: Paths.aboutMe)

    func saveAdvanced() {
        let list = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !list.isEmpty { Store.update { $0.models = list } }
        Keys.save(gemini: geminiKey, elevenLabs: elevenKey)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.saved = false }
    }
}

struct GeneralTab: View {
    @ObservedObject var vm: SettingsModel

    var body: some View {
        Form {
            Section("How to use") {
                Text("Hold \(Store.config.pushToTalkLabel) and speak, release to paste · Double-tap = hands-free · ⇧ while speaking = command mode · Esc = cancel — change keys under Shortcuts")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("General") {
                TextField("Your name", text: $vm.displayName)
            }
            Section("Dynamic Island") {
                Picker("Position", selection: $vm.islandTop) {
                    Text("Top center (blends with notch)").tag(true)
                    Text("Bottom center (like Wispr)").tag(false)
                }
                Toggle("Show mini island when idle (hover for tips · click to dictate)", isOn: $vm.islandIdle)
                Toggle("Show live transcript while speaking (Gemini Live)", isOn: $vm.liveTranscript)
                Picker("Speed / accuracy", selection: $vm.fastText) {
                    Text("Fast — short phrases polished from live text (~1.5–2s)").tag(true)
                    Text("Most accurate — always send audio (~2–3s)").tag(false)
                }
                .disabled(!vm.liveTranscript)
                Text("Fast mode applies to short phrases (≤15s) only; long dictation always sends audio · Requires live transcript · Occasionally the live transcript mishears a word — switch to Most accurate if that happens often")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Start/stop sounds", isOn: $vm.sounds)
                Toggle("Learn words from your edits after pasting", isOn: $vm.learnFromEdits)
                Toggle("Use text before the cursor as context (helps spelling; never reads password fields)", isOn: $vm.useContext)
                Toggle("Restore clipboard after pasting", isOn: $vm.restoreClipboard)
                Toggle("Fall back to ElevenLabs Scribe if Gemini is down", isOn: $vm.elevenLabsFallback)
            }
            Section("Models & API keys") {
                TextField("Gemini models (tried in order)", text: $vm.models)
                SecureField("Gemini API key", text: $vm.geminiKey)
                SecureField("ElevenLabs API key (optional if ~/.config/elevenlabs exists)", text: $vm.elevenKey)
                HStack {
                    Spacer()
                    if vm.saved { Text("Saved ✓").foregroundStyle(.green) }
                    Button("Save") { vm.saveAdvanced() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
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

struct TextFileTab: View {
    @ObservedObject var m: TextFileModel
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $m.text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Button("Reload") { m.load() }
                Spacer()
                if m.saved { Text("Saved ✓").foregroundStyle(.green) }
                Button("Save") { m.save() }.keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(8)
        .onAppear { m.load() }
        .onDisappear { m.save() }
    }
}
