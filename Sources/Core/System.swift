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

    /// ช่องที่โฟกัสอ่านค่าผ่าน Accessibility ได้ไหม (ได้ = รู้ว่า "ไม่ได้เลือกอะไร" จริง)
    static func focusedFieldReadable() -> Bool {
        guard let el = focusedElement(), !isSecure(el) else { return false }
        return string(el, kAXValueAttribute) != nil
    }
}

/// วางข้อความลงแอปที่ใช้อยู่: ใส่คลิปบอร์ด → ⌘V → คืนคลิปบอร์ดเดิม
enum Inserter {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")   // บอก clipboard manager ว่าไม่ต้องเก็บ
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")   // รหัสผ่านจาก password manager
    /// คลิปบอร์ดเดิมที่รอคืน — ถ้าวางซ้ำก่อนคืน ให้ใช้ชุดเดิม (ไม่ snapshot ข้อความของเราเองทับ)
    private static var pendingRestore: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?

    static func paste(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        var saved: [NSPasteboardItem]? = nil
        if restore {
            if let p = pendingRestore { saved = p }
            else {
                let snap = snapshot(pb)
                // ข้อมูลลับจาก password manager → ไม่คืน (ให้ตัวจัดการรหัสผ่านล้างเองตามเวลา)
                saved = snap.contains { $0.types.contains(concealed) } ? nil : snap
            }
        }
        restoreWork?.cancel()
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transient)
        let mark = pb.changeCount
        key(9 /* V */, flags: .maskCommand)
        guard let saved else { pendingRestore = nil; return }
        pendingRestore = saved
        let w = DispatchWorkItem {
            defer { pendingRestore = nil }
            guard pb.changeCount == mark else { return }   // ผู้ใช้ copy อย่างอื่นไปแล้ว → ไม่ทับ
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        restoreWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)   // เผื่อแอปช้า (Electron/VM) ก่อนคืน
    }

    /// ใส่คลิปบอร์ดอย่างเดียว (ไม่วาง) — ตอนสลับแอป/ช่องรหัสผ่าน/อัดยาวเกิน
    static func copy(_ text: String) {
        restoreWork?.cancel(); pendingRestore = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// ข้อความที่เลือกอยู่: ลอง Accessibility ก่อน · อ่านช่องได้แต่ไม่ได้เลือกอะไร = ไม่มี (ไม่ ⌘C — VS Code จะก๊อปทั้งบรรทัด)
    /// อ่านไม่ได้ (แอป Electron บางตัว) → ⌘C แล้วคืนคลิปบอร์ด (รวมกรณีแอปตอบช้า)
    static func selectedText() async -> String? {
        if let s = AX.selectedText() { return s }
        if AX.focusedFieldReadable() { return nil }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        key(8 /* C */, flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else {
            // แอปตอบช้า → ถ้าเปลี่ยนภายหลังก็คืนให้
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if pb.changeCount != before { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) } }
            }
            return nil
        }
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
        for e in [down, up] {
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: ShortcutEngine.syntheticMark)   // tap ของเราปล่อยผ่าน
        }
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
    /// bundle id ของแอปที่วาง (ไว้แสดงไอคอนจริง) — ประวัติเก่าไม่มี
    var bundle: String? = nil
}

enum History {
    /// ประวัติเปลี่ยน → หน้าต่างหลักอัปเดต (object = HistoryEntry ใหม่ หรือ nil = โหลดใหม่ทั้งหมด)
    static let changed = Notification.Name("WFHistoryChanged")

    /// บันทึก (ถ้าผู้ใช้เปิดเก็บประวัติ) · ไฟล์สิทธิ์ 600 · ส่งรายการใหม่ให้หน้าต่างแทรกเลย
    static func append(_ e: HistoryEntry) {
        guard Store.config.keepHistory else { return }
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            FileManager.default.createFile(atPath: Paths.history.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: e) }
    }

    static func delete(_ t: Double) {
        rewrite { $0.t != t }
    }

    /// ลบทั้งหมด
    static func clear() {
        try? FileManager.default.removeItem(at: Paths.history)
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// เก็บไว้ตามจำนวนวันที่ตั้ง (0 = ตลอดไป) — เรียกตอนเปิดแอป
    static func prune() {
        let days = Store.config.historyDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        rewrite { $0.t >= cutoff }
    }

    private static func rewrite(keep: (HistoryEntry) -> Bool) {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        let lines = s.split(separator: "\n")
        let kept = lines.filter { l in (try? dec.decode(HistoryEntry.self, from: Data(l.utf8))).map(keep) ?? false }
        guard kept.count != lines.count else { return }
        let data = Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8)
        Files.writeSecure(data, to: Paths.history)
    }

    static func recent(_ n: Int = 200) -> [HistoryEntry] {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").suffix(n).compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }
}

/// เขียนไฟล์ข้อมูลส่วนตัวด้วยสิทธิ์ 600 ตั้งแต่แรก (ไม่มีช่วงที่ไฟล์อ่านได้ทุกคน) แล้วสลับแทนที่แบบ atomic
enum Files {
    static func writeSecure(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if fm.fileExists(atPath: url.path) { _ = try? fm.replaceItemAt(url, withItemAt: tmp) } else { try? fm.moveItem(at: tmp, to: url) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
