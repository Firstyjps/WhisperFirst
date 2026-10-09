import AppKit
import AVFoundation
import SwiftUI

/// หน้าต่างหลัก — ดีไซน์จาก handoff "UI ปรับปรุงเพื่อ Production" (Claude Design, Round 3)
/// โทนครีมนุ่ม · ตัวอักษร rounded · ไม่มี scrollbar · ภาษาง่ายสำหรับคนทั่วไป
@MainActor
final class HubModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case home, history, dictionary, snippets, style, shortcuts, settings, help
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .history: "History"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .style: "Writing Style"
            case .shortcuts: "Shortcuts"
            case .settings: "Settings"
            case .help: "Help"
            }
        }
        var icon: String {
            switch self {
            case .home: "house"
            case .history: "clock"
            case .dictionary: "character.book.closed"
            case .snippets: "text.insert"
            case .style: "textformat"
            case .shortcuts: "keyboard"
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            }
        }
        static let main: [Page] = [.home, .history, .dictionary, .snippets, .style, .shortcuts]
        static let bottom: [Page] = [.settings, .help]
    }

    @Published var page: Page = .home {
        didSet { if page != oldValue { settings.shortcuts.cancelRecording() } }   // ออกจากหน้า Shortcuts = เลิกอัด
    }
    @Published var entries: [HistoryEntry] = [] { didSet { regroup(); recomputeStats() } }
    @Published var search = "" { didSet { regroup() } }
    /// คำนวณครั้งเดียวเมื่อประวัติเปลี่ยน (ไม่ใช่ทุก render) — ตัดคำทั้งประวัติใช้เวลาหลายร้อย ms
    @Published private(set) var stats = Stats()
    @Published private(set) var grouped: [(id: Date, label: String, items: [HistoryEntry])] = []
    @Published var copiedID: Double?
    @Published var styleTab: StyleCategory = .personal
    @Published var styles: [StyleCategory: WritingStyle] = [:]
    let settings: SettingsModel
    let dictionary = DictionaryModel()
    let snippets = SnippetsModel()
    let checkup = CheckupModel()
    let overlay: OverlayModel
    var onDemo: () -> Void = {}
    var onGuide: () -> Void = {}
    private var observer: NSObjectProtocol?

    init(settings: SettingsModel, overlay: OverlayModel) {
        self.settings = settings
        self.overlay = overlay
        loadStyles()
        // พูดเสร็จ → แทรกรายการใหม่เข้าหัวรายการเลย (ไม่อ่านไฟล์ทั้งก้อนบน main)
        observer = NotificationCenter.default.addObserver(forName: History.changed, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let e = n.object as? HistoryEntry { if !self.entries.contains(where: { $0.t == e.t }) { self.entries.insert(e, at: 0) } }
                else { self.reload() }
            }
        }
    }

    func reload() {
        dictionary.load()
        snippets.load()
        loadStyles()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = History.recent(5000)
            DispatchQueue.main.async { self.entries = list }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { if self.copiedID == e.id { self.copiedID = nil } }
    }

    func delete(_ e: HistoryEntry) {
        History.delete(e.t)
        entries.removeAll { $0.t == e.t }
    }

    // MARK: สถิติ

    struct Stats { var words = 0; var savedMinutes = 0; var streak = 0 }

    private var statsGeneration = 0

    private func recomputeStats() {
        statsGeneration += 1
        let gen = statsGeneration, list = entries
        DispatchQueue.global(qos: .utility).async {
            var s = Stats()
            var spoken = 0.0, ms = 0
            for e in list { s.words += Self.wordCount(e.text); spoken += e.sec; ms += e.ms }
            // พิมพ์เฉลี่ย ~35 คำ/นาที vs เวลาพูด + รอผล
            s.savedMinutes = max(0, Int((Double(s.words) / 35 * 60 - spoken - Double(ms) / 1000) / 60))
            let cal = Calendar.current
            let days = Set(list.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0.t)) })
            var d = cal.startOfDay(for: Date())
            if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
            while days.contains(d) { s.streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
            DispatchQueue.main.async { if gen == self.statsGeneration { self.stats = s } }
        }
    }

    nonisolated     static func wordCount(_ s: String) -> Int {
        EditDiff.tokens(s).filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }.count
    }

    /// ประวัติแบ่งตามวัน (กรองด้วยคำค้น) — id = วันจริง (กันวันเดียวกันต่างปีชนกัน)
    private func regroup() {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        var out: [(id: Date, label: String, items: [HistoryEntry])] = []
        for e in list {
            let d = Date(timeIntervalSince1970: e.t)
            let day = cal.startOfDay(for: d)
            if out.last?.id == day { out[out.count - 1].items.append(e); continue }
            let label = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday"
                : (cal.component(.year, from: d) == thisYear ? Self.dayFmt : Self.dayYearFmt).string(from: d)
            out.append((day, label, [e]))
        }
        grouped = out
    }

    static let dayYearFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE, MMMM d, yyyy"; return f }()
    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE, MMMM d"; return f }()
    static let timeFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mm a"; return f }()

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
}

/// ตรวจสุขภาพ: ไมค์ · สิทธิ์พิมพ์ลงแอปอื่น · การเชื่อมต่อ (ยิงข้อความสั้นๆ วัดเวลาตอบ)
@MainActor
final class CheckupModel: ObservableObject {
    enum State { case idle, checking, done }
    @Published var state: State = .idle
    @Published var mic = false
    @Published var typing = false
    @Published var online = false
    @Published var seconds: Double = 0
    @Published var checkedAt: Date?

    var allGood: Bool { mic && typing && online }

    /// เปิดหน้า Settings: ตรวจไมค์/สิทธิ์ในเครื่องทุกครั้ง · ทดสอบการเชื่อมต่อ (ยิง API) เฉพาะครั้งแรกหรือเกิน 10 นาที
    func runIfStale() {
        if state == .checking { return }
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        typing = AX.trusted
        if let t = checkedAt, Date().timeIntervalSince(t) < 600 { return }
        run()
    }

    func run() {
        state = .checking
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        typing = AX.trusted
        Task {
            let t0 = Date()
            var ok = false
            if Keys.gemini != nil {
                ok = ((try? await Transcriber().complete(system: "Reply with OK only.", user: "ping", json: false)) ?? "").isEmpty == false
            }
            self.online = ok
            self.seconds = Date().timeIntervalSince(t0)
            self.checkedAt = Date()
            self.state = .done
        }
    }
}

/// พจนานุกรม (แก้ไฟล์ dictionary.txt ตรง ไม่ยุ่งกับบรรทัดคอมเมนต์)
@MainActor
final class DictionaryModel: ObservableObject {
    @Published var words: [String] = []
    @Published var fixes: [(String, String)] = []
    @Published var learned: [(String, String)] = []
    @Published var newWord = ""
    @Published var rawMode = false
    @Published var justAdded: String?
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
        load()
        justAdded = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.justAdded == w { self.justAdded = nil } }
    }

    /// ลบบรรทัด — เทียบแบบแยกคู่ (ทนช่องว่างที่ผู้ใช้พิมพ์เองในโหมดข้อความ เช่น "a=>b" / "a  =>  b")
    func remove(line: String) {
        guard let s = try? String(contentsOf: Paths.dictionary, encoding: .utf8) else { return }
        var lines = s.components(separatedBy: "\n")
        let norm: (String) -> String = { l in
            var t = l.trimmingCharacters(in: .whitespaces)
            for sep in ["=>", "~>"] where t.contains(sep) {
                let parts = t.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
                t = parts.joined(separator: " \(sep) ")
            }
            return t
        }
        let target = norm(line)
        if let i = lines.firstIndex(where: { norm($0) == target }) { lines.remove(at: i) }
        try? lines.joined(separator: "\n").write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        load()
    }
}

/// ไอคอนแอปจริงจาก bundle id (ประวัติใหม่) หรือชื่อแอป (ประวัติเก่า)
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(app: String, bundle: String?) -> NSImage? {
        let key = (bundle?.isEmpty == false ? bundle! : app)
        if let c = cache[key] { return c }
        if missing.contains(key) || key.isEmpty { return nil }
        var url: URL?
        if let b = bundle, !b.isEmpty { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) }
        if url == nil {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                let p = "\(dir)/\(app).app"
                if FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p); break }
            }
        }
        if url == nil { url = NSWorkspace.shared.runningApplications.first { $0.localizedName == app }?.bundleURL }
        guard let url else { missing.insert(key); return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = img
        return img
    }
}

// MARK: - Design tokens

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum Theme {
    static let windowBg = Color(hex: 0xF6F2EC)
    static let contentBg = Color(hex: 0xFBF9F6)
    static let card = Color.white
    static let ink = Color(hex: 0x2B2620)
    static let inkSecondary = Color(hex: 0x4A433C)
    // เข้มกว่า handoff เล็กน้อยเพื่อ contrast ≥4.5:1 (เดิม 2.6–3.6:1)
    static let muted = Color(hex: 0x6F665D)
    static let muted2 = Color(hex: 0x776E65)
    static let faint = Color(hex: 0x857B71)
    static let hoverRow = Color(hex: 0xF7F2EC)
    static let chip = Color(hex: 0xF6F2EC)
    static let pillBtn = Color(hex: 0xF3EEE8)
    static let segTrack = Color(hex: 0xEFE9E1)
    static let hairline = Color(hex: 0xF1ECE5)
    static let stroke = Color(hex: 0xEAE3DA)
    static let keycapEdge = Color(hex: 0xE3DBD0)
    static let accent = Color(hex: 0xD9732F)
    static let accentPressed = Color(hex: 0xBF6326)
    static let accentText = Color(hex: 0xC8641F)
    static let accentSoft = Color(hex: 0xFBEADB)
    static let accentSoftText = Color(hex: 0xB3561A)
    static let successText = Color(hex: 0x2E8B4E)
    static let successBg = Color(hex: 0xE6F4EA)
    static let successBanner = Color(hex: 0x1F6E3A)
    static let warnText = Color(hex: 0x9A4A12)
    static let warnBg = Color(hex: 0xFDF0E1)
    static let helpDark = Color(hex: 0x2B2620)
    static let tile = Color(hex: 0xF8F5F1)
    static let shadowTint = Color(hex: 0x50321A)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

// MARK: - ชิ้นส่วนที่ใช้ซ้ำ

extension View {
    /// การ์ดขาวมาตรฐาน: เงาสองชั้นนุ่มๆ
    func wfCard(_ radius: CGFloat = 16) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .shadow(color: Theme.shadowTint.opacity(0.06), radius: 1, y: 1)
            .shadow(color: Theme.shadowTint.opacity(0.05), radius: 10, y: 6)
    }

    /// เส้นขอบ 1pt รอบช่อง/การ์ดแบบ outline
    func wfOutline(_ radius: CGFloat, _ color: Color = Theme.stroke, _ width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width))
    }

    /// เลื่อนได้แต่ไม่มี scrollbar + จางขอบบน/ล่าง
    func wfFade(top: CGFloat = 0, bottom: CGFloat = 40) -> some View {
        mask(
            VStack(spacing: 0) {
                if top > 0 { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top) }
                Color.black
                if bottom > 0 { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom) }
            }
        )
    }
}

struct PageTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.rounded(27, .bold)).tracking(-0.3).foregroundStyle(Theme.ink)
            if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SectionTitle: View {
    let title: String
    var note: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.rounded(16, .semibold)).foregroundStyle(Theme.ink)
            if let note { Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.muted2) }
        }
        .padding(.leading, 4)
    }
}

/// ปุ่มลัดแบบปุ่มคีย์บอร์ดเล็ก
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text.count == 1 ? text.uppercased() : text)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 22)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycapEdge).offset(y: 1)
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chip)
                }
            )
            .wfOutline(7, Theme.keycapEdge)
    }
}

struct Keycaps: View {
    let combo: KeyCombo?
    var body: some View {
        HStack(spacing: 4) {
            if let combo, !combo.isEmpty { ForEach(Keys2.sorted(combo), id: \.self) { Keycap(text: Keys2.label($0)) } }
            else { Text("Not set").font(.system(size: 12)).foregroundStyle(Theme.faint) }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(configuration.isPressed ? Color(hex: 0xA44F18) : Theme.accentPressed))   // ตัวขาวบนส้มเข้มขึ้น อ่านง่ายกว่า
            .opacity(enabled ? 1 : 0.45)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(Theme.pillBtn))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// สถานะ hover ต่อแถว (ไม่ใช้ @State — CLT ไม่มี SwiftUI macro)
final class HoverState: ObservableObject { @Published var on = false }

/// ไอคอนแอป 34pt — ไอคอนจริงจากเครื่อง หรือวงกลมสีพร้อมตัวอักษรแรก
struct AppBadge: View {
    let app: String
    let bundle: String?
    var size: CGFloat = 34
    var body: some View {
        if let img = AppIcons.icon(app: app, bundle: bundle) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Circle().fill(Self.color(app)).frame(width: size, height: size)
                .overlay(Text(String(app.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
        }
    }
    static func color(_ app: String) -> Color {
        let palette: [UInt32] = [0x7A5AA6, 0x22A447, 0x2F7FF0, 0xD9A20B, 0x2FA851, 0xC96A48]
        let h = app.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }   // คงที่ข้ามการเปิดแอป (hashValue สุ่มทุก process)
        return Color(hex: palette[h % palette.count])
    }
}

// MARK: - โครงหน้าต่าง

struct HubView: View {
    @ObservedObject var m: HubModel
    var scrollable = true   // false = เรนเดอร์เป็นภาพ (ImageRenderer วาด ScrollView ไม่ได้)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 212)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.contentBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .wfOutline(12, Color(hex: 0x3C2814, alpha: 0.08), 0.5)
                .padding([.top, .trailing, .bottom], 10)
        }
        .background(Theme.windowBg)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .tint(Theme.accent)
        .frame(minWidth: 940, minHeight: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 46)   // ใต้ปุ่มแดง/เหลือง/เขียว 30pt
            ForEach(HubModel.Page.main) { NavItem(m: m, page: $0) }
            Spacer()
            ForEach(HubModel.Page.bottom) { NavItem(m: m, page: $0) }
        }
        .padding(.top, 0).padding(.horizontal, 12).padding(.bottom, 14)
    }

    @ViewBuilder private var page: some View {
        switch m.page {
        case .home: scroll(HomePage(m: m, overlay: m.overlay))
        case .history: HistoryPage(m: m, scrollable: scrollable)
        case .dictionary: scroll(DictionaryPage(d: m.dictionary, shortcuts: m.settings.shortcuts))
        case .snippets: scroll(SnippetsPage(m: m.snippets))
        case .style: scroll(StylePage(m: m))
        case .shortcuts: scroll(ShortcutsTab(m: m.settings.shortcuts))
        case .settings: scroll(SettingsPage(s: m.settings, checkup: m.checkup))
        case .help: scroll(HelpPage(m: m))
        }
    }

    @ViewBuilder private func scroll<V: View>(_ v: V) -> some View {
        let padded = v.padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 40).frame(maxWidth: .infinity, alignment: .leading)
        if scrollable { ScrollView { padded }.scrollIndicators(.hidden).wfFade(bottom: 40) } else { padded }
    }
}

private struct NavItem: View {
    @ObservedObject var m: HubModel
    let page: HubModel.Page
    @StateObject private var hover = HoverState()

    var body: some View {
        let on = m.page == page
        Button { m.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).font(.system(size: 15)).frame(width: 18)
                    .foregroundStyle(on ? Theme.accent : Theme.muted2)
                Text(page.title).font(.system(size: 13.5, weight: on ? .semibold : .regular)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Theme.card : (hover.on ? Color.black.opacity(0.035) : .clear))
                    .shadow(color: on ? Theme.shadowTint.opacity(0.1) : .clear, radius: 1, y: 1)
            )
            .wfOutline(10, on ? Color(hex: 0x3C2814, alpha: 0.06) : .clear, 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var m: HubModel
    @ObservedObject var overlay: OverlayModel

    var body: some View {
        let st = m.stats
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "\(m.greeting), \(Store.config.displayName)", subtitle: "Talk the way you normally would. WhisperFirst tidies it up.")
                .padding(.bottom, 4)
            holdCard
            statsCard(st)
            HStack {
                SectionTitle(title: "Lately")
                Spacer()
                if !m.entries.isEmpty {
                    Button("See everything") { m.page = .history }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentText)
                }
            }
            .padding(.top, 6)
            if m.entries.isEmpty {
                Text("Nothing yet — hold the key and say something in any app.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted2)
                    .frame(maxWidth: .infinity).padding(.vertical, 26).wfCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(m.entries.prefix(3)) { e in EntryRow(e: e, wrap: false, deletable: false, copied: m.copiedID == e.id) { m.copy(e) } }
                }
                    .padding(6).wfCard()
            }
        }
    }

    private var hint: String {
        switch overlay.phase {
        case .listening: overlay.handsFree ? "Hands-free — press ✓ on the island when you're done" : "Listening… let go when you're done"
        case .thinking: "Polishing…"
        case .done: "Done — it's at the top of Lately"
        default: "Try it: press and hold the key →"
        }
    }

    private var holdCard: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold to talk").font(Theme.rounded(21, .semibold))
                Text("Press and hold the key, say what you want to write, then let go. It appears right where your cursor is — in any app. Double-tap it to talk hands-free.")
                    .font(.system(size: 14)).foregroundStyle(Theme.inkSecondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Text(hint).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentText).padding(.top, 4)
                    .animation(.easeOut(duration: 0.2), value: overlay.phase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BigKeycap(combo: m.settings.shortcuts.combos(.pushToTalk).first,
                      pressed: overlay.phase == .listening && !overlay.handsFree)
        }
        .padding(.vertical, 24).padding(.horizontal, 28)
        .wfCard(18)
    }

    private func statsCard(_ st: HubModel.Stats) -> some View {
        let saved = st.savedMinutes >= 60 ? "\(st.savedMinutes / 60) \(st.savedMinutes / 60 == 1 ? "hour" : "hours")"
            : "\(st.savedMinutes) \(st.savedMinutes == 1 ? "minute" : "minutes")"
        return HStack(spacing: 14) {
            (Text("You've spoken ") + Text("\(st.words.formatted()) words").bold().foregroundColor(Theme.ink)
             + Text(" so far — about ") + Text(saved).bold().foregroundColor(Theme.ink) + Text(" you didn't spend typing."))
                .font(.system(size: 15)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if st.streak > 0 {
                Text("\(st.streak) \(st.streak == 1 ? "day" : "days") in a row")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentSoftText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accentSoft))
            }
        }
        .padding(.vertical, 17).padding(.horizontal, 22)
        .wfCard()
    }
}

/// ปุ่มคีย์บอร์ดใหญ่บน Home — ยุบลงตอนกำลังฟัง
private struct BigKeycap: View {
    let combo: KeyCombo?
    let pressed: Bool

    var body: some View {
        let (symbol, caption) = Self.face(combo)
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.keycapEdge)
                .offset(y: pressed ? 1 : 5)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                    .wfOutline(22, Color(hex: 0xE8E1D8))
                VStack(alignment: .leading) {
                    HStack { Spacer(); Text(symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(Theme.ink) }
                    Spacer()
                    Text(caption).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .offset(y: pressed ? 4 : 0)
        }
        .frame(width: 124, height: 108)
        .shadow(color: Theme.shadowTint.opacity(0.12), radius: 13, y: 12)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }

    static func face(_ combo: KeyCombo?) -> (String, String) {
        guard let c = combo, !c.isEmpty else { return ("?", "not set") }
        if c.count == 1 {
            switch c[0] {
            case "ropt": return ("⌥", "right option")
            case "lopt": return ("⌥", "left option")
            case "rcmd": return ("⌘", "right command")
            case "lcmd": return ("⌘", "left command")
            case "rctrl": return ("⌃", "right control")
            case "lctrl": return ("⌃", "left control")
            case "fn": return ("🌐", "fn / globe")
            default: break
            }
        }
        return (Keys2.sorted(c).map { Keys2.label($0) }.map { $0.count == 1 ? $0.uppercased() : $0 }.joined(separator: " "), "")
    }
}

/// แถวประวัติ (Home: บรรทัดเดียว · History: ข้อความเต็ม + ปุ่มลบ)
struct EntryRow: View {
    let e: HistoryEntry
    let wrap: Bool
    let deletable: Bool
    let copied: Bool
    let onCopy: () -> Void
    var onDelete: () -> Void = {}
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(alignment: wrap ? .top : .center, spacing: 14) {
            AppBadge(app: e.app, bundle: e.bundle)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.text).font(.system(size: 14)).foregroundStyle(Theme.ink)
                    .lineLimit(wrap ? nil : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: wrap)
                    .textSelection(.enabled)
                Text("\(e.app.isEmpty ? "WhisperFirst" : e.app) · \(HubModel.timeFmt.string(from: Date(timeIntervalSince1970: e.t)))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button { onCopy() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel(copied ? "Copied" : "Copy text")
                if deletable {
                    Button { onDelete() } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(width: 30, height: 30).background(Circle().fill(Theme.pillBtn))
                    }
                    .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete from history")
                }
            }
            .opacity(hover.on || copied ? 1 : 0.001)   // ซ่อนด้วยตา แต่ยังกดผ่านคีย์บอร์ด/VoiceOver ได้
            .animation(.easeOut(duration: 0.15), value: hover.on)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover.on ? Theme.hoverRow : .clear))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var m: HubModel
    let scrollable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                PageTitle(title: "Everything you've said")
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    TextField("Find a word or an app", text: $m.search).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 14).frame(width: 240, height: 36)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 14)
            if scrollable { ScrollView { list }.scrollIndicators(.hidden).wfFade(top: 16, bottom: 40) } else { list }
        }
    }

    private var list: some View {
        let groups = m.grouped
        return LazyVStack(alignment: .leading, spacing: 18) {
            if groups.isEmpty {
                Text(m.search.isEmpty ? "Nothing here yet — hold the key and say something." : "Nothing matches \"\(m.search)\" yet")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted2)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
            ForEach(groups, id: \.id) { g in
                VStack(alignment: .leading, spacing: 10) {
                    Text(g.label).font(Theme.rounded(15, .semibold)).padding(.leading, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(g.items) { e in
                            EntryRow(e: e, wrap: true, deletable: true, copied: m.copiedID == e.id, onCopy: { m.copy(e) }, onDelete: { m.delete(e) })
                        }
                    }
                    .padding(6).wfCard()
                }
            }
        }
        .padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 40)
    }
}
