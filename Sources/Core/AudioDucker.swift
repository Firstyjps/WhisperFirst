import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// ปิด/ลดเสียงลำโพงระหว่างพูด แล้วคืนค่าเดิมตอนปล่อยปุ่ม (เพลง/วิดีโอไม่แทรกเสียงพูด และไม่กลบตอนฟังตัวเองพูด)
/// - ใช้ได้กับทุกแอป (ปรับที่อุปกรณ์เสียงออก ไม่ต้องขอสิทธิ์ควบคุมแอปอื่น)
/// - คืนค่าเฉพาะเมื่อผู้ใช้ไม่ได้ปรับเสียงเองระหว่างพูด · แอปปิดกลางคัน → คืนค่าตอนเปิดครั้งถัดไป
/// - ลำโพงที่ปรับเสียงจากเครื่องไม่ได้ (จอผ่าน HDMI/DisplayPort) → กด play/pause แทน เฉพาะเมื่อแอปเพลง/เบราว์เซอร์กำลังเล่นอยู่จริง
@MainActor
final class AudioDucker {
    /// off = ไม่ยุ่ง · mute = ปิดเสียงระหว่างพูด (config เก่าที่เป็น "lower" ถอดรหัสไม่ได้ → ใช้ค่าเริ่มต้น mute)
    enum Mode: String, Codable, CaseIterable { case off, mute }

    /// สิ่งที่เปลี่ยนไป — เก็บลง UserDefaults ด้วย เผื่อแอปปิดกลางคัน
    private struct Saved: Codable {
        let uid: String
        let volume: Float32?   // ค่าเดิม (โหมดลดเสียง)
        let setVolume: Float32?   // ค่าที่เราตั้ง
        let muted: Bool   // เราเป็นคนกดปิดเสียง
    }
    private static let key = "wf.audioDucker.saved"
    private var saved: Saved?
    private var ramp: Timer?
    /// หยุดเพลงด้วยปุ่ม play/pause: แอปที่หยุดไป (nil = ไม่ได้หยุด) · ยืนยันผลแล้วหรือยัง
    private var paused: Set<String>?
    private var pauseCheck: DispatchWorkItem?
    private var launchWatch: NSObjectProtocol?
    /// กำลังฟังว่าเพลงเล่นอยู่จริงไหม (ยังไม่ได้กด play/pause) · ปล่อยปุ่มระหว่างนี้ = ไม่ต้องกด
    private var probing = false
    /// เลขรอบการฟัง — ผลที่มาช้าจากรอบก่อน (กดพูดรัวๆ) ต้องไม่ถูกใช้กับรอบใหม่
    private var probeToken = 0

    init() { recoverAfterCrash() }

    var isDucked: Bool { saved != nil || paused != nil }

    /// ลำโพงนี้ปรับเสียงจากเครื่องไม่ได้ (จอ HDMI/DisplayPort) → ต้องหยุดเพลงแทน — ไม่ต้องรอเสียง Tink จบ (การหยุดเพลงไม่ทำให้ Tink เงียบ)
    static var pausesInsteadOfLowering: Bool {
        guard let dev = outputDevice() else { return false }
        return !canMute(dev) && !canSetVolume(dev)
    }

    func duck(_ mode: Mode) {
        guard mode != .off, saved == nil, paused == nil, !probing, let dev = Self.outputDevice(), let uid = Self.uid(dev) else { return }
        if Self.isMuted(dev) { return }   // ผู้ใช้ปิดเสียงไว้อยู่แล้ว
        if !Self.canMute(dev) && !Self.canSetVolume(dev) { pauseMedia(); return }
        if Self.setMuted(dev, true) {
            store(Saved(uid: uid, volume: nil, setVolume: nil, muted: true))
            Log.write("audio: ปิดเสียงลำโพง")
            return
        }
        // ปิดเสียงไม่ได้ (บางอุปกรณ์) → ค่อยๆ ลดระดับเสียงจนเงียบ
        guard let v = Self.volume(dev), v > 0.01 else { return }
        store(Saved(uid: uid, volume: v, setVolume: 0, muted: false))
        fade(dev, from: v, to: 0)
        Log.write("audio: ลดเสียงลำโพง \(Int(v * 100))% → 0%")
    }

    func restore() {
        probing = false
        probeToken += 1
        resumeMedia()
        guard let s = saved else { return }
        saved = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        let wasFading = ramp != nil   // ปล่อยปุ่มเร็วระหว่างกำลังลดเสียง → ค่าปัจจุบันยังไม่ถึงเป้า แต่เป็นของเรา
        ramp?.invalidate(); ramp = nil
        guard let dev = Self.device(uid: s.uid) else { return }
        if s.muted {
            if Self.isMuted(dev) { _ = Self.setMuted(dev, false) }   // ผู้ใช้เปิดเสียงเองแล้ว → ไม่ยุ่ง
        } else if let orig = s.volume, let set = s.setVolume, let now = Self.volume(dev), wasFading || abs(now - set) < 0.02 {
            fade(dev, from: now, to: orig)   // ผู้ใช้ปรับเสียงเองระหว่างพูด → ไม่ทับ
            // ลำโพงไร้สายบางตัว (HomePod) ส่งค่าเก่ากลับมาทับทีหลัง → ตรวจซ้ำ ยังค้างที่ระดับที่เราลดไว้ = ตั้งใหม่
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let cur = Self.volume(dev), abs(cur - orig) > 0.02, cur < orig else { return }
                if cur <= set + 0.02 || !Self.smoothFade(dev) {
                    Self.setVolume(dev, orig)
                    Log.write("audio: คืนเสียงซ้ำ \(Int(cur * 100))% → \(Int(orig * 100))%")
                }
            }
        } else if let orig = s.volume, let set = s.setVolume, let now = Self.volume(dev) {
            Log.write("audio: ไม่คืนเสียง — ผู้ใช้ปรับเองระหว่างพูด (\(Int(set * 100))% → \(Int(now * 100))%, เดิม \(Int(orig * 100))%)")
        }
    }

    /// สรุปความสามารถของลำโพงตอนนี้ (ไว้ทดสอบ/แสดงใน log)
    static func describe() -> String {
        guard let dev = outputDevice() else { return "ไม่มีลำโพง" }
        let apps = outputtingApps()
        return "mute=\(canMute(dev)) volume=\(canSetVolume(dev)) → \(canMute(dev) || canSetVolume(dev) ? "ปรับเสียงที่ลำโพง" : "กด play/pause แทน") · กำลังส่งเสียง: \(apps.sorted()) · เป็นเพลง/วิดีโอ: \(pausable(apps).sorted())"
    }

    // MARK: หยุด/เล่นต่อด้วยปุ่ม play/pause

    /// แอปที่กดปุ่ม play/pause แล้วหยุดได้ (เสียงออกจาก process ของแอปนี้ เช่น Chrome → com.google.Chrome.helper)
    static let mediaApps = ["com.spotify.client", "com.apple.Music", "com.apple.WebKit", "com.apple.Safari", "com.google.Chrome",
                            "company.thebrowser", "org.mozilla.", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware",
                            "com.vivaldi", "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX", "com.apple.TV",
                            "com.apple.podcasts", "com.tidal", "com.deezer", "com.amazon.music", "com.netflix", "com.google.youtube"]
    static func isMedia(_ bundle: String) -> Bool { mediaApps.contains { bundle.hasPrefix($0) } }

    /// com.apple.WebKit.GPU = เสียงของทุกแอปที่ใช้ WebKit (widget, หน้าเว็บในแอป ฯลฯ) ไม่ใช่แค่ Safari
    /// → นับเป็นเพลงเฉพาะตอนเบราว์เซอร์ WebKit เปิดอยู่ ไม่งั้นปุ่ม play/pause ไม่มีใครรับ แล้ว macOS เปิด Apple Music ขึ้นมาแทน
    static let webKitBrowsers = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"]
    static func pausable(_ outputting: Set<String>) -> Set<String> {
        let browserOpen = NSWorkspace.shared.runningApplications.contains { webKitBrowsers.contains($0.bundleIdentifier ?? "") }
        return outputting.filter { isMedia($0) && (browserOpen || !$0.hasPrefix("com.apple.WebKit")) }
    }

    private func pauseMedia() {
        let procs = Self.outputtingProcesses()
        let before = Set(procs.keys)
        let media = Self.pausable(before)
        guard !media.isEmpty else { return }   // ไม่มีเพลง/วิดีโอเล่นอยู่ → ไม่กดอะไร (กันไปสั่งเล่นเพลงขึ้นมาเอง)
        // เบราว์เซอร์เปิดช่องเสียงค้างไว้แม้หยุดวิดีโอแล้ว → ฟังเสียงจริงก่อน เงียบ = หยุดอยู่แล้ว ห้ามกด (ไม่งั้นกลายเป็นสั่งเล่น)
        probing = true
        probeToken += 1
        let token = probeToken
        PlaybackProbe.check(media.flatMap { procs[$0] ?? [] }) { [weak self] result in
            guard let self, self.probing, self.probeToken == token else { return }   // ปล่อยปุ่ม/เริ่มรอบใหม่ไปแล้วระหว่างฟัง
            self.probing = false
            switch result {
            case .audible(let peak):
                self.sendPause(media: media, before: before, peak: peak)
            case .silent(let peak):
                Log.write("audio: \(media.sorted()) เงียบอยู่ (peak \(String(format: "%.5f", peak))) → ไม่กด play/pause")
            case .unknown(let why):
                // ไม่รู้ว่าเล่นอยู่ไหม → ไม่กด: ปล่อยเพลงเล่นต่อ ดีกว่าไปสั่งเล่นวิดีโอที่หยุดไว้
                Log.write("audio: วัดเสียงไม่ได้ (\(why)) → ไม่กด play/pause")
            case .unsupported:
                self.sendPause(media: media, before: before, peak: nil)   // macOS < 14.2 ไม่มี tap → ใช้วิธีเดิม
            }
        }
    }

    private func sendPause(media: Set<String>, before: Set<String>, peak: Float?) {
        watchMusicLaunch()
        Self.sendPlayPause()
        paused = media
        Log.write("audio: หยุดเพลงชั่วคราว \(media.sorted())\(peak.map { String(format: " (peak %.3f)", $0) } ?? " (วัดเสียงไม่ได้)")")
        // ตรวจซ้ำ: มีแอปเพลงอื่นดังขึ้นมาแทน (ปุ่มไปโดนแอปผิด) → กดคืนทันที
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.paused != nil else { return }
            self.pauseCheck = nil
            let now = Self.outputtingApps()
            let started = now.filter(Self.isMedia).subtracting(before)
            // ไม่ใช้ "ยังส่งเสียงอยู่ไหม" ตัดสินว่าหยุดสำเร็จ: เบราว์เซอร์เปิดช่องเสียงค้างไว้แม้ pause แล้ว
            if !started.isEmpty {
                Self.sendPlayPause(); self.paused = nil
                Log.write("audio: ปุ่ม play/pause ไปโดนแอปอื่น → กดคืน")
            }
        }
        pauseCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// กันอีกชั้น: Apple Music ไม่ได้เปิดอยู่ แล้วเด้งขึ้นมาหลังกด play/pause = ปุ่มไม่มีใครรับ → ปิดคืน และไม่กดซ้ำตอนปล่อยปุ่ม (ไม่งั้นเพลงเล่น)
    private func watchMusicLaunch() {
        stopMusicWatch()
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) else { return }
        launchWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == "com.apple.Music" else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopMusicWatch()
                self.pauseCheck?.cancel(); self.pauseCheck = nil
                self.paused = nil
                app.terminate()
                Log.write("audio: Apple Music เด้งขึ้นมาเพราะปุ่ม play/pause → ปิดคืน")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stopMusicWatch() }
    }

    private func stopMusicWatch() {
        if let w = launchWatch { NSWorkspace.shared.notificationCenter.removeObserver(w) }
        launchWatch = nil
    }

    private func resumeMedia() {
        pauseCheck?.cancel(); pauseCheck = nil
        guard paused != nil else { return }
        paused = nil
        Self.sendPlayPause()
        Log.write("audio: เล่นเพลงต่อ")
    }

    /// ปุ่ม play/pause ของคีย์บอร์ด (macOS ส่งให้แอปที่กำลังเล่นอยู่)
    private static func sendPlayPause() {
        for down in [true, false] {
            let data1 = (16 << 16) | ((down ? 0xA : 0xB) << 8)   // NX_KEYTYPE_PLAY
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            guard let cg = ev?.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: ShortcutEngine.syntheticMark)
            cg.post(tap: .cghidEventTap)
        }
    }

    /// bundle id ของแอป (ยกเว้นตัวเอง) ที่กำลังส่งเสียงออกอยู่ตอนนี้ — macOS 14.2+
    static func outputtingApps() -> Set<String> { Set(outputtingProcesses().keys) }

    /// bundle id → Core Audio process object ของแอปที่กำลังส่งเสียงออก (ไว้ฟังเสียงจริงของ process นั้น)
    static func outputtingProcesses() -> [String: [AudioObjectID]] {
        var a = address(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [:] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [:] }
        let me = getpid()
        var out: [String: [AudioObjectID]] = [:]
        for id in ids {
            var r = address(kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal)
            var run = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &r, 0, nil, &s, &run) == noErr, run != 0 else { continue }
            var p = address(kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal)
            var pid = pid_t(0); s = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &p, 0, nil, &s, &pid) == noErr, pid == me { continue }
            var b = address(kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal)
            var cf: Unmanaged<CFString>?; s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &b, 0, nil, &s, &cf) == noErr, let v = cf?.takeRetainedValue() { out[v as String, default: []].append(id) }
        }
        return out
    }

    private func store(_ s: Saved) {
        saved = s
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    private func recoverAfterCrash() {
        guard let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        saved = s
        restore()
        Log.write("audio: คืนเสียงลำโพงที่ค้างจากครั้งก่อน")
    }

    /// ค่อยๆ ปรับใน ~150ms (ไม่ดังกระชาก)
    private func fade(_ dev: AudioDeviceID, from: Float32, to: Float32) {
        ramp?.invalidate(); ramp = nil
        // AirPlay/Bluetooth: ตั้งทีละขั้นเร็วๆ แล้วลำโพงส่งค่าขั้นกลางกลับมาทับค่าสุดท้าย → ตั้งครั้งเดียว
        guard Self.smoothFade(dev) else { Self.setVolume(dev, to); return }
        var step = 0
        let steps = 6
        ramp = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                step += 1
                let v = from + (to - from) * Float32(step) / Float32(steps)
                Self.setVolume(dev, v)
                if step >= steps { t.invalidate(); if self?.ramp === t { self?.ramp = nil } }
            }
        }
    }

    // MARK: CoreAudio

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func outputDevice() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }

    private static func uid(_ dev: AudioDeviceID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    private static func device(uid: String) -> AudioDeviceID? {
        guard let dev = outputDevice(), Self.uid(dev) == uid else { return nil }   // คืนเฉพาะถ้ายังเป็นลำโพงเดิม
        return dev
    }

    private static func volume(_ dev: AudioDeviceID) -> Float32? {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    private static func setVolume(_ dev: AudioDeviceID, _ v: Float32) -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var x = max(0, min(1, v))
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x) == noErr
    }

    /// ค่อยๆ ปรับได้เฉพาะลำโพงที่ต่อตรง (ในเครื่อง/USB/ช่องหูฟัง)
    private static func smoothFade(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        var t = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBuiltIn || t == kAudioDeviceTransportTypeUSB
    }

    private static func canMute(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyMute)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
    }

    private static func canSetVolume(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
    }

    private static func isMuted(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m) == noErr && m != 0
    }

    private static func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var m = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

/// ฟังเสียงจริงที่แอปหนึ่งๆ ส่งออก (Core Audio process tap, macOS 14.2+) — บอกได้ว่าเพลง "กำลังเล่น" หรือแค่ "เปิดช่องเสียงค้างไว้"
/// ไม่บันทึกอะไร: เก็บแค่ค่าเสียงดังสุดใน ~0.15 วิ · ครั้งแรก macOS ขอสิทธิ์ "System Audio Recording"
enum PlaybackProbe {
    enum Result { case audible(Float), silent(Float), unknown(String), unsupported }

    /// ต่ำกว่านี้ = เงียบ (~ -66 dB) — วิดีโอที่หยุดอยู่ส่งศูนย์ล้วน
    static let silence: Float = 0.0005

    /// ฟังเสียงที่ process เหล่านี้ส่งออก ~0.15 วิ · คืนผลบน main
    static func check(_ procs: [AudioObjectID], _ done: @escaping @MainActor (Result) -> Void) {
        guard !procs.isEmpty else { DispatchQueue.main.async { MainActor.assumeIsolated { done(.unknown("ไม่มี process")) } }; return }
        DispatchQueue.global(qos: .userInitiated).async {
            var r = Result.unsupported
            if #available(macOS 14.2, *) {
                let d = CATapDescription(stereoMixdownOfProcesses: procs)
                switch measure(d, seconds: 0.15) {
                case .success(let peak): r = peak < silence ? .silent(peak) : .audible(peak)
                case .failure(let e): r = .unknown(e.why)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } }
        }
    }

    /// ขอสิทธิ์ล่วงหน้าตอนว่าง (ไม่ให้ dialog เด้งกลางประโยค) — dialog ขึ้นตอนเริ่มฟังจริง เลยต้องเปิดฟังทั้งระบบสั้นๆ
    static func requestPermission() {
        guard #available(macOS 14.2, *) else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = measure(CATapDescription(stereoGlobalTapButExcludeProcesses: []), seconds: 0.05)
        }
    }

    struct Failure: Error { let why: String }

    /// tap อย่างเดียวก่อน — ไม่ยุ่งกับลำโพงเลย (กันเสียงเพลงสะดุด) · ไม่ได้เสียง → ผูกกับลำโพงเป็นนาฬิกาแบบเดิม
    @available(macOS 14.2, *)
    private static func measure(_ desc: CATapDescription, seconds: Double) -> Swift.Result<Float, Failure> {
        if tapOnlyWorks != false {
            let r = measure(desc, seconds: seconds, withOutput: false)
            if case .success = r { tapOnlyWorks = true; return r }
            if tapOnlyWorks == nil { tapOnlyWorks = false; Log.write("probe: ฟังแบบ tap อย่างเดียวไม่ได้ → ผูกกับลำโพง") }
            else { return r }   // เคยใช้ได้ = ครั้งนี้ไม่ได้เพราะเหตุอื่น ไม่ต้องลองซ้ำ
        }
        return measure(desc, seconds: seconds, withOutput: true)
    }

    /// nil = ยังไม่รู้ (ลองครั้งแรก) — แตะจาก thread ของ probe ทีละครั้ง
    nonisolated(unsafe) private static var tapOnlyWorks: Bool?

    @available(macOS 14.2, *)
    private static func measure(_ desc: CATapDescription, seconds: Double, withOutput: Bool) -> Swift.Result<Float, Failure> {
        let t0 = Date()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return .failure(Failure(why: "สร้าง tap ไม่ได้")) }
        defer { AudioHardwareDestroyProcessTap(tap) }

        var fa = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &fa, 0, nil, &sz, &asbd) == noErr,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return .failure(Failure(why: "รูปแบบเสียงไม่รองรับ")) }

        var da = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var out = AudioObjectID(0); sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, &sz, &out)
        var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(out, &ua, 0, nil, &sz, &cf) == noErr, let outUID = cf?.takeRetainedValue() as String? else {
            return .failure(Failure(why: "ไม่พบลำโพง"))
        }

        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperFirst playback probe",
            kAudioAggregateDeviceUIDKey: "wf-probe-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if withOutput {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        var dev = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev) == noErr else { return .failure(Failure(why: "สร้างอุปกรณ์ฟังไม่ได้")) }
        defer { AudioHardwareDestroyAggregateDevice(dev) }

        let q = DispatchQueue(label: "wf.probe")
        var peak: Float = 0, samples = 0
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, dev, q, { _, input, _, _, _ in
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let d = b.mData else { continue }
                let n = Int(b.mDataByteSize) / 4
                let f = d.bindMemory(to: Float32.self, capacity: n)
                for i in 0..<n { let v = abs(f[i]); if v > peak { peak = v } }
                samples += n
            }
        }) == noErr, let proc else { return .failure(Failure(why: "เปิดตัวฟังไม่ได้")) }
        defer { AudioDeviceDestroyIOProcID(dev, proc) }
        guard AudioDeviceStart(dev, proc) == noErr else { return .failure(Failure(why: "เริ่มฟังไม่ได้")) }
        // อุปกรณ์เพิ่งสร้างใช้เวลาสักพักกว่าเสียงแรกจะมา → นับเวลาจากจำนวนเสียงที่ได้จริง (ไม่ใช่เวลานาฬิกา) รอไม่เกิน 0.6 วิ
        let want = Int(max(asbd.mSampleRate, 8000) * Double(max(asbd.mChannelsPerFrame, 1)) * seconds)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline, q.sync(execute: { samples }) < want { Thread.sleep(forTimeInterval: 0.02) }
        AudioDeviceStop(dev, proc)
        let (p, n) = q.sync { (peak, samples) }
        Log.write("probe: peak \(String(format: "%.5f", p)) · \(n)/\(want) samples · \(Int(Date().timeIntervalSince(t0) * 1000))ms\(withOutput ? " · ผูกลำโพง" : " · tap อย่างเดียว")")
        return n * 2 >= want ? .success(p) : .failure(Failure(why: "ได้เสียง \(n)/\(want)"))   // ได้ไม่ถึงครึ่ง = ตัดสินไม่ได้
    }
}
