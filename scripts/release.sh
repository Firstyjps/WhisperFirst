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
SHA=$(git rev-parse --short HEAD)
[[ -z "$(git status --porcelain -- Sources)" ]] || SHA="$SHA-dirty"

swift build -c release --product WhisperFirst
BIN_DIR="$(swift build -c release --show-bin-path)"

DIST=dist; STAGE="$DIST/stage"; APP="$STAGE/WhisperFirst.app"
OUT="$DIST/WhisperFirst-$VERSION.dmg"
rm -rf "$STAGE" "$OUT.tmp.dmg"   # DMG เดิม (ตัวที่แจกอยู่) ยังไม่ลบ จนกว่าตัวใหม่จะผ่านการตรวจ
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
hdiutil create -volname "WhisperFirst" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT.tmp.dmg" >/dev/null
rm -rf "$STAGE"

# ตรวจของที่อยู่ใน DMG จริง (ไม่ใช่แค่ที่ประกอบไว้): signature · เวอร์ชัน · macOS ขั้นต่ำ · prompts
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$OUT.tmp.dmg" >/dev/null
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT
A="$MNT/WhisperFirst.app"
codesign --verify --strict --deep "$A" || { echo "❌ signature ใน DMG ไม่ผ่าน"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$A/Contents/Info.plist")" == "$VERSION" ]] || { echo "❌ เวอร์ชันใน DMG ไม่ตรง"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$A/Contents/Info.plist")" == "14.2" ]] || { echo "❌ LSMinimumSystemVersion ไม่ใช่ 14.2"; exit 1; }
ls "$A/Contents/Resources/prompts/"*.md >/dev/null 2>&1 || { echo "❌ ไม่มี prompts ใน DMG"; exit 1; }
hdiutil detach "$MNT" >/dev/null; trap - EXIT

mv -f "$OUT.tmp.dmg" "$OUT"
cp -f "$OUT" "$DIST/WhisperFirst.dmg"   # ชื่อคงที่ที่ deploy.sh / หน้าเว็บใช้
SUM=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
echo "$SUM  WhisperFirst-$VERSION.dmg" > "$OUT.sha256"
SIZE=$(du -h "$OUT" | cut -f1 | tr -d ' ')
echo "✅ $OUT (+ $DIST/WhisperFirst.dmg) · v$VERSION · $SIZE · $(lipo -archs "$BIN_DIR/WhisperFirst") · commit $SHA"
echo "   sha256 $SUM   ← ใส่ใน RELEASE ของ docs/assets/main.js (เก็บไว้ใน $OUT.sha256 ด้วย)"
