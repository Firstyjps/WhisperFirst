import Foundation

/// คำที่พูดแบบสดๆ ระหว่างพูด (แสดงใน island เท่านั้น — ผลที่วางจริงยังมาจาก Gemini ที่ฟังเสียงเต็มแล้วเกลา)
/// Gemini Live `gemini-3.5-transcribe-live` ผ่าน WebSocket: ส่งเสียงทุก 100ms → ได้ข้อความสะสมกลับทุก ~0.5 วิ
final class LiveTranscriber: NSObject {
    static let model = "gemini-3.5-transcribe-live"
    /// ข้อความสะสมจนถึงตอนนี้ (ส่วนที่นิ่งแล้ว, ส่วนที่ยังเดาอยู่) — เรียกบน main thread
    var onText: ((String, String) -> Void)?
    /// ทุกช่วงได้ฉบับสุดท้ายแล้วระหว่างที่ยังกดค้าง (ผู้ใช้หยุดพูด) → (ข้อความ, จำนวนช่วง, วินาทีที่พูดจริง) — เรียกบน q
    var onSettled: ((String, Int, Double?) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let q = DispatchQueue(label: "wf.live")
    private var buffer = Data()
    private var pending: [Data] = []
    private var ready = false
    private var finished = false
    /// Live ตัดเป็นช่วงตามจังหวะหยุดพูด (ACTIVITY_START → interim… → final → ACTIVITY_END) ข้อความแต่ละช่วงนับใหม่
    /// → สะสมฉบับสุดท้ายของทุกช่วง + ช่วงที่กำลังพูดอยู่ (อ่าน/เขียนบน q)
    private var committed: [String] = []
    private var interim = ""
    private var inSegment = false
    private var endSent = false
    /// ฉบับสุดท้ายของแต่ละช่วงมาช้ากว่าเสียง ~1.4 วิ — ช่วงใหม่อาจเริ่มก่อนช่วงเก่าได้ข้อความ → นับให้ครบทุกช่วงก่อนถือว่าจบ
    private var segmentsStarted = 0
    private var finalsReceived = 0
    private var allFinal: Bool { finalsReceived >= segmentsStarted && interim.isEmpty }
    /// จำนวนช่วงที่ Live ตัด (อ่านหลัง finish) — หลายช่วง = พูดยาว/มีหยุด → ข้อความ Live เสี่ยงข้ามเนื้อหา
    var segments: Int { q.sync { segmentsStarted } }
    private var waiter: CheckedContinuation<String?, Never>?
    private(set) var failed = false
    /// เวลาในเสียง (วินาที) ที่เริ่มพูดช่วงแรก / จบช่วงล่าสุด — จาก voiceActivity.audioOffset
    private var firstStart: Double?
    private var lastEnd: Double?
    /// ความยาวที่ "พูดจริง" (ไม่นับเงียบหัว/ท้าย) — nil ถ้ายังไม่รู้
    var spokenSeconds: Double? { q.sync { firstStart.flatMap { s in lastEnd.map { max(0, $0 - s) } } } }
    var hasFailed: Bool { q.sync { failed } }

    func start(key: String) {
        // key ใน header (ไม่อยู่ใน URL → ไม่หลุดไปกับ proxy log / error message)
        var req = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        send(["setup": ["model": "models/\(Self.model)",
                        "generationConfig": ["responseModalities": ["TEXT"], "speechConfig": ["languageCode": "th-TH"]],
                        "inputAudioTranscription": [String: Any]()]])
        receive()
    }

    /// เสียงที่ต้องปิดเป็นความเงียบ (เสียง Tink ของแอปเองตอนเริ่ม) — จำนวน byte ที่เหลือ
    private var muteBytes = 0

    /// ปิดเสียง N วินาทีถัดไปที่ส่งไป Live (แทนด้วยความเงียบ เวลาในเสียงยังตรงเดิม)
    func muteNext(seconds: Double) { q.async { self.muteBytes = Int(seconds * 16000) * 2 } }

    /// เรียกจาก audio thread ได้
    func append(_ chunk: Data) {
        q.async {
            guard !self.finished else { return }
            var chunk = chunk
            if self.muteBytes > 0 {
                let n = min(self.muteBytes, chunk.count)
                chunk.replaceSubrange(0..<n, with: Data(count: n))
                self.muteBytes -= n
            }
            self.buffer.append(self.agc(chunk))
            if self.buffer.count >= 3200 { self.flush() }   // 100ms
        }
    }

    /// ไมค์เบา → ขยายเสียงแบบค่อยๆ ปรับ (ใช้ peak ที่เจอจนถึงตอนนี้) ให้ ASR ฟังชัด
    private var peakSoFar: Int32 = 2000
    private func agc(_ chunk: Data) -> Data {
        var p: Int32 = 0
        chunk.withUnsafeBytes { b in for v in b.bindMemory(to: Int16.self) { p = max(p, abs(Int32(v))) } }
        peakSoFar = max(peakSoFar, p)
        let gain = min(8.0, 0.7 * 32767 / Double(peakSoFar))
        guard gain > 1.3 else { return chunk }
        var out = Data(count: chunk.count)
        out.withUnsafeMutableBytes { o in
            chunk.withUnsafeBytes { i in
                let src = i.bindMemory(to: Int16.self), dst = o.bindMemory(to: Int16.self)
                for k in 0..<src.count { dst[k] = Int16(max(-32767, min(32767, Double(src[k]) * gain))) }
            }
        }
        return out
    }

    /// ระหว่างยังกดค้าง: ทุกช่วงได้ฉบับสุดท้าย + ไม่ได้พูดอยู่ → บอก session ให้เกลาล่วงหน้าได้
    private func notifySettled() {
        guard !finished, !endSent, allFinal, !inSegment, segmentsStarted > 0 else { return }
        let spoken = firstStart.flatMap { s in lastEnd.map { max(0, $0 - s) } }
        onSettled?(committed.joined(separator: " "), segmentsStarted, spoken)
    }

    private func resolveIfDone() {
        guard endSent, allFinal, !inSegment, let w = waiter else { return }
        waiter = nil
        w.resume(returning: committed.joined(separator: " "))
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        if ready { sendAudio(buffer) } else { pending.append(buffer) }
        buffer = Data()
    }

    private func sendAudio(_ d: Data) {
        send(["realtimeInput": ["audio": ["data": d.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// จบการพูดแล้วรอข้อความฉบับสุดท้าย (ปกติ ~0.3 วิ) · หมดเวลา → nil (ให้ไปใช้ทางส่งเสียงแทน)
    func finish(timeout: Double = 0.8) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            q.async {
                if self.failed || !self.ready {
                    // ยังไม่ต่อสำเร็จ/ล่ม → ปิดให้เรียบร้อย (ไม่ปล่อย socket ค้าง)
                    self.finished = true
                    self.q.asyncAfter(deadline: .now() + 0.5) { self.close() }
                    c.resume(returning: nil); return
                }
                self.flush()
                self.finished = true
                if !self.endSent { self.endSent = true; self.send(["realtimeInput": ["audioStreamEnd": true]]) }
                // ช่วงสุดท้ายจบไปแล้ว (หยุดพูดก่อนปล่อยปุ่ม) → ได้ครบแล้ว ไม่ต้องรอ
                if self.allFinal && !self.inSegment { c.resume(returning: self.committed.joined(separator: " ")); return }
                self.waiter = c
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let w = self.waiter { self.waiter = nil; Log.write("live: รอข้อความสุดท้ายไม่ทัน \(timeout)s"); w.resume(returning: nil) }
                }
                self.q.asyncAfter(deadline: .now() + 3) { self.close() }
            }
        }
    }

    /// จบการพูด: ส่งเสียงที่เหลือ แล้วรอข้อความสุดท้ายสั้นๆ ก่อนปิด
    func stop() {
        q.async {
            guard !self.finished else { return }
            self.flush()
            self.finished = true
            if self.ready && !self.endSent { self.endSent = true; self.send(["realtimeInput": ["audioStreamEnd": true]]) }
            self.q.asyncAfter(deadline: .now() + 2.5) { self.close() }
        }
    }

    func cancel() {
        q.async {
            self.finished = true
            if let w = self.waiter { self.waiter = nil; w.resume(returning: nil) }
            self.close()
        }
    }

    private func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        DispatchQueue.main.async { self.onText = nil }
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { err in if let err { Log.write("live: ส่งไม่ได้ \(err.localizedDescription)") } }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // ปิดแล้ว/เน็ตหลุด/quota — แค่ไม่มีข้อความสด ระบบไปใช้ทางส่งเสียงแทน
                self.q.async {
                    self.failed = true
                    if let w = self.waiter { self.waiter = nil; w.resume(returning: nil) }
                }
                return
            case .success(let msg):
                let data: Data?
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(json) }
                self.receive()
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            q.async {
                self.ready = true
                for d in self.pending { self.sendAudio(d) }
                self.pending = []
                if self.finished && !self.endSent { self.endSent = true; self.send(["realtimeInput": ["audioStreamEnd": true]]) }
            }
            return
        }
        if let err = json["error"] { Log.write("live: error \(err)") }
        if let va = (json["voiceActivity"] as? [String: Any])?["type"] as? String {
            let offset = ((json["voiceActivity"] as? [String: Any])?["audioOffset"] as? String)
                .flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) }
            q.async {
                if va == "ACTIVITY_START" {
                    self.inSegment = true; self.segmentsStarted += 1
                    if self.firstStart == nil { self.firstStart = offset }
                }
                if va == "ACTIVITY_END" { self.inSegment = false; if let offset { self.lastEnd = offset } }
                self.resolveIfDone()
                self.notifySettled()
            }
        }
        guard let sc = json["serverContent"] as? [String: Any] else { return }
        let final = (sc["inputTranscription"] as? [String: Any])?["text"] as? String
        let interimText = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String
        guard final != nil || interimText != nil else { return }
        // ช่วงแรกสุดโมเดลบางทีเดาภาษาผิด (เช่นเวียดนาม "Chơi đi") → ไม่ใช้ข้อความที่มีอักษรละตินแบบมีวรรณยุกต์
        let isForeign: (String) -> Bool = { t in t.unicodeScalars.contains { (0x00C0...0x024F).contains($0.value) || (0x1E00...0x1EFF).contains($0.value) } }
        q.async {
            if let final {
                if !final.trimmingCharacters(in: .whitespaces).isEmpty { self.committed.append(final) }
                self.finalsReceived += 1
                self.interim = ""
                self.resolveIfDone()
                self.notifySettled()
            } else if let t = interimText, !isForeign(t) {
                self.interim = t
            }
            let stable = self.committed.joined(separator: " "), pending = self.interim
            if !stable.isEmpty || !pending.isEmpty { DispatchQueue.main.async { self.onText?(stable, pending) } }
        }
    }
}

/// เกลาข้อความสดก่อนโชว์บนเกาะ (ไม่กระทบผลที่วางจริง)
/// - ช่วงที่ไม่ใช่อักษรไทย/อังกฤษ (ไมค์เบา/เสียงรบกวน → Live เดาเป็นฮินดี/พม่า ฯลฯ) → ไม่โชว์
/// - แก้คำตามพจนานุกรม (คู่แก้คำ => และคำที่เรียนรู้ ~>) — Live ไม่รู้จักพจนานุกรมของผู้ใช้
struct LiveDisplay {
    private let pairs: [(String, String)]

    init(entries: (words: [String], fixes: [(String, String)], hints: [(String, String)]) = Prompt.dictionaryEntries()) {
        pairs = (entries.fixes + entries.hints).filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
    }

    func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, DictationSession.mostlyThaiOrLatin(t) else { return "" }
        var out = t
        for (from, to) in pairs { out = Clean.replace(out, from, to, caseInsensitive: true) }
        return out
    }

    /// (ส่วนที่นิ่งแล้ว, ส่วนที่ยังเดาอยู่)
    func clean(stable: String, pending: String) -> (String, String) { (clean(stable), clean(pending)) }
}
