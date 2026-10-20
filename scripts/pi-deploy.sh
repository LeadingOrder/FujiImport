#!/usr/bin/env bash
# Deploy FujiImport Mac PoC receiver + the EXACT camera-trusted RITM TLS identity.
# Execute from the Git repository root on the Mac: bash scripts/pi-deploy.sh
set -Eeuo pipefail

PI="${1:-lukas@192.168.1.155}"
TARGET='fuji-import-poc'
CERT='poc/mac/certs/ritm-test/server.crt'
KEY='poc/mac/certs/ritm-test/server.key'
PIN='9C:F0:A4:39:33:2E:2E:A0:B6:ED:A4:7A:98:FF:21:17:4F:BF:08:04:1F:B5:AC:B3:7A:5C:31:39:17:B9:84:5D'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
for file in poc/mac/receiver.py scripts/pi-install.sh "$CERT" "$KEY"; do
    [[ -f "$file" ]] || fail "Missing $file. Run from FujiImport root and place the deployment scripts under scripts/."
done
fingerprint="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)"
[[ "$fingerprint" == "$PIN" ]] || fail "Unexpected cert: $fingerprint; expected KNOWN-WORKING $PIN"
openssl x509 -in "$CERT" -checkend 0 -noout >/dev/null || fail 'Trusted cert expired (expires 2026-11-19). Renew/test a replacement before deploying.'
cert_pub="$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
key_pub="$(openssl pkey -in "$KEY" -pubout -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
[[ "$cert_pub" == "$key_pub" ]] || fail 'RITM server.crt and server.key do not match'
python3 -m py_compile poc/mac/receiver.py

echo "Deploying known-good certificate ($fingerprint) and repository receiver to $PI"
# On Pi, target exists from previous experiments. Retain existing output / SQLite.
ssh "$PI" "umask 077; mkdir -p ~/$TARGET/certs; chmod 700 ~/$TARGET ~/$TARGET/certs"
scp poc/mac/receiver.py "$PI:$TARGET/receiver.py"
scp scripts/pi-install.sh "$PI:$TARGET/pi-install.sh"
scp "$CERT" "$PI:$TARGET/certs/server.crt"
scp "$KEY" "$PI:$TARGET/certs/server.key"
ssh "$PI" "chmod 700 ~/$TARGET/pi-install.sh; chmod 600 ~/$TARGET/certs/server.key; chmod 644 ~/$TARGET/certs/server.crt"

echo
printf 'Files copied. Configuring the Pi (sudo may prompt for password)...\n'
ssh -t "$PI" "cd ~/$TARGET && ./pi-install.sh install"
