# WhisperFirst — พิมพ์ด้วยเสียงภาษาไทยแบบ Wispr Flow

กดค้างปุ่ม **⌥ Option ขวา** → พูด → ปล่อย → ข้อความไทยที่เกลาแล้วถูกวางลงแอปที่ใช้อยู่ (~2–2.5 วิ)

## ทำไมเข้าใจภาษาไทยกว่า
- **Gemini ฟังเสียงเองแล้วเขียนออกมาในครั้งเดียว** (ไม่ผ่าน transcript ดิบ) → ใช้บริบททั้งประโยคตัดสินคำกำกวม
- prompt ภาษาไทย ([prompts/dictate.md](prompts/dictate.md)): ตัด เอ่อ/อ่า/แบบว่า · พูดผิดแล้วแก้ ("เอ้ย ไม่ใช่") เก็บแค่ฉบับแก้ · คง ครับ/ค่ะ/นะ/อ่ะ · ศัพท์อังกฤษเขียนเป็นอังกฤษ (ไม่ถอดเป็น "ด็อกเกอร์") · เว้นวรรคแบบไทย · ตัวเลข/เงิน/วันที่เป็นเลขอารบิก แต่เวลาคงแบบพูด ("บ่าย 2 โมง") · ไล่ข้อ → รายการ · ไม่ตอบคำถามที่พูด
- **พจนานุกรมส่วนตัว** (seed ชื่อโปรเจกต์จาก Vault แล้ว) + **เกี่ยวกับฉัน** + **ข้อความก่อนเคอร์เซอร์** เป็นบริบท
- ปรับสไตล์ตามแอป (Terminal/Claude = prompt, LINE/Slack = แชท, Mail = อีเมล) — แก้ได้ใน `config.json` → `appHints`

## การใช้
| ทำ | ผล |
|---|---|
| กดค้าง ⌥ขวา แล้วพูด | ปล่อยแล้ววาง |
| แตะ ⌥ขวา 2 ครั้งเร็วๆ | แฮนด์ฟรี (แตะอีกครั้งเพื่อจบ) |
| กด ⇧ ระหว่างพูด | โหมดคำสั่ง: เลือกข้อความแล้วพูด "แปลเป็นอังกฤษ" / "ทำให้สุภาพขึ้น" → แทนที่ |
| Esc | ยกเลิก |
| ⌃⌥V | วางข้อความล่าสุดอีกครั้ง |
| ⌃⌥D | เพิ่มคำที่เลือกอยู่ลงพจนานุกรม |

เปลี่ยนปุ่ม/คีย์/พจนานุกรม/ดูประวัติ: เมนู ⌁ → ตั้งค่า

### ปุ่มลัด (แท็บ "ปุ่มลัด" — แบบ Wispr Flow)
แต่ละ action ตั้งได้หลายชุด · ✎ = อัดใหม่ (กดปุ่มค้างไว้ ปล่อยเมื่อครบ, Esc = ยกเลิก) · 🗑 ลบ · + เพิ่ม · คืนค่าเริ่มต้น
- action: กดค้างเพื่อพูด · โหมดแฮนด์ฟรี (แตะ 2 ครั้ง หรือปุ่มเฉพาะ) · โหมดคำสั่ง · กด Enter · วางข้อความล่าสุด · เพิ่มคำลงพจนานุกรม
- ชุด = modifier (fn ⌃ ⌥ ⌘ ⇧ — ถ้ากดเดี่ยวจะระบุข้าง) + ปุ่มคีย์บอร์ด + ปุ่มเมาส์ (กลาง/4/5)
- ฟังผ่าน CGEventTap → กลืนปุ่มที่เป็นส่วนของปุ่มลัด (fn+b ไม่พิมพ์ "b") · ชุดเล็กที่ซ้อนในชุดใหญ่ (fn กับ fn+b) ยิงตอนปล่อย
- กันตั้งผิด: ปุ่มตัวอักษรเดี่ยว, ⇧+ตัวอักษร, modifier ซ้ายเดี่ยว, ชุดซ้ำกับ action อื่น
- ใช้ fn: System Settings → Keyboard → "กดปุ่ม 🌐 เพื่อ" = ไม่ทำอะไร · ถ้าตั้งชุดเดียวกับ Wispr Flow ให้ปิด Wispr ก่อน (จะทำงานทั้งคู่)

## หน้าต่างหลัก
เมนู ⌁ → "เปิด WhisperFirst…" (หรือเปิดแอปซ้ำ/คลิก Dock) — แถบซ้าย: หน้าหลัก (สถิติ · วิธีใช้ · เล่นตัวอย่าง Dynamic Island · ล่าสุด) · ประวัติ (ค้นหา แบ่งวัน คัดลอก) · พจนานุกรม (ชิป ลบได้ / เรียนรู้อัตโนมัติ / แก้แบบข้อความ) · Snippets (วลีลัด) · ปุ่มลัด · สไตล์การเขียน · ตั้งค่า · `wf render-hub prefix` เรนเดอร์เป็นภาพ

## Dynamic Island
เกาะสีดำห้อยจากขอบบนกลางจอ (จอมีรอยบาก = กลืนกับรอยบาก) หรือขอบล่างแบบ Wispr — ยืดหดด้วย spring ตามสถานะ
- ว่าง: เกาะเล็ก · ชี้เมาส์ = บอกปุ่มที่ใช้ · คลิก = เริ่มพูดแบบแฮนด์ฟรี
- พูด: ไอคอนแอปที่ข้อความจะไปวาง + คลื่นเสียง + เวลา + ป้าย คำสั่ง/แฮนด์ฟรี + **คำที่พูดสดๆ** (gemini-3.5-transcribe-live, แสดงเท่านั้น) · แฮนด์ฟรีมีปุ่ม ✕ / ✓
- เกลา: ข้อความสดวิบวับ · เสร็จ: ✓ + ข้อความที่วาง · error: ปุ่ม "ลองใหม่" · เรียนรู้คำ: ปุ่ม "เลิกจำ"
- เมาส์ทะลุได้ทุกที่ยกเว้นบนตัวเกาะ · ไม่แย่งโฟกัสจากแอปที่พิมพ์อยู่ · ตั้งค่า: ทั่วไป → Dynamic Island
- `wf render-island out.png` เรนเดอร์ทุกสถานะ · `wf live file.wav` ทดสอบคำสด
- คำสด: ส่วนที่นิ่งแล้วสีขาว ส่วนที่ Live ยังเดาอยู่สีจาง · ช่วงที่ไม่ใช่อักษรไทย/อังกฤษ (ไมค์เบา → Live เดาเป็นฮินดี/พม่า) ไม่โชว์ · แก้คำตามพจนานุกรม (`=>`/`~>`) พร้อมเว้นวรรคแบบไทย · ตัดเสียง Tink 0.3 วิแรกออกจากเสียงที่ส่ง Live

## ลดเสียงรบกวน (ค่าเริ่มต้น)
voice processing ของ macOS (ลดเสียงรบกวน + ตัดเสียงสะท้อน + AGC) — ไมค์เบา/มีเสียงรบกวนดีขึ้นมาก (วัดจริง: เสียงพูด 0.03 → 0.3, เสียงรบกวน 0.012 → 0.004) · แอปอื่นเบาลงเล็กน้อยระหว่างพูด (ducking ระดับต่ำสุด)
- เปิด voice processing ใช้ ~0.9 วิ → เตรียม engine ไว้ตั้งแต่เปิดแอป (ไมค์ยังไม่เปิด) แล้วใช้ซ้ำ กดแล้วอัดได้ใน ~0.1 วิ · เปลี่ยนไมค์ → เตรียมใหม่เอง
- ปิดได้ที่ Settings → General → Reduce background noise · วัดเวลาเปิดไมค์: `open -n -W --stdout out.txt ~/Applications/WhisperFirst.app --args --mic-bench`

## ทางเร็ว: เกลาจากข้อความ Live (ค่าเริ่มต้น)
ประโยคสั้น (≤15 วิ, Live ถอดเป็นช่วงเดียว, ข้อความยาวสมเหตุสมผล) → ใช้ข้อความฉบับสุดท้ายของ Live (มาถึง ~0.3 วิหลังจบ) เกลาด้วยข้อความล้วน (`prompts/dictate-text.md`) · ไม่เข้าเงื่อนไข/Live ล่ม → ส่งเสียงให้ Gemini ฟังเอง
- พูดยาวส่งเสียงเสมอ: ทดสอบเสียง 36 วิ Live ข้ามเนื้อหาทั้งประโยคได้
- เสียงเบาถูกขยายก่อนส่ง (สูงสุด 8 เท่า) · ตั้งค่า → ความเร็ว/ความแม่น เลือก "แม่นสุด" ได้

## (ปิดแล้ว) เกลาล่วงหน้า (speculative)
ปิดถาวร: ไมค์เบาทำให้ตัวจับเสียงคิดว่าเงียบ แล้วใช้ผลล่วงหน้าที่มีแค่ช่วงแรก → ข้อความท้ายๆ หาย
Wispr Flow เร็วเพราะส่งเสียงไปประมวลผลระหว่างพูด — Gemini Live API ยังตอบเป็นข้อความเกลาแล้วไม่ได้ (Live รุ่นที่ฉลาดตอบเป็นเสียงเท่านั้น, `gemini-3.5-transcribe-live` ได้แค่ transcript ดิบที่พลาดชื่อเฉพาะ) จึงใช้วิธีนี้แทน:
- ระหว่างพูด ถ้าเงียบ ≥0.3 วิ → ส่งเสียงที่อัดไว้ไปเกลาล่วงหน้าด้วยโมเดลหลัก (เว้นระยะ ≥1.5 วิ, สูงสุด 4 ครั้ง/รอบ)
- ปล่อยปุ่ม: ถ้าไม่ได้พูดอะไรเพิ่มหลังรอบล่วงหน้า → แข่งระหว่างผลล่วงหน้า vs โมเดลสำรองที่ยิงตอนปล่อย (รอโมเดลหลักเพิ่ม ≤0.5 วิ) · ถ้าพูดต่อ → ส่งเสียงเต็มใหม่
- ความแม่นเท่าเดิม (Gemini ฟังเสียงครบทุกครั้ง) · วัดจริง: หลังปล่อยปุ่ม **2.08 วิ vs 2.64 วิ** (ปล่อยหลังพูดจบ 0.6 วิ)
- เจอ 429 (quota) → งดยิงล่วงหน้า/คู่ขนาน 60 วิอัตโนมัติ

## Snippets (วลีลัด)
พูดคำเรียกสั้นๆ → พิมพ์ข้อความเต็มที่บันทึกไว้ (อีเมล ลิงก์ ที่อยู่ ลายเซ็น) · ตั้งในหน้า Snippets · เก็บที่ `snippets.json` (สิทธิ์ 600)
- ขยายในเครื่องหลังโมเดลถอดเสร็จ — **เนื้อหาไม่ถูกส่งไปที่โมเดล** ส่งแค่คำเรียกให้โมเดลเขียนตรงตัว
- พูดคำเรียกอย่างเดียว (+ ครับ/ค่ะ/นะ) → ได้ข้อความเต็มอย่างเดียว · แทรกกลางประโยคได้ ("ส่งไปที่อีเมลงานนะ" → "ส่งไปที่ me@work.com นะ") เว้นวรรครอบให้แบบไทย
- ไม่สนช่องว่าง/ตัวพิมพ์เล็กใหญ่ · คำเรียกอังกฤษต้องตรงทั้งคำ · คำเรียกยาวก่อนสั้น · ไม่ใช้ในโหมดคำสั่ง

## เรียนรู้คำจากการแก้ไข
วางแล้ว → อ่านช่องพิมพ์ซ้ำทุก 1.5 วิ (Accessibility, นอก main thread) → ผู้ใช้แก้แล้วนิ่ง 6 วิ (ข้ามถ้าลบทั้งช่อง/เขียนใหม่เกินครึ่ง) / เริ่มพูดรอบใหม่ → diff แบบตัดคำไทย (CFStringTokenizer) → Gemini ตัดสินว่า "ฟังผิด/สะกดไม่ตรงใจ" (ออกเสียงคล้ายกัน หรือคำเดียวกันสะกดต่าง) หรือ "เปลี่ยนใจ" (ต้องออกเสียงคล้ายกันจริง · คำต้องมาจากสิ่งที่แก้จริง ≤40 ตัว) → ถ้าใช่ เพิ่มลงพจนานุกรมใต้หัวข้อ "เรียนรู้อัตโนมัติ" เป็น `ได้ยิน ~> คำที่ถูก` (คำใบ้ให้โมเดล ไม่แทนที่ตรงตัว) + toast "📘 จำคำใหม่" · เมนูมี "↶ ลืมคำที่เพิ่งเรียนรู้"
- ทดสอบ: จำ NokNok/สมชัย/GitHub/เช็ก/DeepSeek · ไม่จำ พุธ→ศุกร์, ทีม→ลูกค้า, 10→11 โมง, การพิมพ์ต่อท้าย
- แอป Electron (Slack/VS Code/Discord) เปิด AXManualAccessibility ให้อัตโนมัติ · ช่องรหัสผ่านไม่อ่าน

## เครื่องยนต์
`gemini-3.1-flash-lite` (หลัก แม่นสุด) + `gemini-3.5-flash-lite` แข่งกันพร้อมกัน — ตัวหลักได้สิทธิ์รอเพิ่ม 1 วิ (Gemini มีช่วงค้าง 8–30 วิเป็นพักๆ ยิงตัวเดียวเสี่ยง) · ล่มหมด → ElevenLabs Scribe v2 + ตัดคำเติมเอง
ผลทดสอบ 8 ประโยค (`bench/`): flash-lite one-shot ~98% / 2.1 วิ · ElevenLabs+Gemini 2 ขั้น 4–5 วิ · Whisper large-v3 ในเครื่อง 12–23 วิ และสะกดชื่อผิด

## ไฟล์
- โค้ด: `Sources/Core/*` (ลิงก์ static เข้าตัวแอป) · `Sources/Launcher` (จุดเข้า) — ทั้งแอปเป็นไฟล์เดียว ไม่โหลด dylib จากภายนอก
- การ sign: `./build.sh` sign ด้วยใบรับรอง self-signed ในเครื่อง "WhisperFirst Local Signing" (สร้างให้อัตโนมัติครั้งแรกผ่าน `scripts/make-signing-cert.sh`) + hardened runtime (`WhisperFirst.entitlements` = ไมค์อย่างเดียว) → macOS ผูกสิทธิ์ไมค์/Accessibility กับใบรับรอง: build ใหม่ไม่ต้องให้สิทธิ์ซ้ำ · แอปที่ถูกแก้หรือ sign ด้วยอย่างอื่นไม่ได้สิทธิ์ · DYLD injection ถูกบล็อก
- ย้ายมาจากเวอร์ชัน dylib เดิม: ต้องให้สิทธิ์ Accessibility ใหม่ 1 ครั้ง (ลบรายการเก่าใน System Settings → เปิดแอป → เปิดสวิตช์)
- ข้อมูล: `~/Library/Application Support/WhisperFirst/` → `.env` (API keys), `config.json`, `dictionary.txt`, `snippets.json`, `about-me.md`, `prompts/`, `history.jsonl`
- log: `~/Library/Logs/WhisperFirst/whisperfirst.log` (อ่านได้เฉพาะผู้ใช้ · หมุนไฟล์ที่ 2 MB · ไม่บันทึกข้อความที่พูด)

## ความเป็นส่วนตัว
- ประวัติ (`history.jsonl`) และไฟล์ key/config/พจนานุกรม เขียนแบบ atomic สิทธิ์ 600 · ปิดการเก็บประวัติ / เก็บ 7 วัน / 30 วัน / ตลอด / ล้างทั้งหมด ได้ใน Settings → Privacy
- ไม่อ่านบริบทก่อนเคอร์เซอร์ในเทอร์มินัลและโปรแกรมจัดการรหัสผ่าน · ช่องรหัสผ่าน (Secure Input) → คัดลอกลง clipboard แทนการวาง
- เปลี่ยนแอประหว่างพูด → คัดลอกลง clipboard แทนการวางผิดที่ · ไม่แตะ clipboard ที่เป็นข้อมูลลับ (concealed)
- ElevenLabs key ใน `~/.config` ใช้เฉพาะเมื่อเปิด "Use ElevenLabs key from ~/.config" ใน Settings → Advanced

## Build / ทดสอบ
```bash
./build.sh                                   # build + ติดตั้ง ~/Applications/WhisperFirst.app + เปิด
.build/release/wf transcribe bench/samples/vocab.wav   # ทดสอบ engine จากไฟล์เสียง
.build/release/wf stream bench/samples/vocab.wav --gap 0.6 [--nospec]   # จำลองพูดตามเวลาจริง วัดเวลาหลังปล่อยปุ่ม
.build/release/wf learn "ข้อความที่วาง" "ข้อความหลังแก้"   # ทดสอบ diff + การตัดสินคำ
.build/release/wf learn-e2e                   # ทั้งวงจรกับ TextEdit เบื้องหลัง (ต้องมีสิทธิ์ Accessibility)
.build/release/wf shortcuts-test              # ป้อน key event จำลองเข้า engine ปุ่มลัด (21 กรณี)
.build/release/wf snippets-test               # ทดสอบการขยายวลีลัด (10 กรณี ไม่แตะไฟล์ของผู้ใช้)
.build/release/wf render-shortcuts out.png    # เรนเดอร์หน้าปุ่มลัดเป็นภาพ
python3 bench/run.py gemini:gemini-3.1-flash-lite elevenlabs   # เทียบเครื่องยนต์ (ต้องมี GEMINI_API_KEY)
```
แก้ prompt ที่ `prompts/*.md` แล้ว `./build.sh` (ติดตั้งทับใน Application Support)

## For designers — UI map
Native SwiftUI + AppKit, built with Command Line Tools only (no Xcode). **SwiftUI macros are unavailable** → never use `@State`/`@Observable`; keep view state in `ObservableObject` models with `@Published`. `@StateObject` works (used for per-row hover via `HoverState`).

| Surface | File | Notes |
|---|---|---|
| Snippets page + expansion logic | `Sources/Core/Snippets.swift` | Same card/row patterns as Dictionary. |
| Main window shell, Home, History, design tokens (`Theme`) | `Sources/Core/MainWindow.swift` | Handoff Round 3 tokens (cream, accent `#D9732F`, rounded type). Always light mode. Hidden scrollbars + fades. |
| Dictionary · Writing style · Help pages | `Sources/Core/HubPages.swift` | `FlowLayout`, `Segmented`, `RawEditor` helpers |
| Dynamic Island (top-center overlay) | `Sources/Core/Overlay.swift` | `OverlayModel.Phase` = idle/hover/listening/thinking/done/message/error/learned; sizes in `OverlayModel.size`; spring morph. |
| Shortcuts editor | `Sources/Core/ShortcutsView.swift` | Wispr-style cards, ✎ record / 🗑 / + |
| Settings page (check-up, switches, Advanced) | `Sources/Core/Settings.swift` (`SettingsPage`) | `CheckupModel` in MainWindow.swift |
| Menu bar | `Sources/Core/App.swift` (`menuNeedsUpdate`) | |
| Writing styles data | `Sources/Core/Styles.swift` | Category × Formal/Casual/Very casual, examples |

Preview without opening windows (renders PNGs; native controls like ScrollView/TextField show as placeholders):
```bash
swift build -c release
.build/release/wf render-hub /tmp/hub            # hub pages
.build/release/wf render-island /tmp/island.png  # every island state
.build/release/wf render-shortcuts /tmp/sc.png
./build.sh                                       # install + relaunch the real app
```
Prompts (`prompts/*.md`) are intentionally Thai — they drive the Thai output quality; UI strings are English.
