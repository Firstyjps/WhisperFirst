import AppKit
import Carbon.HIToolbox
import SwiftUI

/// หน้า "ปุ่มลัด" แบบ Wispr Flow: แต่ละ action มีหลายชุด · ✎ อัดใหม่ · 🗑 ลบ · + เพิ่ม · คืนค่าเริ่มต้น
@MainActor
final class ShortcutsModel: ObservableObject {
    struct Slot: Equatable { let action: ShortcutAction; let index: Int? }   // index nil = กำลังเพิ่มชุดใหม่

    let engine: ShortcutEngine
    @Published var bindings: [ShortcutAction: [KeyCombo]]
    @Published var recording: Slot?
    @Published var live: KeyCombo = []
    @Published var message: String?
    @Published var messageIsError = false
    var onChange: (() -> Void)?

    init(engine: ShortcutEngine) {
        self.engine = engine
        bindings = Store.config.shortcutBindings
    }

    func combos(_ a: ShortcutAction) -> [KeyCombo] { bindings[a] ?? [] }

    private var timeout: DispatchWorkItem?

    func startRecording(_ a: ShortcutAction, index: Int?) {
        if recording != nil { engine.endRecording() }
        recording = Slot(action: a, index: index)
        live = []
        message = nil
        engine.beginRecording { [weak self] combo, done in
            MainActor.assumeIsolated { self?.recorded(combo, done: done) }
        }
        // กันโหมดอัดค้าง (ระหว่างอัดปุ่มทั้งเครื่องถูกกลืน) → ยกเลิกเองหลัง 10 วิ
        timeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.recording != nil else { return }
            self.cancelRecording()
            self.message = "Recording timed out — click the shortcut to try again"
            self.messageIsError = true
        }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    /// เรียกเมื่อออกจากหน้า Shortcuts / ปิดหน้าต่าง / สลับไปแอปอื่น — ห้ามปล่อยให้อัดค้าง
    func cancelRecording() {
        timeout?.cancel()
        guard recording != nil || engine.isRecording else { return }
        engine.endRecording()
        recording = nil
        live = []
    }

    private func recorded(_ combo: KeyCombo, done: Bool) {
        guard let slot = recording else { return }
        if !done { live = combo; return }
        timeout?.cancel()
        engine.endRecording()
        recording = nil
        live = []
        guard !combo.isEmpty else { return }   // Esc = ยกเลิก
        if let err = validate(combo, for: slot) { message = err; messageIsError = true; return }
        var list = combos(slot.action)
        if let i = slot.index, i < list.count { list[i] = combo } else { list.append(combo) }
        bindings[slot.action] = list
        message = "\(slot.action.title) is now \(Self.display(combo))"
        messageIsError = false
        save()
    }

    private func validate(_ c: KeyCombo, for slot: Slot) -> String? {
        if c.count == 1, let t = c.first {
            if t.hasPrefix("k:") && !Keys2.isFunctionKey(t) {
                return "“\(Keys2.label(t).uppercased())” on its own would stop you typing it — add ⌃, ⌥ or ⌘"
            }
            if Keys2.isModifier(t) && !["fn", "ropt", "rcmd", "rctrl"].contains(t) {
                return "\(Keys2.label(t)) on its own clashes with normal typing — use a Right-side key or a combination"
            }
        }
        let mods = c.filter(Keys2.isModifier), keys = c.filter { $0.hasPrefix("k:") }
        // คีย์ลัดของระบบ (⌘C ⌘V ⌘S ⌘Q ⌘Tab ฯลฯ) — ถ้าตั้งไว้ จะถูกกลืนทั้งเครื่อง
        let reserved: Set<Int> = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_S, kVK_ANSI_Q, kVK_ANSI_W,
                                  kVK_ANSI_N, kVK_ANSI_T, kVK_ANSI_F, kVK_ANSI_P, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space, kVK_ANSI_Grave]
        if keys.count == 1, let code = Int(keys[0].dropFirst(2)), reserved.contains(code),
           !mods.isEmpty, mods.allSatisfy({ ["cmd", "shift"].contains(Keys2.agnostic($0)) }), mods.contains(where: { Keys2.agnostic($0) == "cmd" }) {
            return "\(Self.display(c)) is a system shortcut — pick something with ⌃ or ⌥"
        }
        if !keys.isEmpty, !keys.contains(where: Keys2.isFunctionKey), !c.contains(where: { $0.hasPrefix("m:") }) {
            if mods.isEmpty { return "Letters on their own would stop you typing them — add ⌃, ⌥ or ⌘" }
            if mods.allSatisfy({ Keys2.agnostic($0) == "shift" }) { return "⇧ + a letter is just a capital letter — use ⌃, ⌥ or ⌘ instead" }
        }
        let key = Set(c)
        for a in ShortcutAction.allCases {
            for (i, other) in combos(a).enumerated() where Set(other) == key && !(a == slot.action && i == slot.index) {
                return "Already used for “\(a.title)”"
            }
        }
        return nil
    }

    func remove(_ a: ShortcutAction, _ i: Int) {
        var list = combos(a)
        guard i < list.count else { return }
        list.remove(at: i)
        bindings[a] = list
        save()
    }

    func reset() {
        cancelRecording()
        var d = ShortcutAction.defaults
        d[.pushToTalk] = [["ropt"]]
        bindings = d
        message = "Shortcuts are back to the defaults"
        messageIsError = false
        save()
    }

    /// ป้ายสำหรับข้อความ: ตัวอักษรตัวใหญ่ เหมือนบนปุ่ม
    static func display(_ c: KeyCombo) -> String {
        Keys2.sorted(c).map { let l = Keys2.label($0); return l.count == 1 ? l.uppercased() : l }.joined(separator: " ")
    }

    private func save() {
        Store.update { $0.shortcutBindings = bindings }
        engine.bindings = bindings
        onChange?()
    }
}

/// หน้า Shortcuts — การ์ดเดียว แถวละ action · คลิกช่องเพื่ออัด · ปุ่มเส้นประ "Add another"
struct ShortcutsTab: View {
    @ObservedObject var m: ShortcutsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageTitle(title: "Shortcuts", subtitle: "Click a shortcut, hold the keys you want, then let go.")
                Spacer()
                Button("Reset to defaults") { m.reset() }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.card)).overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                    .padding(.top, 10)
            }
            if let msg = m.message {
                HStack(spacing: 9) {
                    Image(systemName: m.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(msg).font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(m.messageIsError ? Theme.warnText : Theme.successBanner)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(m.messageIsError ? Theme.warnBg : Theme.successBg))
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { i, a in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    row(a)
                }
            }
            .wfCard(18)
            VStack(alignment: .leading, spacing: 6) {
                (Text("Press ") + Text("Esc").bold() + Text(" while talking to cancel."))
                (Text("Mouse side buttons work too — click a shortcut, then press ") + Text("Mouse 4").bold() + Text(" or ") + Text("Mouse 5").bold() + Text(". No Razer Synapse needed; if it remapped them to keys, those keys get recorded instead."))
                (Text("Want to use the ") + Text("fn / globe").bold() + Text(" key? In System Settings → Keyboard, set “Press globe key to” → Do Nothing."))
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.leading, 4)
        }
        .animation(.easeOut(duration: 0.2), value: m.message)
        .onDisappear { m.cancelRecording() }
    }

    private func row(_ a: ShortcutAction) -> some View {
        let list = m.combos(a)
        let adding = m.recording == ShortcutsModel.Slot(action: a, index: nil)
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.system(size: 14.5, weight: .semibold))
                Text(a.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                if a == .handsFree, let ptt = m.combos(.pushToTalk).first {
                    HStack(spacing: 8) {
                        Text("Double-tap").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Keycaps(combo: ptt)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.windowBg))
                }
                ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                    ComboField(m: m, action: a, index: i, combo: c,
                               removable: !(a.required && list.count <= 1))
                }
                if adding {
                    ComboField(m: m, action: a, index: nil, combo: [], removable: false)
                } else {
                    Button { m.startRecording(a, index: nil) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            Text(list.isEmpty ? "Add a shortcut" : "Add another").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(list.isEmpty ? Theme.accentText : Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color(hex: 0xDDD4C9), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 300)
        }
        .padding(.vertical, 16).padding(.horizontal, 22)
    }
}

/// ช่องปุ่มลัดหนึ่งชุด: คลิกเพื่ออัดใหม่ · ระหว่างอัดขอบส้ม + "Press keys…"
private struct ComboField: View {
    @ObservedObject var m: ShortcutsModel
    let action: ShortcutAction
    let index: Int?
    let combo: KeyCombo
    let removable: Bool
    @StateObject private var hover = HoverState()

    var body: some View {
        let rec = m.recording == ShortcutsModel.Slot(action: action, index: index)
        HStack(spacing: 6) {
            if rec && m.live.isEmpty {
                Text("Press keys or a mouse button…").font(.system(size: 13)).foregroundStyle(Theme.accentText)
            } else {
                Keycaps(combo: rec ? m.live : combo)
            }
            Spacer(minLength: 4)
            if rec {
                Button { m.cancelRecording() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).help("Cancel (Esc)")
            } else {
                Text("Change").font(.system(size: 12)).foregroundStyle(Theme.faint).opacity(hover.on ? 1 : 0.85)
                if removable, let index {
                    Button { m.remove(action, index) } label: { Image(systemName: "trash").font(.system(size: 11.5)).foregroundStyle(Theme.faint) }
                        .buttonStyle(.plain).help("Remove")
                }
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(rec ? Theme.accent : (hover.on ? Theme.keycapEdge : Theme.stroke), lineWidth: rec ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !rec { m.startRecording(action, index: index) } }
        .onHover { hover.on = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.title) shortcut: \(combo.isEmpty ? "not set" : ShortcutsModel.display(combo))")
        .accessibilityHint(rec ? "Press the keys or mouse button you want" : "Activate to change")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !rec { m.startRecording(action, index: index) } }
    }
}
