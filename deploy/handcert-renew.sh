#!/bin/sh
# ต่ออายุ cert ที่ตั้งเองนอก DB ของ NPM (NPM ต่ออายุเฉพาะ npm-<id>) — ทุก cert ใน /etc/letsencrypt/renewal ที่ไม่ใช่ npm-*
# certbot ต่อเมื่อเหลือ < 30 วันเท่านั้น · ต่อสำเร็จ → reload nginx ของ NPM · ล้ม/ใกล้หมด (< 14 วัน) → แจ้ง Telegram
# cron: 23 4 * * * ~/bin/handcert-renew.sh >> ~/logs/handcert-renew.log 2>&1   (ติดตั้ง 9 ต.ค. 2026 — WhisperFirst audit B3)
set -u
C=proxy-npm-1
echo "== $(date -u +%FT%TZ)"
names=$(docker exec $C sh -c "ls /etc/letsencrypt/renewal/ | grep -v ^npm- | grep \\.conf\$ | sed s/\\.conf\$//")
fail=""; renewed=0
docker exec $C rm -f /tmp/handcert-renewed
for n in $names; do
  if docker exec $C certbot renew --cert-name "$n" --no-random-sleep-on-renew --deploy-hook "touch /tmp/handcert-renewed" >/tmp/handcert-$n.log 2>&1; then
    echo "ok $n"
  else
    echo "FAIL $n"; tail -5 /tmp/handcert-$n.log; fail="$fail $n"
  fi
done
if docker exec $C test -f /tmp/handcert-renewed; then
  docker exec $C nginx -t >/dev/null 2>&1 && docker exec $C nginx -s reload && renewed=1 && echo "reloaded nginx"
fi
soon=""
for n in $names; do
  end=$(docker exec $C openssl x509 -enddate -noout -in /etc/letsencrypt/live/$n/fullchain.pem 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || continue
  left=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  [ "$left" -lt 14 ] && soon="$soon $n(${left}d)"
done
if [ -n "$fail$soon" ]; then
  ~/bin/tg-notify.sh "⚠️ Hostinger cert: ต่ออายุไม่สำเร็จ:${fail:- -} · ใกล้หมด (<14 วัน):${soon:- -} · log ~/logs/handcert-renew.log"
fi
[ "$renewed" = 1 ] && echo "renewed + reloaded"
exit 0
