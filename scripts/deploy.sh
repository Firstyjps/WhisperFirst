#!/bin/zsh
# อัปเว็บ (docs/) + DMG ขึ้น whisperfirst.kronkasem.com — ดู deploy/README.md
# - ตรวจว่า sha256 ใน RELEASE (docs/assets/main.js) ตรงกับ dist/WhisperFirst.dmg ก่อน
# - อัปลง releases/<stamp>/ ทั้งชุด ตรวจ sha256 บน server แล้วค่อยสลับ current (ไม่มีช่วงที่เว็บใหม่ชี้ DMG เก่า)
# - เก็บ release ล่าสุดไว้ 3 ชุด (ย้อนกลับได้)
set -euo pipefail
cd "${0:A:h}/.."
DMG=dist/WhisperFirst.dmg
[[ -f $DMG ]] || { echo "❌ ไม่มี $DMG — รัน ./scripts/release.sh ก่อน"; exit 1; }
LOCAL=$(shasum -a 256 $DMG | cut -d' ' -f1)
grep -q "sha256: '$LOCAL'" docs/assets/main.js || { echo "❌ sha256 ใน docs/assets/main.js ไม่ตรงกับ $DMG ($LOCAL)"; exit 1; }
REL=$(date +%Y%m%d-%H%M%S)
ssh hostinger "mkdir -p ~/projects/whisperfirst/releases/$REL/download"
rsync -a --exclude .nojekyll docs/ hostinger:projects/whisperfirst/releases/$REL/
rsync -a $DMG hostinger:projects/whisperfirst/releases/$REL/download/WhisperFirst.dmg
REMOTE=$(ssh hostinger "shasum -a 256 ~/projects/whisperfirst/releases/$REL/download/WhisperFirst.dmg | cut -d' ' -f1")
[[ "$REMOTE" == "$LOCAL" ]] || { echo "❌ sha256 บน server ไม่ตรง — ไม่สลับ"; exit 1; }
ssh hostinger "cd ~/projects/whisperfirst && ln -sfn releases/$REL current && ls -1d releases/* | sort | head -n -3 | xargs -r rm -rf"
LIVE=$(curl -s https://whisperfirst.kronkasem.com/download/WhisperFirst.dmg | shasum -a 256 | cut -d' ' -f1)
[[ "$LIVE" == "$LOCAL" ]] && echo "✅ live: releases/$REL · DMG sha256 $LOCAL" || { echo "❌ DMG บนเว็บไม่ตรง ($LIVE)"; exit 1; }
