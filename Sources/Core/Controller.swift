import AppKit
import Carbon.HIToolbox

/// วงจรหลัก: กดค้าง → อัด (ส่งเกลาล่วงหน้าตอนเงียบ) → ปล่อย → วางลงแอปที่ใช้อยู่ → เฝ้าดูการแก้ไขเพื่อเรียนรู้คำ
/// - แตะปุ่ม 2 ครั้งเร็วๆ = แฮนด์ฟรี (พูดยาวได้ แตะอีกครั้งเพื่อจบ)
/// - กด ⇧ ระหว่างพูด = โหมดคำสั่ง (แก้/แปล/เขียนใหม่ ข้อความที่เลือกไว้)
/// - Esc = ยกเลิก
@MainActor
final class Controller {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle {
        didSet {
            shortcuts.escapeArmed = state != .idle   // Esc ถูกกลืน+ยกเลิกเฉพาะตอนกำลังพูด/ประมวลผล
            onStateChange?()
        }
    }
    var onStateChange: (() -> Void)?
    let overlay = OverlayModel()
    let shortcuts = ShortcutEngine()
    private(set) var lastText: String?
    private(set) var lastInput: DictationInput?

    private let recorder = Recorder()
    private let transcriber = Transcriber()
    lazy var learner = Learner(transcriber: transcriber)
    private var session: DictationSession?
    private var live: LiveTranscriber?
    private var pressAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var handsFree = false
    private var commandMode = false
    private var target = (name: "", bundle: "")
    private var task: Task<Void, Never>?
    private var commitWork: DispatchWorkItem?
    private var committed = false
    private var prefetchedSelection: String?
    private let maxSeconds = 360.0
    /// แอปที่ไม่ส่งข้อความก่อนเคอร์เซอร์ขึ้น cloud: terminal (scrollback อาจมี secret) + ตัวจัดการรหัสผ่าน
    static let noContextApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    func start() {
        shortcuts.bindings = Store.config.shortcutBindings
        shortcuts.onAction = { [weak self] a, p in MainActor.assumeIsolated { self?.handle(a, p) } }
        shortcuts.onShift = { [weak self] in MainActor.assumeIsolated { self?.shiftPressed() } }
        shortcuts.onEscape = { [weak self] in MainActor.assumeIsolated { self?.escape() } }
        shortcuts.start()
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, self.committed else { return }
                self.overlay.push(level: level)
                if Date().timeIntervalSince(self.pressAt) > self.maxSeconds { self.finish(auto: true) }
            }
        }
        learner.onLearned = { [weak self] word in self?.overlay.learned(word) }
        overlay.onStart = { [weak self] in self?.toggleHandsFree() }
        overlay.onStop = { [weak self] in if self?.state == .recording { self?.finish() } }
        overlay.onCancel = { [weak self] in self?.cancel(silent: false) }
        overlay.onRetry = { [weak self] in self?.retryLast() }
        overlay.onUndoLearned = { [weak self] in self?.learner.undoLast() }
        updateHint()
    }

    func demoIsland() {
        guard state == .idle else { return }
        overlay.demo()
    }

    /// ข้อความตอนชี้เมาส์ที่เกาะ
    func updateHint() {
        let sc = Store.config.shortcutBindings
        var parts: [String] = []
        if let h = sc[.handsFree]?.first { parts.append("Press \(Keys2.label(h)) for hands-free") }
        if let p = sc[.pushToTalk]?.first { parts.append("hold \(Keys2.label(p)) to dictate") }
        parts.append("or click here")
        overlay.hint = parts.joined(separator: " · ")
    }

    // MARK: ปุ่ม

    private func handle(_ a: ShortcutAction, _ p: ShortcutEngine.Phase) {
        switch (a, p) {
        case (.pushToTalk, .down), (.commandMode, .down): pressed(command: a == .commandMode)
        case (.pushToTalk, .up), (.commandMode, .up): released()
        case (_, .cancel): if state == .recording && !handsFree { cancel(silent: true) }
        case (_, .interrupted): otherKey()
        case (.handsFree, .down): toggleHandsFree()
        case (.pressEnter, .down): Inserter.key(36 /* Return */, flags: [])
        case (.pasteLast, .down): pasteLast()
        case (.addWord, .down): addSelectionToDictionary()
        default: break
        }
    }

    private func pressed(command: Bool) {
        switch state {
        case .processing: return
        case .recording: if handsFree { finish() }
        case .idle: begin(command: command)
        }
    }

    /// ปุ่มแฮนด์ฟรีโดยตรง: กด = เริ่ม (ไม่ต้องกดค้าง) · กดอีกครั้ง = จบ
    func toggleHandsFree() {
        switch state {
        case .processing: return
        case .recording: finish()
        case .idle:
            begin(command: false)
            guard state == .recording else { return }
            handsFree = true
            overlay.handsFree = true
        }
    }

    private func released() {
        guard state == .recording, !handsFree else { return }
        let held = Date().timeIntervalSince(pressAt)
        if held < 0.3 {
            // แตะสั้น: ครั้งแรก = ยกเลิกเงียบๆ, ครั้งที่สองติดกัน = แฮนด์ฟรี
            if Date().timeIntervalSince(lastTapAt) < 0.5 {
                handsFree = true
                overlay.handsFree = true
                lastTapAt = .distantPast
                return
            }
            lastTapAt = Date()
            cancel(silent: true)
            return
        }
        finish()
    }

    private func otherKey() {
        if state == .recording && !handsFree { cancel(silent: true) }
    }

    private func escape() {
        if state != .idle { cancel(silent: false) }
    }

    private func shiftPressed() {
        guard state == .recording, !commandMode else { return }
        commandMode = true
        overlay.command = true
        session?.setCommand()
        prefetchSelection()
    }

    /// โหมดคำสั่ง: อ่านข้อความที่เลือกผ่าน Accessibility ตั้งแต่ตอนนี้ (ไม่ต้องรอหลังปล่อยปุ่ม)
    private func prefetchSelection() {
        DispatchQueue.global(qos: .userInitiated).async {
            let sel = AX.selectedText()
            DispatchQueue.main.async { [weak self] in if self?.commandMode == true { self?.prefetchedSelection = sel } }
        }
    }

    // MARK: อัด → ประมวลผล

    private func begin(command: Bool) {
        // ช่องรหัสผ่าน (Secure Input) → ไม่ฟัง: macOS ส่งแค่ modifier มา จับการพิมพ์แทรกไม่ได้ เสี่ยงวางลงช่องรหัสผ่าน
        if IsSecureEventInputEnabled() {
            overlay.flash("Can't listen while a password field is active")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        target = (app?.localizedName ?? "", app?.bundleIdentifier ?? "")
        let s = DictationSession(transcriber: transcriber, appName: target.name, bundleID: target.bundle)
        session = s
        // Live สร้างไว้ก่อน (เก็บเสียงช่วงแรกไว้ในบัฟเฟอร์) แต่เชื่อมต่อจริงตอน commit
        let lv: LiveTranscriber? = Store.config.liveTranscript && Keys.gemini != nil ? LiveTranscriber() : nil
        lv?.onText = { [weak self] t in self?.overlay.liveText = t }
        lv?.onSettled = { [weak s] text, segs, spoken in s?.liveSettled(text: text, segments: segs, spoken: spoken) }
        live = lv
        s.live = lv
        recorder.onChunk = { data, rms in s.append(data, rms: rms); lv?.append(data) }
        do { try recorder.start() } catch {
            session = nil; live = nil
            overlay.flash("Couldn't open microphone: \(error.localizedDescription)")
            return
        }
        pressAt = Date()
        handsFree = false
        commandMode = command
        committed = false
        prefetchedSelection = nil
        if commandMode { s.setCommand(); prefetchSelection() }
        state = .recording
        // แตะสั้น/⌥+ตัวอักษร ภายใน 0.2 วิ → ไม่มีอะไรโผล่ ไม่มีเสียง ไม่ส่งอะไรขึ้น cloud
        let w = DispatchWorkItem { [weak self] in self?.commit(app: app) }
        commitWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// กดค้างจริง (≥0.2 วิ) → โชว์เกาะ เล่นเสียง เชื่อม Live อ่านบริบท
    private func commit(app: NSRunningApplication?) {
        guard state == .recording, let s = session, !committed else { return }
        committed = true
        learner.flush()   // พูดรอบใหม่ = ผู้ใช้แก้ข้อความรอบก่อนเสร็จแล้ว
        overlay.listening(command: commandMode, icon: app?.icon)
        if handsFree { overlay.handsFree = true }
        s.ignoreNext(seconds: 0.3)   // เสียง Tink ของเราเองเข้าไมค์ → ไม่นับว่าเป็นเสียงพูด
        Sounds.play("Tink")
        transcriber.prewarm()
        if let key = Keys.gemini { live?.start(key: key) }
        // อ่านข้อความก่อนเคอร์เซอร์นอก main (AX อาจค้างได้ถึงวินาที) · ไม่อ่านใน terminal/ตัวจัดการรหัสผ่าน
        let pid = app?.processIdentifier
        let useContext = Store.config.useContext && !Self.noContextApps.contains(target.bundle)
        DispatchQueue.global(qos: .userInitiated).async {
            if let pid { AX.enableManualAccessibility(pid: pid) }
            s.setBefore(useContext ? AX.textBeforeCursor() : nil)
        }
    }

    func cancel(silent: Bool) {
        commitWork?.cancel()
        recorder.stop()
        session?.cancel()
        session = nil
        live?.cancel()
        live = nil
        task?.cancel()
        task = nil
        handsFree = false
        committed = false
        state = .idle
        if silent { overlay.hide() } else { overlay.flash("Cancelled") }
    }

    /// auto = อัดครบเวลาสูงสุด (หรือไม่ได้ปล่อยปุ่มเอง) → ไม่วางเอง ใส่คลิปบอร์ดแทน
    private func finish(auto: Bool = false) {
        guard state == .recording, let s = session else { return }
        commitWork?.cancel()
        if !committed { commit(app: nil) }
        session = nil
        live = nil     // session รอข้อความสุดท้ายจาก Live เอง (ข้อความยังไหลมาแสดงระหว่างเกลา)
        handsFree = false
        let command = commandMode
        state = .processing
        overlay.thinking(command: command)
        Sounds.play("Pop")
        let released = Date()
        task = Task { [weak self] in
            // อัดต่ออีกนิดหลังปล่อยปุ่ม กันท้ายประโยคขาด (บัฟเฟอร์สุดท้ายของไมค์)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            self.recorder.stop()
            let seconds = s.seconds, peak = s.peakValue
            guard seconds >= 0.4, peak >= 0.008 else {
                s.cancel()
                self.state = .idle
                self.overlay.flash(seconds < 0.4 ? "Too short" : "No speech detected — check your mic")
                Log.write("skip: \(String(format: "%.2f", seconds))s peak=\(peak)")
                return
            }
            var selected: String? = nil
            if command {
                if let pre = self.prefetchedSelection { selected = pre } else { selected = await Inserter.selectedText() }
            }
            do {
                let r = try await s.finish(selected: selected)
                self.lastInput = s.builtInput
                guard !Task.isCancelled else { return }
                Log.write("หลังปล่อยปุ่ม \(Int(Date().timeIntervalSince(released) * 1000))ms\(s.usedEarly ? " (เกลาล่วงหน้า)" : s.usedText ? " (ข้อความ Live)" : " (ส่งเสียง)")")
                self.deliver(r, command: command, seconds: seconds, auto: auto)
            } catch is DictationSession.NoSpeech {
                guard !Task.isCancelled else { return }
                self.lastInput = s.builtInput
                self.state = .idle
                self.task = nil
                self.overlay.flash("No speech detected")
            } catch is CancellationError {
            } catch {
                self.lastInput = s.builtInput
                guard !Task.isCancelled else { return }
                self.failed(error)
            }
        }
    }

    /// ลองใหม่กับเสียงล่าสุด (เช่นตอนเน็ตหลุด)
    func retryLast() {
        guard state == .idle, let input = lastInput else { return }
        state = .processing
        overlay.thinking(command: input.command)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.transcriber.run(input)
                guard !Task.isCancelled else { return }
                self.deliver(r, command: input.command, seconds: input.seconds)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }   // ถูกยกเลิกแล้ว (Esc) → อย่าไปทับสถานะของการพูดรอบใหม่
                self.failed(error)
            }
        }
    }

    private func failed(_ error: Error) {
        state = .idle
        task = nil
        Log.write("error: \(error.localizedDescription)")
        overlay.error("Transcription failed — check network/quota")
    }

    private func deliver(_ r: DictationResult, command: Bool, seconds: Double, auto: Bool = false) {
        task = nil
        state = .idle
        var text = r.text
        guard !text.isEmpty else {
            overlay.flash("No speech detected")
            return
        }
        // ไม่วางถ้า: สลับแอปไประหว่างรอ / ช่องรหัสผ่านทำงานอยู่ / อัดยาวจนครบเวลา → ใส่คลิปบอร์ดให้ผู้ใช้วางเอง
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let switched = !target.bundle.isEmpty && front != target.bundle
        if switched || auto || IsSecureEventInputEnabled() {
            Inserter.copy(text)
            lastText = text
            History.append(HistoryEntry(t: Date().timeIntervalSince1970, app: target.name, mode: command ? "command" : "dictate",
                                        text: r.text, model: r.model, ms: r.ms, sec: seconds, bundle: target.bundle))
            overlay.flash(switched ? "You switched apps — copied, press ⌘V" : auto ? "Long recording — copied, press ⌘V" : "Password field active — copied instead", seconds: 3.5)
            return
        }
        // พูดต่อจากข้อความเดิมในบรรทัดเดียวกัน → เว้นวรรคให้ (แบบไทย: เว้นระหว่างประโยค)
        if !command, Store.config.useContext, let last = AX.textBeforeCursor(limit: 1)?.last, !last.isWhitespace,
           let first = text.first, !first.isPunctuation, !first.isWhitespace {
            text = " " + text
        }
        Inserter.paste(text, restore: Store.config.restoreClipboard)
        lastText = text
        History.append(HistoryEntry(t: Date().timeIntervalSince1970, app: target.name, mode: command ? "command" : "dictate",
                                    text: r.text, model: r.model, ms: r.ms, sec: seconds, bundle: target.bundle))
        overlay.done(r.text)
        if !command { learner.track(inserted: text) }
    }

    func pasteLast() {
        guard let t = lastText ?? History.recent(1).first?.text else { return }
        Inserter.paste(t, restore: Store.config.restoreClipboard)
    }

    /// เลือกคำในแอปไหนก็ได้ → ⌃⌥D → เพิ่มลงพจนานุกรม
    func addSelectionToDictionary() {
        Task {
            guard let word = await Inserter.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !word.isEmpty, word.count <= 60, !word.contains("\n") else {
                overlay.flash("Select a word first, then press ⌃⌥D")
                return
            }
            if Prompt.dictionaryEntries().words.contains(word) {
                overlay.flash("\"\(word)\" is already in your dictionary")
                return
            }
            var s = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            s += word + "\n"
            try? s.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
            overlay.flash("Added \"\(word)\" to dictionary ✓")
        }
    }
}
