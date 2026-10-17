# Deploy — whisperfirst.kronkasem.com (Hostinger VPS, `ssh hostinger`)

- container `whisperfirst` สร้างด้วย `run-container.sh` (nginx:1.28-alpine pin ด้วย digest · read-only rootfs · cap-drop ALL · pids/RAM จำกัด · healthcheck · network `proxy-net`)
  mount: `nginx.conf` → `/etc/nginx/conf.d/default.conf` · `headers.conf` → `/etc/nginx/wf-headers.conf` · `site/` → `/srv/site` (ro) — container ไม่เห็นไฟล์อื่นในโฟลเดอร์โปรเจกต์
- `~/projects/whisperfirst/{nginx.conf, headers.conf, run-container.sh, site/releases/<stamp>, site/current → releases/<stamp>}` · DMG อยู่ที่ `site/current/download/WhisperFirst.dmg`
- Nginx Proxy Manager (`proxy-npm-1`): hand conf `/data/nginx/proxy_host/whisperfirst.kronkasem.com.conf` = `whisperfirst-https.conf` (ไม่อยู่ใน DB ของ NPM · ไม่ใช้ block-exploits เพราะกัน download manager)
- TLS: Let's Encrypt webroot · NPM ไม่ต่ออายุ cert ที่ตั้งเอง → `~/bin/handcert-renew.sh` (= `handcert-renew.sh` ที่นี่) รันทุกวัน 04:23 จาก crontab ของ deploy
- ปล่อยเวอร์ชันใหม่: `./scripts/release.sh X.Y.Z` → แก้ `RELEASE` ใน `docs/assets/main.js` (version/size/sha256) → `./scripts/deploy.sh`
- แก้แค่หน้าเว็บ (DMG เดิม): `./scripts/deploy.sh` ได้เลย (ตรวจ sha256 ของ DMG ใน dist/ กับ RELEASE ให้ตรงก่อน)
- ย้อนเวอร์ชัน: `ssh hostinger 'cd ~/projects/whisperfirst/site && ls releases && ln -sfn releases/<stamp> current.new && mv -Tf current.new current'`
- อัปเดต nginx: `docker pull nginx:1.28-alpine` → ใส่ digest ใหม่ใน `run-container.sh` → copy ขึ้น server → `sh ~/projects/whisperfirst/run-container.sh`
- เก็บ release ล่าสุด 3 ชุด (deploy.sh ลบที่เก่ากว่าเอง)
