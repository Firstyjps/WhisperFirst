#!/bin/zsh
# ทำ DMG สำหรับแจกเพื่อน → dist/WhisperFirst.dmg (ไม่แตะแอปที่ติดตั้งอยู่ในเครื่อง)
# - sign ด้วยใบรับรองเดียวกับ build.sh → อัปเดตแล้วเพื่อนไม่ต้องให้สิทธิ์ไมค์/Accessibility ใหม่
# - prompts + defaults อยู่ใน Contents/Resources (แอปวางลง Application Support เองตอนเปิด)
# ใช้: ./scripts/release.sh [เวอร์ชัน]   (ไม่ใส่ = ใช้ CFBundleShortVersionString ใน Info.plist)
set -euo pipefail
cd "${0:A:h}/.."
SIGN_ID="${WF_SIGN_ID:-WhisperFirst Local Signing}"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
# ใบรับรองต้องเป็นใบเดิม (DR ของแอปที่แจกไปผูกกับ hash นี้) — ใบใหม่ = เพื่อนทุกคนต้องให้สิทธิ์ไมค์/Accessibility ใหม่
CERT_SHA1="F271BE8DF5B3C437BF921A70F93BD093EDB4C0E1"
GOT=$(security find-certificate -c "$SIGN_ID" -Z 2>/dev/null | awk '/SHA-1/{print $NF}')
[[ "$GOT" == "$CERT_SHA1" ]] || { echo "❌ ใบรับรอง $SIGN_ID ไม่ใช่ใบเดิม (ได้ ${GOT:-ไม่พบ}) — กู้จาก .p12 ที่สำรองไว้ก่อน (ดู README)"; exit 1; }
# DMG ต้องตรงกับโค้ดที่ commit แล้ว (repo สาธารณะ) · ทดสอบเองได้ด้วย WF_ALLOW_DIRTY=1
if [[ -n "$(git status --porcelain -- Sources Package.swift Info.plist WhisperFirst.entitlements prompts defaults Resources)" && "${WF_ALLOW_DIRTY:-}" != 1 ]]; then
  echo "❌ มีไฟล์ที่ยังไม่ commit — commit ก่อน (หรือ WF_ALLOW_DIRTY=1 สำหรับ build ทดสอบ)"; git status --short -- Sources Package.swift Info.plist; exit 1
fi
SHA=$(git rev-parse --short HEAD)$([[ -n "$(git status --porcelain -- Sources)" ]] && echo "-dirty")

swift build -c release --product WhisperFirst
BIN_DIR="$(swift build -c release --show-bin-path)"

DIST=dist; STAGE="$DIST/stage"; APP="$STAGE/WhisperFirst.app"
rm -rf "$STAGE" "$DIST/WhisperFirst.dmg"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/prompts" "$APP/Contents/Resources/defaults"
cp "$BIN_DIR/WhisperFirst" "$APP/Contents/MacOS/WhisperFirst"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :WFGitCommit string $SHA" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarIconTemplate.png Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"
cp prompts/*.md "$APP/Contents/Resources/prompts/"
cp defaults/* "$APP/Contents/Resources/defaults/"
codesign --force --sign "$SIGN_ID" --identifier com.kron.whisperfirst --options runtime \
  --entitlements WhisperFirst.entitlements --timestamp=none "$APP"
codesign --verify --strict "$APP"

ln -s /Applications "$STAGE/Applications"   # ลากแอปลงตรงนี้
hdiutil create -volname "WhisperFirst" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DIST/WhisperFirst.dmg" >/dev/null
rm -rf "$STAGE"
SIZE=$(du -h "$DIST/WhisperFirst.dmg" | cut -f1 | tr -d ' ')
echo "✅ $DIST/WhisperFirst.dmg · v$VERSION · $SIZE · $(lipo -archs "$BIN_DIR/WhisperFirst") · commit $SHA"
echo "   sha256 $(shasum -a 256 "$DIST/WhisperFirst.dmg" | cut -d' ' -f1)   ← ใส่ใน RELEASE ของ docs/assets/main.js"
