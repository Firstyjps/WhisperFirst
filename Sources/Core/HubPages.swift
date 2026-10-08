import AppKit
import SwiftUI

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var d: DictionaryModel
    @ObservedObject var shortcuts: ShortcutsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageTitle(title: "Dictionary", subtitle: "Names, brands and jargon you want spelled your way, every time.")
                Spacer()
                HStack(spacing: 8) {
                    Text("Edit as text").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Toggle("", isOn: $d.rawMode).toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
                }
                .padding(.top, 8)
            }
            if d.rawMode { raw } else { visual }
        }
    }

    @ViewBuilder private var visual: some View {
        addBar
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Your words").font(Theme.rounded(16, .semibold))
                Text("\(d.words.count)").font(.system(size: 12.5)).foregroundStyle(Theme.muted2)
            }
            .padding(.leading, 4)
            FlowLayout(spacing: 8) {
                ForEach(d.words, id: \.self) { w in WordChip(word: w, flash: d.justAdded == w) { d.remove(line: w) } }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).wfCard()
        }
        if !d.learned.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Learned from your edits", note: "When you fix a word after it's typed, WhisperFirst remembers it")
                VStack(spacing: 0) {
                    ForEach(Array(d.learned.enumerated()), id: \.offset) { i, pair in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12) }
                        HStack(spacing: 14) {
                            Image(systemName: "book").font(.system(size: 13)).foregroundStyle(Theme.accentText)
                                .frame(width: 30, height: 30).background(Circle().fill(Theme.accentSoft))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.1).font(.system(size: 14, weight: .semibold))
                                Text("You said it like \"\(pair.0)\"").font(.system(size: 12)).foregroundStyle(Theme.muted2)
                            }
                            Spacer()
                            Button("Forget") { d.remove(line: "\(pair.0) ~> \(pair.1)") }.buttonStyle(PillButtonStyle())
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                }
                .padding(6).wfCard()
            }
        }
        if !d.fixes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Always replace", note: "Swapped every time, exactly")
                VStack(spacing: 0) {
                    ForEach(Array(d.fixes.enumerated()), id: \.offset) { i, pair in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12) }
                        HStack(spacing: 12) {
                            Text(pair.0).font(.system(size: 14)).foregroundStyle(Theme.muted)
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Color(hex: 0xC9C0B5))
                            Text(pair.1).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button { d.remove(line: "\(pair.0) => \(pair.1)") } label: {
                                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.muted2)
                            }
                            .buttonStyle(.plain).help("Delete")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
                .padding(6).wfCard()
            }
        }
        HStack(spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(Theme.accentText)
            Text("Quick add: select a word in any app, then press").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
            Keycaps(combo: shortcuts.combos(.addWord).first)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.pillBtn))
    }

    private var addBar: some View {
        let empty = d.newWord.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
            TextField("Add a name, a brand or a word — e.g. a friend's name", text: $d.newWord)
                .textFieldStyle(.plain).font(.system(size: 14)).onSubmit { d.add() }
            Button("Add") { d.add() }.buttonStyle(PrimaryButtonStyle(enabled: !empty)).disabled(empty)
        }
        .padding(.leading, 18).padding(.trailing, 6).frame(height: 46)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: Theme.shadowTint.opacity(0.05), radius: 7, y: 4)
    }

    @ViewBuilder private var raw: some View {
        Text("One word per line · heard => correct always replaces · heard ~> correct is a hint · lines starting with # are notes")
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        RawEditor(m: d.raw) { d.load() }
    }
}

private struct WordChip: View {
    let word: String
    let flash: Bool
    let onRemove: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 6) {
            Text(word).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(hover.on ? Color.black.opacity(0.07) : .clear))
            }
            .buttonStyle(.plain).onHover { hover.on = $0 }.help("Remove")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(Capsule().fill(flash ? Theme.accentSoft : Theme.chip))
        .animation(.easeOut(duration: 0.4), value: flash)
    }
}

/// ตัวแก้ไฟล์ข้อความแบบ monospaced + ปุ่มบันทึก
struct RawEditor: View {
    @ObservedObject var m: TextFileModel
    var onSave: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextEditor(text: $m.text)
                .font(.system(size: 13, design: .monospaced)).lineSpacing(6)
                .scrollContentBackground(.hidden).scrollIndicators(.hidden)
                .padding(14).frame(minHeight: 380)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .wfOutline(16)
            HStack(spacing: 12) {
                if m.saved { Text("Saved ✓").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.successText) }
                Button("Save") { m.save(); onSave() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear { m.load() }
    }
}

/// ชิปเรียงต่อกันแล้วขึ้นบรรทัดใหม่เอง
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// Segmented control แบบ capsule (ราง segTrack + ปุ่มที่เลือกเป็นสีขาว)
struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    let selection: T
    var capsule = true
    var fontSize: CGFloat = 13
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, label in
                let on = value == selection
                Button { onSelect(value) } label: {
                    Text(label).font(.system(size: fontSize, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, capsule ? 16 : 12).padding(.vertical, capsule ? 7 : 5)
                        .background(
                            RoundedRectangle(cornerRadius: capsule ? 999 : 7, style: .continuous)
                                .fill(on ? Theme.card : .clear)
                                .shadow(color: on ? Theme.shadowTint.opacity(0.12) : .clear, radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(capsule ? 4 : 3)
        .background(RoundedRectangle(cornerRadius: capsule ? 999 : 10, style: .continuous).fill(Theme.segTrack))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Writing style

struct StylePage: View {
    @ObservedObject var m: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Writing style", subtitle: "Pick how text looks in each kind of app. Only punctuation and layout change — never your words.")
            Segmented(items: StyleCategory.allCases.map { ($0, $0.title) }, selection: m.styleTab) { m.styleTab = $0 }
            HStack(spacing: 6) {
                Text("Used in").font(.system(size: 12.5)).foregroundStyle(Theme.muted2)
                ForEach(m.styleTab.appList, id: \.self) { app in
                    Text(app).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.card)).overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(WritingStyle.allCases) { styleCard($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "About you")
                Text("A few lines about your work and the words you use. It helps WhisperFirst guess names and tone.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.leading, 4)
                AboutEditor(m: m.settings.aboutMe)
            }
            .padding(.top, 6)
        }
    }

    private func styleCard(_ s: WritingStyle) -> some View {
        let on = m.styles[m.styleTab] == s
        return Button { m.setStyle(s, for: m.styleTab) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title + (s == .formal ? "." : "")).font(Theme.rounded(20, .semibold))
                        Text(s.subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    ZStack {
                        if on {
                            Circle().fill(Theme.accent)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Circle().strokeBorder(Color(hex: 0xD6CCC0), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                Text("PREVIEW").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.faint).padding(.top, 12)
                Text(s.example)
                    .font(.system(size: 13)).lineSpacing(5).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
                    .padding(14)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous).fill(Theme.windowBg))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wfCard(18)
            .wfOutline(18, on ? Theme.accent : Color(hex: 0xEFE9E1), on ? 2 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// ช่อง "About you" — บันทึกอัตโนมัติขณะพิมพ์
private struct AboutEditor: View {
    @ObservedObject var m: TextFileModel
    var body: some View {
        TextEditor(text: $m.text)
            .font(.system(size: 14)).lineSpacing(4)
            .scrollContentBackground(.hidden).scrollIndicators(.hidden)
            .padding(12).frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .wfOutline(16)
            .onAppear { m.load() }
            .onChange(of: m.text) { _ in m.save() }
    }
}

// MARK: - Help · How it works

struct HelpPage: View {
    @ObservedObject var m: HubModel

    private struct Step { let n: Int; let title: String; let detail: String; let icon: String; let bg: UInt32; let fg: UInt32 }

    var body: some View {
        let ptt = m.settings.shortcuts.combos(.pushToTalk).first
        let pttText = ptt.map { Keys2.sorted($0).map(Keys2.label).joined(separator: " ") } ?? "the key"
        let steps = [
            Step(n: 1, title: "Hold the key", detail: "\(pttText) — in any app, wherever your cursor is", icon: "keyboard", bg: 0xFBEADB, fg: 0xC8641F),
            Step(n: 2, title: "Just talk", detail: "Thai, English or both. Pauses and “umm”s are fine.", icon: "mic", bg: 0xFDE7EA, fg: 0xD9475A),
            Step(n: 3, title: "It gets tidied", detail: "Fillers removed, slips fixed, your tone kept", icon: "pencil.line", bg: 0xEAE6FB, fg: 0x6A55C8),
            Step(n: 4, title: "Typed for you", detail: "Let go — the text appears in about 2 seconds", icon: "character.cursor.ibeam", bg: 0xE6F4EA, fg: 0x2E8B4E),
        ]
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "How it works", subtitle: "From your voice to finished text in about two seconds.")
            HStack(spacing: 8) {
                ForEach(steps, id: \.n) { s in
                    if s.n > 1 { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    stepTile(s)
                }
            }
            .fixedSize(horizontal: false, vertical: true)   // ทุกช่องสูงเท่ากันตามเนื้อหา ไม่ยืด
            .padding(16).wfCard()
            beforeAfter
            FlowLayout(spacing: 8) {
                ForEach(["Removes เอ่อ / อ่า / แบบว่า", "Keeps only your correction", "Keeps ครับ / ค่ะ / นะ",
                         "English words stay in English", "Numbers and dates as digits", "Spoken lists become bullet points"], id: \.self) { c in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.successText)
                        Text(c).font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.card)).overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Keys to remember")
                    keysCard(ptt)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "The island")
                    islandCard
                }
                .frame(width: 300)   // ≈ 1.2 : 1 กับการ์ดปุ่มลัดที่ความกว้างหน้าต่างปกติ
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepTile(_ s: Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: s.icon).font(.system(size: 15)).foregroundStyle(Color(hex: s.fg))
                    .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: s.bg)))
                Spacer()
                Text("STEP \(s.n)").font(.system(size: 11.5, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.faint)
            }
            Text(s.title).font(.system(size: 14, weight: .semibold)).padding(.top, 4)
            Text(s.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.tile))
    }

    private var beforeAfter: some View {
        let said: [(String, Bool)] = [("เอ่อ", true), ("พรุ่งนี้ประชุมตอน", false), ("10 โมง เอ้ย ไม่ใช่", true),
                                      ("10 โมงครึ่ง แล้วก็", false), ("แบบว่า", true), ("ฝากเตรียม สไลด์ ด้วยนะครับ", false)]
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("WHAT YOU SAID").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.faint)
                FlowLayout(spacing: 5) {
                    ForEach(Array(said.enumerated()), id: \.offset) { _, part in
                        if part.1 {
                            Text(part.0).font(.system(size: 14)).strikethrough().foregroundStyle(Color(hex: 0xB8AEA2))
                                .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                        } else {
                            Text(part.0).font(.system(size: 14)).foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).wfCard()
            Image(systemName: "arrow.right").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 10) {
                Text("WHAT GETS TYPED").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.accentText)
                Text("พรุ่งนี้ประชุมตอน 10 โมงครึ่ง แล้วก็ฝากเตรียม slide ด้วยนะครับ").font(.system(size: 14)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).wfCard()
            .wfOutline(16, Color(hex: 0xF0C9A8), 1.5)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func keysCard(_ ptt: KeyCombo?) -> some View {
        let sc = m.settings.shortcuts
        let rows: [(AnyView, String, String)] = [
            (AnyView(Keycaps(combo: ptt)), "Push to talk", "Hold, speak, let go"),
            (AnyView(HStack(spacing: 4) { Keycap(text: "2×"); Keycaps(combo: ptt) }), "Hands-free", "Double-tap to start, tap again to finish"),
            (AnyView(Keycap(text: "⇧")), "Command mode", "Press while talking to edit selected text"),
            (AnyView(Keycap(text: "Esc")), "Cancel", "While talking or waiting"),
            (AnyView(Keycaps(combo: sc.combos(.addWord).first)), "Teach a word", "Select it in any app, then press"),
            (AnyView(Keycaps(combo: sc.combos(.pasteLast).first)), "Paste again", "Your most recent text"),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(alignment: .center, spacing: 12) {
                    r.0.frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.1).font(.system(size: 13.5, weight: .semibold))
                        Text(r.2).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .wfCard()
    }

    private var islandCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The black bar at the top of your screen shows what's happening — listening, polishing, done. Hover it for a reminder, click it to start hands-free.")
                .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.9)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                legend(0xFF3B30, "Red dot — listening")
                legend(0xFF9F0A, "Orange — command mode")
                legend(0x30D158, "Green check — typed in")
            }
            Spacer(minLength: 12)
            Button { m.onDemo() } label: {
                Label("Play demo", systemImage: "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.helpDark))
    }

    private func legend(_ hex: UInt32, _ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: hex)).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
        }
    }
}
