import AppKit
import ApplicationServices

/// เทียบข้อความที่ระบบวาง กับข้อความหลังผู้ใช้แก้ → หาจุดที่ "แทนที่คำ" (ไม่ใช่แค่พิมพ์ต่อ/ลบทิ้ง)
/// ภาษาไทยไม่มีเว้นวรรค → ตัดคำด้วย CFStringTokenizer (พจนานุกรมไทยของระบบ)
enum EditDiff {
    struct Hunk: Equatable { let old: String; let new: String }

    static func tokens(_ s: String) -> [String] {
        let ns = s as NSString
        guard let tok = CFStringTokenizerCreate(nil, s as CFString, CFRange(location: 0, length: ns.length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "th_TH") as CFLocale) else { return [s] }
        var out: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            out.append(ns.substring(with: NSRange(location: r.location, length: r.length)))
        }
        return out
    }

    static func replacements(old: String, new: String) -> [Hunk] {
        let a = tokens(old), b = tokens(new)
        guard a.count * b.count <= 250_000 else { return [] }
        // LCS
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var del = "", ins = ""
        func flush() {
            let o = del.trimmingCharacters(in: .whitespacesAndNewlines), n = ins.trimmingCharacters(in: .whitespacesAndNewlines)
            if !o.isEmpty, !n.isEmpty, o != n { hunks.append(Hunk(old: o, new: n)) }
            del = ""; ins = ""
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                // เว้นวรรคเดี่ยวระหว่างคำที่ถูกแทน ไม่ตัดก้อน (เช่น "Knock Knock" → "NokNok")
                let isGap = a[i].trimmingCharacters(in: .whitespaces).isEmpty && (!del.isEmpty || !ins.isEmpty)
                if isGap { del += a[i]; ins += b[j] } else { flush() }
                i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                ins += b[j]; j += 1
            } else {
                del += a[i]; i += 1
            }
        }
        flush()
        return hunks.filter { h in
            h.old.count <= 40 && h.new.count <= 40
                && h.new.rangeOfCharacter(from: .letters) != nil
                && squash(h.old) != squash(h.new)
        }
    }

    /// ต่างกันแค่ช่องว่าง/เครื่องหมาย → ไม่ใช่การแก้คำ
    private static func squash(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) })
    }
}

/// เรียนรู้คำจากการแก้ไขหลังวาง (แบบ Wispr Flow):
/// วางเสร็จ → จำตำแหน่งในช่องพิมพ์ → อ่านซ้ำทุก 1.5 วิ → ผู้ใช้แก้แล้วนิ่ง 6 วิ → diff → Gemini ตัดสินว่าเป็น "คำศัพท์ที่ฟังผิด" ไหม → เพิ่มลงพจนานุกรม
@MainActor
final class Learner {
    struct Learned { let word: String; let lines: [String] }

    var onLearned: ((String) -> Void)?
    private(set) var lastLearned: Learned?
    private let transcriber: Transcriber

    private struct Watch {
        let el: AXUIElement
        let inserted: String
        let prefix: String
        let suffix: String
        var current: String
        var changedAt: Date
        let startedAt: Date
    }
    private var watch: Watch?
    private var timer: Timer?
    static let header = "# — เรียนรู้อัตโนมัติจากการแก้ไข (ลบบรรทัดที่ไม่ต้องการได้) —"

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func track(inserted: String) {
        flush()
        guard Store.config.learnFromEdits, AX.trusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.anchor(inserted) }
    }

    private func anchor(_ inserted: String) {
        guard let el = AX.focusedElement() else { Log.write("learn: ไม่มีช่องที่โฟกัส"); return }
        anchor(el, inserted)
    }

    /// (แยกออกมาเพื่อทดสอบกับช่องที่ระบุได้ โดยไม่ต้องแย่งโฟกัส)
    func anchor(_ el: AXUIElement, _ inserted: String) {
        guard let value = AX.value(el) else {
            Log.write("learn: อ่านช่องพิมพ์ไม่ได้ (แอปไม่รองรับ Accessibility) → ไม่ติดตาม")
            return
        }
        let ns = value as NSString, len = (inserted as NSString).length
        var loc = NSNotFound
        if let caret = AX.caret(el), caret >= len, caret <= ns.length,
           ns.substring(with: NSRange(location: caret - len, length: len)) == inserted {
            loc = caret - len
        } else {
            loc = ns.range(of: inserted, options: .backwards).location
        }
        guard loc != NSNotFound else { Log.write("learn: หาข้อความที่วางไม่เจอ (แอปแปลงรูปแบบ?)"); return }
        let end = loc + len
        let prefix = ns.substring(with: NSRange(location: max(0, loc - 30), length: min(30, loc)))
        let suffix = ns.substring(with: NSRange(location: end, length: min(30, ns.length - end)))
        watch = Watch(el: el, inserted: inserted, prefix: prefix, suffix: suffix, current: inserted, changedAt: Date(), startedAt: Date())
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// ช่วงข้อความที่เคยเป็นของเรา: ระหว่าง prefix กับ suffix เดิม
    nonisolated static func region(in value: String, prefix: String, suffix: String, approx: Int) -> String? {
        let ns = value as NSString
        var start = 0
        if !prefix.isEmpty {
            let r = ns.range(of: prefix)
            guard r.location != NSNotFound else { return nil }
            start = r.location + r.length
        }
        var end = ns.length
        if !suffix.isEmpty {
            let r = ns.range(of: suffix, options: [], range: NSRange(location: start, length: ns.length - start))
            guard r.location != NSNotFound else { return nil }
            end = r.location
        }
        guard end >= start, end - start <= approx * 3 + 200 else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private func tick() {
        guard var w = watch else { timer?.invalidate(); return }
        let now = Date()
        guard let value = AX.value(w.el),
              let region = Self.region(in: value, prefix: w.prefix, suffix: w.suffix, approx: (w.inserted as NSString).length) else {
            flush()   // ช่องปิดไป/ข้อความรอบๆ เปลี่ยนมาก → ใช้สิ่งที่เห็นล่าสุด
            return
        }
        if region != w.current { w.current = region; w.changedAt = now }
        watch = w
        let idle = now.timeIntervalSince(w.changedAt), age = now.timeIntervalSince(w.startedAt)
        if (w.current != w.inserted && idle > 6) || age > 120 || (w.current == w.inserted && age > 45) { flush() }
    }

    /// จบการติดตาม (เริ่มพูดรอบใหม่ / ครบเวลา) แล้วประมวลผลสิ่งที่ผู้ใช้แก้
    func flush() {
        timer?.invalidate()
        timer = nil
        guard let w = watch else { return }
        watch = nil
        guard w.current != w.inserted else { return }
        let hunks = EditDiff.replacements(old: w.inserted, new: w.current)
        Log.write("learn: แก้ \(hunks.count) จุด \(hunks.map { "\($0.old)→\($0.new)" })")
        guard !hunks.isEmpty, hunks.count <= 3 else { return }   // แก้เยอะ = เขียนใหม่ ไม่ใช่แก้คำ
        let sentence = w.current
        Task { [weak self] in
            for h in hunks {
                guard let self, let d = await self.judge(h, sentence: sentence), d.learn else { continue }
                self.add(word: d.word, heard: d.heard)
            }
        }
    }

    struct Decision { let learn: Bool; let word: String; let heard: String }

    nonisolated func judge(_ h: EditDiff.Hunk, sentence: String) async -> Decision? {
        let system = """
        คุณดูแลพจนานุกรมส่วนตัวของระบบพิมพ์ด้วยเสียงภาษาไทย ระบบพิมพ์คำหนึ่งไป แล้วผู้ใช้แก้เอง
        ตัดสินว่าการแก้นี้คือ "ระบบฟังผิด/สะกดไม่ตรงใจ" ซึ่งควรจำไว้ใช้ครั้งหน้า หรือ "ผู้ใช้เปลี่ยนเนื้อหา" ซึ่งไม่ต้องจำ

        จำ (learn=true) เฉพาะเมื่อเข้าข้อใดข้อหนึ่ง:
        1. คำเดิมกับคำใหม่ออกเสียงเหมือนหรือคล้ายกัน แปลว่าระบบได้ยินถูกแต่เลือกคำ/ชื่อผิด (สมชาย→สมชัย, knock-knock→NokNok, deep search→DeepSeek)
        2. เป็นคำเดียวกันแต่ต่างที่ตัวสะกด ตัวพิมพ์ใหญ่-เล็ก หรืออักษร (github→GitHub, เช็ค→เช็ก, ด็อกเกอร์→Docker)
        ไม่จำ (learn=false):
        - ออกเสียงต่างกันชัดเจน = ผู้ใช้เปลี่ยนใจ/แก้เนื้อหา (วันพุธ→วันศุกร์, 10 โมง→11 โมง, ลูกค้า→ทีม)
        - เรียบเรียงใหม่ แก้ไวยากรณ์ เพิ่ม/ลบคำลงท้าย (ครับ→ค่ะ)
        - คำใหม่เป็นคำธรรมดาทั่วไปที่ไม่ใช่ชื่อเฉพาะหรือศัพท์เฉพาะ และไม่ใช่เรื่องการสะกด

        ตอบ JSON เท่านั้น: {"sounds_similar": true/false, "learn": true/false, "word": "คำที่ถูกตามที่ผู้ใช้แก้ เฉพาะตัวคำศัพท์", "heard": "คำที่ระบบเขียนผิด"}
        """
        let user = "ประโยคหลังแก้: \(sentence)\nระบบเขียน: \"\(h.old)\"\nผู้ใช้แก้เป็น: \"\(h.new)\""
        do {
            let raw = try await transcriber.complete(system: system, user: user, json: true)
            guard let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
            let word = (obj["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? h.new
            let heard = (obj["heard"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? h.old
            let d = Decision(learn: (obj["learn"] as? Bool) == true && !word.isEmpty, word: word, heard: heard)
            Log.write("learn judge: \(h.old)→\(h.new) = \(d.learn ? "จำ \(word)" : "ไม่จำ")")
            return d
        } catch {
            Log.write("learn judge error: \(error.localizedDescription)")
            return nil
        }
    }

    func add(word: String, heard: String) {
        let (words, _, hints) = Prompt.dictionaryEntries()
        var lines: [String] = []
        if !words.contains(word) { lines.append(word) }
        if !heard.isEmpty, heard != word, !hints.contains(where: { $0.0 == heard && $0.1 == word }) { lines.append("\(heard) ~> \(word)") }
        guard !lines.isEmpty else { return }
        var s = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
        if !s.contains(Self.header) { s += (s.isEmpty || s.hasSuffix("\n") ? "" : "\n") + "\n" + Self.header + "\n" }
        if !s.hasSuffix("\n") { s += "\n" }
        s += lines.joined(separator: "\n") + "\n"
        try? s.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        lastLearned = Learned(word: word, lines: lines)
        Log.write("learn: เพิ่ม \(lines)")
        onLearned?(word)
    }

    func undoLast() {
        guard let l = lastLearned, let s = try? String(contentsOf: Paths.dictionary, encoding: .utf8) else { return }
        var out = s.components(separatedBy: "\n")
        for line in l.lines { if let i = out.lastIndex(of: line) { out.remove(at: i) } }
        try? out.joined(separator: "\n").write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        lastLearned = nil
    }
}
