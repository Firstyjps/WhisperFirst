import AppKit

/// วงจรหลัก: กดค้าง → อัด (ส่งเกลาล่วงหน้าตอนเงียบ) → ปล่อย → วางลงแอปที่ใช้อยู่ → เฝ้าดูการแก้ไขเพื่อเรียนรู้คำ
/// - แตะปุ่ม 2 ครั้งเร็วๆ = แฮนด์ฟรี (พูดยาวได้ แตะอีกครั้งเพื่อจบ)
/// - กด ⇧ ระหว่างพูด = โหมดคำสั่ง (แก้/แปล/เขียนใหม่ ข้อความที่เลือกไว้)
/// - Esc = ยกเลิก
@MainActor
final class Controller {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle { didSet { onStateChange?() } }
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
    private let maxSeconds = 360.0

    func start() {
        shortcuts.bindings = Store.config.shortcutBindings
        shortcuts.onAction = { [weak self] a, p in MainActor.assumeIsolated { self?.handle(a, p) } }
        shortcuts.onShift = { [weak self] in MainActor.assumeIsolated { self?.shiftPressed() } }
        shortcuts.escapeHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state != .idle else { return false }
                DispatchQueue.main.async { self.escape() }
                return true
            }
        }
        shortcuts.start()
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.overlay.push(level: level)
                if Date().timeIntervalSince(self.pressAt) > self.maxSeconds { self.finish() }
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
    }

    // MARK: อัด → ประมวลผล

    private func begin(command: Bool) {
        learner.flush()   // พูดรอบใหม่ = ผู้ใช้แก้ข้อความรอบก่อนเสร็จแล้ว
        let app = NSWorkspace.shared.frontmostApplication
        target = (app?.localizedName ?? "", app?.bundleIdentifier ?? "")
        let s = DictationSession(transcriber: transcriber, appName: target.name, bundleID: target.bundle)
        session = s
        let lv: LiveTranscriber? = Store.config.liveTranscript ? Keys.gemini.map { key in
            let l = LiveTranscriber()
            l.onText = { [weak self] t in self?.overlay.liveText = t }
            l.start(key: key)
            return l
        } : nil
        live = lv
        s.live = lv
        recorder.onChunk = { data, rms in s.append(data, rms: rms); lv?.append(data) }
        do { try recorder.start() } catch {
            session = nil
            overlay.flash("Couldn't open microphone: \(error.localizedDescription)")
            return
        }
        pressAt = Date()
        handsFree = false
        commandMode = command
        if commandMode { s.setCommand() }
        state = .recording
        overlay.listening(command: commandMode, icon: app?.icon)
        Sounds.play("Tink")
        transcriber.prewarm()
        // หลังเปิดไมค์แล้ว — ไม่เสียเสียงช่วงแรก
        if let pid = app?.processIdentifier { AX.enableManualAccessibility(pid: pid) }
        s.setBefore(Store.config.useContext ? AX.textBeforeCursor() : nil)
    }

    func cancel(silent: Bool) {
        recorder.stop()
        session?.cancel()
        session = nil
        live?.cancel()
        live = nil
        task?.cancel()
        task = nil
        handsFree = false
        state = .idle
        if silent { overlay.hide() } else { overlay.flash("Cancelled") }
    }

    private func finish() {
        recorder.stop()
        live = nil     // session รอข้อความสุดท้ายจาก Live เอง (ข้อความยังไหลมาแสดงระหว่างเกลา)
        handsFree = false
        guard let s = session else { state = .idle; return }
        session = nil
        let seconds = s.seconds, peak = s.peak
        guard seconds >= 0.4, peak >= 0.008 else {
            s.cancel()
            state = .idle
            overlay.flash(seconds < 0.4 ? "Too short" : "No speech detected — check your mic")
            Log.write("skip: \(String(format: "%.2f", seconds))s peak=\(peak)")
            return
        }
        Sounds.play("Pop")
        let command = commandMode
        lastInput = DictationInput(wav: s.wav, seconds: seconds, command: command, appName: target.name, bundleID: target.bundle)
        state = .processing
        overlay.thinking(command: command)
        let released = Date()
        task = Task { [weak self] in
            let selected = command ? await Inserter.selectedText() : nil
            self?.lastInput?.selected = selected
            do {
                let r = try await s.finish(selected: selected)
                guard !Task.isCancelled, let self else { return }
                Log.write("หลังปล่อยปุ่ม \(Int(Date().timeIntervalSince(released) * 1000))ms\(s.usedText ? " (ข้อความ Live)" : s.usedSpeculative ? " (ล่วงหน้า)" : " (ส่งเสียง)")")
                self.deliver(r, command: command, seconds: seconds)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
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

    private func deliver(_ r: DictationResult, command: Bool, seconds: Double) {
        task = nil
        state = .idle
        var text = r.text
        guard !text.isEmpty else {
            overlay.flash("No speech detected")
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
