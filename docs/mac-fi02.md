# FI-02 — X-E5 → Mac HTTPS connection (temporary test only)

This is a standalone local lab. It does not change the Raspberry Pi, router or
Mac system-wide DNS. FI-03 pairing and uploads are **not** implemented yet.

## Prerequisites

- Existing FI-01 receiver running on port 8765.
- Mac and camera on the same LAN; camera-to-LAN connectivity confirmed.
- Use one camera test profile; note old settings before changing them.
- Camera firmware version recorded in `docs/mac-poc.md`.

## 1. Generate a private test CA and server certificate

```bash
./scripts/fi02-certs.sh
```

This generates `poc/mac/certs/ca.pem` (PUBLIC CA) and private keys
`ca.key` and `server.key`. The entire `certs/` directory is gitignored.
Copy **only `ca.pem`** to the SD card. Never copy private keys.

## 2. Record Mac LAN IP

```bash
MAC_IF=$(route -n get default | awk '/interface:/{print $2;exit}')
MAC_IP=$(ipconfig getifaddr "$MAC_IF")
echo "$MAC_IF $MAC_IP"
sysctl -n net.inet.ip.forwarding
```

IP forwarding should be `0` for the offline-gateway test. If `1`, stop and
investigate rather than relying on the Mac to block WAN access.

## 3. Run three processes in separate terminals

Receiver (already running; keep it running):

```bash
python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765
```

Check no other program is listening on ports 443 and 53:

```bash
sudo lsof -nP -iTCP:443 -sTCP:LISTEN
sudo lsof -nP -iTCP:53 -sTCP:LISTEN
sudo lsof -nP -iUDP:53
```

TLS front end (TCP 443):

```bash
sudo "$(command -v python3)" poc/mac/tls_frontend.py --bind "$MAC_IP"
```

Fail-closed DNS (UDP+TCP 53):

```bash
sudo "$(command -v python3)" poc/mac/dns_lab.py --bind "$MAC_IP"
```

Both services listen **only on the specified Mac LAN IP**.

## 4. Test without the camera

```bash
curl --cacert poc/mac/certs/ca.crt \
    --resolve "api.frame.io:443:$MAC_IP" \
    https://api.frame.io/health

dig @"$MAC_IP" api.frame.io A +short
dig @"$MAC_IP" example.org A +noall +comments
```

Expected: JSON `status: ok` from HTTPS; DNS returns the Mac IP for
`api.frame.io`; other domains return NXDOMAIN. The curl test uses no external
Frame.io servers.

## 5. Camera configuration

- Copy `poc/mac/certs/ca.pem` to the card (ideally card root, without modifying photos).
- X-E5: NETWORK/USB SETTING → Frame.io Camera to Cloud → UPLOAD SETTING →
  ROOT CERTIFICATE → LOAD FROM STORAGE MEDIA; select the test CA.
- X-E5: NETWORK/USB SETTING → NETWORK SETTING → registered home Wi-Fi → EDIT →
  IP ADDRESS SETTING → MANUAL. Use a genuinely free static IPv4 on your LAN,
  the correct subnet mask, `GATEWAY ADDRESS = MAC_IP`, and
  `DNS SERVER ADDRESS = MAC_IP`.
- A Mac gateway with IP forwarding disabled prevents ordinary IPv4 WAN access
  from the camera while permitting direct access to the Mac. It is **not** a
  substitute for checking other routes, IPv6, or external IP traffic.
- Use Frame.io Camera to Cloud → CONNECT to trigger an attempt.

At FI-02, a 404 or failed Frame.io pairing **after an observed HTTPS request** is
expected: the pairing API is FI-03. Record SNI, DNS lookups and request paths
without copying tokens or personal photo contents into documentation.

If the camera cannot find/import the certificate, do not guess success: record
the camera message and research its certificate file-format expectations.

## Rollback

1. Stop both services with Ctrl+C; stop the receiver when finished.
2. Restore camera IP ADDRESS SETTING to AUTO (or its original configuration).
3. On camera ROOT CERTIFICATE → DELETE to remove the test CA.
4. Optionally remove the temporary public cert from the SD card.
5. No router, global Mac resolver, Pi or Nextcloud setting should have changed.

Do **not** expose the test certificate private key, make router-wide DNS changes,
or interpret failed pairing as an FI-02 failure if HTTPS requests arrived.
