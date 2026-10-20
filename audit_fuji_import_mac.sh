#!/usr/bin/env bash
# Non-destructive diagnostic audit for the Mac FI-02 prototype.
# Run from FujiImport repository root: bash audit_fuji_import_mac.sh
# Optional MAC_IP override: bash audit_fuji_import_mac.sh 192.168.1.203
set -u

MAC_IP="${1:-192.168.1.203}"
CERT_DIR='poc/mac/certs'

if [[ ! -f poc/mac/receiver.py || ! -f poc/mac/tls_frontend.py || ! -f poc/mac/dns_lab.py ]]; then
    echo 'ERROR: Run from FujiImport repository root. FI-02 Python files not found.' >&2
    exit 1
fi

section() { printf '\n========== %s ==========\n' "$1"; }
info() { printf '%s\n' "$*"; }

section 'Network interface and address'
info "Expected Mac IPv4: $MAC_IP"
route -n get default 2>/dev/null | grep -E 'gateway:|interface:' || true
ifconfig | grep -B 3 -A 1 "inet $MAC_IP " || true

section 'FI-02-related Python processes'
for name in receiver.py tls_frontend.py dns_lab.py; do
    info "-- $name --"
    pgrep -fl "poc/mac/${name}" || info 'Not found by name'
done

section 'Listening ports (requires read-only sudo lsof)'
sudo -v || exit 1
info '-- TCP 443 --'
sudo lsof -nP -iTCP:443 -sTCP:LISTEN || true
info '-- TCP 8765 --'
sudo lsof -nP -iTCP:8765 -sTCP:LISTEN || true
info '-- UDP 53 --'
sudo lsof -nP -iUDP:53 || true
info '-- TCP 53 --'
sudo lsof -nP -iTCP:53 -sTCP:LISTEN || true

section 'Number of unique listener processes'
for port in 443 8765; do
    count=$(sudo lsof -nP -iTCP:$port -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')
    info "TCP $port listener process count: $count (expected 1)"
done
for proto in UDP TCP; do
    if [[ "$proto" = UDP ]]; then
        count=$(sudo lsof -nP -iUDP:53 -t 2>/dev/null | sort -u | wc -l | tr -d ' ')
    else
        count=$(sudo lsof -nP -iTCP:53 -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')
    fi
    info "$proto 53 process count: $count (expected 1, same DNS PID for both)"
done

section 'CA and leaf certificates on disk'
for fname in ca.crt ca.pem server.crt server.key; do
    if [[ -f "$CERT_DIR/$fname" ]]; then
        info "Present: $CERT_DIR/$fname"
    else
        info "MISSING: $CERT_DIR/$fname"
    fi
done
if [[ -f "$CERT_DIR/ca.crt" ]]; then
    info '-- Root CA --'
    openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject -issuer -dates -fingerprint -sha256
    openssl x509 -in "$CERT_DIR/ca.crt" -noout -text | grep -A 3 'X509v3 Basic Constraints' | head -4
fi
if [[ -f "$CERT_DIR/server.crt" ]]; then
    info '-- Server certificate --'
    openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -issuer -dates -fingerprint -sha256 -ext subjectAltName
fi
if [[ -f "$CERT_DIR/ca.crt" && -f "$CERT_DIR/ca.pem" ]]; then
    if cmp -s "$CERT_DIR/ca.crt" "$CERT_DIR/ca.pem"; then
        info 'OK: ca.pem and ca.crt are identical.'
    else
        info 'WARNING: ca.pem and ca.crt differ! Camera may have received a different CA.'
    fi
fi
if [[ -f "$CERT_DIR/ca.crt" && -f "$CERT_DIR/server.crt" ]]; then
    info '-- Check server cert is signed by local CA --'
    openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt" || true
fi
if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
    cert_pub=$(openssl x509 -in "$CERT_DIR/server.crt" -pubkey -noout 2>/dev/null | openssl dgst -sha256)
    key_pub=$(openssl rsa -in "$CERT_DIR/server.key" -pubout 2>/dev/null | openssl dgst -sha256)
    if [[ "$cert_pub" = "$key_pub" ]]; then
        info 'OK: server.crt and server.key match.'
    else
        info 'WARNING: server.crt and server.key DO NOT MATCH.'
    fi
fi

section 'Certificate actually presented by the HTTPS listener'
if [[ -f "$CERT_DIR/server.crt" ]]; then
    expected=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
    actual=$(openssl s_client -connect "${MAC_IP}:443" -servername api.frame.io -showcerts </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
    info "On disk:   ${expected:-UNAVAILABLE}"
    info "Live TLS:  ${actual:-UNAVAILABLE}"
    if [[ -n "$actual" && "$actual" = "$expected" ]]; then
        info 'OK: HTTPS listener presents exactly the configured server certificate.'
    else
        info 'WARNING: Live certificate differs or TLS listener cannot be contacted.'
    fi
fi

section 'HTTP backend health'
curl -sS --max-time 5 --noproxy '*' -w '\nHTTP %{http_code}\n' 'http://127.0.0.1:8765/health' || true

section 'HTTPS full-chain health (validating against custom CA)'
if [[ -f "$CERT_DIR/ca.crt" ]]; then
    curl -sS --max-time 8 --noproxy '*' --cacert "$CERT_DIR/ca.crt" \
        --resolve "api.frame.io:443:$MAC_IP" \
        -w '\nHTTP %{http_code}\n' 'https://api.frame.io/health' || true
fi

section 'DNS checks (UDP and TCP)'
if command -v dig >/dev/null 2>&1; then
    info '-- UDP A record --'
    dig +time=2 +tries=1 "@$MAC_IP" api.frame.io A +short
    info '-- TCP A record --'
    dig +time=2 +tries=1 +tcp "@$MAC_IP" api.frame.io A +short
    info '-- AAAA should have no address --'
    dig +time=2 +tries=1 "@$MAC_IP" api.frame.io AAAA +short
fi

section 'Done'
info 'The audit changed no process, certificate, DNS or network setting.'
info 'Even if all tests pass, camera trust can still differ from curl trust.'
info 'Do not upload or paste private keys, certificate signing requests, or camera pairing tokens.'
