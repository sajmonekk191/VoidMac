#!/bin/zsh
set -e
NAME="VoidMac Dev"
KC="$HOME/Library/Keychains/voidmac.keychain-db"
PW="voidmac"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  exit 0
fi
TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:x -legacy 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:x
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/cert.p12" -k "$KC" -P x -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC" >/dev/null
rm -rf "$TMP"
echo "Created signing identity '$NAME' in $KC"
