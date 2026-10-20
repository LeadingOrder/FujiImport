#!/usr/bin/env bash
# Execute from the FujiImport repository root on the Mac:
#     bash deploy_fuji_pi.sh [lukas@192.168.1.155]
# Copies the ACTUAL WORKING Mac files; no generated/replacement certs.
set -Eeuo pipefail

PI="${1:-lukas@192.168.1.155}"
DEST="fuji-import-poc"

for item in poc/mac/receiver.py poc/mac/dns_lab.py \
    poc/mac/certs/server.crt poc/mac/certs/server.key run_fuji_pi.sh; do
    [[ -f "$item" ]] || {
        echo "Missing: $item (run from FujiImport repo root)" >&2
        exit 1
    }
done

printf 'Copying working receiver, DNS script, trusted TLS cert/key and Pi launcher to %s\n' "$PI"
ssh "$PI" "umask 077; mkdir -p ~/$DEST/certs ~/$DEST/output; chmod 700 ~/$DEST ~/$DEST/certs"
scp \
    poc/mac/receiver.py \
    poc/mac/dns_lab.py \
    run_fuji_pi.sh \
    "$PI:$DEST/"
scp \
    poc/mac/certs/server.crt \
    poc/mac/certs/server.key \
    "$PI:$DEST/certs/"
ssh "$PI" "chmod 700 ~/$DEST/run_fuji_pi.sh; chmod 600 ~/$DEST/certs/server.key; chmod 644 ~/$DEST/certs/server.crt"
printf '\nFiles copied. Now run:\n'
printf 'ssh %s\n' "$PI"
printf 'cd ~/%s && ./run_fuji_pi.sh\n' "$DEST"
