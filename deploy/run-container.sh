#!/bin/sh
# สร้าง container `whisperfirst` ใหม่ (รันบน server: sh ~/projects/whisperfirst/run-container.sh)
# - image pin ด้วย digest (อัปเดต: docker pull nginx:1.28-alpine → แก้ IMAGE เป็น digest ใหม่ → รันสคริปต์นี้)
# - rootfs อ่านอย่างเดียว · ตัด capability · จำกัด pids/RAM · healthcheck
# - สร้างตัวใหม่ข้างตัวเดิมก่อน ทดสอบผ่านแล้วค่อยสลับชื่อ (NPM หา upstream จากชื่อ container) → เว็บไม่ล่มระหว่างเปลี่ยน
set -eu
IMAGE=nginx@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236   # nginx:1.28-alpine (1.28.3, pull 17 ต.ค. 2026)
P=$HOME/projects/whisperfirst
docker rm -f whisperfirst-new >/dev/null 2>&1 || true
docker run -d --name whisperfirst-new --network proxy-net --restart unless-stopped \
  --memory 64m --pids-limit 100 --read-only \
  --tmpfs /var/cache/nginx --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  --health-cmd 'wget -q -O /dev/null http://127.0.0.1/ || exit 1' --health-interval 30s --health-timeout 5s --health-retries 3 \
  -v "$P/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$P/headers.conf:/etc/nginx/wf-headers.conf:ro" \
  -v "$P/site:/srv/site:ro" \
  "$IMAGE" >/dev/null
sleep 2
docker exec whisperfirst-new wget -q -O /dev/null http://127.0.0.1/ || { echo "❌ ตัวใหม่ไม่ตอบ — ตัวเดิมยังรันอยู่"; docker logs --tail 20 whisperfirst-new; docker rm -f whisperfirst-new; exit 1; }
docker rm -f whisperfirst >/dev/null 2>&1 || true
docker rename whisperfirst-new whisperfirst
echo "✅ whisperfirst ($IMAGE)"
