import Foundation
import Network

/// เน็ตใช้ได้ไหม (ไม่ต้องรอ timeout ถึงรู้ว่าออฟไลน์)
final class Net: @unchecked Sendable {
    static let shared = Net()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); let was = self.online; self.online = p.status == .satisfied; let now = self.online; self.lock.unlock()
            if was != now { Log.write(now ? "net: กลับมาออนไลน์" : "net: ออฟไลน์") }
        }
        monitor.start(queue: DispatchQueue(label: "wf.net"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }
}

/// ถอดเสียงในเครื่องด้วย whisper.cpp (whisper-server จาก Homebrew) — เสียงไม่ออกจากเครื่อง
/// - เปิด server เมื่อจำเป็น (Private mode: ตอนเริ่มกดพูด · สำรอง: ตอนออฟไลน์/ cloud ล่ม) แล้วเปิดค้างไว้ 10 นาทีหลังใช้ครั้งล่าสุด
/// - ฟังเฉพาะ 127.0.0.1 พอร์ตสุ่ม · คำในพจนานุกรมส่งเป็น prompt ช่วยสะกดชื่อเฉพาะ
final class LocalWhisper: @unchecked Sendable {
    static let shared = LocalWhisper()

    static let serverPaths = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
    /// โมเดลที่หาให้อัตโนมัติ (ตัวแรกที่เจอ) — ตั้งเองได้ใน config.offlineModel
    static var modelCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // large-v3 ก่อน: วัดบนภาษาไทยแล้ว turbo เร็วกว่า ~1.5 เท่าแต่บางประโยคถอดเป็นอักษรโรมัน/ผิดคำ
        return [Paths.support.appendingPathComponent("models/ggml-large-v3.bin"),
                home.appendingPathComponent(".cache/hyperframes/whisper/models/ggml-large-v3.bin"),
                Paths.support.appendingPathComponent("models/ggml-large-v3-turbo.bin")]
    }

    /// ตัวตัดช่วงเงียบ (Silero VAD) — ไม่มีก็ทำงานได้ แต่ Whisper อาจแต่งประโยคตอนเงียบ
    static var vadModel: URL? {
        let fm = FileManager.default
        let dirs = [Paths.support.appendingPathComponent("models"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/hyperframes/whisper/models")]
        for d in dirs {
            if let f = (try? fm.contentsOfDirectory(atPath: d.path))?.sorted().last(where: { $0.hasPrefix("ggml-silero") && $0.hasSuffix(".bin") }) {
                return d.appendingPathComponent(f)
            }
        }
        return nil
    }

    private let lock = NSLock()
    private var process: Process?
    private var port = 0
    private var ready = false
    private var starting: Task<Bool, Never>?
    private var idleTimer: DispatchWorkItem?
    private static let pidKey = "wf.localWhisper.pid"

    private init() { killOrphan() }

    static var serverPath: String? { serverPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static var modelURL: URL? {
        if let p = Store.config.offlineModel, !p.isEmpty {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return modelCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// พร้อมใช้ไหม (มีตัวโปรแกรม + โมเดล) — ใช้แสดงสถานะใน Settings
    static var status: String {
        guard serverPath != nil else { return "Needs whisper.cpp — run: brew install whisper-cpp" }
        guard let m = modelURL else { return "No model yet — put ggml-large-v3.bin (~3 GB) in Application Support/WhisperFirst/models" }
        return "On-device model: \(m.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: ""))"
    }
    static var available: Bool { serverPath != nil && modelURL != nil }

    /// เริ่มโหลดโมเดลไว้ก่อน (เรียกตอนเริ่มกดพูด) — ไม่รอ
    func prewarm() {
        guard Self.available else { return }
        Task { _ = await ensureRunning() }
    }

    func transcribe(_ input: DictationInput) async throws -> String {
        guard await ensureRunning() else { throw WFError("ถอดเสียงในเครื่องไม่ได้ (\(Self.status))") }
        let p = lock.withLock { port }
        let boundary = "wf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("language", "th")
        field("response_format", "text")
        field("temperature", "0")
        let prompt = Self.prompt()
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(input.wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(p)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 20 + input.seconds * 1.5
        let (data, resp) = try await URLSession.shared.data(for: req)
        scheduleIdleStop()
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw WFError("whisper-server HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ผลจาก Whisper ยังไม่ได้เกลา → ตัดคำเติม + แทนคำตามพจนานุกรม (รวมคำที่เรียนรู้ เพราะไม่มีโมเดลช่วยตัดสิน)
    /// ประโยคที่ Whisper ชอบแต่งขึ้นเองตอนเงียบ (มาจากซับไตเติลวิดีโอที่ใช้ฝึก)
    static let hallucinations = ["ขอบคุณที่รับชม", "ขอบคุณสําหรับการรับชม", "ขอบคุณสำหรับการรับชม", "ฝากกดไลค์", "กดติดตาม", "ซับไตเติ้ล", "โปรดติดตามตอนต่อไป",
                                 "thank you for watching", "thanks for watching", "subtitles by"]

    static func polish(_ raw: String) -> String {
        let low = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if low.isEmpty || (low.count < 40 && hallucinations.contains { low.contains($0) }) { return "" }
        var t = Clean.fillers(raw)
        for (from, to) in Prompt.dictionaryEntries().hints { t = Clean.replace(t, from, to, caseInsensitive: true) }
        // Whisper บางทีใส่ "..." / ซ้ำบรรทัดตอนเงียบท้าย
        t = t.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
        // รายการ "มี 3 อย่าง1. ตอบอีเมล2. รีวิวโค้ด" → ขึ้นบรรทัดใหม่ทีละข้อ (เฉพาะเมื่อมีอย่างน้อย 2 ข้อ)
        let item = #"\s*(?<![\d.,])([1-9])\.\s*(?=[^\d\s])"#
        if let re = try? NSRegularExpression(pattern: item), re.numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) >= 2 {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "\n$1. ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// คำในพจนานุกรม (ชื่อเฉพาะ/ศัพท์) เป็นบริบทให้ Whisper สะกดตาม — Whisper รับ prompt ได้ ~220 token
    private static func prompt() -> String {
        let e = Prompt.dictionaryEntries()
        var words: [String] = []
        for w in e.words + e.fixes.map(\.1) + e.hints.map(\.1) where !words.contains(w) { words.append(w) }
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + ", " + w
            if next.utf8.count > 600 { break }
            out = next
        }
        return out
    }

    // MARK: server

    private func ensureRunning() async -> Bool {
        let (isReady, t): (Bool, Task<Bool, Never>?) = lock.withLock {
            if ready, process?.isRunning == true { return (true, nil) }
            if let s = starting { return (false, s) }
            let s = Task { await self.start() }
            starting = s
            return (false, s)
        }
        if isReady { scheduleIdleStop(); return true }
        let ok = await t?.value ?? false
        lock.withLock { starting = nil }
        if ok { scheduleIdleStop() }
        return ok
    }

    private func start() async -> Bool {
        guard let exe = Self.serverPath, let model = Self.modelURL else { return false }
        stop()
        let p = Self.freePort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        var args = ["-m", model.path, "-l", "th", "--host", "127.0.0.1", "--port", "\(p)",
                    "-t", "\(max(4, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))", "-nt"]
        if let vad = Self.vadModel { args += ["--vad", "-vm", vad.path] }   // ช่วงเงียบไม่ถูกถอด (กันแต่งประโยค)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let t0 = Date()
        do { try proc.run() } catch {
            Log.write("local: เปิด whisper-server ไม่ได้ \(error.localizedDescription)")
            return false
        }
        UserDefaults.standard.set(Int(proc.processIdentifier), forKey: Self.pidKey)
        lock.withLock { process = proc; port = p; ready = false }
        // รอโหลดโมเดล (ปกติ ~1–3 วิ)
        for _ in 0..<240 {   // ≤60 วิ (เครื่องโหลดหนักอาจโหลดโมเดลช้า)
            guard proc.isRunning else { break }
            if await Self.ping(p) {
                lock.withLock { ready = true }
                Log.write("local: โหลด \(model.lastPathComponent) เสร็จใน \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        Log.write("local: whisper-server ไม่พร้อม")
        stop()
        return false
    }

    func stop() {
        lock.withLock {
            idleTimer?.cancel(); idleTimer = nil
            if let p = process, p.isRunning { p.terminate() }
            process = nil; ready = false
        }
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
    }

    /// ไม่ได้ใช้ 10 นาที → ปิด (คืน RAM ~3 GB)
    private func scheduleIdleStop() {
        lock.withLock {
            idleTimer?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Log.write("local: ไม่ได้ใช้ 10 นาที → ปิดโมเดลในเครื่อง")
                self.stop()
            }
            idleTimer = w
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: w)
        }
    }

    /// แอปปิดกะทันหันครั้งก่อน → server ค้างกิน RAM อยู่ → ปิดทิ้ง (ตรวจว่าเป็น whisper-server จริงก่อน)
    private func killOrphan() {
        let pid = UserDefaults.standard.integer(forKey: Self.pidKey)
        guard pid > 0 else { return }
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid_t(pid), &buf, UInt32(buf.count)) > 0,
              String(cString: buf).hasSuffix("/whisper-server") else { return }
        kill(pid_t(pid), SIGTERM)
        Log.write("local: ปิด whisper-server ที่ค้างจากครั้งก่อน")
    }

    private static func ping(_ port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private static func freePort() -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 18178
    }
}
