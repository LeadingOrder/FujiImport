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
VHOST_NAME="zz-fuji-import-poc.conf"
VHOST_FILE="/etc/apache2/sites-available/${VHOST_NAME}"
CERT_DIR="/etc/ssl/fuji-import-poc"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
info() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

if [[ "$EUID" -eq 0 ]]; then
    fail "Run as your normal Pi user (e.g. ./run_fuji_pi.sh), not using sudo. The script invokes sudo when needed."
fi

case "$ACTION" in
start | status | logs | stop) ;;
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
for name in python3 openssl curl ip sudo apache2ctl ss; do need "$name"; done
[[ -f "$APP_DIR/receiver.py" ]] || fail "Missing $APP_DIR/receiver.py"
[[ -f "$APP_DIR/dns_lab.py" ]] || fail "Missing $APP_DIR/dns_lab.py"
[[ -f "$APP_DIR/certs/server.crt" ]] || fail "Missing $APP_DIR/certs/server.crt"
[[ -f "$APP_DIR/certs/server.key" ]] || fail "Missing $APP_DIR/certs/server.key"
[[ "$PI_IP" =~ ^[0-9.]+$ ]] || fail "PI_IP must be an IPv4 address"
ip -4 -o addr show scope global | grep -Fq "inet $PI_IP/" || fail "Pi IP $PI_IP is not assigned to an interface"

# Validate cert and key are a matching pair; preserve the camera-trusted leaf cert.
openssl x509 -in "$APP_DIR/certs/server.crt" -noout -checkend 0 >/dev/null ||
    fail "Camera-trusted server certificate has expired or cannot be read"
cert_pub="$(openssl x509 -in "$APP_DIR/certs/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
key_pub="$(openssl pkey -in "$APP_DIR/certs/server.key" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
[[ "$cert_pub" == "$key_pub" ]] || fail "server.crt and server.key do not match"
python3 -m py_compile "$APP_DIR/receiver.py" "$APP_DIR/dns_lab.py"
if ! systemctl is-active --quiet "$RECEIVER_UNIT"; then
    if [[ -n "$(ss -H -ltn 'sport = :8765')" ]]; then
        fail "Port 8765 already in use on the Pi. Stop the earlier manually started receiver before running this script."
    fi
fi
mkdir -p "$OUTPUT_DIR"
printf 'Receiver output/database: %s\n' "$OUTPUT_DIR"

if [[ -e "$VHOST_FILE" ]]; then
    grep -Fq '# Managed by Fuji Import Pi PoC' "$VHOST_FILE" ||
        fail "$VHOST_FILE exists but is not ours; refusing to overwrite it"
fi

info "Requesting sudo and installing the exact camera-trusted TLS certificate"
sudo -v
sudo install -d -m 700 "$CERT_DIR"
sudo install -m 644 "$APP_DIR/certs/server.crt" "$CERT_DIR/server.crt"
sudo install -m 600 "$APP_DIR/certs/server.key" "$CERT_DIR/server.key"

info "Installing temporary systemd services (not enabled at boot)"
receiver_unit="$(mktemp)"
dns_unit="$(mktemp)"
vhost_tmp="$(mktemp)"
trap 'rm -f -- "$receiver_unit" "$dns_unit" "$vhost_tmp"' EXIT

cat >"$receiver_unit" <<EOF
[Unit]
Description=Fuji Import PoC receiver (loopback only)
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON -u $APP_DIR/receiver.py --bind 127.0.0.1 --port 8765 --output $OUTPUT_DIR
Restart=on-failure
RestartSec=2
UMask=0077

EOF

cat >"$dns_unit" <<EOF
[Unit]
Description=Fuji Import PoC DNS for api.frame.io on $PI_IP
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON -u $APP_DIR/dns_lab.py --bind $PI_IP --port 53
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=2

EOF

sudo install -m 644 "$receiver_unit" "/etc/systemd/system/$RECEIVER_UNIT"
sudo install -m 644 "$dns_unit" "/etc/systemd/system/$DNS_UNIT"
sudo systemctl daemon-reload
sudo systemctl restart "$RECEIVER_UNIT"
sudo systemctl restart "$DNS_UNIT"

info "Checking local receiver and DNS startup"
for i in {1..12}; do
    if curl --noproxy '*' -fsS --connect-timeout 2 http://127.0.0.1:8765/health >/dev/null; then
        break
    fi
    sleep 0.5
done
curl --noproxy '*' -fsS http://127.0.0.1:8765/health || fail "Receiver not healthy; run: ./run_fuji_pi.sh logs"
sudo systemctl is-active --quiet "$DNS_UNIT" || fail "DNS service failed; run: ./run_fuji_pi.sh logs"

info "Adding LAN-restricted Apache vhost; existing Nextcloud vhost stays unchanged"
cat >"$vhost_tmp" <<EOF
# Managed by Fuji Import Pi PoC; do not place camera secrets here.
<VirtualHost *:443>
    ServerName api.frame.io

    SSLEngine On
    SSLCertificateFile $CERT_DIR/server.crt
    SSLCertificateKeyFile $CERT_DIR/server.key

    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 600

    # Nextcloud is reachable on public HTTPS. Keep THIS API restricted to LAN.
    <Location "/">
        Require ip $LAN_CIDR
    </Location>

    # Specific WebSocket route precedes general HTTP proxy.
    ProxyPass "/devices/websocket" "http://127.0.0.1:8765/devices/websocket" upgrade=websocket timeout=650
    ProxyPassReverse "/devices/websocket" "http://127.0.0.1:8765/devices/websocket"
    ProxyPass "/" "http://127.0.0.1:8765/" timeout=600
    ProxyPassReverse "/" "http://127.0.0.1:8765/"

    ErrorLog \${APACHE_LOG_DIR}/fuji-import-poc-error.log
    CustomLog \${APACHE_LOG_DIR}/fuji-import-poc-access.log combined
</VirtualHost>
EOF

sudo a2enmod proxy proxy_http
sudo install -m 644 "$vhost_tmp" "$VHOST_FILE"
sudo a2ensite "$VHOST_NAME"
if ! sudo apache2ctl configtest; then
    sudo a2dissite "$VHOST_NAME" || true
    fail "Apache configtest failed. Fuji site disabled again; Nextcloud's running configuration was not reloaded."
fi
sudo systemctl reload apache2

info "Verifying api.frame.io routes to the Pi's receiver"
for i in {1..10}; do
    if curl --noproxy '*' -ksSf --connect-timeout 3 --resolve "api.frame.io:443:$PI_IP" https://api.frame.io/health >/dev/null; then
        break
    fi
    sleep 0.5
done
response="$(curl --noproxy '*' -ksSf --connect-timeout 4 --resolve "api.frame.io:443:$PI_IP" https://api.frame.io/health)" ||
    fail "HTTPS check failed; inspect: sudo tail -n 60 /var/log/apache2/fuji-import-poc-error.log"
[[ "$response" == '{"ok":true}' ]] || fail "Unexpected health response: $response"

expected_fingerprint="$(openssl x509 -in "$APP_DIR/certs/server.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
served_fingerprint="$(timeout 8 openssl s_client -connect "$PI_IP:443" -servername api.frame.io </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)" ||
    fail "Could not read the TLS certificate served by Apache"
[[ "$expected_fingerprint" == "$served_fingerprint" ]] || fail "Apache is serving a DIFFERENT certificate; do not reconnect camera"

printf '\nSUCCESS: Pi now serves https://api.frame.io/health -> %s\n' "$response"
printf 'Certificate SHA256 fingerprint: %s (matches original)\n' "$served_fingerprint"
printf '\nCamera change: Frame.io DNS server = %s (instead of Mac 192.168.1.203).\n' "$PI_IP"
printf 'Keep the camera on the same LAN; upload a JPEG, then a RAF.\n'
printf '\nView logs:  ./run_fuji_pi.sh logs\n'
printf 'Check state: ./run_fuji_pi.sh status\n'
printf 'Stop test:   ./run_fuji_pi.sh stop\n'
printf 'Storage:     %s\n' "$OUTPUT_DIR"
printf 'Neither Fuji service is enabled at boot yet.\n'
