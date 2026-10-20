#!/usr/bin/env bash
# FujiImport Pi proof-of-concept installer. Run as lukas from ~/fuji-import-poc.
# Reuses EXISTING dnsmasq; does not change Nextcloud vhosts or require Docker.
set -Eeuo pipefail

ACTION="${1:-install}"
PI_IP="${PI_IP:-192.168.1.155}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
EXPECTED_FINGERPRINT="9C:F0:A4:39:33:2E:2E:A0:B6:ED:A4:7A:98:FF:21:17:4F:BF:08:04:1F:B5:AC:B3:7A:5C:31:39:17:B9:84:5D"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_USER="$(id -un)"
SERVICE="fuji-import-poc-receiver.service"
OLD_DNS_SERVICE="fuji-import-poc-dns.service"
DNSMASQ_CONF="/etc/dnsmasq.d/fuji-import.conf"
VHOST_NAME="zz-fuji-import-poc.conf"
VHOST_FILE="/etc/apache2/sites-available/$VHOST_NAME"
TLS_DIR="/etc/ssl/fuji-import-poc"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
info() { printf '\n==> %s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || fail "Missing command $1"; }

[[ "$EUID" -ne 0 ]] || fail 'Run as the normal Pi user, without sudo. The script invokes sudo where needed.'
[[ "$PI_IP" == '192.168.1.155' ]] || fail 'Unexpected Pi IP. Audit before changing PI_IP.'

case "$ACTION" in
status)
    systemctl --no-pager --full status "$SERVICE" dnsmasq || true
    sudo /usr/sbin/apache2ctl -S
    dig +time=2 +tries=1 @"$PI_IP" api.frame.io +short || true
    exit 0
    ;;
logs)
    exec sudo journalctl -fu "$SERVICE" --output=short-iso
    ;;
stop)
    info 'Stopping the Fuji receiver and disabling ONLY the Fuji Apache site (dnsmasq/Nextcloud remain running)'
    sudo systemctl stop "$SERVICE" || true
    if [[ -e "/etc/apache2/sites-enabled/$VHOST_NAME" ]]; then
        sudo a2dissite "$VHOST_NAME"
        sudo /usr/sbin/apache2ctl configtest
        sudo systemctl reload apache2
    fi
    echo 'Note: the dnsmasq api.frame.io override remains pointed at the Pi. Change it separately if rolling back to the Mac.'
    exit 0
    ;;
install) ;;
*) fail "Usage: $0 [install|status|logs|stop]" ;;
esac

info 'Preflight: receiver, Pi address, existing dnsmasq, camera-trusted certificate'
for tool in python3 openssl curl ip ss sudo dig systemctl; do require "$tool"; done
[[ -x /usr/sbin/apache2ctl ]] || fail 'Apache is missing at /usr/sbin/apache2ctl'
[[ -f "$APP_DIR/receiver.py" ]] || fail "Missing $APP_DIR/receiver.py"
[[ -f "$APP_DIR/certs/server.crt" ]] || fail "Missing $APP_DIR/certs/server.crt"
[[ -f "$APP_DIR/certs/server.key" ]] || fail "Missing $APP_DIR/certs/server.key"
[[ -f "$DNSMASQ_CONF" ]] || fail "Missing existing $DNSMASQ_CONF. This installer will not create or replace your DNS service."
ip -4 -o addr show scope global | grep -Fq "inet $PI_IP/" || fail "Pi IPv4 $PI_IP is not assigned"

if systemctl is-active --quiet "$OLD_DNS_SERVICE"; then
    fail "Obsolete Python DNS service $OLD_DNS_SERVICE is active; stop/disable it first."
fi
systemctl is-active --quiet dnsmasq || fail 'The existing dnsmasq service must be running. Do not run the old Fuji DNS launcher.'

CERT="$APP_DIR/certs/server.crt"
KEY="$APP_DIR/certs/server.key"
actual_fingerprint="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)"
[[ "$actual_fingerprint" == "$EXPECTED_FINGERPRINT" ]] || fail "Wrong TLS certificate fingerprint! Expected $EXPECTED_FINGERPRINT; got $actual_fingerprint. NEVER use v2 or disposable CA certificates here."
openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null || fail 'Known-good RITM certificate has expired. Renew separately and validate on camera.'
cert_key_digest="$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
private_key_digest="$(openssl pkey -in "$KEY" -pubout -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
[[ "$cert_key_digest" == "$private_key_digest" ]] || fail 'server.key does not belong to camera-trusted server.crt'
python3 -m py_compile "$APP_DIR/receiver.py"

# Guard against creating two HTTPS vhosts with the same ServerName.
for enabled in /etc/apache2/sites-enabled/*.conf; do
    [[ -e "$enabled" ]] || continue
    if [[ "$(basename "$enabled")" != "$VHOST_NAME" ]] && grep -Eq '^[[:space:]]*ServerName[[:space:]]+api\.frame\.io([[:space:]]|$)' "$enabled"; then
        fail "Conflicting api.frame.io Apache vhost: $enabled. Review it before installing."
    fi
done
if [[ -f "$VHOST_FILE" ]] && ! grep -Fq '# Managed by Fuji Import Pi PoC' "$VHOST_FILE"; then
    fail "Existing $VHOST_FILE is not our managed file; refusing overwrite."
fi

# Current override must be owned by the earlier experimental deployment.
overrides="$(grep -Ec '^address=/api\.frame\.io/[0-9]+(\.[0-9]+){3}$' "$DNSMASQ_CONF" || true)"
[[ "$overrides" == '1' ]] || fail "Expected exactly one address=/api.frame.io/IPv4 directive in $DNSMASQ_CONF, found $overrides. Review manually."

# Legacy data directory retains earlier device session tokens and test uploads.
if [[ -f "$HOME/fuji-import-test/output/.fuji-import.sqlite3" ]]; then
    OUTPUT_DIR="$HOME/fuji-import-test/output"
else
    OUTPUT_DIR="$APP_DIR/output"
fi
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
info "Receiver files: $OUTPUT_DIR"
printf 'Known-good TLS fingerprint: %s\n' "$actual_fingerprint"

sudo -v

info 'Installing receiver as a loopback-only systemd service'
if ! systemctl is-active --quiet "$SERVICE" && [[ -n "$(ss -H -ltn '( sport = :8765 )')" ]]; then
    fail 'Port 8765 is occupied by a manually started receiver/tunnel. Stop it before installation.'
fi
unit_tmp="$(mktemp)"
vhost_tmp="$(mktemp)"
dns_tmp="$(mktemp)"
trap 'rm -f -- "$unit_tmp" "$vhost_tmp" "$dns_tmp"' EXIT

cat >"$unit_tmp" <<EOF
[Unit]
Description=Fuji Import local Frame.io receiver
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 -u $APP_DIR/receiver.py --bind 127.0.0.1 --port 8765 --output $OUTPUT_DIR
Restart=on-failure
RestartSec=2
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 644 "$unit_tmp" "/etc/systemd/system/$SERVICE"
sudo systemctl daemon-reload
