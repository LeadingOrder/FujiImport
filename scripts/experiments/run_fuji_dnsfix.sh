#!/usr/bin/env bash
# Fuji Import Raspberry Pi proof of concept.
# Run as your normal Pi user: ./run_fuji_pi.sh [start|status|logs|stop]
# Installs a separate LAN-only Apache HTTPS vhost; does not modify Nextcloud's site files.
set -Eeuo pipefail

ACTION="${1:-start}"
PI_IP="${PI_IP:-192.168.1.155}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="$(id -un)"
# Reuse an existing Pi receiver database and uploaded files when available,
# so moving from the earlier SSH-tunnel test doesn't force re-pairing.
if [[ -f "$HOME/fuji-import-test/output/.fuji-import.sqlite3" ]]; then
    OUTPUT_DIR="$HOME/fuji-import-test/output"
else
    OUTPUT_DIR="$APP_DIR/output"
fi
PYTHON="/usr/bin/python3"
RECEIVER_UNIT="fuji-import-poc-receiver.service"
DNS_UNIT="fuji-import-poc-dns.service"
DNSMASQ="/usr/sbin/dnsmasq"
DNS_UPSTREAM="${DNS_UPSTREAM:-192.168.1.1}"
DNS_CONFIG_DIR="/etc/fuji-import-poc"
DNS_CONFIG_FILE="$DNS_CONFIG_DIR/dnsmasq.conf"
VHOST_NAME="zz-fuji-import-poc.conf"
VHOST_FILE="/etc/apache2/sites-available/${VHOST_NAME}"
CERT_DIR="/etc/ssl/fuji-import-poc"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

if [[ "$EUID" -eq 0 ]]; then
    fail "Run as your normal Pi user (e.g. ./run_fuji_pi.sh), not using sudo. The script invokes sudo when needed."
fi

case "$ACTION" in
    start|status|logs|stop) ;;
    *) fail "Usage: $0 [start|status|logs|stop]" ;;
esac

if [[ "$ACTION" == "status" ]]; then
    systemctl --no-pager --full status "$RECEIVER_UNIT" "$DNS_UNIT" || true
    sudo apache2ctl -S
    exit 0
fi

if [[ "$ACTION" == "logs" ]]; then
    exec sudo journalctl -f -u "$RECEIVER_UNIT" -u "$DNS_UNIT" --output=short-iso
fi

if [[ "$ACTION" == "stop" ]]; then
    info "Stopping the Fuji test services (not Nextcloud)"
    sudo systemctl stop "$DNS_UNIT" "$RECEIVER_UNIT" || true
    if [[ -e "/etc/apache2/sites-enabled/$VHOST_NAME" ]]; then
        sudo a2dissite "$VHOST_NAME"
        sudo apache2ctl configtest
        sudo systemctl reload apache2
    fi
    info "Stopped. The Pi's custom DNS will no longer answer until restarted."
    exit 0
fi

info "Validating Pi deployment"
for name in python3 openssl curl ip sudo ss; do need "$name"; done
[[ -x /usr/sbin/apache2ctl ]] || fail "Apache executable missing: /usr/sbin/apache2ctl"
[[ -f "$APP_DIR/receiver.py" ]] || fail "Missing $APP_DIR/receiver.py"
[[ -f "$APP_DIR/certs/server.crt" ]] || fail "Missing $APP_DIR/certs/server.crt"
[[ -f "$APP_DIR/certs/server.key" ]] || fail "Missing $APP_DIR/certs/server.key"
[[ "$PI_IP" =~ ^[0-9.]+$ ]] || fail "PI_IP must be an IPv4 address"
[[ "$DNS_UPSTREAM" =~ ^[0-9.]+$ ]] || fail "DNS_UPSTREAM must be an IPv4 address"
[[ "$DNS_UPSTREAM" != "$PI_IP" ]] || fail "DNS_UPSTREAM must not be the Pi IP (would create a DNS loop)"
ip -4 -o addr show scope global | grep -Fq "inet $PI_IP/" || fail "Pi IP $PI_IP is not assigned to an interface"

# Validate cert and key are a matching pair; preserve the camera-trusted leaf cert.
openssl x509 -in "$APP_DIR/certs/server.crt" -noout -checkend 0 >/dev/null \
    || fail "Camera-trusted server certificate has expired or cannot be read"
cert_pub="$(openssl x509 -in "$APP_DIR/certs/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
key_pub="$(openssl pkey -in "$APP_DIR/certs/server.key" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
[[ "$cert_pub" == "$key_pub" ]] || fail "server.crt and server.key do not match"
python3 -m py_compile "$APP_DIR/receiver.py"
if ! systemctl is-active --quiet "$RECEIVER_UNIT"; then
    if [[ -n "$(ss -H -ltn 'sport = :8765')" ]]; then
        fail "Port 8765 already in use on the Pi. Stop the earlier manually started receiver before running this script."
    fi
fi
mkdir -p "$OUTPUT_DIR"
printf 'Receiver output/database: %s\n' "$OUTPUT_DIR"

if [[ -e "$VHOST_FILE" ]]; then
    grep -Fq '# Managed by Fuji Import Pi PoC' "$VHOST_FILE" \
        || fail "$VHOST_FILE exists but is not ours; refusing to overwrite it"
fi

info "Requesting sudo and installing the exact camera-trusted TLS certificate"
sudo -v

# dnsmasq-base supplies the resolver executable without enabling a separate
# system-wide dnsmasq service that could conflict with this PoC on port 53.
if [[ ! -x "$DNSMASQ" ]]; then
    info "Installing dnsmasq-base (DNS forwarding, without a global daemon)"
    sudo apt-get update
    sudo apt-get install -y dnsmasq-base
fi
[[ -x "$DNSMASQ" ]] || fail "dnsmasq was not installed at $DNSMASQ"
sudo install -d -m 700 "$CERT_DIR"
sudo install -m 644 "$APP_DIR/certs/server.crt" "$CERT_DIR/server.crt"
sudo install -m 600 "$APP_DIR/certs/server.key" "$CERT_DIR/server.key"

info "Installing temporary systemd services (not enabled at boot)"
receiver_unit="$(mktemp)"
dns_unit="$(mktemp)"
dns_config_tmp="$(mktemp)"
vhost_tmp="$(mktemp)"
trap 'rm -f -- "$receiver_unit" "$dns_unit" "$dns_config_tmp" "$vhost_tmp"' EXIT

cat > "$receiver_unit" <<EOF
[Unit]
Description=Fuji Import PoC receiver (loopback only)
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON -u $APP_DIR/receiver.py --bind 127.0.0.1 --port 8765 --output $OUTPUT_DIR
Restart=on-failure
