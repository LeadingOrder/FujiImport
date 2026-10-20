#!/usr/bin/env bash
# Generate disposable private CA + api.frame.io leaf certificate; run from FujiImport root.
set -euo pipefail
cd "$(dirname "$0")/.."
certdir='poc/mac/certs'
mkdir -p "$certdir"
if [[ -e "$certdir/ca.key" || -e "$certdir/server.key" ]]; then
    echo 'Certificates already exist; refusing to rotate keys. Move/remove them deliberately to regenerate.' >&2
    exit 1
fi
umask 077
cat > "$certdir/ca.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca
[dn]
CN = Fuji Import Disposable Test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
cat > "$certdir/server.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
subjectAltName = DNS:api.frame.io
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl genrsa -out "$certdir/ca.key" 2048
openssl req -new -x509 -sha256 -days 30 -key "$certdir/ca.key" -out "$certdir/ca.crt" -config "$certdir/ca.cnf" -extensions v3_ca
openssl genrsa -out "$certdir/server.key" 2048
openssl req -new -sha256 -key "$certdir/server.key" -out "$certdir/server.csr" -subj '/CN=api.frame.io'
openssl x509 -req -sha256 -days 30 -in "$certdir/server.csr" -CA "$certdir/ca.crt" -CAkey "$certdir/ca.key" -set_serial 1 -extfile "$certdir/server.ext" -out "$certdir/server.crt"
cp "$certdir/ca.crt" "$certdir/ca.pem"
chmod 600 "$certdir"/*.key
printf '\nGenerated: %s/ca.crt (PUBLIC certificate to import into camera)\n' "$certdir"
printf 'Do NOT copy ca.key or server.key to the camera, share them, or commit them.\n'
openssl x509 -in "$certdir/server.crt" -noout -subject -issuer -ext subjectAltName
