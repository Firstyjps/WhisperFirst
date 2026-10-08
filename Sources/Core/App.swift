import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// WhisperFirst — แอป menu bar (ไม่มีไอคอนใน Dock)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = Controller()
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel!
    private var hubWindow: NSWindow?
    private var hub: HubModel?
    private var trustTimer: Timer?
    private var wasTrusted = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        overlayPanel = OverlayPanel(model: controller.overlay)
        controller.onStateChange = { [weak self] in self?.updateIcon() }
        controller.start()

        AVCaptureDevice.requestAccess(for: .audio) { ok in if !ok { Log.write("ไม่ได้สิทธิ์ไมค์") } }
        wasTrusted = AX.trusted
        if !wasTrusted { AX.prompt() }
        // ได้สิทธิ์ Accessibility ระหว่างที่แอปเปิดอยู่ → ติดตั้งตัวฟังปุ่มใหม่ให้ใช้ได้ทันที
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = AX.trusted
                if now != self.wasTrusted {
                    self.wasTrusted = now
                    if now { self.controller.shortcuts.start(); self.controller.overlay.flash("Ready — hold \(Store.config.pushToTalkLabel) and speak", seconds: 3) }
                    self.updateIcon()
                }
            }
        }
        if Keys.gemini == nil { showSettings() }
        // open -a WhisperFirst --args --login-item-on → ลงทะเบียนเปิดตอนเข้าสู่ระบบ (เหมือนกดในเมนู)
        if CommandLine.arguments.contains("--login-item-on"), SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch { Log.write("login item: \(error.localizedDescription)") }
        }
        Log.write("login item: \(SMAppService.mainApp.status == .enabled ? "เปิด" : "ปิด (status \(SMAppService.mainApp.status.rawValue))")")
        Log.write("start (ax=\(wasTrusted))")
    }

    private func updateIcon() {
        let name: String
        switch controller.state {
        case .idle: name = AX.trusted ? "waveform" : "exclamationmark.triangle"
        case .recording: name = "mic.fill"
        case .processing: name = "ellipsis.circle"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "WhisperFirst")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // MARK: เมนู (สร้างใหม่ทุกครั้งที่เปิด → สถานะเป็นปัจจุบันเสมอ)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hk = Store.config.pushToTalkLabel
        let sc = Store.config.shortcutBindings
        func keys(_ a: ShortcutAction) -> String { sc[a]?.first.map { "  (\(Keys2.label($0)))" } ?? "" }
        if !AX.trusted {
            menu.addItem(item("⚠️ Accessibility permission needed — click to open", #selector(openAXSettings)))
        } else if Keys.gemini == nil {
            menu.addItem(item("⚠️ Gemini API key missing", #selector(openSettings)))
        } else {
            let s = NSMenuItem(title: "Hold \(hk) to dictate · Double-tap for hands-free\(keys(.handsFree).isEmpty ? "" : " or" + keys(.handsFree))", action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
            let s2 = NSMenuItem(title: "Press ⇧ while speaking = edit selected text · Esc = cancel", action: nil, keyEquivalent: "")
            s2.isEnabled = false
            menu.addItem(s2)
        }
        menu.addItem(.separator())
        menu.addItem(item("Paste Last Transcript\(keys(.pasteLast))", #selector(pasteLast)))
        let retry = item("↻ Retry Last Recording", #selector(retryLast))
        retry.isEnabled = controller.lastInput != nil
        menu.addItem(retry)
        menu.addItem(item("Add Selection to Dictionary\(keys(.addWord))", #selector(addWord)))
        if let l = controller.learner.lastLearned {
            menu.addItem(item("↶ Forget Learned Word: \(l.word)", #selector(undoLearned)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open WhisperFirst…", #selector(openHub)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show Data Folder", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit WhisperFirst", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openAXSettings() {
        AX.prompt()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func retryLast() { controller.retryLast() }
    @objc private func addWord() { controller.addSelectionToDictionary() }
    @objc private func undoLearned() { controller.learner.undoLast() }
    @objc private func openSettings() { showSettings() }
    @objc private func openHub() { showHub(.home) }
    @objc private func openFolder() { NSWorkspace.shared.open(Paths.support) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            controller.overlay.flash("Couldn't change Launch at Login: \(error.localizedDescription)", seconds: 4)
        }
    }

    func showSettings() { showHub(.settings) }

    /// หน้าต่างหลัก — ระหว่างเปิดแอปโผล่ใน Dock/⌘Tab · ปิดแล้วกลับไปอยู่ menu bar อย่างเดียว
    func showHub(_ page: HubModel.Page? = nil) {
        if hubWindow == nil {
            let vm = SettingsModel(engine: controller.shortcuts)
            vm.onIslandChange = { [weak self] in self?.overlayPanel.applySettings() }
            vm.shortcuts.onChange = { [weak self] in self?.controller.updateHint() }
            let h = HubModel(settings: vm, overlay: controller.overlay)
            h.onDemo = { [weak self] in self?.controller.demoIsland() }
            hub = h
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "WhisperFirst"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .aqua)          // โทนสว่างแบบ Wispr เสมอ
            w.backgroundColor = NSColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: HubView(m: h))
            w.setFrameAutosaveName("WhisperFirstHub")
            if w.frame.origin == .zero { w.center() }
            hubWindow = w
        }
        hub?.reload()
        if let page { hub?.page = page }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === hubWindow else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub()
        return false
    }
}

/// จุดเข้าของ dylib — Launcher (ตัวแอป) โหลด dylib นี้แล้วเรียกฟังก์ชันนี้
@_cdecl("whisperfirst_main")
public func whisperfirstMain() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
