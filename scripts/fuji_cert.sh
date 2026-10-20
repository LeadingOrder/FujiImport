#!/usr/bin/env bash
# Reproduce the known-working RITM-style X-E5 TLS certificate.
# Run from the FujiImport repository root. Never overwrites old certificates.
set -euo pipefail

BASE="."
[ -d "$BASE" ] || {
    echo "Run this from the FujiImport repository root" >&2
    exit 1
}
umask 077
DIR="$(mktemp -d "$BASE/ritm-new-XXXXXXXX")"

cat >"$DIR/openssl.cnf" <<'CONF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = api.frame.io
[ext]
subjectAltName = DNS:api.frame.io
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 \
    -keyout "$DIR/server.key" -out "$DIR/server.crt" \
    -config "$DIR/openssl.cnf" -extensions ext

openssl verify -purpose sslserver -CAfile "$DIR/server.crt" "$DIR/server.crt"
echo
echo "Created: $DIR"
openssl x509 -in "$DIR/server.crt" -noout -subject -issuer -fingerprint -sha256 -dates
echo
echo "CAMERA: import $DIR/server.crt (Frame.io Root Certificate)"
echo "MAC TLS: use --cert $DIR/server.crt --key $DIR/server.key"
echo "NOTE: This is a new identity; it must be imported into the camera before use."
