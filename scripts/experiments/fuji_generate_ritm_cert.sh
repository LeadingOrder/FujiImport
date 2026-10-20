!/usr/bin/env bash
# Generate a NEW Fuji/RITM-style dual-purpose, self-signed TLS/trust certificate.
# Run from the FujiImport repository root. Never overwrites the known-good cert.
set -euo pipefail

ROOT="$(pwd)"
if [ ! -d "$ROOT/poc/mac/certs" ]; then
    echo "ERROR: run from the FujiImport repository root (poc/mac/certs missing)" >&2
    exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$ROOT/poc/mac/certs/ritm-repro-$STAMP"
mkdir -m 700 "$DEST"

cat >"$DEST/openssl.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = dn
x509_extensions = ritm

[dn]
CN = api.frame.io

[ritm]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = DNS:api.frame.io
subjectKeyIdentifier = hash
CONFIG

umask 077
openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
    -days 30 \
    -keyout "$DEST/server.key" \
    -out "$DEST/server.crt" \
    -config "$DEST/openssl.cnf" \
    -extensions ritm

openssl verify -CAfile "$DEST/server.crt" -purpose sslserver "$DEST/server.crt"

echo
echo "Created RITM-style cert/key in: $DEST"
openssl x509 -in "$DEST/server.crt" -noout -subject -issuer -dates -fingerprint -sha256
openssl x509 -in "$DEST/server.crt" -noout -text | grep -A3 -E 'Basic Constraints|Key Usage|Extended Key Usage|Subject Alternative Name|Subject Key Identifier'
echo
echo "CAUTION: This is a NEW cryptographic identity. You must import THIS server.crt into the camera before using it."
echo "Do not replace the working ritm-test/server.crt or server.key."
