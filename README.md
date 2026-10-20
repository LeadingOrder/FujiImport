# Fuji Import

Private-first, self-hosted wireless Fujifilm photo importer.

**Current milestone: Mac-only protocol proof of concept (FI-01 → FI-04).**
Do not inspect or modify the Raspberry Pi / Nextcloud installation until FI-04 passes.

- [Specification](docs/fuji-import-spec.md)
- [Implementation tickets](docs/fuji-import-implementation-tickets.md)
- [Mac experiment notes](docs/mac-poc.md)

## Start FI-01

Requires Python 3 (standard library only). Run from the repository root:

```sh
python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765
```

In another terminal:

```sh
curl -fsS http://127.0.0.1:8765/health
printf 'test payload' | curl -fsS -X POST --data-binary @- http://127.0.0.1:8765/_debug/upload
```

To permit LAN requests **during an isolated test**, bind to `0.0.0.0` and use
`http://<mac-lan-ip>:8765/health` from another device. This is a diagnostic
HTTP service, **not** the HTTPS/Frame.io implementation. It is unauthenticated;
stop it after testing and do not expose it to the Internet.

FI-02 adds test-only DNS/TLS. FI-03 and FI-04 implement the camera protocol.
