#!/bin/zsh
# build WhisperFirst → libWhisperFirstCore.dylib (โค้ดจริง) + WhisperFirst.app (ตัวเปิด)
# - dylib + prompts ไปที่ ~/Library/Application Support/WhisperFirst/ ทุกครั้ง
# - WhisperFirst.app ติดตั้งใหม่เฉพาะเมื่อ Launcher/Info.plist/ไอคอนเปลี่ยน → ปกติ build ใหม่ไม่ต้องให้สิทธิ์ซ้ำ
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/WhisperFirst.app"
SUPPORT="$HOME/Library/Application Support/WhisperFirst"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 1) โค้ดจริง → แทนที่แบบ atomic
mkdir -p "$SUPPORT/prompts"
cp "$BIN_DIR/libWhisperFirstCore.dylib" "$SUPPORT/.libWhisperFirstCore.new"
codesign --force --sign - "$SUPPORT/.libWhisperFirstCore.new" 2>/dev/null
mv -f "$SUPPORT/.libWhisperFirstCore.new" "$SUPPORT/libWhisperFirstCore.dylib"
cp prompts/*.md "$SUPPORT/prompts/"

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

# 3) ตัวแอป — เฉพาะเมื่อเปลี่ยน
ICON="$BIN_DIR/icon-1024.png"
[[ -f "$ICON" ]] || swift scripts/make-icon.swift "$ICON"
STAMP=$(cat "$BIN_DIR/WhisperFirst" Info.plist scripts/make-icon.swift | shasum -a 256 | cut -c1-16)
if [[ "$(cat "$APP/Contents/Resources/.stamp" 2>/dev/null)" != "$STAMP" ]]; then
  echo "⚠️  ตัวแอปเปลี่ยน → ติดตั้งใหม่ (อาจต้องให้สิทธิ์ไมค์/Accessibility อีกครั้ง)"
  pkill -x WhisperFirst 2>/dev/null || true
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/WhisperFirst" "$APP/Contents/MacOS/WhisperFirst"
  cp Info.plist "$APP/Contents/Info.plist"
  ICONSET="$(mktemp -d)/WhisperFirst.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/WhisperFirst.icns"
  echo "$STAMP" > "$APP/Contents/Resources/.stamp"
  codesign --force --sign - --identifier com.kron.whisperfirst "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

# 4) รีสตาร์ทแอปให้ใช้โค้ดใหม่
if pgrep -x WhisperFirst >/dev/null; then
  osascript -e 'tell application id "com.kron.whisperfirst" to quit' 2>/dev/null || pkill -x WhisperFirst
  for i in {1..10}; do pgrep -x WhisperFirst >/dev/null || break; sleep 0.5; done
fi
[[ "${NO_OPEN:-}" == 1 ]] || open "$APP"
echo "✅ WhisperFirst อัปเดตแล้ว"
