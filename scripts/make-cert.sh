#!/bin/bash
# Создаёт локальный самоподписанный сертификат для подписи «Мнемозины».
# Зачем: с ad-hoc подписью macOS сбрасывает разрешения (микрофон, звук приложений)
# после каждой пересборки. Со стабильным сертификатом разрешения сохраняются.
# Сертификат живёт только в связке ключей login, наружу не уходит.
set -euo pipefail

NAME="Mnemosyne Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Сертификат «${NAME}» уже есть"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:mnemosyne

security import "$TMP/id.p12" -k "$KEYCHAIN" -P mnemosyne -T /usr/bin/codesign >/dev/null
echo "Сертификат «${NAME}» создан"
