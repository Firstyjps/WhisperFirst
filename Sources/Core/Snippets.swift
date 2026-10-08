import SwiftUI

/// วลีลัด: พูดคำเรียกสั้นๆ → พิมพ์ข้อความเต็มที่บันทึกไว้ (อีเมล ลิงก์ ที่อยู่ ลายเซ็น)
/// ขยายในเครื่องหลังโมเดลถอดเสร็จ — เนื้อหาไม่ถูกส่งไปที่โมเดล ส่งแค่คำเรียกให้โมเดลเขียนตรงตัว
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

enum Snippets {
    static func all() -> [Snippet] {
        guard let d = try? Data(contentsOf: Paths.snippets) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: d)) ?? []
    }

    static func save(_ list: [Snippet]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(list) else { return }
        Files.writeSecure(d, to: Paths.snippets)
    }

    /// ใส่ใน prompt: ให้โมเดลเขียนคำเรียกตรงตัว (ไม่ส่งเนื้อหา)
    static func promptText(_ list: [Snippet] = all()) -> String? {
        let t = list.map(\.trigger).filter { !$0.isEmpty }
        guard !t.isEmpty else { return nil }
        return "- วลีลัดของผู้ใช้ ถ้าได้ยินให้เขียนตรงตัวตามนี้ ห้ามแก้/ห้ามขยายความ: " + t.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static let particles = ["ครับ", "คับ", "ค่ะ", "คะ", "นะ", "น่ะ", "จ้า", "จ้ะ", "เลย", "ด้วย", "หน่อย"]

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// ไม่สนช่องว่างระหว่างตัวอักษร ("อีเมล ฉัน" = "อีเมลฉัน") · ตัวพิมพ์เล็กใหญ่ · คำอังกฤษต้องตรงทั้งคำ
    static func regex(for trigger: String) -> NSRegularExpression? {
        let chars = trigger.filter { !$0.isWhitespace }
        guard let first = chars.first, let last = chars.last else { return nil }
        var p = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\u200B]*")
        if isLatin(first) { p = "(?<![A-Za-z0-9])" + p }
        if isLatin(last) { p += "(?![A-Za-z0-9])" }
        return try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// คืนข้อความที่ขยายแล้ว + คำเรียกที่ถูกใช้
    static func expand(_ text: String, with list: [Snippet] = all()) -> (text: String, used: [String]) {
        let items = list.filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty && !$0.text.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }   // คำเรียกยาวก่อน (กันคำสั้นไปกินส่วนหนึ่งของคำยาว)
        guard !items.isEmpty else { return (text, []) }

        // พูดคำเรียกอย่างเดียว (+ คำลงท้าย/เครื่องหมาย) → ใส่ข้อความเต็มอย่างเดียว
        for s in items {
            guard let re = regex(for: s.trigger) else { continue }
            let ns = text as NSString
            let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard ms.count == 1 else { continue }
            var rest = ns.replacingCharacters(in: ms[0].range, with: "")
            rest = String(rest.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) })
            for p in particles { rest = rest.replacingOccurrences(of: p, with: "") }
            if rest.isEmpty { return (s.text, [s.trigger]) }
        }

        // แทรกกลางประโยค — ใช้ตัวแทนชั่วคราวก่อน กันข้อความที่ใส่แล้วไปตรงกับคำเรียกอื่น
        var out = text
        var used: [String] = []
        for (i, s) in items.enumerated() {
            guard let re = regex(for: s.trigger) else { continue }
            let ns = out as NSString
            guard re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: "\u{E000}\(i)\u{E001}"))
            used.append(s.trigger)
        }
        guard !used.isEmpty else { return (text, []) }
        for (i, s) in items.enumerated() {
            let token = "\u{E000}\(i)\u{E001}"
            while let r = out.range(of: token) {
                var v = s.text
                // เว้นวรรครอบข้อความที่ใส่ ถ้าติดตัวอักษร (แบบไทย: เว้นรอบคำอังกฤษ/ตัวเลข)
                if r.lowerBound > out.startIndex, let c = out[..<r.lowerBound].last, !c.isWhitespace, c != "(" { v = " " + v }
                if r.upperBound < out.endIndex, let c = out[r.upperBound...].first, !c.isWhitespace, !c.isPunctuation || c == "(" { v += " " }
                out.replaceSubrange(r, with: v)
            }
        }
        return (out, used)
    }
}

// MARK: - หน้า Snippets

@MainActor
final class SnippetsModel: ObservableObject {
    @Published var items: [Snippet] = []
    @Published var trigger = ""
    @Published var text = ""
    @Published var editing: UUID?
    @Published var justAdded: UUID?

    func load() { items = Snippets.all() }

    var problem: String? {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if t.contains("\n") { return "Keep the phrase on one line" }
        if t.filter({ !$0.isWhitespace }).count < 3 { return "Use a longer phrase so it doesn't fire by accident" }
        if t.count > 40 { return "Keep the phrase under 40 characters" }
        let key = t.lowercased().filter { !$0.isWhitespace }
        if items.contains(where: { $0.id != editing && $0.trigger.lowercased().filter { !$0.isWhitespace } == key }) {
            return "You already have a snippet with this phrase"
        }
        return nil
    }

    var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem == nil
    }

    func submit() {
        guard canSave else { return }
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .newlines)
        load()
        if let id = editing, let i = items.firstIndex(where: { $0.id == id }) {
            items[i].trigger = t; items[i].text = body
        } else {
            let s = Snippet(trigger: t, text: body)
            items.insert(s, at: 0)
            flash(s.id)
        }
        Snippets.save(items)
        cancel()
    }

    func edit(_ s: Snippet) { editing = s.id; trigger = s.trigger; text = s.text }

    func cancel() { editing = nil; trigger = ""; text = "" }

    func remove(_ s: Snippet) {
        load()
        items.removeAll { $0.id == s.id }
        Snippets.save(items)
        if editing == s.id { cancel() }
    }

    private func flash(_ id: UUID) {
        justAdded = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.justAdded == id { self.justAdded = nil } }
    }
}

struct SnippetsPage: View {
    @ObservedObject var m: SnippetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Snippets",
                      subtitle: "Say a short phrase, get the full text — your email, a meeting link, an address. Expanded on your Mac; the text itself is never sent to the model.")
            editor
            if m.items.isEmpty { examples } else { list }
        }
        .onAppear { m.load() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("When I say").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 84, alignment: .leading)
                TextField("e.g. my work email", text: $m.trigger)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip))
                    .accessibilityLabel("Snippet phrase")
            }
            HStack(alignment: .top, spacing: 10) {
                Text("Type this").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 84, alignment: .leading).padding(.top, 9)
                TextEditor(text: $m.text)
                    .font(.system(size: 14)).lineSpacing(3)
                    .scrollContentBackground(.hidden).scrollIndicators(.hidden)
                    .padding(.horizontal, 7).padding(.vertical, 7).frame(height: 84)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip))
                    .accessibilityLabel("Snippet text")
            }
            HStack(spacing: 10) {
                if let p = m.problem {
                    Label(p, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.accentText)
                } else {
                    Text("Tip: pick a phrase you wouldn't say by accident — 2+ words works best")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted2)
                }
                Spacer()
                if m.editing != nil { Button("Cancel") { m.cancel() }.buttonStyle(PillButtonStyle()) }
                Button(m.editing == nil ? "Add snippet" : "Save") { m.submit() }
                    .buttonStyle(PrimaryButtonStyle(enabled: m.canSave)).disabled(!m.canSave)
            }
        }
        .padding(18).wfCard(18)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Your snippets", note: "\(m.items.count)")
            VStack(spacing: 0) {
                ForEach(Array(m.items.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12) }
                    SnippetRow(s: s, highlight: m.justAdded == s.id || m.editing == s.id,
                               onEdit: { m.edit(s) }, onDelete: { m.remove(s) })
                }
            }
            .padding(6).wfCard()
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Ideas", note: "Nothing saved yet")
            VStack(alignment: .leading, spacing: 8) {
                ForEach([("อีเมลงาน", "you@company.com"), ("ลิงก์นัดประชุม", "https://meet.example.com/your-room"),
                         ("ลงท้ายอีเมล", "ขอบคุณครับ\nชื่อ นามสกุล\nตำแหน่ง · เบอร์โทร")], id: \.0) { t, v in
                    HStack(alignment: .top, spacing: 10) {
                        Text("“\(t)”").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 130, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.top, 3)
                        Text(v).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).wfCard()
        }
    }
}

private struct SnippetRow: View {
    let s: Snippet
    let highlight: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "text.insert").font(.system(size: 13)).foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30).background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text("“\(s.trigger)”").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(s.text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button("Edit", action: onEdit).buttonStyle(PillButtonStyle())
                Button("Delete", action: onDelete).buttonStyle(PillButtonStyle())
            }
            .opacity(hover.on || highlight ? 1 : 0.001)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(highlight ? Theme.accentSoft.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Snippet \(s.trigger)")
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
        .animation(.easeOut(duration: 0.3), value: highlight)
    }
}
