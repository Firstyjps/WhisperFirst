import AppKit
import Carbon.HIToolbox

/// ปุ่มลัดแบบ Wispr Flow: แต่ละ action มีได้หลายชุด · ชุด = ปุ่มที่กดพร้อมกัน (modifier / ปุ่มคีย์บอร์ด / ปุ่มเมาส์)
/// token: "fn" · "lctrl/rctrl/lopt/ropt/lcmd/rcmd/lshift/rshift" (ระบุข้าง) · "ctrl/opt/cmd/shift" (ข้างไหนก็ได้) · "k:<keycode>" · "m:<ปุ่มเมาส์>"
typealias KeyCombo = [String]

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case pushToTalk, handsFree, commandMode, pressEnter, pasteLast, addWord
    var id: String { rawValue }

    /// กดค้าง (เริ่มตอนกด จบตอนปล่อย) vs กดครั้งเดียว
    var isHold: Bool { self == .pushToTalk || self == .commandMode }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free mode"
        case .commandMode: "Command mode"
        case .pressEnter: "Press Enter"
        case .pasteLast: "Paste last text"
        case .addWord: "Add word to dictionary"
        }
    }

    var detail: String {
        switch self {
        case .pushToTalk: "Hold to say something short, let go to paste"
        case .handsFree: "Press to start, press again to stop — for longer thoughts"
        case .commandMode: "Hold and say what to do with selected text, like “translate to English”. You can also press ⇧ while talking."
        case .pressEnter: "Send messages faster — map Enter to a mouse button or another key"
        case .pasteLast: "Paste the most recent thing you said, again"
        case .addWord: "Select a word in any app, then press"
        }
    }

    /// ต้องมีอย่างน้อย 1 ชุดไหม (ถังขยะซ่อนเมื่อเหลือชุดเดียว)
    var required: Bool { self == .pushToTalk }

    static let defaults: [ShortcutAction: [KeyCombo]] = [
        .pushToTalk: [["ropt"]],
        .handsFree: [],
        .commandMode: [],
        .pressEnter: [],
        .pasteLast: [["ctrl", "opt", "k:9"]],
        .addWord: [["ctrl", "opt", "k:2"]],
    ]
}

enum Keys2 {
    static let modifierOrder = ["fn", "ctrl", "lctrl", "rctrl", "opt", "lopt", "ropt", "cmd", "lcmd", "rcmd", "shift", "lshift", "rshift"]
    static func isModifier(_ t: String) -> Bool { modifierOrder.contains(t) }
    static func agnostic(_ t: String) -> String {
        switch t {
        case "lctrl", "rctrl": "ctrl"
        case "lopt", "ropt": "opt"
        case "lcmd", "rcmd": "cmd"
        case "lshift", "rshift": "shift"
        default: t
        }
    }

    static func sorted(_ c: [String]) -> [String] {
        c.sorted { a, b in
            let ia = modifierOrder.firstIndex(of: a) ?? (a.hasPrefix("k:") ? 100 : 200)
            let ib = modifierOrder.firstIndex(of: b) ?? (b.hasPrefix("k:") ? 100 : 200)
            return ia != ib ? ia < ib : a < b
        }
    }

    static func label(_ t: String) -> String {
        switch t {
        case "fn": return "fn"
        case "ctrl": return "⌃"
        case "opt": return "⌥"
        case "cmd": return "⌘"
        case "shift": return "⇧"
        case "lctrl": return "Left ⌃"
        case "rctrl": return "Right ⌃"
        case "lopt": return "Left ⌥"
        case "ropt": return "Right ⌥"
        case "lcmd": return "Left ⌘"
        case "rcmd": return "Right ⌘"
        case "lshift": return "Left ⇧"
        case "rshift": return "Right ⇧"
        default: break
        }
        if t.hasPrefix("m:"), let n = Int(t.dropFirst(2)) { return n == 2 ? "Middle Click" : "Mouse \(n + 1)" }
        if t.hasPrefix("k:"), let c = Int(t.dropFirst(2)) { return keyName(c) }
        return t
    }

    static func label(_ c: KeyCombo) -> String { sorted(c).map(label).joined(separator: " ") }

    /// ชื่อปุ่มตามผังคีย์บอร์ดอังกฤษ (ไม่ขึ้นกับว่าตอนนี้พิมพ์ไทยอยู่)
    static func keyName(_ c: Int) -> String {
        let special: [Int: String] = [
            kVK_Space: "space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "home", kVK_End: "end",
            kVK_PageUp: "pgup", kVK_PageDown: "pgdn", kVK_CapsLock: "caps",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
            kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let s = special[c] { return s }
        let ansi: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g",
            kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n",
            kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u",
            kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
            kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        return ansi[c] ?? "key\(c)"
    }

    static func isFunctionKey(_ t: String) -> Bool {
        guard t.hasPrefix("k:"), let c = Int(t.dropFirst(2)) else { return false }
        return keyName(c).hasPrefix("F")
    }
}

/// ฟังปุ่มทั้งระบบผ่าน CGEventTap (ต้องได้สิทธิ์ Accessibility) — กลืนปุ่มที่เป็นส่วนของปุ่มลัด เช่น "b" ใน fn+b ไม่ให้พิมพ์ออกไป
/// tap รันบน thread ของตัวเอง (ไม่ใช่ main) → main ค้างแค่ไหนคีย์บอร์ดทั้งเครื่องก็ไม่หน่วง และไม่โดนปิดเพราะ timeout
/// สถานะทั้งหมดป้องกันด้วย lock · callback ทุกตัวส่งกลับ main
final class ShortcutEngine {
    enum Phase { case down, up, cancel, interrupted }

    /// event ที่แอปสร้างเอง (⌘V ตอนวาง, ⌘C, Enter) ติดเครื่องหมายนี้ → tap ปล่อยผ่าน ไม่วนกลับมาทริกเกอร์ปุ่มลัดซ้ำ
    static let syntheticMark: Int64 = 0x5746_4D4B   // "WFMK"

    private let lock = NSLock()
    private var _bindings: [ShortcutAction: [KeyCombo]] = [:]
    var bindings: [ShortcutAction: [KeyCombo]] {
        get { lock.lock(); defer { lock.unlock() }; return _bindings }
        set { lock.lock(); _bindings = newValue; lock.unlock() }
    }
    /// hold: .down/.up/.cancel(ถูกขยายเป็นชุดอื่น / tap ถูกปิด)/.interrupted(กดปุ่มอื่นแทรก) · กดครั้งเดียว: .down
    var onAction: (ShortcutAction, Phase) -> Void = { _, _ in }
    var onShift: () -> Void = {}
    var onEscape: () -> Void = {}
    private var _escapeArmed = false
    /// controller ตั้งเป็น true ตอนกำลังพูด/ประมวลผล → Esc ถูกกลืนและยกเลิก (ไม่หลุดไปแอป)
    var escapeArmed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _escapeArmed }
        set { lock.lock(); _escapeArmed = newValue; lock.unlock() }
    }

    private var recorder: ((KeyCombo, Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var pressed: Set<String> = []
    private var active: (action: ShortcutAction, combo: KeyCombo)?
    private var pending: (action: ShortcutAction, combo: KeyCombo, at: Date)?
    private var swallowedKeys: Set<Int64> = []
    private var swallowedMouse: Set<Int64> = []
    private var recordPeak: Set<String> = []

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, user in
            let engine = Unmanaged<ShortcutEngine>.fromOpaque(user!).takeUnretainedValue()
            return engine.handle(type, event)
        }, userInfo: me) else {
            Log.write("shortcuts: สร้าง event tap ไม่ได้ (ยังไม่ได้สิทธิ์ Accessibility?)")
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        source = src
        let th = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            self?.lock.lock(); self?.runLoop = rl; self?.lock.unlock()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "wf.eventtap"
        th.qualityOfService = .userInteractive
        th.start()
        Log.write("shortcuts: เริ่มฟังปุ่ม (thread แยก)")
        return true
    }

    /// เสียสิทธิ์ Accessibility → ปิด tap ให้เรียบร้อย (เปิดใหม่ด้วย start())
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; source = nil; runLoop = nil
        resetState()
        Log.write("shortcuts: ปิด event tap")
    }

    private func resetState() {
        if let a = active, a.action.isHold { fire(a.action, .cancel) }   // ไม่ปล่อยให้ไมค์ค้างรอ keyUp ที่จะไม่มาแล้ว
        pressed.removeAll(); active = nil; pending = nil
        swallowedKeys.removeAll(); swallowedMouse.removeAll()
    }

    // MARK: event

    func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {   // internal: CLI ทดสอบป้อน event จำลองได้
        lock.lock(); defer { lock.unlock() }
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.write("shortcuts: tap ถูกปิด (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) → เปิดใหม่ + ยกเลิกปุ่มที่ค้าง")
            resetState()
            return pass
        }
        if e.getIntegerValueField(.eventSourceUserData) == Self.syntheticMark { return pass }
        switch type {
        case .flagsChanged:
            pruneStale()
            let before = pressed
            updateModifiers(e)
            let added = pressed.subtracting(before), removed = before.subtracting(pressed)
            if recorder != nil { record(); return pass }
            for t in removed { keyUp(t) }
            for t in added { _ = keyDown(t) }
            return pass

        case .keyDown, .keyUp:
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            let token = "k:\(code)"
            if type == .keyDown {
                if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return swallowedKeys.contains(code) || recorder != nil ? nil : pass
                }
                pruneStale()
                if recorder != nil {
                    if code == Int64(kVK_Escape) && pressed.isEmpty {
                        let cb = recorder
                        recordPeak = []
                        DispatchQueue.main.async { cb?([], true) }   // Esc เดี่ยว = ยกเลิกการอัด
                        return nil
                    }
                    pressed.insert(token); record(); return nil
                }
                if code == Int64(kVK_Escape), _escapeArmed {
                    active = nil; pending = nil          // Esc ระหว่างกดค้าง = ยกเลิก ไม่ใช่ "กดปุ่มอื่นแทรก"
                    swallowedKeys.insert(code)
                    DispatchQueue.main.async { self.onEscape() }
                    return nil
                }
                if keyDown(token) { swallowedKeys.insert(code); return nil }
                swallowedKeys.remove(code)   // ปุ่มนี้ไม่ได้ถูกกลืนแล้ว → keyUp ต้องผ่าน (กันปุ่มค้างในแอป)
                return pass
            } else {
                if recorder != nil { pressed.remove(token); record(); return nil }
                keyUp(token)
                if swallowedKeys.remove(code) != nil { return nil }
                return pass
            }

        case .otherMouseDown, .otherMouseUp:
            let n = e.getIntegerValueField(.mouseEventButtonNumber)
            guard n >= 2 else { return pass }
            let token = "m:\(n)"
            if recorder != nil {
                if type == .otherMouseDown { pressed.insert(token) } else { pressed.remove(token) }
                record(); return nil
            }
            if type == .otherMouseDown {
                pruneStale()
                if keyDown(token) { swallowedMouse.insert(n); return nil }
                swallowedMouse.remove(n)
                return pass
            }
            keyUp(token)
            return swallowedMouse.remove(n) != nil ? nil : pass

        default:
            return pass
        }
    }

    private func updateModifiers(_ e: CGEvent) {
        let raw = e.flags.rawValue
        let bits: [(String, UInt64)] = [("lctrl", 0x01), ("rctrl", 0x2000), ("lshift", 0x02), ("rshift", 0x04),
                                         ("lcmd", 0x08), ("rcmd", 0x10), ("lopt", 0x20), ("ropt", 0x40)]
        for (t, b) in bits { if raw & b != 0 { pressed.insert(t) } else { pressed.remove(t) } }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if code == Int64(kVK_Function) || code == 179 {
            if e.flags.contains(.maskSecondaryFn) { pressed.insert("fn") } else { pressed.remove("fn") }
        } else if !e.flags.contains(.maskSecondaryFn) {
            pressed.remove("fn")
        }
    }

    /// ปุ่ม/เมาส์ที่ค้างอยู่ในสถานะแต่จริงๆ ปล่อยไปแล้ว (keyUp หลุด เช่นตอนช่องรหัสผ่านเปิด secure input)
    private func pruneStale() {
        for t in pressed {
            if t.hasPrefix("k:"), let c = UInt16(t.dropFirst(2)), !CGEventSource.keyState(.combinedSessionState, key: c) { pressed.remove(t) }
            if t.hasPrefix("m:"), let n = UInt32(t.dropFirst(2)), let b = CGMouseButton(rawValue: n),
               !CGEventSource.buttonState(.combinedSessionState, button: b) { pressed.remove(t) }
        }
    }

    // MARK: จับคู่

    private func satisfied(_ token: String) -> Bool {
        switch token {
        case "ctrl", "opt", "cmd", "shift": return pressed.contains { Keys2.agnostic($0) == token }
        default: return pressed.contains(token)
        }
    }

    private func exact(_ c: KeyCombo) -> Bool {
        c.allSatisfy(satisfied) && pressed.allSatisfy { c.contains($0) || c.contains(Keys2.agnostic($0)) }
    }

    private func match() -> (ShortcutAction, KeyCombo)? {
        for a in ShortcutAction.allCases { for c in _bindings[a] ?? [] where !c.isEmpty && exact(c) { return (a, c) } }
        return nil
    }

    /// มีชุดอื่นที่ใหญ่กว่าและครอบชุดนี้ไหม (เช่น "fn" กับ "fn b") → ชุดเล็กต้องรอดูว่าจะกดต่อไหม
    private func hasSuperset(_ c: KeyCombo) -> Bool {
        _bindings.values.joined().contains { other in other.count > c.count && c.allSatisfy { other.contains($0) || other.contains(Keys2.agnostic($0)) } }
    }

    /// คืน true = กลืน event นี้
    private func keyDown(_ token: String) -> Bool {
        pressed.insert(token)
        let isModifier = Keys2.isModifier(token)
        if let a = active {
            if let (action, combo) = match(), combo != a.combo {
                fire(a.action, .cancel)
                active = nil
                activate(action, combo)
                return !isModifier
            }
            if token == "lshift" || token == "rshift" { DispatchQueue.main.async { self.onShift() }; return false }
            if !a.combo.contains(token) && !a.combo.contains(Keys2.agnostic(token)) {
                fire(a.action, .interrupted)
                active = nil
            }
            return false
        }
        pending = nil
        guard let (action, combo) = match() else { return false }
        activate(action, combo)
        return !isModifier
    }

    private func activate(_ action: ShortcutAction, _ combo: KeyCombo) {
        if action.isHold {
            active = (action, combo)
            fire(action, .down)
        } else if hasSuperset(combo) || combo.allSatisfy(Keys2.isModifier) {
            // ยิงตอนปล่อยแบบ "แตะ": ชุดที่อาจเป็นส่วนของชุดใหญ่ (fn กับ fn+b)
            // หรือ modifier ล้วน (แตะ fn) — กันชนกับ fn+← / fn+F1 ฯลฯ ที่ใช้ปกติ
            pending = (action, combo, Date())
        } else {
            fire(action, .down)
        }
    }

    private func keyUp(_ token: String) {
        let inCombo: (KeyCombo) -> Bool = { $0.contains(token) || $0.contains(Keys2.agnostic(token)) }
        if let a = active, inCombo(a.combo) {
            active = nil
            fire(a.action, .up)
        }
        if let p = pending, inCombo(p.combo) {
            pending = nil
            if Date().timeIntervalSince(p.at) < 1.0 { fire(p.action, .down) }   // กดค้างนาน = ไม่ใช่แตะ
        }
        pressed.remove(token)
    }

    private func fire(_ a: ShortcutAction, _ p: Phase) {
        DispatchQueue.main.async { self.onAction(a, p) }   // คืน event tap ให้เร็วที่สุด
    }

    // MARK: อัดปุ่มลัด

    func beginRecording(_ cb: @escaping (KeyCombo, Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let a = active, a.action.isHold { fire(a.action, .cancel) }
        recordPeak = []
        active = nil
        pending = nil
        recorder = cb
    }

    func endRecording() {
        lock.lock(); defer { lock.unlock() }
        recorder = nil; recordPeak = []
    }

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recorder != nil }

    private func record() {
        if pressed.isEmpty && recordPeak.isEmpty { return }   // flagsChanged ว่าง (เช่น caps lock) ไม่ใช่การกด
        if pressed.count >= recordPeak.count && !pressed.isEmpty { recordPeak = pressed }
        if pressed.isEmpty {
            var combo = Array(recordPeak)
            // มีปุ่มธรรมดา/เมาส์ร่วม → modifier ข้างไหนก็ได้ · modifier ล้วน → ระบุข้าง (กันชนกับการใช้ ⌥ ซ้ายปกติ)
            if combo.contains(where: { !Keys2.isModifier($0) }) { combo = Array(Set(combo.map(Keys2.agnostic))) }
            let cb = recorder
            recordPeak = []
            DispatchQueue.main.async { cb?(Keys2.sorted(combo), true) }
        } else {
            let live = Keys2.sorted(Array(recordPeak))
            let cb = recorder
            DispatchQueue.main.async { cb?(live, false) }
        }
    }
}
