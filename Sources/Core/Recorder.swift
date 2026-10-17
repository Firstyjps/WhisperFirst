import AVFoundation
import ObjCTry

/// อัดเสียงจากไมค์ default → PCM16 16kHz mono ส่งต่อทีละก้อน (~20ms) ให้ DictationSession
/// เปิดไมค์ตั้งแต่กดปุ่มลง (เก็บเสียงช่วงแรกไว้ ไม่ให้คำแรกขาด) จนปล่อยปุ่ม/จบแฮนด์ฟรี — ไฟไมค์สีส้มติดช่วงนั้น รวมถึงตอนแตะสั้นๆ ด้วย
final class Recorder {
    /// ระดับเสียง (RMS 0…1) — เรียกบน main thread
    var onLevel: ((Float) -> Void)?
    /// เสียงแต่ละก้อน + RMS — เรียกบน audio thread
    var onChunk: ((Data, Float) -> Void)?
    /// ไมค์/อุปกรณ์เสียงเปลี่ยนระหว่างอัด (เช่นต่อ AirPods กลางประโยค) → engine หยุดเงียบๆ — แจ้งบน main ให้จบรอบนี้
    var onInterrupted: (() -> Void)?
    private var recObserver: NSObjectProtocol?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    var isRunning: Bool { engine != nil }
    /// ใช้ voice processing ของ macOS (ลดเสียงรบกวน + ตัดเสียงสะท้อน + ปรับระดับเสียงอัตโนมัติ) — ตั้งก่อน start
    var voiceProcessing = false
    /// เปิด voice processing ใช้เวลา ~0.9 วิ → เตรียม engine ไว้ล่วงหน้า (ยังไม่เปิดไมค์) แล้วใช้ซ้ำทุกครั้ง
    private var warm: AVAudioEngine?
    private var warming = false
    private var configObserver: NSObjectProtocol?

    /// เรียกบน main — เตรียมนอก main thread ไม่ทำให้แอปค้าง
    func prewarm() {
        guard voiceProcessing, warm == nil, !warming, engine == nil else { return }
        warming = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let e = AVAudioEngine()
            var ok = true
            do { try e.inputNode.setVoiceProcessingEnabled(true); Self.limitDucking(e.inputNode) } catch {
                ok = false
                Log.write("mic: เปิดตัวลดเสียงรบกวนไม่ได้ (\(error.localizedDescription)) → อัดแบบปกติ")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.warming = false
                guard ok, self.voiceProcessing, self.warm == nil else { return }
                self.adopt(e)
                Log.write("mic: เตรียมตัวลดเสียงรบกวนไว้ (\(Int(Date().timeIntervalSince(t0) * 1000))ms)")
            }
        }
    }

    /// เปิด voice processing แล้ว macOS ลดเสียงแอปอื่นลงมากทันที (แม้ยังไม่เปิดไมค์) → ตั้งให้ลดน้อยที่สุดทันทีหลังเปิด
    /// ไม่งั้นเปิดเครื่อง/ตื่นจาก sleep แล้วเสียงเพลงเบาค้างจนกว่าจะกดพูดครั้งแรก · การลดเสียงเพลงตอนพูดให้ AudioDucker คุมเอง
    private static func limitDucking(_ input: AVAudioInputNode) {
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    }

    /// ไมค์/อุปกรณ์เสียงเปลี่ยน → engine ที่เตรียมไว้ใช้ไม่ได้แล้ว เตรียมใหม่
    private func adopt(_ e: AVAudioEngine) {
        warm = e
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self, self.warm === e, self.engine == nil else { return }
            self.discardWarm()
            self.prewarm()
        }
    }

    private func discardWarm() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        warm = nil
    }

    func start() throws {
        stop()
        let t0 = Date()
        var vp = false
        let e: AVAudioEngine
        if voiceProcessing, let w = warm, w.inputNode.outputFormat(forBus: 0).sampleRate > 0 {
            e = w; vp = true
        } else if voiceProcessing {
            // ยังเตรียมตัวลดเสียงรบกวนไม่เสร็จ → อัดแบบปกติไปก่อน (เปิด voice processing ตรงนี้ค้าง main ~0.9 วิ คำแรกขาด)
            // แล้วค่อยเตรียมไว้ให้รอบหน้าหลังปิดไมค์
            discardWarm()
            e = AVAudioEngine()
            Log.write("mic: ตัวลดเสียงรบกวนยังไม่พร้อม → รอบนี้อัดแบบปกติ")
        } else {
            discardWarm()
            e = AVAudioEngine()
        }
        let input = e.inputNode
        if vp {
            Self.limitDucking(input)
            input.isVoiceProcessingAGCEnabled = true   // AGC ของระบบช่วยไมค์เบา
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { discardWarm(); throw WFError("ไม่พบไมค์") }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else { discardWarm(); throw WFError("แปลงรูปแบบเสียงไม่ได้") }
        // voice processing อาจให้หลายช่อง (ไมค์หลายตัว) — ช่องแรกคือเสียงพูดที่ประมวลผลแล้ว
        if inFormat.channelCount > 1 { conv.channelMap = [0] }
        converter = conv

        var err: NSError?
        let ok = WFObjCTry({
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.handle(buf) }
        }, &err)
        if !ok { discardWarm(); throw err ?? WFError("เปิดไมค์ไม่ได้") }
        // prepare/start โยน NSException ได้ (อุปกรณ์หลุดกลางทาง) → จับไว้ ไม่ให้แอปล่ม
        var startErr: Error?
        let started = WFObjCTry({
            e.prepare()
            do { try e.start() } catch { startErr = error }
        }, &err)
        if !started || startErr != nil {
            input.removeTap(onBus: 0); discardWarm()
            throw startErr ?? err ?? WFError("เปิดไมค์ไม่ได้")
        }
        engine = e
        recObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self, self.engine === e else { return }
            Log.write("mic: อุปกรณ์เสียงเปลี่ยนระหว่างอัด → จบรอบนี้")
            self.stop()
            self.discardWarm()
            self.onInterrupted?()
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms > 300 { Log.write("mic: เปิดไมค์ช้า \(ms)ms\(vp ? " (ลดเสียงรบกวน)" : "")") }
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        let data = Data(bytes: ch[0], count: n * 2)
        var sum: Float = 0
        for i in 0..<n { let s = Float(ch[0][i]) / 32768; sum += s * s }
        let rms = sqrt(sum / Float(n))
        onChunk?(data, rms)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
    }

    func stop() {
        guard let e = engine else { return }
        if let o = recObserver { NotificationCenter.default.removeObserver(o) }
        recObserver = nil
        e.inputNode.removeTap(onBus: 0)
        e.stop()   // engine ที่ลดเสียงรบกวนเก็บไว้ใช้รอบหน้า (ไมค์ปิดแล้ว)
        engine = nil
        converter = nil
        if voiceProcessing, warm == nil { DispatchQueue.main.async { [weak self] in self?.prewarm() } }   // รอบนี้อัดแบบปกติ → เตรียมไว้ให้รอบหน้า
    }
}

// MARK: - วัดเวลาเปิดไมค์ (wf.app --mic-bench) — ใช้ตอนพัฒนาเท่านั้น
import CoreAudio

enum MicBench {
    static func inputRunning() -> Bool {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return false }
        var running = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &running)
        return running != 0
    }

    static func run() {
        func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
        var out: [String] = []
        func say(_ s: String) { out.append(s); print(s) }
        for vp in [false, true] {
            var t = Date()
            let e = AVAudioEngine()
            let input = e.inputNode
            if vp { try? input.setVoiceProcessingEnabled(true) }
            let f = input.outputFormat(forBus: 0)
            let tSetup = ms(t)
            let sem = DispatchSemaphore(value: 0)
            var first = true
            input.installTap(onBus: 0, bufferSize: 1024, format: f) { _, _ in if first { first = false; sem.signal() } }
            t = Date(); e.prepare(); let tPrep = ms(t)
            t = Date(); try? e.start(); let tStart = ms(t)
            _ = sem.wait(timeout: .now() + 3); let tFirst = ms(t)
            e.pause()
            Thread.sleep(forTimeInterval: 0.8)
            let runPaused = inputRunning()
            first = true
            t = Date(); try? e.start(); let tRe = ms(t)
            _ = sem.wait(timeout: .now() + 3); let tReFirst = ms(t)
            e.stop()
            Thread.sleep(forTimeInterval: 0.8)
            say("vp=\(vp) \(Int(f.sampleRate))Hz \(f.channelCount)ch · setup \(tSetup)ms prepare \(tPrep)ms start \(tStart)ms first-audio \(tFirst)ms · paused→mic running=\(runPaused) · restart \(tRe)ms first-audio \(tReFirst)ms · stopped→running=\(inputRunning())")
        }
        Log.write("mic-bench: " + out.joined(separator: " | "))
    }
}
