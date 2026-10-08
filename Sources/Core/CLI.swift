import AppKit
import SwiftUI
import Foundation

/// ทดสอบ engine เดียวกับในแอปจากไฟล์เสียง (ไม่ต้องกดไมค์จริง)
/// wf transcribe <file.wav> [--app ชื่อ] [--bundle id] [--before "…"] [--command] [--selected "…"]
public enum WFCLI {
    public static func main(_ args: [String]) {
        if args.count >= 3, args[1] == "stream" { return stream(args) }
        if args.count >= 4, args[1] == "learn" { return learn(args) }
        if args.count >= 2, args[1] == "learn-e2e" { return learnE2E() }
        if args.count >= 2, args[1] == "shortcuts-test" { return shortcutsTest() }
        if args.count >= 2, args[1] == "snippets-test" { return snippetsTest() }
        if args.count >= 2, args[1] == "duck-test" { return duckTest() }
        if args.count >= 3, args[1] == "render-shortcuts" { return renderShortcuts(args[2]) }
        if args.count >= 3, args[1] == "render-island" { return renderIsland(args[2]) }
        if args.count >= 3, args[1] == "live" { return liveTest(args[2]) }
        if args.count >= 3, args[1] == "render-hub" { return renderHub(args[2]) }
        guard args.count >= 3, args[1] == "transcribe" else {
            print("ใช้: wf stream <file.wav> [--gap 0.5] [--nospec]   (จำลองพูดตามเวลาจริง วัดเวลาหลังปล่อยปุ่ม)")
            print("    wf learn \"ข้อความที่ระบบวาง\" \"ข้อความหลังแก้\"   (ทดสอบ diff + การตัดสินคำ ไม่เขียนพจนานุกรม)")
            print("ใช้: wf transcribe <file.wav> [--app ชื่อแอป] [--bundle id] [--before \"ข้อความก่อนเคอร์เซอร์\"] [--command --selected \"ข้อความ\"]")
            exit(1)
        }
        Log.echo = true
        func opt(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: args[2])) else { print("อ่านไฟล์ไม่ได้"); exit(1) }
        let input = DictationInput(wav: wav, seconds: Double(max(0, wav.count - 44)) / 32000,
                                   command: args.contains("--command"),
                                   appName: opt("--app") ?? "Notes", bundleID: opt("--bundle") ?? "com.apple.Notes",
                                   before: opt("--before"), selected: opt("--selected"))
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let r = try await Transcriber().run(input)
                print("[\(r.model) \(r.ms)ms]")
                print(r.text)
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
    }

    /// ป้อนไฟล์เสียงทีละ 20ms ตามเวลาจริง (เหมือนไมค์) → ปล่อยปุ่มหลังจบไฟล์ `gap` วิ → วัดเวลาที่เหลือ
    static func stream(_ args: [String]) {
        Log.echo = true
        let gap = Double(opt(args, "--gap") ?? "0.5") ?? 0.5
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: args[2])), wav.count > 44 else { print("อ่านไฟล์ไม่ได้"); exit(1) }
        let pcm = wav.subdata(in: 44..<wav.count)
        let s = DictationSession(transcriber: Transcriber(), appName: opt(args, "--app") ?? "Notes", bundleID: "com.apple.Notes")
        let gain = Double(opt(args, "--gain") ?? "1") ?? 1   // จำลองไมค์เบา เช่น 0.12
        if args.contains("--live"), let key = Keys.gemini {
            let l = LiveTranscriber()
            l.onSettled = { [weak s] text, segs, spoken in s?.liveSettled(text: text, segments: segs, spoken: spoken) }
            l.start(key: key)
            s.live = l
        }
        let sem = DispatchSemaphore(value: 0)
        Task {
            let chunk = 640   // 20ms
            let t0 = Date()
            var i = 0
            // หลังจบไฟล์ ป้อนความเงียบต่ออีก gap วิ (ไมค์จริงยังส่งเสียงเงียบมาจนกว่าจะปล่อยปุ่ม)
            let pcm = pcm + Data(count: Int(gap * 32000) / 2 * 2)
            while i < pcm.count {
                var c = pcm.subdata(in: i..<min(i + chunk, pcm.count))
                if gain != 1 {
                    let n = c.count / 2
                    c.withUnsafeMutableBytes { p in let b = p.bindMemory(to: Int16.self); for k in 0..<n { b[k] = Int16(Double(b[k]) * gain) } }
                }
                var sum: Float = 0
                c.withUnsafeBytes { p in for v in p.bindMemory(to: Int16.self) { let f = Float(v) / 32768; sum += f * f } }
                let rms = sqrt(sum / Float(max(1, c.count / 2)))
                s.append(c, rms: rms)
                s.live?.append(c)
                i += chunk
                let due = t0.addingTimeInterval(Double(i) / 32000)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            let released = Date()
            do {
                let r = try await s.finish()
                print("[\(r.model) หลังปล่อย \(Int(Date().timeIntervalSince(released) * 1000))ms\(s.usedEarly ? " เกลาล่วงหน้า" : s.usedText ? " ข้อความLive" : " ส่งเสียง")]")
                print(r.text)
            } catch { print("ERROR: \(error.localizedDescription)") }
            sem.signal()
        }
        sem.wait()
    }

    static func learn(_ args: [String]) {
        Log.echo = true
        let hunks = EditDiff.replacements(old: args[2], new: args[3])
        print("tokens: \(EditDiff.tokens(args[3]))")
        print("hunks: \(hunks.map { "\($0.old) → \($0.new)" })")
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let l = Learner(transcriber: Transcriber())
            for h in hunks {
                if let d = await l.judge(h, context: Learner.context(of: h.new, in: args[3])) { print("  \(h.old) → \(h.new): learn=\(d.learn) word=\(d.word) heard=\(d.heard)") }
            }
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func opt(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// ทดสอบทั้งวงจรกับ TextEdit (เปิดเบื้องหลัง ไม่แย่งโฟกัส): วาง → แก้ → รอระบบเรียนรู้ → ตรวจพจนานุกรม → ยกเลิก
    static func learnE2E() {
        Log.echo = true
        let file = NSTemporaryDirectory() + "wf-learn-test.txt"
        try? "".write(toFile: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", "TextEdit", file]
        try? p.run(); p.waitUntilExit()
        func findArea() -> AXUIElement? {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return nil }
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var wins: CFTypeRef?
            AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &wins)
            for w in (wins as? [AXUIElement]) ?? [] {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
                guard (title as? String)?.contains("wf-learn-test") == true else { continue }
                var stack = [w]
                while let e = stack.popLast() {
                    var role: CFTypeRef?
                    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
                    if role as? String == "AXTextArea" { return e }
                    var kids: CFTypeRef?
                    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
                    stack += (kids as? [AXUIElement]) ?? []
                }
            }
            return nil
        }
        var area: AXUIElement?
        for _ in 0..<40 { area = findArea(); if area != nil { break }; Thread.sleep(forTimeInterval: 0.25) }
        guard let area else { print("หา TextEdit ไม่เจอ"); exit(1) }
        func set(_ v: String, caret: Int) {
            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, v as CFString)
            var r = CFRange(location: caret, length: 0)
            AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
        }
        let before = "บันทึกประชุม: "
        let inserted = "อัปเดตสถานะ knock-knock กับ Alphast ใน Vault ด้วย"
        let after = "\nบรรทัดถัดไป"
        set(before + inserted + after, caret: (before + inserted as NSString).length)
        print("1) วางแล้ว: \(AX.value(area) ?? "?")")
        let sem = DispatchSemaphore(value: 0)
        var learned: String?
        Task { @MainActor in
            let l = Learner(transcriber: Transcriber())
            l.onLearned = { w in learned = w }
            l.anchor(area, inserted)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let edited = before + "อัปเดตสถานะ NokNok กับ Alphast ใน Vault ด้วย" + after
            set(edited, caret: 20)
            print("2) ผู้ใช้แก้: \(AX.value(area) ?? "?")")
            for _ in 0..<30 where learned == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            let dict = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
            print("3) เรียนรู้: \(learned ?? "ไม่มี") · ในพจนานุกรม: \(dict.components(separatedBy: "\n").suffix(4))")
            l.undoLast()
            let dict2 = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
            print("4) หลังยกเลิก มี 'knock-knock ~> NokNok' อยู่ไหม: \(dict2.contains("knock-knock ~> NokNok"))")
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// ป้อน key event จำลองเข้า ShortcutEngine (ไม่ได้กดปุ่มจริง) แล้วตรวจว่ายิง action / กลืนปุ่ม ถูกต้อง
    static func shortcutsTest() {
        let e = ShortcutEngine()
        var log: [String] = []
        e.onAction = { a, p in log.append("\(a.rawValue).\(p)") }
        e.onShift = { log.append("shift") }
        func flags(_ code: Int64, _ raw: UInt64) -> CGEvent {
            let ev = CGEvent(source: nil)!
            ev.type = .flagsChanged
            ev.setIntegerValueField(.keyboardEventKeycode, value: code)
            ev.flags = CGEventFlags(rawValue: raw)
            return ev
        }
        let fnDown = flags(63, CGEventFlags.maskSecondaryFn.rawValue), fnUp = flags(63, 0)
        let roptDown = flags(61, 0x40 | CGEventFlags.maskAlternate.rawValue), roptUp = flags(61, 0)
        func key(_ code: UInt16, _ down: Bool) -> CGEvent { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)! }
        func mouse(_ n: Int64, _ down: Bool) -> CGEvent {
            let ev = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)!
            ev.setIntegerValueField(.mouseEventButtonNumber, value: n)
            return ev
        }
        var swallowed: [Bool] = []
        func feed(_ evs: [CGEvent]) { for ev in evs { swallowed.append(e.handle(ev.type, ev) == nil) } }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var fails = 0
        func check(_ name: String, _ expect: [String], _ expectSwallow: [Bool]? = nil) {
            settle()
            let ok = log == expect && (expectSwallow == nil || swallowed == expectSwallow!)
            if !ok { fails += 1 }
            print("\(ok ? "✅" : "❌") \(name): \(log)\(expectSwallow != nil ? " กลืน=\(swallowed)" : "")\(ok ? "" : "  (คาด \(expect) \(expectSwallow.map { "\($0)" } ?? ""))")")
            log = []; swallowed = []
        }

        e.bindings = [.pushToTalk: [["fn", "k:11"]], .handsFree: [["fn"]], .pressEnter: [["m:3"]], .pasteLast: [["ctrl", "opt", "k:9"]]]
        feed([fnDown, key(11, true), key(11, false), fnUp])
        check("fn+b กดค้าง → พูด, b ถูกกลืน", ["pushToTalk.down", "pushToTalk.up"], [false, true, true, false])
        feed([fnDown, fnUp])
        check("แตะ fn เดี่ยว → แฮนด์ฟรี (ยิงตอนปล่อย)", ["handsFree.down"])
        feed([fnDown, key(0, true), key(0, false), fnUp])
        check("fn+a (ไม่ใช่ปุ่มลัด) → ไม่ยิง ไม่กลืน", [], [false, false, false, false])
        feed([mouse(3, true), mouse(3, false)])
        check("เมาส์ 4 → กด Enter, กลืนทั้งกด/ปล่อย", ["pressEnter.down"], [true, true])
        feed([flags(59, 0x01 | CGEventFlags.maskControl.rawValue), flags(58, 0x01 | 0x20 | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue),
              key(9, true), key(9, false), flags(58, 0x01 | CGEventFlags.maskControl.rawValue), flags(59, 0)])
        check("⌃⌥V (ฝั่งซ้าย) → วางล่าสุด", ["pasteLast.down"], [false, false, true, true, false, false])

        e.bindings = [.pushToTalk: [["ropt"]], .handsFree: [["fn"]]]
        feed([fnDown, fnUp])
        check("แฮนด์ฟรี = fn: แตะ fn → เริ่ม (ตอนปล่อย)", ["handsFree.down"])
        feed([fnDown, key(123, true), key(123, false), fnUp])
        check("แฮนด์ฟรี = fn: fn+← (Home) → ไม่เริ่ม ไม่กลืน", [], [false, false, false, false])
        feed([roptDown, roptUp])
        check("แฮนด์ฟรี = fn: ⌥ขวายังกดค้างพูดได้", ["pushToTalk.down", "pushToTalk.up"])

        e.bindings = [.pushToTalk: [["ropt"]], .handsFree: [["opt", "k:49"]]]
        let loptDown = flags(58, 0x20 | CGEventFlags.maskAlternate.rawValue), loptUp = flags(58, 0)
        feed([loptDown, key(49, true), key(49, false), loptUp])
        check("แฮนด์ฟรี = ⌥Space: ⌥ซ้าย+Space → เริ่มทันที, Space ถูกกลืน", ["handsFree.down"], [false, true, true, false])
        feed([roptDown, key(49, true), key(49, false), roptUp])
        check("แฮนด์ฟรี = ⌥Space: ⌥ขวา+Space → ยกเลิกกดค้าง แล้วเปิดแฮนด์ฟรี", ["pushToTalk.down", "pushToTalk.cancel", "handsFree.down"], [false, true, true, false])
        feed([loptDown, key(0, true), key(0, false), loptUp])
        check("แฮนด์ฟรี = ⌥Space: ⌥+a ยังพิมพ์อักษรพิเศษได้", [], [false, false, false, false])

        e.bindings = [.pushToTalk: [["ropt"]], .handsFree: [["ropt", "k:49"]]]
        feed([roptDown, key(0, true), key(0, false), roptUp])
        check("⌥ขวา แล้วกด a → ยกเลิก (ใช้ ⌥ พิมพ์อักษรพิเศษ)", ["pushToTalk.down", "pushToTalk.interrupted"], [false, false, false, false])
        feed([roptDown, flags(56, 0x40 | 0x02 | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue), flags(56, 0x40 | CGEventFlags.maskAlternate.rawValue), roptUp])
        check("⌥ขวา + ⇧ → โหมดคำสั่ง", ["pushToTalk.down", "shift", "pushToTalk.up"])
        feed([roptDown, key(49, true), key(49, false), roptUp])
        check("⌥ขวา + space → ยกเลิกกดค้าง แล้วเปิดแฮนด์ฟรี", ["pushToTalk.down", "pushToTalk.cancel", "handsFree.down"], [false, true, true, false])

        // --- เคสจากออดิท ---
        e.onEscape = { log.append("escape") }
        e.bindings = [.pushToTalk: [["ropt"]], .pasteLast: [["ctrl", "opt", "k:9"]]]
        // A2: ⌘V ที่แอปส่งเอง (ติด syntheticMark) ต้องผ่าน ไม่วนกลับมาทริกเกอร์ ⌃⌥V ซ้ำ
        let ctrlOptDown = flags(58, 0x01 | 0x20 | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
        let synthV = key(9, true); synthV.setIntegerValueField(.eventSourceUserData, value: ShortcutEngine.syntheticMark)
        let synthVUp = key(9, false); synthVUp.setIntegerValueField(.eventSourceUserData, value: ShortcutEngine.syntheticMark)
        feed([flags(59, 0x01 | CGEventFlags.maskControl.rawValue), ctrlOptDown, key(9, true), key(9, false), synthV, synthVUp,
              flags(58, 0x01 | CGEventFlags.maskControl.rawValue), flags(59, 0)])
        check("⌃⌥V แล้ว ⌘V ของแอปเองไม่วนทริกเกอร์ซ้ำ", ["pasteLast.down"], [false, false, true, true, false, false, false, false])
        // A3: tap ถูกปิดระหว่างกดค้าง → ต้องยกเลิก (ไม่ปล่อยไมค์ค้าง)
        feed([roptDown]); _ = e.handle(.tapDisabledByTimeout, CGEvent(source: nil)!); swallowed.append(false); feed([roptUp])
        check("tap ถูกปิดระหว่างกดค้าง → ยกเลิกทันที", ["pushToTalk.down", "pushToTalk.cancel"])
        // A9: Esc ระหว่างกดค้าง (กำลังพูด) → กลืน + ยกเลิก ไม่หลุดไปแอป
        e.escapeArmed = true
        feed([roptDown, key(53, true), key(53, false), roptUp])
        check("Esc ระหว่างกดค้าง → กลืน + ยกเลิก", ["pushToTalk.down", "escape"], [false, true, true, false])
        e.escapeArmed = false
        feed([key(53, true), key(53, false)])
        check("Esc ตอนว่าง → ผ่านไปแอปตามปกติ", [], [false, false])

        var got: [(KeyCombo, Bool)] = []
        e.beginRecording { c, d in got.append((c, d)) }
        feed([fnDown, key(11, true), key(11, false), fnUp])
        settle()
        let ok1 = got.last?.1 == true && got.last?.0 == ["fn", "k:11"]
        print("\(ok1 ? "✅" : "❌") อัดปุ่ม fn+b → \(got.last.map { Keys2.label($0.0) } ?? "-") · กลืนปุ่มระหว่างอัด=\(swallowed)"); if !ok1 { fails += 1 }
        got = []; swallowed = []
        e.beginRecording { c, d in got.append((c, d)) }
        feed([flags(59, 0x01 | CGEventFlags.maskControl.rawValue), flags(58, 0x01 | 0x20 | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue),
              key(9, true), key(9, false), flags(58, 0x01 | CGEventFlags.maskControl.rawValue), flags(59, 0)])
        settle()
        let ok2 = got.last?.0 == ["ctrl", "opt", "k:9"]
        print("\(ok2 ? "✅" : "❌") อัดปุ่ม ⌃⌥V ฝั่งซ้าย → \(got.last.map { "\($0.0)" } ?? "-") (ข้างไหนก็ได้)"); if !ok2 { fails += 1 }
        got = []; swallowed = []
        e.beginRecording { c, d in got.append((c, d)) }
        feed([roptDown, roptUp])
        settle()
        let ok3 = got.last?.0 == ["ropt"]
        print("\(ok3 ? "✅" : "❌") อัดปุ่ม ⌥ขวาเดี่ยว → \(got.last.map { Keys2.label($0.0) } ?? "-") (ระบุข้าง)"); if !ok3 { fails += 1 }
        e.endRecording()
        print(fails == 0 ? "ผ่านทั้งหมด" : "ไม่ผ่าน \(fails) ข้อ")
        exit(fails == 0 ? 0 : 1)
    }

    /// เรนเดอร์หน้า "ปุ่มลัด" เป็น PNG (ไว้ตรวจหน้าตา ไม่ต้องเปิดหน้าต่าง) — ตัวอย่างตั้งแบบในภาพ Wispr: fn+b, แฮนด์ฟรี fn
    static func renderShortcuts(_ out: String) {
        MainActor.assumeIsolated {
            let m = ShortcutsModel(engine: ShortcutEngine())
            m.bindings = [.pushToTalk: [["fn", "k:11"]], .handsFree: [["fn"]], .commandMode: [], .pressEnter: [["m:3"]],
                          .pasteLast: [["ctrl", "opt", "k:9"]], .addWord: [["ctrl", "opt", "k:2"]]]
            m.message = "ตั้ง กดค้างเพื่อพูด = fn b แล้ว ✓"
            m.recording = .init(action: .commandMode, index: nil); m.live = ["rcmd"]
            let view = ShortcutsTab(m: m).padding(40).frame(width: 820).background(Theme.contentBg).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("render ไม่ได้"); exit(1) }
            try? png.write(to: URL(fileURLWithPath: out))
            print("saved \(out)")
        }
    }

    /// เรนเดอร์ Dynamic Island ทุกสถานะเป็นภาพเดียว (ตรวจหน้าตา)
    static func renderIsland(_ out: String) {
        MainActor.assumeIsolated {
            @MainActor func model(_ setup: (OverlayModel) -> Void) -> OverlayModel {
                let m = OverlayModel()
                m.hint = "แตะ fn เพื่อพูดยาว · กดค้าง ⌥ ขวา · หรือคลิกที่นี่"
                m.meter.set((0..<OverlayModel.bars).map { i in CGFloat(abs(sin(Double(i) * 0.7))) * 0.8 + 0.1 })
                m.appIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
                setup(m)
                return m
            }
            let states: [(String, OverlayModel)] = [
                ("ว่าง (จอไม่มีรอยบาก)", model { _ in }),
                ("ชี้เมาส์", model { $0.phase = .hover }),
                ("กำลังพูด (กดค้าง)", model { $0.phase = .listening }),
                ("กำลังพูด + คำสด (แฮนด์ฟรี)", model { $0.phase = .listening; $0.handsFree = true; $0.setLive(stable: "พรุ่งนี้ประชุมกับทีมตอน 10:30 น. นะ แล้วก็", pending: "ฝากเตรียมสไลด์เรื่อง") }),
                ("โหมดคำสั่ง", model { $0.phase = .listening; $0.command = true }),
                ("กำลังเกลา", model { $0.phase = .thinking; $0.liveText = "พรุ่งนี้ประชุมกับทีมตอน 10:30 น. นะ แล้วก็ฝากเตรียมสไลด์เรื่อง funding dashboard ด้วย" }),
                ("วางแล้ว", model { $0.phase = .done; $0.doneText = "พรุ่งนี้ประชุมกับทีมตอน 10 โมงครึ่งนะ แล้วก็ฝากเตรียม slide เรื่อง funding dashboard ด้วย" }),
                ("error", model { $0.phase = .error; $0.message = "ถอดเสียงไม่สำเร็จ — เช็คเน็ต/quota" }),
                ("เรียนรู้คำ", model { $0.phase = .learned; $0.learnedWord = "NokNok" }),
                ("กำลังพูด บนจอมีรอยบาก", model { $0.phase = .listening; $0.notchWidth = 180; $0.topInset = 32; $0.liveText = "สวัสดีครับ ทดสอบ 1 2 3" }),
                ("ล่างแบบ Wispr", model { $0.phase = .listening; $0.top = false }),
            ]
            let view = VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                    Text(st.0).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 8)
                    IslandView(m: st.1).frame(height: 110, alignment: .top).clipped()
                        .background(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.95)], startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(10).background(Color.white)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("render ไม่ได้"); exit(1) }
            try? png.write(to: URL(fileURLWithPath: out))
            print("saved \(out)")
        }
    }

    /// ป้อนไฟล์เสียงตามเวลาจริงเข้า LiveTranscriber แล้วพิมพ์ข้อความสดที่ได้
    static func liveTest(_ path: String) {
        guard let key = Keys.gemini, let wav = try? Data(contentsOf: URL(fileURLWithPath: path)), wav.count > 44 else { print("ไม่มีคีย์/ไฟล์"); exit(1) }
        let pcm = wav.subdata(in: 44..<wav.count)
        let l = LiveTranscriber()
        let t0 = Date()
        var last = ""
        let display = LiveDisplay()
        l.onText = { stable, pending in
            let (a, b) = display.clean(stable: stable, pending: pending)
            let t = [a, b].filter { !$0.isEmpty }.joined(separator: " ")
            if t != last { last = t; print(String(format: "  %5.2fs  %@", Date().timeIntervalSince(t0), t)) }
        }
        l.start(key: key)
        Task {
            var i = 0
            while i < pcm.count {
                l.append(pcm.subdata(in: i..<min(i + 640, pcm.count)))
                i += 640
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print(String(format: "  %5.2fs  (จบเสียง)", Date().timeIntervalSince(t0)))
            l.stop()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(Double(pcm.count) / 32000 + 3.5))
    }

    /// ดูว่าลำโพงตอนนี้ปิดเสียงด้วยวิธีไหน + แอปที่กำลังส่งเสียง (ไม่เปลี่ยนเสียงเครื่อง)
    static func duckTest() {
        MainActor.assumeIsolated {
            print(AudioDucker.describe())
            for b in ["com.google.Chrome.helper", "com.spotify.client", "com.apple.WebKit.GPU", "us.zoom.xos", "com.kron.friday"] {
                print("  \(b): \(AudioDucker.isMedia(b) ? "เพลง/วิดีโอ → หยุดได้" : "ไม่ยุ่ง")")
            }
        }
    }

    /// ทดสอบการขยายวลีลัด (ไม่แตะ snippets.json ของผู้ใช้)
    static func snippetsTest() {
        let list = [Snippet(trigger: "อีเมลงาน", text: "me@work.com"),
                    Snippet(trigger: "ลงท้ายอีเมล", text: "ขอบคุณครับ\nสมชาย"),
                    Snippet(trigger: "my zoom", text: "https://zoom.us/j/123"),
                    Snippet(trigger: "อีเมล", text: "SHORT")]
        let cases: [(String, String)] = [
            ("อีเมลงาน", "me@work.com"),
            ("อีเมลงานครับ", "me@work.com"),
            ("อีเมล งาน", "me@work.com"),
            ("ส่งไปที่อีเมลงานนะ", "ส่งไปที่ me@work.com นะ"),
            ("ส่งไปที่ อีเมลงาน นะ", "ส่งไปที่ me@work.com นะ"),
            ("เข้าห้อง My Zoom ได้เลย", "เข้าห้อง https://zoom.us/j/123 ได้เลย"),
            ("my zoomer friend", "my zoomer friend"),
            ("ลงท้ายอีเมล", "ขอบคุณครับ\nสมชาย"),
            ("วันนี้ไม่มีอะไร", "วันนี้ไม่มีอะไร"),
            ("อีเมลงาน กับ อีเมล", "me@work.com กับ SHORT"),
        ]
        var fail = 0
        for (input, want) in cases {
            let got = Snippets.expand(input, with: list).text
            let ok = got == want
            if !ok { fail += 1 }
            print("\(ok ? "✅" : "❌") \(input.debugDescription) → \(got.debugDescription)\(ok ? "" : " (ต้องได้ \(want.debugDescription))")")
        }
        print(fail == 0 ? "ผ่านทั้งหมด" : "ไม่ผ่าน \(fail) กรณี")
        if fail > 0 { exit(1) }
    }

    /// เรนเดอร์หน้าต่างหลักแต่ละหน้าเป็นภาพ (ใช้ข้อมูลจริง) → <prefix>-home.png ฯลฯ
    static func renderHub(_ prefix: String) {
        MainActor.assumeIsolated {
            let h = HubModel(settings: SettingsModel(engine: ShortcutEngine()), overlay: OverlayModel())
            h.reload()
            for p in HubModel.Page.allCases {
                h.page = p
                let view = HubView(m: h, scrollable: false).frame(width: 1040)
                let r = ImageRenderer(content: view)
                r.scale = 1.5
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("render ไม่ได้ \(p)"); continue }
                try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(p.rawValue).png"))
                print("saved \(prefix)-\(p.rawValue).png")
            }
        }
    }
}
