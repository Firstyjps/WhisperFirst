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
        // ไม่รู้ตำแหน่งเคอร์เซอร์ → ไม่เดาเอาท้ายเอกสาร (อาจเป็นข้อความคนละส่วนกับที่กำลังพิมพ์)
        var range = CFRange()
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXValueGetTypeID(), AXValueGetValue(r as! AXValue, .cfRange, &range) else { return nil }
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

    /// ช่องที่โฟกัสเป็นช่องรหัสผ่านไหม · nil = ไม่รู้ (อ่าน Accessibility ไม่ได้)
    static func focusedFieldIsSecure() -> Bool? {
        guard let el = focusedElement() else { return nil }
        if isSecure(el) { return true }
        return string(el, kAXRoleAttribute) == nil ? nil : false
    }

    /// หน้าต่างของช่องที่โฟกัส (ไว้เทียบว่าผู้ใช้ย้ายไปช่อง/แชทอื่นไหม)
    static func focusedWindow() -> AXUIElement? {
        guard let el = focusedElement() else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
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
    private static let slowPasteApps = ["com.parallels.", "com.vmware.", "com.utmapp.", "com.microsoft.rdc", "com.teamviewer.", "com.anydesk.", "com.realvnc."]

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
        // เผื่อแอปช้าก่อนคืน · VM/remote desktop อ่านคลิปบอร์ดช้ากว่านั้นมาก → รอนานขึ้น
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let slow = slowPasteApps.contains { front.hasPrefix($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (slow ? 3.0 : 1.2), execute: w)
    }

    /// ใส่คลิปบอร์ดอย่างเดียว (ไม่วาง) — ตอนสลับแอป/ช่องรหัสผ่าน/อัดยาวเกิน
    static func copy(_ text: String) {
        restoreWork?.cancel(); pendingRestore = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transient)
    }

    /// ข้อความที่เลือกอยู่: ลอง Accessibility ก่อน · อ่านช่องได้แต่ไม่ได้เลือกอะไร = ไม่มี (ไม่ ⌘C — VS Code จะก๊อปทั้งบรรทัด)
    /// อ่านไม่ได้ (แอป Electron บางตัว) → ⌘C แล้วคืนคลิปบอร์ด (รวมกรณีแอปตอบช้า)
    @MainActor   // NSPasteboard ต้องใช้บน main
    static func selectedText() async -> String? {
        if let s = AX.selectedText() { return s }
        if AX.focusedFieldReadable() { return nil }
        if AX.focusedFieldIsSecure() == true { return nil }   // ช่องรหัสผ่าน → ห้าม ⌘C
        let pb = NSPasteboard.general
        // ยังรอคืนคลิปบอร์ดเดิมจากการวางรอบก่อน → ของเดิมคือชุดนั้น ไม่ใช่ข้อความที่เราเพิ่งวาง
        if let p = pendingRestore { restoreWork?.cancel(); restoreWork = nil; pendingRestore = nil; pb.clearContents(); if !p.isEmpty { pb.writeObjects(p) } }
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

    /// สำเนาคลิปบอร์ด — เกิน 20 MB (รูป/ไฟล์ใหญ่) ไม่คัดลอกทุกชนิดบน main: เก็บแค่ข้อความ (ภาพใหญ่หายจากคลิปบอร์ดหลังวาง ดีกว่าค้าง)
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        var total = 0
        let limit = 20_000_000
        return (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                guard total < limit || t == .string, let d = item.data(forType: t) else { continue }
                total += d.count
                if total > limit && t != .string { continue }
                copy.setData(d, forType: t)
            }
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
    /// ทุกการเขียนไฟล์ (เพิ่ม/ลบ/ล้าง/ตัดเก่า) ผ่านคิวนี้คิวเดียว — ไม่มี read-modify-write ซ้อนกัน
    private static let q = DispatchQueue(label: "wf.history")
    nonisolated(unsafe) private static var lastPrune = Date.distantPast   // ใช้บน q เท่านั้น

    /// บันทึก (ถ้าผู้ใช้เปิดเก็บประวัติ) · ไฟล์สิทธิ์ 600 · ส่งรายการใหม่ให้หน้าต่างแทรกเลย
    static func append(_ e: HistoryEntry) {
        guard Store.config.keepHistory else { return }
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        q.async {
            if let h = try? FileHandle(forWritingTo: Paths.history) {
                defer { try? h.close() }
                // API แบบ throw: ดิสก์เต็ม/ไฟล์หาย → ทิ้งบรรทัดนี้ ไม่ทำแอปล่ม (แบบเก่า seekToEndOfFile/write โยน NSException)
                do { try h.seekToEnd(); try h.write(contentsOf: line) } catch { Log.write("history: บันทึกไม่ได้ (\(error.localizedDescription))") }
            } else {
                FileManager.default.createFile(atPath: Paths.history.path, contents: line, attributes: [.posixPermissions: 0o600])
                excludeFromBackup()
            }
            // เก็บตามจำนวนวันที่ตั้ง: ตัดของเก่าระหว่างใช้งานด้วย (ไม่ใช่แค่ตอนเปิดแอป) — อย่างมากชั่วโมงละครั้ง
            if Date().timeIntervalSince(lastPrune) > 3600 { pruneNow() }
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: e) }
        }
    }

    static func delete(_ t: Double) {
        q.async { if rewrite(keep: { $0.t != t }) { postReload() } }
    }

    /// ลบทั้งหมด
    static func clear() {
        q.async {
            try? FileManager.default.removeItem(at: Paths.history)
            postReload()
        }
    }

    /// เก็บไว้ตามจำนวนวันที่ตั้ง (0 = ตลอดไป) — เปิดแอป / เปลี่ยนค่า / ระหว่างใช้ (ชั่วโมงละครั้ง)
    static func prune() {
        q.async { if pruneNow() { postReload() } }
    }

    @discardableResult
    private static func pruneNow() -> Bool {
        lastPrune = Date()
        let days = Store.config.historyDays
        guard days > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return rewrite { $0.t >= cutoff }
    }

    private static func postReload() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// ประวัติเป็นข้อความที่พูดทั้งหมด (plaintext) → ไม่ให้ไปอยู่ใน Time Machine/iCloud backup
    private static func excludeFromBackup() {
        var u = Paths.history
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// true = ไฟล์เปลี่ยน
    private static func rewrite(keep: (HistoryEntry) -> Bool) -> Bool {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return false }
        let dec = JSONDecoder()
        let lines = s.split(separator: "\n")
        let kept = lines.filter { l in (try? dec.decode(HistoryEntry.self, from: Data(l.utf8))).map(keep) ?? false }
        guard kept.count != lines.count else { return false }
        let data = Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8)
        let ok = Files.writeSecure(data, to: Paths.history)
        excludeFromBackup()
        return ok
    }

    static func recent(_ n: Int = 200) -> [HistoryEntry] {
        guard let s = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").suffix(n).compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }
}

/// เขียนไฟล์ข้อมูลส่วนตัวด้วยสิทธิ์ 600 ตั้งแต่แรก (ไม่มีช่วงที่ไฟล์อ่านได้ทุกคน) แล้วสลับแทนที่แบบ atomic
enum Files {
    /// คืน false ถ้าเขียนไม่สำเร็จ (ไฟล์เดิมไม่ถูกแตะ และไม่ทิ้งไฟล์ชั่วคราวที่มีข้อมูลลับไว้)
    @discardableResult
    static func writeSecure(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            Log.write("file: เขียน \(url.lastPathComponent) ไม่ได้")
            return false
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)
            Log.write("file: บันทึก \(url.lastPathComponent) ไม่ได้ (\(error.localizedDescription))")
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
