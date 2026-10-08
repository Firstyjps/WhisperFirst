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
    enum Mode: String, Codable, CaseIterable { case off, lower, mute }

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

    init() { recoverAfterCrash() }

    var isDucked: Bool { saved != nil || paused != nil }

    func duck(_ mode: Mode) {
        guard mode != .off, saved == nil, paused == nil, let dev = Self.outputDevice(), let uid = Self.uid(dev) else { return }
        if Self.isMuted(dev) { return }   // ผู้ใช้ปิดเสียงไว้อยู่แล้ว
        if !Self.canMute(dev) && !Self.canSetVolume(dev) { pauseMedia(); return }
        if mode == .mute, Self.setMuted(dev, true) {
            store(Saved(uid: uid, volume: nil, setVolume: nil, muted: true))
            Log.write("audio: ปิดเสียงลำโพง")
            return
        }
        // ปิดเสียงไม่ได้ (บางอุปกรณ์) หรือโหมดลดเสียง → ลดระดับเสียงแบบค่อยๆ
        guard let v = Self.volume(dev), v > 0.01 else { return }
        let target = mode == .mute ? 0 : v * 0.2
        store(Saved(uid: uid, volume: v, setVolume: target, muted: false))
        fade(dev, from: v, to: target)
        Log.write("audio: ลดเสียงลำโพง \(Int(v * 100))% → \(Int(target * 100))%")
    }

    func restore() {
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
        }
    }

    /// สรุปความสามารถของลำโพงตอนนี้ (ไว้ทดสอบ/แสดงใน log)
    static func describe() -> String {
        guard let dev = outputDevice() else { return "ไม่มีลำโพง" }
        let apps = outputtingApps()
        return "mute=\(canMute(dev)) volume=\(canSetVolume(dev)) → \(canMute(dev) || canSetVolume(dev) ? "ปรับเสียงที่ลำโพง" : "กด play/pause แทน") · กำลังส่งเสียง: \(apps.sorted()) · เป็นเพลง/วิดีโอ: \(apps.filter(isMedia).sorted())"
    }

    // MARK: หยุด/เล่นต่อด้วยปุ่ม play/pause

    /// แอปที่กดปุ่ม play/pause แล้วหยุดได้ (เสียงออกจาก process ของแอปนี้ เช่น Chrome → com.google.Chrome.helper)
    static let mediaApps = ["com.spotify.client", "com.apple.Music", "com.apple.WebKit", "com.apple.Safari", "com.google.Chrome",
                            "company.thebrowser", "org.mozilla.", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware",
                            "com.vivaldi", "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX", "com.apple.TV",
                            "com.apple.podcasts", "com.tidal", "com.deezer", "com.amazon.music", "com.netflix", "com.google.youtube"]
    static func isMedia(_ bundle: String) -> Bool { mediaApps.contains { bundle.hasPrefix($0) } }

    private func pauseMedia() {
        let before = Self.outputtingApps()
        let media = before.filter(Self.isMedia)
        guard !media.isEmpty else { return }   // ไม่มีเพลง/วิดีโอเล่นอยู่ → ไม่กดอะไร (กันไปสั่งเล่นเพลงขึ้นมาเอง)
        Self.sendPlayPause()
        paused = media
        Log.write("audio: หยุดเพลงชั่วคราว \(media.sorted())")
        // ยืนยันผล: แอปหยุดจริงไหม · ถ้ามีแอปเพลงอื่นดังขึ้นมาแทน (ปุ่มไปโดนแอปผิด) → กดคืนทันที
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.paused != nil else { return }
            self.pauseCheck = nil
            let now = Self.outputtingApps()
            let started = now.filter(Self.isMedia).subtracting(before)
            if !started.isEmpty {
                Self.sendPlayPause(); self.paused = nil
                Log.write("audio: ปุ่ม play/pause ไปโดนแอปอื่น → กดคืน")
            } else if media.isSubset(of: now) {
                self.paused = nil   // หยุดไม่ได้ (แอปไม่รับปุ่มนี้) → ตอนปล่อยปุ่มไม่ต้องกดเล่นต่อ
                Log.write("audio: กด play/pause แล้วเพลงไม่หยุด → ไม่กดเล่นต่อ")
            }
        }
        pauseCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func resumeMedia() {
        pauseCheck?.cancel(); pauseCheck = nil
        guard let media = paused else { return }
        paused = nil
        // ผู้ใช้กดเล่นต่อเองแล้ว / ปุ่มยังไม่ทันได้ผล → ไม่กดซ้ำ
        guard Self.outputtingApps().isDisjoint(with: media) else { return }
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
    static func outputtingApps() -> Set<String> {
        var a = address(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        var out = Set<String>()
        for id in ids {
            var r = address(kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal)
            var run = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &r, 0, nil, &s, &run) == noErr, run != 0 else { continue }
            var p = address(kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal)
            var pid = pid_t(0); s = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &p, 0, nil, &s, &pid) == noErr, pid == me { continue }
            var b = address(kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal)
            var cf: Unmanaged<CFString>?; s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &b, 0, nil, &s, &cf) == noErr, let v = cf?.takeRetainedValue() { out.insert(v as String) }
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
        ramp?.invalidate()
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
