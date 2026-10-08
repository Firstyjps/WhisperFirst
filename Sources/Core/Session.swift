import Foundation

/// ตรวจช่วงพูด/เงียบจากระดับเสียง (RMS) — ปรับระดับเสียงรบกวนพื้นหลังเอง (ใช้ประกอบ ไม่ใช้ตัดสินหลัก: ไมค์เบาทำให้ประเมินต่ำ)
struct SpeechGate {
    static let rate = 16000
    private(set) var noise: Float = 0.004
    private var voicedRun = 0
    private(set) var voicedTotal = 0

    var threshold: Float { max(0.006, noise * 3) }

    mutating func feed(rms: Float, samples n: Int) {
        if rms > threshold {
            voicedRun += n
            if voicedRun >= Self.rate * 12 / 100 { voicedTotal += n }   // ≥120ms ติดกัน = พูดจริง (ไม่ใช่เสียงคลิก)
            return
        }
        voicedRun = 0
        noise = noise * 0.97 + min(rms, 0.05) * 0.03
    }
}

/// หนึ่งรอบการพูด: เก็บเสียง → ตอนปล่อยปุ่มเลือกทาง
/// - ทางเร็ว: ข้อความที่ Live ถอดครบแล้ว (ประโยคสั้นช่วงเดียว) → เกลาด้วยข้อความล้วน · ถ้า Live ส่งฉบับสุดท้ายตั้งแต่ยังกดค้าง → เริ่มเกลาล่วงหน้า
/// - ทางส่งเสียง: Gemini ฟังเสียงเต็มเอง (ยิงสำรองไว้ที่ +0.6 วิ เผื่อ Live ช้า)
/// - ด่านคุณภาพ: ไม่มีเสียงพูด → ไม่เรียกโมเดลเลย · ผลไม่ตรงกับ transcript / transcript ไม่ใช่ไทย-อังกฤษ → ใช้ทางส่งเสียงแทน
final class DictationSession {
    struct NoSpeech: Error {}

    private let transcriber: Transcriber
    private let q = DispatchQueue(label: "wf.session")
    private var pcm = Data()
    private var gate = SpeechGate()
    private var base: DictationInput
    private var peak: Float = 0
    /// ไม่นับ peak/gate จนถึง sample นี้ (เสียง Tink ของแอปเองเข้าไมค์)
    private var ignoreUntil = 0
    /// เกลาล่วงหน้าจาก Live (ตอนผู้ใช้หยุดพูดแต่ยังกดค้าง)
    private var early: (text: String, task: Task<DictationResult, Error>)?
    private var earlyCount = 0
    var live: LiveTranscriber?
    private(set) var usedText = false
    private(set) var usedEarly = false
    /// input ที่ประกอบแล้วตอนจบ (ไว้ให้ปุ่ม Retry ใช้ — มีบริบทก่อนเคอร์เซอร์ครบ)
    private(set) var builtInput: DictationInput?

    init(transcriber: Transcriber, appName: String, bundleID: String) {
        self.transcriber = transcriber
        base = DictationInput(wav: Data(), seconds: 0, appName: appName, bundleID: bundleID)
    }

    var seconds: Double { q.sync { Double(pcm.count) / 32000 } }
    var peakValue: Float { q.sync { peak } }
    var voicedSeconds: Double { q.sync { Double(gate.voicedTotal) / Double(SpeechGate.rate) } }

    func setBefore(_ s: String?) { q.async { self.base.before = s } }

    /// แอปกำลังเล่นเสียงเริ่ม (Tink) → ไม่นับ ~0.25 วิถัดไป
    func ignoreNext(seconds: Double) {
        q.async { self.ignoreUntil = self.pcm.count / 2 + Int(seconds * Double(SpeechGate.rate)) }
    }

    func setCommand() {
        q.async {
            self.base.command = true
            self.early?.task.cancel(); self.early = nil
        }
    }

    /// เรียกจาก thread ไหนก็ได้ (audio thread)
    func append(_ chunk: Data, rms: Float) {
        q.async {
            self.pcm.append(chunk)
            guard self.pcm.count / 2 > self.ignoreUntil else { return }
            self.peak = max(self.peak, rms)
            self.gate.feed(rms: rms, samples: chunk.count / 2)
        }
    }

    /// Live ได้ฉบับสุดท้ายครบทุกช่วงตอนผู้ใช้หยุดพูด (ยังกดค้าง) → เริ่มเกลาเลย ถ้าปล่อยปุ่มโดยไม่พูดต่อ ผลพร้อมเร็วขึ้น
    func liveSettled(text: String, segments: Int, spoken: Double?) {
        q.async {
            guard Store.config.fastText, !self.base.command, segments == 1, self.earlyCount < 3,
                  self.early?.text != text,
                  (spoken ?? Double(self.pcm.count) / 32000) <= 15,
                  Self.looksComplete(text, seconds: spoken ?? Double(self.pcm.count) / 32000),
                  Self.mostlyThaiOrLatin(text) else { return }
            self.early?.task.cancel()
            var ti = self.base
            ti.transcript = text
            ti.before = nil
            let t = self.transcriber
            self.early = (text, Task { try await t.run(ti, fallback: false) })
            self.earlyCount += 1
        }
    }

    /// ตอนปล่อยปุ่ม
    func finish(selected: String? = nil) async throws -> DictationResult {
        let input = q.sync { () -> DictationInput in
            var i = base
            i.wav = WAV.encode(pcm: WAV.normalized(pcm))
            i.seconds = Double(pcm.count) / 32000
            i.selected = selected
            Log.write(String(format: "gate: เสียง %.1fs พูด %.1fs noise=%.4f peak=%.3f",
                             i.seconds, Double(gate.voicedTotal) / Double(SpeechGate.rate), gate.noise, peak))
            return i
        }
        builtInput = input
        let voiced = voicedSeconds
        defer { live?.stop(); q.async { self.early?.task.cancel() } }   // ไม่ปล่อย WebSocket/งานค้าง

        guard let live else { return try await transcriber.run(input) }

        // โหมดคำสั่ง / แม่นสุด: ส่งเสียงเสมอ แต่ยังกันกรณีไม่ได้พูดเลย
        if input.command || !Store.config.fastText {
            let tx = await live.finish(timeout: 0.5)
            if try isNoSpeech(live, tx, voiced) { throw NoSpeech() }
            return try await transcriber.run(input)
        }

        // เกินเกณฑ์ชัดๆ (ยาว/หลายช่วง) → ไม่ต้องรอ Live
        if input.seconds > 24 || live.segments > 1 {
            Log.write("ใช้ทางส่งเสียง: \(live.segments) ช่วง · เสียง \(String(format: "%.1f", input.seconds))s")
            return try await transcriber.run(input)
        }

        // สำรอง: ถ้า Live ส่งฉบับสุดท้ายช้ากว่า 0.6 วิ ทางส่งเสียงเริ่มไปก่อนแล้ว
        let t = transcriber
        let audio = Task { () throws -> DictationResult in
            try await Task.sleep(nanoseconds: 600_000_000)
            return try await t.run(input)
        }
        return try await withTaskCancellationHandler {
            let t0 = Date()
            let raw = await live.finish(timeout: 0.8)
            try Task.checkCancellation()
            if try isNoSpeech(live, raw, voiced) { audio.cancel(); throw NoSpeech() }
            let segs = live.segments
            let spoken = live.spokenSeconds ?? input.seconds
            guard let tx = raw?.trimmingCharacters(in: .whitespacesAndNewlines), segs <= 1, spoken <= 15,
                  Self.looksComplete(tx, seconds: spoken) else {
                Log.write("ใช้ทางส่งเสียง: live \(raw?.count ?? -1) ตัว · \(segs) ช่วง · พูด \(String(format: "%.1f", spoken))s")
                return try await audio.value
            }
            guard Self.mostlyThaiOrLatin(tx) else {
                Log.write("live ได้อักษรภาษาอื่น → ส่งเสียง")
                return try await audio.value
            }
            Log.write("live final +\(Int(Date().timeIntervalSince(t0) * 1000))ms (\(tx.count) ตัว)")
            var result: DictationResult?
            if let e = q.sync(execute: { early }), e.text == tx, let r = try? await e.task.value {
                result = r; usedEarly = true
            }
            if result == nil {
                var ti = input
                ti.transcript = tx
                ti.before = nil   // ทางเร็วไม่ส่งข้อความก่อนเคอร์เซอร์ (ต้นเหตุก๊อปข้อความเก่ามาวางซ้ำ)
                result = try? await transcriber.run(ti, fallback: false)
            }
            try Task.checkCancellation()
            if let r = result {
                let sim = Self.similarity(tx, r.text)
                if sim >= 0.35 {
                    audio.cancel()
                    usedText = true
                    return r
                }
                Log.write(String(format: "ผลไม่ตรงกับ transcript (%.2f) → ส่งเสียง", sim))
            } else {
                Log.write("ทางเร็วล้ม → ส่งเสียง")
            }
            return try await audio.value
        } onCancel: {
            audio.cancel()
        }
    }

    /// Live ทำงานปกติแต่ไม่เจอช่วงพูดเลย + ระดับเสียงก็แทบไม่มีเสียงพูด → อย่าเรียกโมเดล (กันโมเดลแต่งประโยคเอง)
    private func isNoSpeech(_ live: LiveTranscriber, _ tx: String?, _ voiced: Double) throws -> Bool {
        let empty = (tx ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let no = !live.hasFailed && tx != nil && live.segments == 0 && empty && voiced < 0.3
        if no { Log.write(String(format: "ไม่มีเสียงพูด (Live 0 ช่วง · gate %.2fs) → ไม่เรียกโมเดล", voiced)) }
        return no
    }

    /// ข้อความถอดยาวพอกับความยาวเสียงไหม (ภาษาไทยพูด ~8–15 ตัวอักษร/วิ — ต่ำกว่า 3/วิ = น่าจะขาด)
    static func looksComplete(_ tx: String, seconds: Double) -> Bool {
        !tx.isEmpty && Double(tx.count) >= seconds * 3 - 6
    }

    /// ตัวอักษรเป็นไทย/ละตินพื้นฐานอย่างน้อย 90% (Live บางทีถอดเป็นอักษรพม่า/เวียดนาม)
    static func mostlyThaiOrLatin(_ s: String) -> Bool {
        var ok = 0, total = 0
        for u in s.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) {
            total += 1
            if (0x0E00...0x0E7F).contains(u.value) || u.value < 0x250 || CharacterSet.punctuationCharacters.contains(u) { ok += 1 }
        }
        return total == 0 || Double(ok) / Double(total) >= 0.9
    }

    /// ความคล้ายระดับตัวอักษร (2·LCS / ความยาวรวม) ไม่นับช่องว่าง/เครื่องหมาย
    static func similarity(_ a: String, _ b: String) -> Double {
        let strip: (String) -> [Unicode.Scalar] = { s in
            Array(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }.prefix(600))
        }
        let x = strip(a), y = strip(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1), cur = prev
        for i in 1...x.count {
            for j in 1...y.count { cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            swap(&prev, &cur)
        }
        return 2 * Double(prev[y.count]) / Double(x.count + y.count)
    }

    func cancel() {
        live?.cancel()
        q.async { self.early?.task.cancel(); self.early = nil }
    }
}
