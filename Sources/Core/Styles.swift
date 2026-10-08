import Foundation

/// สไตล์การเขียนแยกตามประเภทแอป (แบบ Wispr Flow) — ปรับแค่การจัดรูปแบบ/เครื่องหมาย ไม่เปลี่ยนคำที่พูด
enum StyleCategory: String, CaseIterable, Identifiable, Codable {
    case personal, work, email, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Other"
        }
    }

    var apps: String {
        switch self {
        case .personal: "LINE, Messenger, WhatsApp, Messages, Telegram, Discord"
        case .work: "Slack, Microsoft Teams"
        case .email: "Mail, Outlook"
        case .other: "All other apps — notes, docs, Terminal, Claude, ChatGPT…"
        }
    }

    static let bundles: [StyleCategory: Set<String>] = [
        .personal: ["jp.naver.line.mac", "com.facebook.archon", "net.whatsapp.WhatsApp", "com.apple.MobileSMS",
                    "ru.keepcoder.Telegram", "com.hnc.Discord"],
        .work: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams"],
        .email: ["com.apple.mail", "com.microsoft.Outlook"],
    ]

    static func of(bundleID: String) -> StyleCategory {
        for (c, ids) in bundles where ids.contains(bundleID) { return c }
        return .other
    }

    var defaultStyle: WritingStyle {
        switch self {
        case .personal: .casual
        case .work, .other: .normal
        case .email: .formal
        }
    }
}

enum WritingStyle: String, CaseIterable, Identifiable, Codable {
    case formal, normal, casual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: "Formal"
        case .normal: "Casual"
        case .casual: "Very casual"
        }
    }

    var subtitle: String {
        switch self {
        case .formal: "Full punctuation + paragraphs"
        case .normal: "Light punctuation"
        case .casual: "Chat style, no punctuation"
        }
    }

    /// ตัวอย่างประโยคเดียวกัน จัดรูปแบบต่างกัน (คำไม่เปลี่ยน)
    var example: String {
        switch self {
        case .formal: "สวัสดีครับพี่\n\nพรุ่งนี้สะดวกคุยเรื่อง Dashboard ตอน 10 โมงไหมครับ?\nเดี๋ยวผมส่ง Slide ให้ก่อนนะครับ"
        case .normal: "สวัสดีครับพี่ พรุ่งนี้สะดวกคุยเรื่อง dashboard ตอน 10 โมงไหมครับ? เดี๋ยวผมส่ง slide ให้ก่อนนะครับ"
        case .casual: "สวัสดีครับพี่ พรุ่งนี้สะดวกคุยเรื่อง dashboard ตอน 10 โมงไหมครับ เดี๋ยวผมส่ง slide ให้ก่อนนะครับ"
        }
    }

    var promptHint: String {
        switch self {
        case .formal: "ทางการ — ใส่เครื่องหมายวรรคตอนครบ (? ! ท้ายคำถาม/อุทาน) แบ่งย่อหน้าตามความหมาย คำอังกฤษขึ้นต้นตัวพิมพ์ใหญ่เมื่อเป็นชื่อเรียก"
        case .normal: "ปกติ — เว้นวรรคแบบไทยตามปกติ ใส่เครื่องหมายเท่าที่จำเป็น"
        case .casual: "สบายๆ แบบแชท — ไม่ใส่ ? หรือ ! ไม่แบ่งย่อหน้า คำอังกฤษตัวพิมพ์เล็กได้ (ยกเว้นชื่อเฉพาะในพจนานุกรม)"
        }
    }
}

extension Config {
    func style(for c: StyleCategory) -> WritingStyle {
        styles[c.rawValue].flatMap(WritingStyle.init(rawValue:)) ?? c.defaultStyle
    }
}
