#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="ContextRing Local Signing"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -Fq "\"$CERT_NAME\""; then
  echo "Certificate '$CERT_NAME' is already installed in $KEYCHAIN_PATH."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CNF_FILE="$TMP_DIR/cert.cnf"
KEY_FILE="$TMP_DIR/key.pem"
CRT_FILE="$TMP_DIR/cert.pem"
P12_FILE="$TMP_DIR/cert.p12"
P12_PASS="contextring-local-cert"

cat > "$CNF_FILE" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[req_distinguished_name]
CN = $CERT_NAME
O = ContextRing Local

[v3_codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_FILE" \
  -out "$CRT_FILE" \
  -days 3650 \
  -config "$CNF_FILE" \
  >/dev/null 2>&1

openssl pkcs12 -export \
  -legacy \
  -inkey "$KEY_FILE" \
  -in "$CRT_FILE" \
  -out "$P12_FILE" \
  -passout "pass:$P12_PASS" \
  2>/dev/null || \
openssl pkcs12 -export \
  -inkey "$KEY_FILE" \
  -in "$CRT_FILE" \
  -out "$P12_FILE" \
  -passout "pass:$P12_PASS"

echo "Importing '$CERT_NAME' into $KEYCHAIN_PATH..."
security import "$P12_FILE" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign

echo "Trusting '$CERT_NAME' for code signing (macOS may prompt for your login password)..."
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$CRT_FILE"

echo "Done! Re-run ./build.sh to sign ContextRing.app with '$CERT_NAME'."
