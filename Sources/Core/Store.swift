import AppKit
import Foundation

/// ไฟล์ทั้งหมดของแอปอยู่ที่ ~/Library/Application Support/WhisperFirst/
enum Paths {
    static let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/WhisperFirst")
    static var config: URL { support.appendingPathComponent("config.json") }
    static var env: URL { support.appendingPathComponent(".env") }
    static var dictionary: URL { support.appendingPathComponent("dictionary.txt") }
    static var snippets: URL { support.appendingPathComponent("snippets.json") }
    static var aboutMe: URL { support.appendingPathComponent("about-me.md") }
    static var prompts: URL { support.appendingPathComponent("prompts") }
    static var history: URL { support.appendingPathComponent("history.jsonl") }
    /// log อยู่ใน ~/Library/Logs (สิทธิ์ 600, หมุนไฟล์ที่ 2MB) · ไม่เก็บข้อความที่พูด
    static let log = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/WhisperFirst/whisperfirst.log")

    /// ติดตั้งจาก DMG (ไม่ผ่าน build.sh) → เอา prompts + ไฟล์เริ่มต้นจากในตัวแอปมาวาง
    /// - dictionary/about-me: วางครั้งแรกเท่านั้น
    /// - prompts: วางถ้ายังไม่มี · แอปเวอร์ชันใหม่มี prompt ใหม่ → ทับเฉพาะไฟล์ที่ผู้ใช้ไม่ได้แก้ (เทียบกับสำเนา .orig ที่วางไว้รอบก่อน)
    static func seedFromBundle(resources: URL? = Bundle.main.resourceURL, into support: URL = support) {
        guard let res = resources else { return }
        let fm = FileManager.default
        let bundled = res.appendingPathComponent("prompts")
        guard fm.fileExists(atPath: bundled.path) else { return }   // รันจาก CLI — ไม่มี Resources
        let prompts = support.appendingPathComponent("prompts")
        try? fm.createDirectory(at: prompts, withIntermediateDirectories: true)
        for name in ["dictionary.txt", "about-me.md"] {
            let dst = support.appendingPathComponent(name), src = res.appendingPathComponent("defaults/\(name)")
            if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
        }
        for file in (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "md" {
            let dst = prompts.appendingPathComponent(file.lastPathComponent)
            let orig = prompts.appendingPathComponent("." + file.lastPathComponent + ".orig")
            guard let new = try? Data(contentsOf: file) else { continue }
            let current = try? Data(contentsOf: dst)
            if current == new { try? new.write(to: orig, options: .atomic); continue }
            if current == nil || current == (try? Data(contentsOf: orig)) {
                try? new.write(to: dst, options: .atomic)
                try? new.write(to: orig, options: .atomic)
            }
        }
    }
}

/// ปุ่มที่กดค้างเพื่อพูด (ปุ่ม modifier ฝั่งขวา ไม่ชนกับคีย์ลัดทั่วไป)
enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn
    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        case .fn: "fn / 🌐"
        }
    }
    var short: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .fn: "fn"
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }
    /// ใช้ device-dependent flag เพื่อแยกปุ่มขวาออกจากปุ่มซ้าย
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch self {
        case .rightOption: return raw & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return raw & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .rightControl: return raw & 0x2000 != 0   // NX_DEVICERCTLKEYMASK
        case .fn: return flags.contains(.function)
        }
    }
}

struct Config: Codable {
    /// (เวอร์ชันแรก) ปุ่มกดค้างปุ่มเดียว — ใช้ย้ายค่าไปเป็น shortcuts เท่านั้น
    var hotkey: HotkeyChoice = .rightOption
    /// action → ชุดปุ่มลัด (หลายชุดได้) · nil = ค่าเริ่มต้น
    var shortcuts: [String: [[String]]]?
    /// ตัวแรก = หลัก (3.1 แม่นกว่าในชุดทดสอบ) · ตัวถัดไป = สำรอง ยิงคู่ขนานเมื่อตัวหลักล่มหรือช้า
    var models: [String] = ["gemini-3.1-flash-lite", "gemini-3.5-flash-lite"]
    /// วินาทีก่อนยิงโมเดลถัดไปคู่ขนาน (0 = แข่งพร้อมกันตั้งแต่แรก — เร็วสุด ค่าใช้จ่ายเพิ่มเล็กน้อย)
    var hedgeDelay = 0.0
    /// ตัวสำรองเสร็จก่อน → รอโมเดลหลัก (แม่นกว่า) อีกไม่เกินกี่วินาที
    var preferGrace = 1.0
    /// Gemini ล่มหมด → ถอดดิบด้วย ElevenLabs Scribe แล้วตัดคำเติมเอง
    var elevenLabsFallback = true
    var sounds = true
    /// Dynamic Island: บน (ขอบบนกลางจอ/รอยบาก) · false = ล่างแบบ Wispr
    var islandTop = true
    /// ชื่อที่ใช้ทักในหน้าต่างหลัก (ค่าเริ่มต้น = ชื่อผู้ใช้ของเครื่อง)
    var displayName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    /// หมวดแอป → สไตล์การเขียน (formal/normal/casual)
    var styles: [String: String] = [:]
    /// แสดงเกาะเล็กๆ ตอนว่าง (ชี้เมาส์ดูวิธีใช้ / คลิกเพื่อเริ่มพูด)
    var islandIdle = true
    /// แสดงคำที่พูดสดๆ ใน island (Gemini Live transcribe — แสดงอย่างเดียว ไม่ใช่ผลที่วาง)
    var liveTranscript = true
    /// true = ทางเร็ว: เกลาจากข้อความที่ Live ถอดแล้ว (~1.2–2 วิ, นานๆ ครั้ง Live ฟังผิดจนความหมายเปลี่ยน)
    /// false = แม่นสุด: ส่งเสียงให้ Gemini ฟังเองทุกครั้ง (~2–3 วิ)
    var fastText = true
    /// เงียบระหว่างพูด → ส่งไปเกลาล่วงหน้า — ปิดไว้: ไมค์เบาทำให้ตัวจับเสียงคิดว่าเงียบ แล้วข้อความท้ายๆ หาย
    /// (ทางเร็วตอนนี้ = เกลาจากข้อความ Live แทน)
    var speculative = false
    /// เรียนรู้คำจากการแก้ไขหลังวาง → เพิ่มลงพจนานุกรมเอง
    var learnFromEdits = true
    /// ส่งข้อความก่อนเคอร์เซอร์ไปเป็นบริบท (ช่วยสะกดชื่อ/ต่อประโยค) — ช่องรหัสผ่านไม่ส่งเสมอ
    var useContext = true
    var restoreClipboard = true
    /// ลดเสียงรบกวนจากไมค์ด้วย voice processing ของ macOS (แอปอื่นเบาลงเล็กน้อยระหว่างพูด)
    var noiseReduction = true
    /// ระหว่างพูด: ปิดเสียงลำโพง (เพลง วิดีโอ) แล้วคืนค่าเดิมตอนปล่อยปุ่ม · ลำโพงที่ปรับเสียงไม่ได้ → หยุดเพลงแทน
    var muteWhileTalking: AudioDucker.Mode = .mute
    /// Private mode: ถอดเสียงในเครื่องเท่านั้น (Whisper) ไม่ส่งเสียง/ข้อความขึ้น cloud เลย
    var privateMode = false
    /// เน็ตหลุด/cloud ล่ม → ถอดในเครื่องแทน
    var offlineFallback = true
    /// path โมเดล Whisper (ggml) — nil = หาเอง
    var offlineModel: String? = nil
    /// เก็บประวัติในเครื่อง · จำนวนวัน (0 = ตลอดไป)
    var keepHistory = true
    var historyDays = 30
    /// ใช้ key จาก ~/.config/elevenlabs/api_key (ของเครื่องมืออื่น) ได้ — ต้องเปิดเอง
    var useSystemElevenLabsKey = false
    /// ผ่านไกด์ครั้งแรกแล้ว (config เก่าที่ไม่มีค่านี้ = ใช้แอปอยู่แล้ว ไม่ต้องโชว์)
    var onboarded = false
    /// bundle id → ลักษณะการเขียนในแอปนั้น
    var appHints: [String: String] = Config.defaultHints

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = Config()
        hotkey = v(.hotkey, d.hotkey)
        shortcuts = v(.shortcuts, d.shortcuts)
        models = v(.models, d.models)
        hedgeDelay = v(.hedgeDelay, d.hedgeDelay)
        preferGrace = v(.preferGrace, d.preferGrace)
        elevenLabsFallback = v(.elevenLabsFallback, d.elevenLabsFallback)
        sounds = v(.sounds, d.sounds)
        islandTop = v(.islandTop, d.islandTop)
        displayName = v(.displayName, d.displayName)
        styles = v(.styles, d.styles)
        islandIdle = v(.islandIdle, d.islandIdle)
        liveTranscript = v(.liveTranscript, d.liveTranscript)
        fastText = v(.fastText, d.fastText)
        speculative = v(.speculative, d.speculative)
        learnFromEdits = v(.learnFromEdits, d.learnFromEdits)
        useContext = v(.useContext, d.useContext)
        restoreClipboard = v(.restoreClipboard, d.restoreClipboard)
        noiseReduction = v(.noiseReduction, d.noiseReduction)
        muteWhileTalking = v(.muteWhileTalking, d.muteWhileTalking)
        privateMode = v(.privateMode, d.privateMode)
        offlineFallback = v(.offlineFallback, d.offlineFallback)
        offlineModel = v(.offlineModel, d.offlineModel)
        keepHistory = v(.keepHistory, d.keepHistory)
        historyDays = v(.historyDays, d.historyDays)
        useSystemElevenLabsKey = v(.useSystemElevenLabsKey, d.useSystemElevenLabsKey)
        appHints = v(.appHints, d.appHints)
        onboarded = v(.onboarded, true)
    }

    var shortcutBindings: [ShortcutAction: [KeyCombo]] {
        get {
            guard let s = shortcuts else {
                var d = ShortcutAction.defaults
                let legacy: [HotkeyChoice: String] = [.rightOption: "ropt", .rightCommand: "rcmd", .rightControl: "rctrl", .fn: "fn"]
                d[.pushToTalk] = [[legacy[hotkey] ?? "ropt"]]
                return d
            }
            var out: [ShortcutAction: [KeyCombo]] = [:]
            for a in ShortcutAction.allCases { out[a] = s[a.rawValue] ?? ShortcutAction.defaults[a] ?? [] }
            return out
        }
        set { shortcuts = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }) }
    }

    /// ชื่อปุ่มกดค้างชุดแรก ไว้แสดงในเมนู/ข้อความ
    var pushToTalkLabel: String { shortcutBindings[.pushToTalk]?.first.map(Keys2.label) ?? "-" }

    static let defaultHints: [String: String] = {
        let code = "ผู้ใช้กำลังพิมพ์คำสั่งหรือ prompt ให้ AI/โปรแกรม: คงศัพท์เทคนิค ชื่อไฟล์ ชื่อคำสั่ง เป็นภาษาอังกฤษตรงตัว เขียนเป็นข้อความต่อเนื่อง จัดรายการเฉพาะเมื่อผู้พูดไล่ข้อชัดเจน"
        let chat = "แชท: เขียนสั้น เป็นกันเองตามที่พูด ไม่ต้องแบ่งย่อหน้า"
        let email = "อีเมล: แบ่งย่อหน้าตามความหมายได้ คงระดับภาษาตามที่พูด"
        let notes = "โน้ต: จัดรายการ/ย่อหน้าได้ตามโครงสร้างที่พูด"
        var h: [String: String] = [:]
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                   "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.anthropic.claudefordesktop",
                   "com.openai.chat", "com.openai.codex"] { h[id] = code }
        for id in ["jp.naver.line.mac", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "com.hnc.Discord",
                   "net.whatsapp.WhatsApp", "com.facebook.archon", "com.apple.MobileSMS"] { h[id] = chat }
        for id in ["com.apple.mail", "com.microsoft.Outlook"] { h[id] = email }
        for id in ["com.apple.Notes", "md.obsidian", "notion.id"] { h[id] = notes }
        return h
    }()
}

enum Store {
    private(set) static var config: Config = load()

    private static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config), let c = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return c
    }

    static func update(_ change: (inout Config) -> Void) {
        change(&config)
        save()
    }

    static func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(config) { Files.writeSecure(data, to: Paths.config) }
    }
}

/// API keys: ~/Library/Application Support/WhisperFirst/.env (สิทธิ์ 600)
enum Keys {
    private static func env() -> [String: String] {
        guard let s = try? String(contentsOf: Paths.env, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in s.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            out[String(t[..<eq])] = v
        }
        return out
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static var gemini: String? {
        nonEmpty(env()["GEMINI_API_KEY"]) ?? nonEmpty(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
    }

    /// key ของ ElevenLabs: ที่ใส่ในแอป · หรือ ~/.config/elevenlabs/api_key เฉพาะเมื่อผู้ใช้อนุญาตให้ใช้ (ไม่หยิบ key ของโปรแกรมอื่นเงียบๆ)
    static var elevenLabs: String? {
        nonEmpty(env()["ELEVENLABS_API_KEY"])
            ?? (Store.config.useSystemElevenLabsKey
                ? nonEmpty(try? String(contentsOfFile: NSHomeDirectory() + "/.config/elevenlabs/api_key", encoding: .utf8)) : nil)
    }

    static func save(gemini: String, elevenLabs: String) {
        var lines = ["# WhisperFirst API keys (readable by this user only)"]
        if let g = nonEmpty(gemini) { lines.append("GEMINI_API_KEY=\(g)") }
        if let e = nonEmpty(elevenLabs) { lines.append("ELEVENLABS_API_KEY=\(e)") }
        Files.writeSecure(Data((lines.joined(separator: "\n") + "\n").utf8), to: Paths.env)
    }

    /// ค่าที่ผู้ใช้ตั้งเองใน .env (ไม่รวม fallback) — ไว้แสดงในหน้าตั้งค่า
    static var savedElevenLabs: String { env()["ELEVENLABS_API_KEY"] ?? "" }
}

/// log → ~/logs/whisperfirst.log
enum Log {
    private static let q = DispatchQueue(label: "wf.log")
    static var echo = false   // CLI พิมพ์ออกจอด้วย

    static func write(_ s: String) {
        if echo { FileHandle.standardError.write("· \(s)\n".data(using: .utf8)!) }
        let line = "\(ISO8601DateFormatter().string(from: Date())) | \(s)\n"
        q.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Paths.log.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: Paths.log.path))?[.size] as? Int, size > 2_000_000 {
                let old = Paths.log.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: Paths.log, to: old)
            }
            if let h = try? FileHandle(forWritingTo: Paths.log) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                fm.createFile(atPath: Paths.log.path, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
