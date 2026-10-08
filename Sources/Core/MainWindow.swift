import AppKit
import SwiftUI

/// หน้าต่างหลัก — ภาษาดีไซน์แบบ Wispr Flow: โทนครีมสว่าง · การ์ดเนื้อหาสีขาว · ตัวเลข serif · รายการเส้นคั่นบางๆ
@MainActor
final class HubModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case dictation, dictionary, style, shortcuts, settings, help
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dictation: "Dictation"
            case .dictionary: "Dictionary"
            case .style: "Style"
            case .shortcuts: "Shortcuts"
            case .settings: "Settings"
            case .help: "Help"
            }
        }
        var icon: String {
            switch self {
            case .dictation: "mic"
            case .dictionary: "character.book.closed"
            case .style: "textformat"
            case .shortcuts: "keyboard"
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            }
        }
        static let main: [Page] = [.dictation, .dictionary, .style, .shortcuts]
        static let bottom: [Page] = [.settings, .help]
    }

    @Published var page: Page = .dictation
    @Published var entries: [HistoryEntry] = []
    @Published var search = ""
    @Published var searching = false
    @Published var hovered: Double?
    @Published var copiedID: Double?
    @Published var styleTab: StyleCategory = .personal
    @Published var styles: [StyleCategory: WritingStyle] = [:]
    let settings: SettingsModel
    let dictionary = DictionaryModel()
    var onDemo: () -> Void = {}

    init(settings: SettingsModel) {
        self.settings = settings
        loadStyles()
    }

    func reload() {
        entries = History.recent(5000)
        dictionary.load()
        loadStyles()
    }

    private func loadStyles() {
        for c in StyleCategory.allCases { styles[c] = Store.config.style(for: c) }
    }

    func setStyle(_ s: WritingStyle, for c: StyleCategory) {
        styles[c] = s
        Store.update { $0.styles[c.rawValue] = s.rawValue }
    }

    func copy(_ e: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
        copiedID = e.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.copiedID == e.id { self.copiedID = nil } }
    }

    func delete(_ e: HistoryEntry) {
        History.delete(e.t)
        entries.removeAll { $0.t == e.t }
    }

    // MARK: สถิติ

    struct Stats { var words = 0; var savedMinutes = 0; var wpm = 0; var streak = 0 }

    var stats: Stats {
        var s = Stats()
        var spoken = 0.0, ms = 0
        for e in entries { s.words += Self.wordCount(e.text); spoken += e.sec; ms += e.ms }
        // พิมพ์ไทยเฉลี่ย ~35 คำ/นาที vs เวลาพูด + รอผล
        s.savedMinutes = max(0, Int((Double(s.words) / 35 * 60 - spoken - Double(ms) / 1000) / 60))
        s.wpm = spoken > 0 ? Int(Double(s.words) / (spoken / 60)) : 0
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0.t)) })
        var d = cal.startOfDay(for: Date())
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while days.contains(d) { s.streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return s
    }

    static func wordCount(_ s: String) -> Int {
        EditDiff.tokens(s).filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }.count
    }

    /// ประวัติแบ่งตามวัน (กรองด้วยคำค้น)
    var grouped: [(String, [HistoryEntry])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        for e in list {
            let d = Date(timeIntervalSince1970: e.t)
            let label = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : Self.dayFmt.string(from: d)
            if out.last?.0 == label { out[out.count - 1].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE, MMMM d"; return f }()
    static let timeFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f }()
}

/// พจนานุกรม (แก้ไฟล์ dictionary.txt ตรง ไม่ยุ่งกับบรรทัดคอมเมนต์)
@MainActor
final class DictionaryModel: ObservableObject {
    @Published var words: [String] = []
    @Published var fixes: [(String, String)] = []
    @Published var learned: [(String, String)] = []
    @Published var newWord = ""
    @Published var adding = false
    @Published var rawMode = false
    @Published var hovered: String?
    let raw = TextFileModel(url: Paths.dictionary)

    func load() {
        let e = Prompt.dictionaryEntries()
        words = e.words
        fixes = e.fixes
        learned = e.hints
        raw.load()
    }

    func add() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !w.contains("\n") else { return }
        var s = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        if !words.contains(w) { s += w + "\n" }
        try? s.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        newWord = ""
        adding = false
        load()
    }

    func remove(line: String) {
        guard let s = try? String(contentsOf: Paths.dictionary, encoding: .utf8) else { return }
        var lines = s.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { lines.remove(at: i) }
        try? lines.joined(separator: "\n").write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        load()
    }
}

// MARK: - สี/ตัวอักษร

enum Theme {
    static let canvas = Color(red: 0.965, green: 0.957, blue: 0.937)     // ครีม (พื้นหลังหน้าต่าง + แถบซ้าย)
    static let paper = Color.white                                         // การ์ดเนื้อหา
    static let line = Color(red: 0.905, green: 0.894, blue: 0.870)         // เส้นขอบ/คั่น
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.11)
    static let muted = Color(red: 0.47, green: 0.46, blue: 0.43)
    static let selected = Color(red: 0.918, green: 0.910, blue: 0.890)
    static let hover = Color(red: 0.975, green: 0.970, blue: 0.957)
    static func serif(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .serif) }
}

struct HubView: View {
    @ObservedObject var m: HubModel
    var scrollable = true   // false = เรนเดอร์เป็นภาพ (ImageRenderer วาด ScrollView ไม่ได้)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 206)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                .padding([.top, .trailing, .bottom], 8)
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .frame(minWidth: 940, minHeight: 640)
    }

    // MARK: แถบซ้าย

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 17, weight: .bold))
                Text("WhisperFirst").font(.system(size: 17, weight: .bold)).tracking(-0.3)
            }
            .padding(.horizontal, 16).padding(.top, 46).padding(.bottom, 16)
            ForEach(HubModel.Page.main) { navItem($0) }
            Spacer()
            readiness.padding(.horizontal, 10).padding(.bottom, 10)
            ForEach(HubModel.Page.bottom) { navItem($0) }
            Spacer().frame(height: 12)
        }
    }

    private var readiness: some View {
        let ok = AX.trusted && Keys.gemini != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(ok ? "Ready" : "Setup incomplete").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 4) {
                Text("Hold").font(.system(size: 11)).foregroundStyle(Theme.muted)
                ForEach(m.settings.shortcuts.combos(.pushToTalk).first.map(Keys2.sorted) ?? [], id: \.self) { keyCap(Keys2.label($0)) }
                Text("to dictate").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Capsule().fill(Theme.line).frame(height: 4)
                .overlay(alignment: .leading) { Capsule().fill(Theme.ink).frame(width: ok ? 150 : 50, height: 4) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func navItem(_ p: HubModel.Page) -> some View {
        let on = m.page == p
        return Button { m.page = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon).font(.system(size: 13)).frame(width: 18)
                Text(p.title).font(.system(size: 13.5, weight: on ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 6.5)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: หน้า

    @ViewBuilder private var page: some View {
        switch m.page {
        case .dictation: scroll(DictationPage(m: m))
        case .dictionary: scroll(DictionaryPage(d: m.dictionary))
        case .style: scroll(StylePage(m: m))
        case .shortcuts: ShortcutsTab(m: m.settings.shortcuts, scrollable: scrollable)
        case .settings: SettingsPage(s: m.settings)
        case .help: scroll(HelpPage(m: m))
        }
    }

    @ViewBuilder private func scroll<V: View>(_ v: V) -> some View {
        if scrollable { ScrollView { v.padding(.horizontal, 36).padding(.vertical, 32) } }
        else { v.padding(.horizontal, 36).padding(.vertical, 32) }
    }
}

func keyCap(_ s: String) -> some View {
    Text(s).font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
}

private func outlined<V: View>(_ radius: CGFloat = 12, @ViewBuilder _ content: () -> V) -> some View {
    content()
        .background(RoundedRectangle(cornerRadius: radius).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.line))
}

private func blackButton(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
    }
    .buttonStyle(.plain)
}

// MARK: พิมพ์ด้วยเสียง (หน้าหลัก)

private struct DictationPage: View {
    @ObservedObject var m: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Welcome back, \(Store.config.displayName)").font(.system(size: 21, weight: .semibold))
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 26) {
                    banner
                    history
                }
                .frame(maxWidth: .infinity)
                statsCard.frame(width: 200)
            }
        }
    }

    private var banner: some View {
        ZStack(alignment: .leading) {
            Color.black
            // แสงอุ่นๆ ฟุ้งด้านขวา (แทนภาพถ่าย)
            GeometryReader { g in
                ZStack {
                    Circle().fill(Color(red: 0.98, green: 0.62, blue: 0.25)).frame(width: 240).offset(x: g.size.width * 0.32, y: -10).blur(radius: 60)
                    Circle().fill(Color(red: 0.85, green: 0.30, blue: 0.20)).frame(width: 160).offset(x: g.size.width * 0.18, y: 40).blur(radius: 55)
                    Circle().fill(Color(red: 1.0, green: 0.85, blue: 0.55)).frame(width: 90).offset(x: g.size.width * 0.38, y: 10).blur(radius: 30)
                }
                .frame(width: g.size.width, height: g.size.height)
                .opacity(0.9)
            }
            VStack(alignment: .leading, spacing: 8) {
                (Text("Make WhisperFirst sound like ").font(Theme.serif(25)) + Text("you").font(Theme.serif(25).italic()))
                    .foregroundStyle(.white)
                Text("Set up different writing styles for different apps.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Button { m.page = .style } label: {
                    Text("Start now").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 26)
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statsCard: some View {
        let st = m.stats
        return outlined {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    statLine("\(st.words.formatted())", "total words")
                    statLine("\(st.wpm)", "wpm")
                    statLine("\(st.streak)", "day streak")
                }
                .padding(18)
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    (Text("\(st.savedMinutes) min").font(.system(size: 13, weight: .semibold)).foregroundColor(Color(red: 0.85, green: 0.42, blue: 0.13))
                        + Text(" saved").font(.system(size: 13, weight: .medium)))
                    Text("vs. typing at ~35 words per minute").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .padding(18)
            }
        }
    }

    private func statLine(_ v: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(v).font(Theme.serif(22))
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var history: some View {
        let groups = m.grouped
        if m.entries.isEmpty {
            Text("No dictations yet — hold your shortcut and speak in any app").font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(g.0.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                    Spacer()
                    if i == 0 {
                        if m.searching {
                            TextField("Search", text: $m.search).textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 180)
                        }
                        Button { m.searching.toggle(); if !m.searching { m.search = "" } } label: {
                            Image(systemName: m.searching ? "xmark" : "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                outlined(10) {
                    VStack(spacing: 0) {
                        ForEach(Array(g.1.enumerated()), id: \.element.id) { j, e in
                            if j > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                            HistoryRow(m: m, e: e)
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @ObservedObject var m: HubModel
    let e: HistoryEntry

    var body: some View {
        let hover = m.hovered == e.id
        HStack(alignment: .top, spacing: 0) {
            Text(HubModel.timeFmt.string(from: Date(timeIntervalSince1970: e.t)))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.text).font(.system(size: 13.5)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if hover {
                    Text("\(e.app.isEmpty ? "-" : e.app) · spoke \(String(format: "%.1f", e.sec))s · ready in \(String(format: "%.1f", Double(e.ms) / 1000))s\(e.mode == "command" ? " · command" : "")")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 12) {
                icon(m.copiedID == e.id ? "checkmark" : "doc.on.doc", "Copy") { m.copy(e) }
                icon("trash", "Delete") { m.delete(e) }
            }
            .opacity(hover ? 1 : 0)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hover ? Theme.hover : Theme.paper)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { m.hovered = e.id } else if m.hovered == e.id { m.hovered = nil }
        }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
            .buttonStyle(.plain).help(help)
    }
}

// MARK: พจนานุกรม

private struct DictionaryPage: View {
    @ObservedObject var d: DictionaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Text("Dictionary").font(.system(size: 21, weight: .semibold))
                Spacer()
                Toggle("Edit as text", isOn: $d.rawMode).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                blackButton("Add new") { d.adding = true; d.rawMode = false }
            }
            Text("Names, projects and jargon you want spelled right every time · Select a word in any app and press ⌃⌥D to add it · WhisperFirst also learns words you correct after pasting")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if d.rawMode {
                TextFileTab(m: d.raw, hint: "One word per line · heard => correct (always replaced) · heard ~> correct (hint for the model)")
                    .frame(minHeight: 420)
                    .onDisappear { d.load() }
            } else {
                if d.adding {
                    outlined(10) {
                        HStack {
                            TextField("Type a word and press Enter — e.g. a friend's name or a brand", text: $d.newWord)
                                .textFieldStyle(.plain).font(.system(size: 13.5)).onSubmit { d.add() }
                            Button("Cancel") { d.adding = false; d.newWord = "" }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                            blackButton("Add") { d.add() }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                list("My words", d.words.map { ($0, nil, $0) })
                if !d.learned.isEmpty {
                    list("Learned from your edits", d.learned.map { ($0.1, "heard as \"\($0.0)\"", "\($0.0) ~> \($0.1)") })
                }
                if !d.fixes.isEmpty {
                    list("Replacements", d.fixes.map { ($0.1, "replaces \"\($0.0)\"", "\($0.0) => \($0.1)") })
                }
            }
        }
    }

    private func list(_ title: String, _ rows: [(word: String, note: String?, line: String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title.uppercased()) · \(rows.count)").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
            outlined(10) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.line) { i, r in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        let hover = d.hovered == r.line
                        HStack {
                            Text(r.word).font(.system(size: 13.5))
                            if let note = r.note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                            Spacer()
                            Button { d.remove(line: r.line) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                                .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Delete")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(hover ? Theme.hover : Theme.paper)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { d.hovered = r.line } else if d.hovered == r.line { d.hovered = nil } }
                    }
                }
            }
        }
    }
}

// MARK: สไตล์

private struct StylePage: View {
    @ObservedObject var m: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Style").font(.system(size: 21, weight: .semibold))
            HStack(spacing: 22) {
                ForEach(StyleCategory.allCases) { c in
                    Button { m.styleTab = c } label: {
                        VStack(spacing: 7) {
                            Text(c.title).font(.system(size: 13.5, weight: m.styleTab == c ? .semibold : .regular))
                                .foregroundStyle(m.styleTab == c ? Theme.ink : Theme.muted)
                            Rectangle().fill(m.styleTab == c ? Theme.ink : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 0.5) }
            Text("This style applies in \(m.styleTab.apps) · Only formatting and punctuation change — never your words")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            HStack(alignment: .top, spacing: 14) {
                ForEach(WritingStyle.allCases) { s in styleCard(s) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("About you".uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                TextFileTab(m: m.settings.aboutMe, hint: "Describe your work, common jargon and how you like to write — it helps WhisperFirst guess words and tone")
                    .frame(minHeight: 170)
            }
            .padding(.top, 8)
        }
    }

    private func styleCard(_ s: WritingStyle) -> some View {
        let on = m.styles[m.styleTab] == s
        return Button { m.setStyle(s, for: m.styleTab) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title + (s == .formal ? "." : "")).font(Theme.serif(26))
                Text(s.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(s.example)
                    .font(.system(size: 12.5)).lineSpacing(3)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
                    .padding(.top, 14)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.ink : Theme.line, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: วิธีใช้

private struct HelpPage: View {
    @ObservedObject var m: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Help").font(.system(size: 21, weight: .semibold))
            outlined {
                VStack(spacing: 0) {
                    row(m.settings.shortcuts.combos(.pushToTalk).first, "Push to talk", "Release to paste into the current app")
                    divider
                    row(m.settings.shortcuts.combos(.handsFree).first, "Hands-free", "Press to start, press again to stop — or double-tap push to talk")
                    divider
                    row(["shift"], "Command mode", "Press while speaking, then say e.g. \"translate to English\" for the selected text")
                    divider
                    row(["k:53"], "Cancel", "While speaking or waiting for the result")
                    divider
                    row(m.settings.shortcuts.combos(.addWord).first, "Teach a word", "Select a word in any app, then press")
                }
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dynamic Island").font(Theme.serif(20))
                    Text("The island at the top of your screen shows everything from the moment you speak until text is pasted — waveform, live transcript, the pasted text, retry.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                blackButton("Play demo") { m.onDemo() }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.canvas))
        }
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func row(_ combo: KeyCombo?, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                if let combo { ForEach(Keys2.sorted(combo), id: \.self) { keyCap(Keys2.label($0)) } } else { Text("Not set").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            .frame(width: 120, alignment: .leading)
            Text(title).font(.system(size: 13.5, weight: .medium)).frame(width: 110, alignment: .leading)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: ตั้งค่า

private struct SettingsPage: View {
    @ObservedObject var s: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: 21, weight: .semibold)).padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 4)
            GeneralTab(vm: s).scrollContentBackground(.hidden)
        }
    }
}
