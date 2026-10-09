# Deploy — whisperfirst.kronkasem.com (Hostinger VPS, `ssh hostinger`)

- container `whisperfirst` (nginx:1.27-alpine, network `proxy-net`, mem 64m, `--restart unless-stopped`)
  mount `~/projects/whisperfirst/nginx.conf` → `/etc/nginx/conf.d/default.conf` และ `~/projects/whisperfirst` → `/srv/whisperfirst` (ro)
- `~/projects/whisperfirst/{releases/<stamp>, current → releases/<stamp>, nginx.conf, headers.conf}` · DMG อยู่ที่ `current/download/WhisperFirst.dmg`
- Nginx Proxy Manager (`proxy-npm-1`): hand conf `/data/nginx/proxy_host/whisperfirst.kronkasem.com.conf` = `whisperfirst-https.conf` (ไม่อยู่ใน DB ของ NPM)
- TLS: Let's Encrypt webroot · NPM ไม่ต่ออายุ cert ที่ตั้งเอง → `~/bin/handcert-renew.sh` (= `handcert-renew.sh` ที่นี่) รันทุกวัน 04:23 จาก crontab ของ deploy
- ปล่อยเวอร์ชันใหม่: `./scripts/release.sh X.Y.Z` → แก้ `RELEASE` ใน `docs/assets/main.js` (version/size/sha256) → `./scripts/deploy.sh`
- ย้อนเวอร์ชัน: `ssh hostinger 'cd ~/projects/whisperfirst && ls releases && ln -sfn releases/<stamp> current'`
