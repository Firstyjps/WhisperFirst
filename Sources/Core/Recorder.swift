import AVFoundation
import ObjCTry

/// อัดเสียงจากไมค์ default → PCM16 16kHz mono ส่งต่อทีละก้อน (~20ms) ให้ DictationSession
/// เปิดไมค์เฉพาะตอนกดค้าง (ไฟไมค์สีส้มของ macOS ติดเฉพาะตอนพูด)
final class Recorder {
    /// ระดับเสียง (RMS 0…1) — เรียกบน main thread
    var onLevel: ((Float) -> Void)?
    /// เสียงแต่ละก้อน + RMS — เรียกบน audio thread
    var onChunk: ((Data, Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    var isRunning: Bool { engine != nil }

    func start() throws {
        stop()
        let e = AVAudioEngine()
        let input = e.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw WFError("ไม่พบไมค์") }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw WFError("แปลงรูปแบบเสียงไม่ได้") }
        converter = conv

        var err: NSError?
        let ok = WFObjCTry({
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.handle(buf) }
        }, &err)
        if !ok { throw err ?? WFError("เปิดไมค์ไม่ได้") }
        e.prepare()
        try e.start()
        engine = e
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
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        converter = nil
    }
}
