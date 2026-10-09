#!/bin/zsh
# build WhisperFirst → ~/Applications/WhisperFirst.app (โค้ดทั้งหมดในไฟล์เดียว) + prompts ใน Application Support
# - sign ด้วยใบรับรองในเครื่อง "WhisperFirst Local Signing" + hardened runtime
#   → macOS ผูกสิทธิ์ไมค์/Accessibility กับใบรับรอง: build ใหม่ไม่ต้องให้สิทธิ์ซ้ำ และแอปที่ถูกแก้/sign ด้วยอย่างอื่นจะไม่ได้สิทธิ์
# - ไม่มีใบรับรอง → สร้างให้อัตโนมัติ (scripts/make-signing-cert.sh) · ใช้ใบอื่น: WF_SIGN_ID="ชื่อ" ./build.sh
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/WhisperFirst.app"
SUPPORT="$HOME/Library/Application Support/WhisperFirst"
SIGN_ID="${WF_SIGN_ID:-WhisperFirst Local Signing}"

security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 || ./scripts/make-signing-cert.sh "$SIGN_ID"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 1) prompts → Application Support · ลบ dylib รุ่นเก่า (เคยโหลดจากที่นี่ — ตอนนี้ไม่ใช้แล้ว)
mkdir -p "$SUPPORT/prompts"
cp prompts/*.md "$SUPPORT/prompts/"
rm -f "$SUPPORT/libWhisperFirstCore.dylib" "$SUPPORT/.libWhisperFirstCore.new"

# 2) ไฟล์ของผู้ใช้ — สร้างครั้งแรกเท่านั้น ไม่ทับของเดิม
[[ -f "$SUPPORT/dictionary.txt" ]] || cp defaults/dictionary.txt "$SUPPORT/dictionary.txt"
[[ -f "$SUPPORT/about-me.md" ]] || cp defaults/about-me.md "$SUPPORT/about-me.md"
# API key: ใส่ในแอป (Settings → Models & API keys) หรือ export GEMINI_API_KEY ก่อนรัน build ครั้งแรก
if [[ ! -f "$SUPPORT/.env" ]]; then
  umask 077   # ไฟล์ key ไม่เคยถูกเปิดให้คนอื่นอ่าน แม้ชั่วขณะก่อน chmod
  print -r -- "# WhisperFirst API keys (readable by this user only)" > "$SUPPORT/.env"
  [[ -n "${GEMINI_API_KEY:-}" ]] && print -r -- "GEMINI_API_KEY=$GEMINI_API_KEY" >> "$SUPPORT/.env"
  chmod 600 "$SUPPORT/.env"
fi

# 3) ตัวแอป — ประกอบในที่ชั่วคราว sign + ตรวจ แล้วค่อยสลับเข้าที่ (ล้มกลางทางไม่ทำแอปเดิมเสีย)
# โลโก้ (7b "Echo") อยู่ใน Resources/ — AppIcon.icns + ไอคอน menu bar (template PNG)
NEW="$HOME/Applications/.WhisperFirst.new.app"
rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$BIN_DIR/WhisperFirst" "$NEW/Contents/MacOS/WhisperFirst"
cp Info.plist "$NEW/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarIconTemplate.png Resources/MenuBarIconTemplate@2x.png "$NEW/Contents/Resources/"
# prompts + ไฟล์เริ่มต้นในตัวแอป — เครื่องที่ติดตั้งจาก DMG ใช้ตอนเปิดครั้งแรก (Paths.seedFromBundle)
mkdir -p "$NEW/Contents/Resources/prompts" "$NEW/Contents/Resources/defaults"
cp prompts/*.md "$NEW/Contents/Resources/prompts/"
cp defaults/* "$NEW/Contents/Resources/defaults/"
codesign --force --sign "$SIGN_ID" --identifier com.kron.whisperfirst --options runtime \
  --entitlements WhisperFirst.entitlements --timestamp=none "$NEW"
codesign --verify --strict "$NEW"
rm -rf "$APP"
mv "$NEW" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# 4) รีสตาร์ทแอปให้ใช้โค้ดใหม่
if pgrep -x WhisperFirst >/dev/null; then
  osascript -e 'tell application id "com.kron.whisperfirst" to quit' 2>/dev/null || pkill -x WhisperFirst
  for i in {1..10}; do pgrep -x WhisperFirst >/dev/null || break; sleep 0.5; done
fi
[[ "${NO_OPEN:-}" == 1 ]] || open "$APP"
echo "✅ WhisperFirst อัปเดตแล้ว"
