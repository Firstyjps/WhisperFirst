import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility: อ่านช่องที่กำลังพิมพ์ (ข้อความก่อนเคอร์เซอร์ / ข้อความที่เลือก)
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)   // แอปที่ค้างต้องไม่ทำให้เราค้างตาม
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        string(el, kAXRoleAttribute) == "AXSecureTextField" || string(el, kAXSubroleAttribute) == "AXSecureTextField"
    }

    /// ข้อความก่อนเคอร์เซอร์ไม่เกิน limit ตัว — ช่องรหัสผ่านคืน nil เสมอ
    static func textBeforeCursor(limit: Int = 400) -> String? {
        guard let el = focusedElement(), !isSecure(el), let value = string(el, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        var range = CFRange(location: ns.length, length: 0)
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r,
           CFGetTypeID(r) == AXValueGetTypeID() {
            AXValueGetValue(r as! AXValue, .cfRange, &range)
        }
        let end = min(max(range.location, 0), ns.length)
        let start = max(0, end - limit)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    static func value(_ el: AXUIElement) -> String? {
        guard !isSecure(el) else { return nil }
        return string(el, kAXValueAttribute)
    }

    static func caret(_ el: AXUIElement) -> Int? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &range)
        return range.location + range.length
    }

    /// แอป Electron (Slack, VS Code, Discord …) เปิด accessibility tree เฉพาะเมื่อมีคนขอ
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func selectedText() -> String? {
        guard let el = focusedElement(), !isSecure(el), let s = string(el, kAXSelectedTextAttribute), !s.isEmpty else { return nil }
        return s
    }
}

/// วางข้อความลงแอปที่ใช้อยู่: ใส่คลิปบอร์ด → ⌘V → คืนคลิปบอร์ดเดิม
enum Inserter {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")   // บอก clipboard manager ว่าไม่ต้องเก็บ

    static func paste(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        let saved = restore ? snapshot(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transient)
        let mark = pb.changeCount
        key(9 /* V */, flags: .maskCommand)
        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pb.changeCount == mark else { return }   // ผู้ใช้ copy อย่างอื่นไปแล้ว → ไม่ทับ
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
    }

    /// ข้อความที่เลือกอยู่: ลอง Accessibility ก่อน ถ้าไม่ได้ (เช่นแอป Electron) → ⌘C แล้วคืนคลิปบอร์ด
    static func selectedText() async -> String? {
        if let s = AX.selectedText() { return s }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        key(8 /* C */, flags: .maskCommand)
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        let s = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return s?.isEmpty == false ? s : nil
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum Sounds {
    static func play(_ name: String) {
        guard Store.config.sounds, let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = 0.25
        s.play()
    }
}

/// ประวัติการพูด (JSON lines) → ไว้ดูย้อนหลัง/คัดลอก/ปรับพจนานุกรม
struct HistoryEntry: Codable, Identifiable {
    var id: Double { t }
    var t: Double
    var app: String
    var mode: String
    var text: String
    var model: String
    var ms: Int
    var sec: Double
}

enum History {
    static func append(_ e: HistoryEntry) {
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Paths.history)
        }
    }

    static func delete(_ t: Double) {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        let kept = s.split(separator: "\n").filter { (try? dec.decode(HistoryEntry.self, from: Data($0.utf8)))?.t != t }
        try? (kept.joined(separator: "\n") + "\n").write(to: Paths.history, atomically: true, encoding: .utf8)
    }

    static func recent(_ n: Int = 200) -> [HistoryEntry] {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").suffix(n).compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }
}
