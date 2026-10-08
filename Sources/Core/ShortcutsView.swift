import AppKit
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
    var onChange: (() -> Void)?

    init(engine: ShortcutEngine) {
        self.engine = engine
        bindings = Store.config.shortcutBindings
    }

    func combos(_ a: ShortcutAction) -> [KeyCombo] { bindings[a] ?? [] }

    func startRecording(_ a: ShortcutAction, index: Int?) {
        if recording != nil { engine.endRecording() }
        recording = Slot(action: a, index: index)
        live = []
        message = nil
        engine.beginRecording { [weak self] combo, done in
            MainActor.assumeIsolated { self?.recorded(combo, done: done) }
        }
    }

    func cancelRecording() {
        engine.endRecording()
        recording = nil
        live = []
    }

    private func recorded(_ combo: KeyCombo, done: Bool) {
        guard let slot = recording else { return }
        if !done { live = combo; return }
        engine.endRecording()
        recording = nil
        live = []
        guard !combo.isEmpty else { return }   // Esc = ยกเลิก
        if let err = validate(combo, for: slot) { message = err; return }
        var list = combos(slot.action)
        if let i = slot.index, i < list.count { list[i] = combo } else { list.append(combo) }
        bindings[slot.action] = list
        message = "Set \(slot.action.title) to \(Keys2.label(combo)) ✓"
        save()
    }

    private func validate(_ c: KeyCombo, for slot: Slot) -> String? {
        if c.count == 1, let t = c.first {
            if t.hasPrefix("k:") && !Keys2.isFunctionKey(t) {
                return "\"\(Keys2.label(t))\" alone can't be used (you couldn't type it anymore) — combine with fn / ⌃ / ⌥ / ⌘"
            }
            if Keys2.isModifier(t) && !["fn", "ropt", "rcmd", "rctrl"].contains(t) {
                return "\(Keys2.label(t)) alone conflicts with typing/system shortcuts — use fn, a right-side modifier, or a combination"
            }
        }
        let mods = c.filter(Keys2.isModifier), keys = c.filter { $0.hasPrefix("k:") }
        if !keys.isEmpty, !keys.contains(where: Keys2.isFunctionKey), !c.contains(where: { $0.hasPrefix("m:") }) {
            if mods.isEmpty { return "Letter keys alone would block typing — combine with fn / ⌃ / ⌥ / ⌘" }
            if mods.allSatisfy({ Keys2.agnostic($0) == "shift" }) { return "⇧ + a letter is just a capital letter — use fn / ⌃ / ⌥ / ⌘ instead" }
        }
        let key = Set(c)
        for a in ShortcutAction.allCases {
            for (i, other) in combos(a).enumerated() where Set(other) == key && !(a == slot.action && i == slot.index) {
                return "Already used for \"\(a.title)\""
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
        message = "Reset to defaults"
        save()
    }

    private func save() {
        Store.update { $0.shortcutBindings = bindings }
        engine.bindings = bindings
        onChange?()
    }
}

struct ShortcutsTab: View {
    @ObservedObject var m: ShortcutsModel
    var scrollable = true   // false = เรนเดอร์เป็นภาพ (ImageRenderer วาด ScrollView ไม่ได้)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shortcuts").font(.system(size: 22, weight: .semibold))
            Text("Choose your preferred shortcuts — click ✎, hold the keys you want, release when done")
                .foregroundStyle(.secondary).padding(.top, 4)
            if scrollable { ScrollView { cards } } else { cards }
            if let msg = m.message {
                Text(msg).font(.callout).foregroundStyle(msg.hasSuffix("✓") || msg.hasPrefix("Reset") ? Color.green : Color.orange)
                    .padding(.bottom, 8)
            }
            HStack(alignment: .center) {
                Button("Reset to default") { m.reset() }.controlSize(.large)
                Spacer()
                Text("Esc cancels while dictating · To use fn: System Settings → Keyboard → \"Press 🌐 key to\" = Do Nothing")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
    }

    private var cards: some View {
        VStack(spacing: 12) {
            ForEach(ShortcutAction.allCases) { a in card(a) }
        }
        .padding(.vertical, 16)
    }

    private func card(_ a: ShortcutAction) -> some View {
        let list = m.combos(a)
        let addingHere = m.recording == ShortcutsModel.Slot(action: a, index: nil)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(a.title).font(.system(size: 15, weight: .semibold))
                Text(a.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 10) {
                if a == .handsFree, let ptt = m.combos(.pushToTalk).first {
                    HStack(spacing: 10) {
                        field(prefix: "Double tap", combo: ptt, recording: false, buttons: false, a: a, i: nil)
                        Color.clear.frame(width: 40, height: 1)
                    }
                }
                ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                    let rec = m.recording == ShortcutsModel.Slot(action: a, index: i)
                    HStack(spacing: 10) {
                        field(prefix: nil, combo: rec ? m.live : c, recording: rec, buttons: true, a: a, i: i)
                        if i == list.count - 1 && !addingHere { plusButton(a) } else { Color.clear.frame(width: 40, height: 1) }
                    }
                }
                if addingHere {
                    HStack(spacing: 10) {
                        field(prefix: nil, combo: m.live, recording: true, buttons: true, a: a, i: nil)
                        Color.clear.frame(width: 40, height: 1)
                    }
                } else if list.isEmpty {
                    HStack(spacing: 10) {
                        Button { m.startRecording(a, index: nil) } label: {
                            HStack {
                                Text("Click to add a shortcut").foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(fieldBackground(active: false))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 250)
                        Color.clear.frame(width: 40, height: 1)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }

    private func field(prefix: String?, combo: KeyCombo, recording: Bool, buttons: Bool, a: ShortcutAction, i: Int?) -> some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix).foregroundStyle(.secondary) }
            if recording && combo.isEmpty {
                Text("Press keys…").foregroundStyle(Color.accentColor)
            } else {
                ForEach(Keys2.sorted(combo), id: \.self) { t in chip(Keys2.label(t)) }
            }
            Spacer(minLength: 4)
            if buttons {
                if recording {
                    Button { m.cancelRecording() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel (Esc)")
                } else {
                    Button { m.startRecording(a, index: i) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Edit")
                    if let i, !(a.required && m.combos(a).count <= 1) {
                        Button { m.remove(a, i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
                    }
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(width: 250, height: 40)
        .background(fieldBackground(active: recording))
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
    }

    private func plusButton(_ a: ShortcutAction) -> some View {
        Button { m.startRecording(a, index: nil) } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Add another")
    }

    private func fieldBackground(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: active ? 2 : 1))
    }
}
