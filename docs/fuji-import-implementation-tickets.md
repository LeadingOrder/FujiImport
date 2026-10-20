# Fuji Import — Concrete implementation tickets

**Status:** v2 — Mac-first protocol proof, then Raspberry Pi deployment  
**Companion specification:** `fuji-import-spec-v2.1-mac-first.md`  
**Working rule:** Demonstrate a fully offline RAF+JPEG upload **to the Mac first**. Do not inspect or configure the Raspberry Pi, home-network DNS, reverse proxy or Nextcloud until FI-04 succeeds. Each ticket is small enough to hand to a coding agent with a clear completion test.

## How to use this backlog

**First prove the camera-to-Mac transfer.** The home-network/Pi assessment is **FI-05**, strictly dependent on passing FI-04. During FI-01–04, any DNS/TLS work is temporary and exclusively for the Mac test, not the eventual deployment.

- **NOW**: do in order, stopping if M1 is blocked.
- **MVP**: needed for a useful personal deployment after M1.
- **LATER**: do only after our own importer works reliably.
- Sizes are relative (**S**, **M**, **L**), not time guarantees. The X-E5 protocol is the largest unknown.
- Every ticket includes its own verification; do not create a separate documentation/testing bureaucracy.
- Prefer a single repository and container, with focused modules rather than premature abstractions.

## Milestone M1 — Prove the X-E5 works completely offline on the Mac

### FI-01 — Prepare a disposable Mac-local protocol experiment

**Priority:** NOW · **Size:** S · **Depends on:** nothing

**Work**
- Prepare a minimal Python receiver on the Mac with a local output directory and basic request logging. No Docker, database, dashboard, Pi or Nextcloud work.
- Record the X-E5 firmware version and the Mac's current local IP. Choose an easily reversible test-only setup for the camera to reach the Mac over Wi-Fi.
- Decide how to block WAN access for the camera and test receiver while allowing local Mac↔camera traffic. Keep the production household network unchanged.
- Record the Mac-only setup and undo instructions in `docs/mac-poc.md`.

**Done when**
- The Mac can listen for local HTTP(S) requests, a camera-to-Mac LAN path is available, and the experiment can be reset without changing Pi/Nextcloud services.

### FI-02 — Direct camera Frame.io hostnames to local Mac HTTPS

**Priority:** NOW · **Size:** M · **Depends on:** FI-01

**Work**
- Set up a temporary per-camera DNS override or isolated test network so necessary Frame.io hostnames resolve to the **Mac**, not the Pi. Avoid router-wide or production DNS changes.
- Generate a disposable test CA and TLS certificate with the correct hostname SAN; serve a minimal HTTPS endpoint on the Mac.
- Import the CA into the X-E5 and observe certificate / connectivity errors.
- Verify the test remains local with WAN unavailable; document any camera-specific DNS limitations and teardown steps.

**Done when**
- Camera requests for the required hostname can reach Mac HTTPS (or a precise blocker is documented), and nothing on the Pi/home production configuration was changed.

### FI-03 — Implement only the observed camera pairing endpoints

**Priority:** NOW · **Size:** L/unknown · **Depends on:** FI-02

**Work**
- Trigger Frame.io connection on the X-E5 and record sanitized HTTP/DNS/TLS behavior **at the Mac receiver**.
- Determine which endpoints and responses the camera actually expects for device pairing and authorization.
- Implement only those request/response handlers in the throwaway **Mac-local** Python prototype. No permanent architecture, Docker or UI yet.
- If additional upload hostnames are observed, include only those in the **Mac test DNS/TLS** routing.
- Use the published X100VI/Roach work as research; check licensing before copying code.

**Done when**
- Without Adobe credentials or WAN access, the camera accepts **Mac-hosted** local pairing and proceeds to the stage of attempting an upload.
- A short protocol log documents the exact paths, response shapes and remaining uncertainties (with secrets redacted).

### FI-04 — Receive one RAF + JPEG and verify the bytes

**Priority:** NOW · **Size:** L/unknown · **Depends on:** FI-03

**Work**
- Implement the smallest needed asset-creation, upload URL and multipart receiving routes.
- Capture one full RAF and one JPEG **directly on the Mac's disk**; assemble multipart payloads if used.
- Independently copy the two source files from SD/USB; compare sizes and SHA-256 hashes.
- Check that the camera reports upload completion; repeat the experiment once after reconnecting.
- Record WAN-blocking evidence and exact **Mac-side** camera/receiver settings. Do not rely on or change the Pi.

**Done when — HARD GO/NO-GO**
- Original RAF and JPEG both arrive **byte-identically on the Mac**, with upload completion confirmed on the X-E5 and no Adobe/Internet dependency.
- If not, stop the remaining backlog and document the specific blocker. Do **not** inspect the Pi or compensate by building an unrelated importer or dashboard.

---

## Milestone M2 — Inspect the Pi and plan deployment (only after Mac proof)

### FI-05 — Inspect Raspberry Pi 4 and choose production DNS/TLS routing

**Priority:** MVP · **Size:** S · **Depends on:** FI-04 (hard gate passed)

**Work**
- **Only now** inspect Pi OS/architecture, RAM, available storage, Docker/Compose, Nextcloud deployment, and listeners on ports 53/80/443.
- Verify camera Wi-Fi can reach the Pi's Ethernet subnet and determine the least invasive camera-specific DNS override and HTTPS routing.
- Document a reversible deployment plan that does not interrupt Nextcloud; do not change anything until the plan is understood.
- Keep the Mac proof-of-concept code and observed protocol as the basis of the Pi deployment.

**Done when**
- `docs/pi-deployment.md` records the Pi/network facts, chosen routing, storage location and rollback steps. No production services have been disturbed.

---

## Milestone M3 — Turn the prototype into a reliable personal receiver

### FI-06 — Small application + Docker Compose skeleton

**Priority:** MVP · **Size:** S · **Depends on:** FI-05

**Work**
- Put the working handlers into one Python application with `protocol`, `imports`, `jobs`, and `web` modules; no microservices.
- Add `compose.yaml`, Dockerfile, a persisted `/data` mount, `.env.example`, `config.example.yaml`, and startup validation of only the required YAML fields.
- Use SQLite for import and job state; default to one active transfer and one worker until measurements justify more.
- Adapt the Mac-proven protocol to the Pi 4 ARM64 Compose installation. Do not build a publishing pipeline yet.

**Done when**
- `docker compose up --build -d` starts the receiver on the target Pi, and application restart does not erase configuration or state.

### FI-07 — Durable, streaming, restart-safe uploads

**Priority:** MVP · **Size:** M · **Depends on:** FI-06

**Work**
- Replace prototype buffering with disk-streamed multipart files and a staging directory.
- Record upload/part state in SQLite; accept repeated parts idempotently when an identifier is known.
- Check expected file size; atomically move a complete file into the photo directory, calculate SHA-256, and only then send final camera success.
- On restart, recover or safely retain incomplete staged uploads. Return errors instead of falsely acknowledging when disk is full.

**Done when**
- A normal transfer survives interruption/retry and application restart without producing a corrupted finalized file.
- A deliberately incomplete transfer is not marked successful.

### FI-08 — Date folders, distinct assets and safe names

**Priority:** MVP · **Size:** S/M · **Depends on:** FI-07

**Work**
- Store finalized originals in `Photos/YYYY/MM/` using capture date if trustworthy, otherwise receipt date.
- Sanitize camera names, avoid overwrites, and suffix filename collisions predictably.
- Suppress recognized retransmissions using persistent camera/upload IDs. Preserve ambiguous duplicates rather than risk dropping distinct images.
- Record original name, stored path, file size, SHA-256 and available camera metadata in SQLite.

**Done when**
- Two different assets named `DSCF0001.RAF` are both retained; the same identifiable upload repeated does not create a second copy.
- RAF/JPEG remain distinct, originals remain byte-identical, and restart preserves deduplication metadata.

---

## Milestone M4 — Our Nextcloud workflow without a Nextcloud-specific backend

### FI-09 — YAML-configured file hooks with retries

**Priority:** MVP · **Size:** M · **Depends on:** FI-08

**Work**
- Support `file.stored` hooks in YAML as an executable argument array or simple HTTP POST webhook.
- Pass one JSON manifest with stable import ID, path, original name, timestamp, size, checksum, and retry/idempotency key.
- Execute commands inside the container from read-only mounted scripts, without implicit shell parsing; apply timeout and bounded log capture.
- Persist per-hook result/error; retry required failures with backoff, while best-effort failures do not block success.
- On restart, resume pending jobs. CLI-based recovery is sufficient; no admin web controls.

**Done when**
- A successful test hook runs once normally; a purposely failing required hook is shown as incomplete, retried, and remains recoverable after container restart.
- Duplicate execution is documented as possible; manifest IDs stay stable across retries.

### FI-10 — Import batches and batch hooks

**Priority:** MVP · **Size:** S/M · **Depends on:** FI-09

**Work**
- Start/open a batch when import activity begins; close after a configurable quiet period, default 120 seconds, with no upload actively transferring.
- Support `batch.closed` command/webhook hooks using a batch JSON manifest.
- Track batch processing separately from file processing; a failing required batch hook never changes a file's own success state.

**Done when**
- Two files arriving close together trigger one batch hook after inactivity; a later file opens a new batch.
- A failed batch hook shows a failed/retrying **batch**, not failed photos.

### FI-11 — Safe optional deletion after verified delivery

**Priority:** MVP · **Size:** S/M · **Depends on:** FI-09, FI-10

**Work**
- Default to retaining local originals.
- Support `delete_after_delivery` only when a required **file-level** hook is explicitly designated a delivery verifier.
- Delete only after that hook reports verified success, all required file hooks succeed, and no unfinished file hook needs the bytes.
- Keep originals on failure, timeout or restart; make cleanup idempotent and visible in the manifest.

**Done when**
- Failed delivery never removes the local file. Verified successful delivery removes it only when deletion is enabled.
- Enabling deletion without a qualifying delivery hook fails configuration validation.

### FI-12 — Nextcloud upload hook for our Pi

**Priority:** MVP · **Size:** S/M · **Depends on:** FI-09, FI-11

**Work**
- Write `examples/hooks/nextcloud-upload.sh` (or a small Python command) receiving the file manifest.
- Upload the original through Nextcloud WebDAV to our existing photo archive path, keeping `YYYY/MM` folders; do not write directly into Nextcloud's internal filesystem.
- Verify delivery with a remote size/metadata check before returning success; retry-safe behavior must avoid overwriting unrelated files.
- Keep credentials in a mounted secret/environment and the script in a mounted directory.

**Done when**
- A test RAF lands in the intended Nextcloud folder and appears through normal Nextcloud access; a simulated Nextcloud outage causes a retry while the Pi original remains intact.
- Deletion-after-delivery can be turned on safely for our household configuration.

---

## Milestone M5 — Tiny read-only dashboard

### FI-13 — Status API and dashboard

**Priority:** MVP · **Size:** S/M · **Depends on:** FI-08, FI-09, FI-10

**Work**
- Expose read-only endpoints for health, camera last seen, active transfers, recent files, processing errors, recent batches and hook attempts.
- Build one React + TypeScript + Mantine screen, matching the already agreed simple mockup.
- Poll status at a modest interval. No thumbnails, charting, configuration editor, authentication system, or live socket infrastructure.
- Show clear labels: `last seen` rather than an invented persistent connected state.
- Bind dashboard access to the LAN; use YAML/SSH for all administrative changes.

**Done when**
- While transferring and while deliberately failing a hook, the dashboard shows current status, file history and an understandable error; reloading it changes nothing on the server.

---

## Milestone M6 — Deploy and use it ourselves

### FI-14 — End-to-end Pi deployment and short reliability trial

**Priority:** MVP · **Size:** M · **Depends on:** FI-12, FI-13

**Work**
- Integrate the working Compose service with actual LAN DNS/TLS routing without breaking existing Nextcloud.
- Use real X-E5 shooting sessions (RAF+JPEG; optionally video/HEIF), including a reconnect, backend restart, deliberately missing network, and an unavailable Nextcloud destination.
- Check Pi disk usage, memory, CPU and user-visible behavior; tune only demonstrable bottlenecks.
- Document the actual working camera steps, Pi startup command, logs, backups for configuration/SQLite, and rollback.

**Done when**
- After a normal photo session, images arrive in the Nextcloud archive and subsequently on the Mac without any PC-side import action.
- Failed transfers and hooks are visible; no originals are silently dropped, overwritten or deleted before verified delivery.
- The whole setup can be restarted after a Pi reboot.

---

## Milestone M7 — Make it shareable (explicitly deferred)

### FI-15 — Clean public GitHub release

**Priority:** LATER · **Size:** M · **Depends on:** FI-14 and a few successful real-world sessions

**Work**
- Confirm source licensing; do not ship third-party Roach source without permission or a compatible license.
- Remove household IP addresses, tokens, certificates, photos, and private captures.
- Write quickstart, Linux/ARM64/x86-64 notes, minimal security warnings, sample hooks and supported-camera limits.
- Add a small automated test/build check only where it helps prevent regression. Test x86-64 on a real/container environment before claiming support.

**Done when**
- Someone without our network, Pi, or Nextcloud can follow the README to run the receiver and understand precisely what has and has not been tested.

---

## Recommended execution sequence

```text
MAC-ONLY PROOF OF CONCEPT (no Pi or Nextcloud work)
FI-01 → FI-02 → FI-03 → FI-04
                             │
                      FAIL: investigate on Mac
                      PASS: continue
                             ↓
PI AND HOME-NETWORK INSPECTION (only now)
FI-05
                             ↓
RELIABLE RECEIVER
FI-06 → FI-07 → FI-08
                             ↓
NEXTCLOUD WORKFLOW
FI-09 → FI-10 → FI-11 → FI-12
             └──────────→ FI-13  (dashboard in parallel)
                             ↓
PERSONAL PI DEPLOYMENT
FI-14
                             ↓
OPTIONAL GITHUB RELEASE
FI-15
```

## Definition of done for *our* project

We return home, initiate the camera transfer with at most one action, and the complete original RAF/JPEG files appear in the correct Nextcloud photo folder and then on the Mac. The Pi handles interrupted uploads, retries failed deliveries, and does not lose originals. The tiny dashboard tells us what succeeded and what failed. **Anything beyond that is optional until it solves a real problem for us.**
