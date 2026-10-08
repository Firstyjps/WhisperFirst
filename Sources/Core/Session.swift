import Foundation

/// ตรวจช่วงพูด/เงียบจากระดับเสียง (RMS) — ปรับระดับเสียงรบกวนพื้นหลังเอง
struct SpeechGate {
    static let rate = 16000
    private(set) var noise: Float = 0.004
    private var voicedRun = 0
    private var silenceRun = 0
    private(set) var inSpeech = false
    /// ตำแหน่ง (sample) ที่เสียงพูดล่าสุดจบ
    private(set) var lastVoiceEnd = 0
    private(set) var voicedTotal = 0
    private var total = 0

    var threshold: Float { max(0.006, noise * 3) }

    /// คืน true เมื่อเพิ่งเงียบต่อเนื่องครบ `pause` วินาทีหลังจากพูด
    mutating func feed(rms: Float, samples n: Int, pause: Double) -> Bool {
        total += n
        if rms > threshold {
            voicedRun += n
            silenceRun = 0
            if voicedRun >= Self.rate * 12 / 100 { inSpeech = true }      // ≥120ms ติดกัน = พูดจริง (ไม่ใช่เสียงคลิก)
            if inSpeech { lastVoiceEnd = total; voicedTotal += n }
            return false
        }
        voicedRun = 0
        silenceRun += n
        noise = noise * 0.97 + min(rms, 0.05) * 0.03
        if inSpeech && silenceRun >= Int(Double(Self.rate) * pause) {
            inSpeech = false
            return true
        }
        return false
    }
}

/// หนึ่งรอบการพูด: รับเสียงทีละก้อนระหว่างพูด → ตอนเงียบ ส่งไปเกลาล่วงหน้า (speculative)
/// ตอนปล่อยปุ่ม ถ้าไม่ได้พูดอะไรเพิ่มหลังรอบล่วงหน้า → ใช้ผลนั้นเลย (เสร็จก่อน/ใกล้ๆ ตอนปล่อย)
/// ถ้าพูดต่อ → ทิ้งแล้วส่งเสียงเต็มใหม่ — ความแม่นเท่าเดิมเพราะ Gemini ได้ฟังเสียงครบทุกครั้ง
final class DictationSession {
    private let transcriber: Transcriber
    private let q = DispatchQueue(label: "wf.session")
    private var pcm = Data()
    private var gate = SpeechGate()
    private var base: DictationInput
    private var spec: (end: Int, task: Task<DictationResult, Error>, at: Date)?
    private var specCount = 0
    private var lastSpecAt = Date.distantPast
    private(set) var peak: Float = 0
    var speculate = Store.config.speculative
    /// ข้อความสด (Live) — ถ้ามี ตอนจบใช้ข้อความฉบับสุดท้ายไปเกลาแบบไม่ส่งเสียง
    var live: LiveTranscriber?
    private(set) var usedText = false
    let pause = 0.3
    /// log ไว้ดูว่าช่วยได้จริงไหม
    private(set) var usedSpeculative = false

    init(transcriber: Transcriber, appName: String, bundleID: String) {
        self.transcriber = transcriber
        base = DictationInput(wav: Data(), seconds: 0, appName: appName, bundleID: bundleID)
    }

    var seconds: Double { q.sync { Double(pcm.count) / 32000 } }
    var wav: Data { q.sync { WAV.encode(pcm: WAV.normalized(pcm)) } }

    func setBefore(_ s: String?) { q.async { self.base.before = s } }

    /// โหมดคำสั่งต้องรู้ข้อความที่เลือกก่อน → ไม่เดาล่วงหน้า
    func setCommand() {
        q.async {
            self.base.command = true
            self.spec?.task.cancel()
            self.spec = nil
        }
    }

    /// เรียกจาก thread ไหนก็ได้ (audio thread)
    func append(_ chunk: Data, rms: Float) {
        q.async {
            self.pcm.append(chunk)
            self.peak = max(self.peak, rms)
            let paused = self.gate.feed(rms: rms, samples: chunk.count / 2, pause: self.pause)
            if paused { self.maybeSpeculate() }
        }
    }

    private func maybeSpeculate() {
        guard speculate, !base.command, specCount < 4, !Transcriber.throttled,
              gate.voicedTotal >= SpeechGate.rate / 2,                  // พูดรวม ≥0.5 วิ (ไม่ยิงตอนพูดแค่ "เอ่อ")
              Date().timeIntervalSince(lastSpecAt) > 1.5 else { return }
        spec?.task.cancel()
        var input = base
        input.wav = WAV.encode(pcm: WAV.normalized(pcm))
        input.seconds = Double(pcm.count) / 32000
        let t = transcriber
        let primary = Array(Store.config.models.prefix(1))   // รอบล่วงหน้ายิงตัวเดียว ประหยัด quota
        spec = (pcm.count / 2, Task { try await t.run(input, models: primary, fallback: false) }, Date())
        specCount += 1
        lastSpecAt = Date()
        Log.write("speculate #\(specCount) at \(String(format: "%.1f", input.seconds))s")
    }

    /// ตอนปล่อยปุ่ม
    func finish(selected: String? = nil) async throws -> DictationResult {
        let (input, s, lastVoice) = q.sync { () -> (DictationInput, (end: Int, task: Task<DictationResult, Error>, at: Date)?, Int) in
            var i = base
            i.wav = WAV.encode(pcm: WAV.normalized(pcm))
            i.seconds = Double(pcm.count) / 32000
            i.selected = selected
            let tail = Double(pcm.count / 2 - gate.lastVoiceEnd) / Double(SpeechGate.rate)
            Log.write(String(format: "gate: เสียง %.1fs พูด %.1fs เงียบท้าย %.2fs noise=%.4f peak=%.3f ล่วงหน้า %d ครั้ง",
                             i.seconds, Double(gate.voicedTotal) / Double(SpeechGate.rate), tail, gate.noise, peak, specCount))
            return (i, spec, gate.lastVoiceEnd)
        }
        // ทางเร็ว: ข้อความที่ Live ถอดครบทั้งช่วงแล้ว → เกลาด้วยข้อความล้วน
        if let live, !input.command, Store.config.fastText {
            let t0 = Date()
            let tx = await live.finish()
            try Task.checkCancellation()
            let segs = live.segments
            // ใช้ทางเร็วเฉพาะประโยคสั้นช่วงเดียว: ทดสอบแล้ว Live ข้ามเนื้อหาทั้งประโยคได้เมื่อพูดยาวหลายช่วง
            if let tx = tx?.trimmingCharacters(in: .whitespacesAndNewlines), input.seconds <= 15, segs <= 1,
               Self.looksComplete(tx, seconds: input.seconds) {
                s?.task.cancel()
                Log.write("live final +\(Int(Date().timeIntervalSince(t0) * 1000))ms (\(tx.count) ตัว): \(tx)")
                var ti = input
                ti.transcript = tx
                do {
                    let r = try await transcriber.run(ti, fallback: false)
                    usedText = true
                    return r
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.write("text path ล้ม → ส่งเสียง: \(error.localizedDescription)")
                }
            } else {
                Log.write("ใช้ทางส่งเสียง: live \(tx?.count ?? -1) ตัว · \(segs) ช่วง · เสียง \(String(format: "%.1f", input.seconds))s")
            }
            return try await transcriber.run(input)
        }
        if let s, !input.command, lastVoice <= s.end {
            // แข่ง: ผลล่วงหน้า (โมเดลหลัก ยิงไว้ก่อน) vs โมเดลสำรองที่ยิงตอนปล่อยปุ่ม (เสียงเต็ม)
            // สำรองเสร็จก่อน → รอโมเดลหลัก (แม่นกว่า) อีกไม่เกิน grace วิ · ติด quota → สำรองรอ 1.5 วิก่อนค่อยยิง
            let t = transcriber
            let models = Store.config.models
            let backup = models.count > 1 ? Array(models.dropFirst()) : models
            let backupDelay = Transcriber.throttled ? 1.5 : 0
            let grace = min(0.5, Store.config.preferGrace)
            let r: DictationResult? = await withTaskGroup(of: (Int, DictationResult?).self) { g in
                g.addTask {
                    let v = try? await withTaskCancellationHandler { try await s.task.value } onCancel: { s.task.cancel() }
                    return (0, v)
                }
                g.addTask {
                    if backupDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(backupDelay * 1_000_000_000)) }
                    if Task.isCancelled { return (1, nil) }
                    return (1, try? await t.run(input, models: backup, fallback: false))
                }
                var pending = 2
                var held: DictationResult?
                for await (who, v) in g {
                    pending -= 1
                    if who == 0, let v { g.cancelAll(); self.usedSpeculative = true; return v }
                    if who == 2 { if let held { g.cancelAll(); return held }; continue }      // หมดเวลารอโมเดลหลัก
                    if who == 1, let v {
                        if pending == 0 { return v }
                        held = v
                        g.addTask { try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000)); return (2, nil) }
                        pending += 1
                        continue
                    }
                    if pending == 0 || (pending == 1 && held != nil) { if let held { g.cancelAll(); return held } }
                }
                return held
            }
            try Task.checkCancellation()
            if let r {
                Log.write(usedSpeculative ? "speculative hit (request ใช้เวลารวม \(String(format: "%.2f", Date().timeIntervalSince(s.at)))s)" : "สำรองที่ยิงตอนปล่อยปุ่มชนะ")
                return r
            }
            Log.write("speculative fail → ส่งใหม่")
        } else {
            s?.task.cancel()
        }
        return try await transcriber.run(input)
    }

    /// ข้อความถอดยาวพอกับความยาวเสียงไหม (ภาษาไทยพูด ~8–15 ตัวอักษร/วิ — ต่ำกว่า 3/วิ = น่าจะขาด)
    static func looksComplete(_ tx: String, seconds: Double) -> Bool {
        !tx.isEmpty && Double(tx.count) >= seconds * 3 - 6
    }

    func cancel() {
        live?.cancel()
        q.async {
            self.spec?.task.cancel()
            self.spec = nil
        }
    }
}
