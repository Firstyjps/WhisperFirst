#!/bin/zsh
# สร้างใบรับรอง self-signed สำหรับ sign WhisperFirst.app (ครั้งเดียวต่อเครื่อง)
# macOS ผูกสิทธิ์ไมค์/Accessibility กับใบรับรองนี้ (ไม่ใช่ hash ของไฟล์) → build ใหม่กี่ครั้งก็ไม่ต้องให้สิทธิ์ซ้ำ
# ใบรับรองอยู่ใน login keychain · ไม่ได้ตั้งให้ระบบ "เชื่อถือ" (ไม่จำเป็นสำหรับการ sign ใช้เองในเครื่อง)
set -euo pipefail
NAME="${1:-WhisperFirst Local Signing}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "มีใบรับรอง \"$NAME\" อยู่แล้ว"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# macOS security import อ่าน PKCS#12 แบบใหม่ (AES) ไม่ได้ → ใช้ 3DES/SHA1
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
       -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "✅ สร้างใบรับรอง \"$NAME\" แล้ว"
