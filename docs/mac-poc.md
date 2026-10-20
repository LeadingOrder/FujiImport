# Mac proof of concept — lab notes

## FI-01 — Minimal local receiver

- [ ] Record X-E5 firmware version: **TBD**
- [ ] Record Mac version and Python version: **TBD**
- [ ] Record active Mac LAN IP/interface: **TBD**
- [ ] Start `python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765`
- [ ] Confirm `curl -fsS http://127.0.0.1:8765/health` responds
- [ ] Confirm test binary POST saves to `poc/mac/output/`
- [ ] Temporarily bind to LAN interface and verify another LAN device can access `/health`
- [ ] Choose a **temporary, reversible** Mac↔camera Wi-Fi connection method
- [ ] Document how WAN access will be blocked for both camera and test receiver
- [ ] Document exact rollback; verify no production router/Pi/Nextcloud changes

## FI-02 — DNS and local HTTPS (not yet started)

- Required Frame.io hostnames observed: **TBD**
- Test-only DNS choice: **TBD**
- Certificate SAN / camera CA import result: **TBD**
- TLS request observed at Mac receiver: **TBD**

## FI-03 — Pairing protocol (not yet started)

- Redacted endpoint sequence and response shapes: **TBD**
- Fully offline pairing result: **TBD**

## FI-04 — Original file transfer (not yet started)

| Original | Source SHA-256 | Received SHA-256 | Match? |
|---|---|---|---|
| RAF | TBD | TBD | TBD |
| JPEG | TBD | TBD | TBD |

- Camera reports upload completion: **TBD**
- WAN access blocked during test: **TBD**
- Reconnection retest: **TBD**

## Rollback

- Stop the Mac receiver (`Ctrl-C`).
- Remove any temporary DNS overrides and restore previous camera network settings.
- Remove the *test* root certificate from camera trust, once no longer needed.
- Delete test-only certificates under `poc/mac/certs/` if appropriate.

Never log or commit camera authentication tokens, private keys, personal photos or packet captures.
