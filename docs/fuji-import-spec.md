# Fuji Import — Private-first specification

**Status:** Implementation-ready requirements, v2.1 (Mac-first proof of concept)  
**Date:** 20 October 2026  
**Primary user:** One household, one Fujifilm X-E5  
**Proof-of-concept host:** Mac on the local Wi-Fi/LAN, with no Raspberry Pi or Nextcloud changes  
**Final host:** Existing Raspberry Pi 4 running Nextcloud (Ethernet); camera on home Wi-Fi  
**Goal:** Eliminate manual photo import, not build a general photo platform.

## 1. Product in one paragraph

Fuji Import is a small, self-hosted service that makes the X-E5 upload its original files using the camera's built-in Frame.io Camera-to-Cloud workflow, **without Adobe, Internet connectivity, or modified firmware**. We **first demonstrate the full transfer locally to the Mac**; only once that succeeds do we examine the Pi and move the service there. The camera queues captured files; pressing a camera control to start the upload is acceptable. The service saves files in `Photos/YYYY/MM/`, optionally invokes user-defined scripts or webhooks, and shows transfer status in a minimal read-only web dashboard. Our Nextcloud integration is just a script. The software should be tidy enough to publish later, but **our working setup takes priority over generality**.

## 2. The workflow we are actually optimizing

**Build order:** Phase 1 proves the camera-to-Mac transfer with a temporary receiver and test-only DNS/TLS. We do **not** inspect the Pi, router configuration, Nextcloud, reverse proxy, or production storage until the Mac test has passed. The following is the eventual daily-use workflow, not the proof-of-concept setup.

1. Take photographs as usual. The X-E5 queues supported originals for upload.
2. At home, start the camera's Frame.io connection (one camera action is fine).
3. The camera reaches a local HTTPS service over home Wi-Fi. The Pi is connected to the same LAN by Ethernet.
4. The receiver accepts RAF, JPEG, and any other file type the camera sends, stores completed originals safely, and acknowledges them to the camera.
5. A configured script optionally sends each file to Nextcloud; we can retain or delete the Pi's local copy when delivery is verified.
6. Nextcloud handles its own sync to the Mac. The dashboard shows activity, failures, and what happened to each file.

No manual card reader, USB cable, photo selection on the PC, external service, or UI interaction is required for a normal import.

## 3. The one hard technical uncertainty

A previous self-hosted Frame.io emulation was demonstrated with a Fujifilm X100VI (Brandon Cazander's **Roach** project). The X-E5 has Frame.io upload and a custom root-certificate import feature, but **we have not demonstrated that its current firmware accepts a local substitute**. In particular, DNS, TLS, device pairing/authentication, and actual upload URL behavior must be measured rather than assumed.

**Reference research, not a license grant:** https://cazander.ca/2024/realfakeframe.io/ and https://gitlab.com/brandoncazander/roach . Check the Roach license or seek permission before incorporating its source into a future public repository; otherwise implement the observed API behavior ourselves.

### Milestone M1 — Offline original-file transfer to the Mac (go/no-go)

**Run the entire experiment on the Mac. Do not inspect, configure, or depend on the Raspberry Pi or Nextcloud yet.** No Docker requirement for the prototype: a local Python process is fine.

- Run a minimal local HTTPS receiver on the Mac. Arrange **temporary test-only** DNS resolution so the X-E5 reaches the Mac for the required Frame.io hostname(s). Prefer per-camera DNS configuration or an isolated test access point; do not reconfigure the household router or production services just for this experiment.
- Generate a disposable local CA and server certificate; test whether the camera accepts the certificate via its documented import mechanism.
- Implement **only** the pairing and upload endpoints actually contacted by the X-E5. Log contacted hostnames and request paths without credentials or private keys.
- Keep Internet access blocked for the camera **and the test receiver** during the proof. No Adobe login, external authorization or cloud upload.
- Transfer one original RAF and one original JPEG **directly to a folder on the Mac**. Compare SHA-256 hashes against independent copies from the SD card.
- Confirm the camera reports upload completion. Repeat once after disconnect/reconnect and document the minimal working Mac setup.

**M1 passes only if the X-E5 completes entirely offline pairing and uploads both byte-identical originals to the Mac.** If this fails, diagnose that blocker rather than starting Docker, the dashboard or Raspberry Pi network work. No firmware flashing is in scope.

### Milestone M2 — Inspect the Pi and plan deployment (only after M1)

After successful Mac proof of concept, examine the Pi 4 operating system, storage, Docker, Nextcloud installation, reverse proxy, DNS options and LAN connectivity. Pick the smallest production routing setup that preserves existing services and has clear rollback steps. Adapt the **already-proven** Mac receiver for deployment; do not redo protocol discovery on the Pi.

## 4. Scope: what we build and what we do not

### Private MVP (required)

- Working X-E5 wireless transfers on our home LAN; one manual connection action permitted.
- Local directory as the **only built-in destination**, default `Photos/YYYY/MM/` by capture date where available, otherwise receipt date.
- Opaque, unchanged original files. Do not need format-specific processors. RAF/JPEG acceptance is mandatory; support other camera-sent types without artificial filtering.
- Preserve distinct assets and never overwrite a file. Recognize and suppress **identifiable retransmissions**; when identity is ambiguous, preserve both.
- Interrupted transfers handled safely; completed files persist across restart. Acknowledgments only after durable storage of the relevant bytes.
- Configurable hooks after files and after batches; each hook `required` or `best_effort`, with visible errors and retries.
- File status and batch status independent; close a batch after configurable inactivity (120 seconds by default), not while an upload is actively progressing.
- Configurable keep/delete policy for local originals, with safe deletion conditions (below).
- Small **read-only** React + TypeScript + Mantine dashboard for status, recent files, errors, and hook outcomes.
- YAML configuration; commands run **inside the Docker container** using mounted scripts. Raspberry Pi 4 via Docker Compose.
- One working example hook for our Nextcloud WebDAV upload. This is an example script, not a Nextcloud subsystem.

### Deliberately out of scope now

- Multiuser accounts, public Internet access, a browser settings editor, a plugin framework, multiple built-in cloud destinations, firmware modifications, direct Bluetooth/PTP control, image previews/editing/transcoding, thumbnails, notification services, and broad Fujifilm compatibility testing.
- High availability, a distributed queue, Kubernetes, Redis/Celery, complicated deployment wizards, and an elaborate monitoring stack.
- Automated release infrastructure before the personal installation works reliably.

**Publish later:** when our setup is dependable, add a clean README, license, sanitized examples, ARM64/x86-64 build instructions, and clearly scoped camera compatibility notes. Public usability should shape code boundaries, not delay personal functionality.

## 5. Minimal technical design

The following is the post-M1 application design. **During M1, use a disposable Mac-local protocol prototype without Docker, SQLite, hooks, UI or Nextcloud integration.**

**One Docker Compose application** is enough. Use a Python HTTP backend (FastAPI is a reasonable default), a small SQLite database for durable import/job state, and a React/Vite dashboard built to static files and served by that backend or the current reverse proxy. One in-process worker processes hooks; it polls durable pending jobs on startup. No message broker.

Logical code boundaries, not independently deployed services:

- `protocol`: X-E5's Frame.io-compatible HTTP requests and responses.
- `imports`: streaming multipart reception, safe file naming and finalization.
- `jobs`: file/batch hooks, retries and deletion rules.
- `web`: read-only status API + dashboard.

Persist data in one mounted directory:

```text
/data/
    config.yaml       # or mounted separately
    state.sqlite
    staging/           # incomplete uploads; never treated as imported
    photos/YYYY/MM/    # verified originals
```

Prefer existing reliable external/SSD storage if present; verify free space before transfers. Do not require a second Pi or new hardware unless the current Pi genuinely cannot cope.

### File handling rules

- Stream incoming chunks to disk rather than buffering whole images or video in RAM.
- Persist enough upload identifiers and part state to handle ordinary retries/restarts; validate sizes and assemble multipart files only when complete.
- Write to temporary paths and atomically finalize the original. Once finalized, calculate/store SHA-256 and metadata; do not alter media bytes.
- Sanitize names, retain original names in metadata and append a suffix on collision. Keep RAF/JPEG stems aligned when possible, but never at the cost of losing a file.
- A content hash **alone** does not prove two separate camera assets are the same. Never discard an ambiguous image just because its bytes match.
- Treat recording time and capture date as potentially missing; default the destination month to receipt date when uncertain.
- Never delete anything from the camera card.

### Acknowledgment and job states

Camera protocol success means **durably received**—not "uploaded to Nextcloud". File postprocessing runs independently, so a Nextcloud outage cannot force retransfer from the camera.

Keep only the essential visible states:

- **Transfer:** `receiving`, `stored`, `failed`.
- **File processing:** `pending`, `running`, `complete`, `retrying`, `needs_attention`.
- **Batch processing:** corresponding independent processing states.

Persist changes in SQLite. On restart, recover incomplete transfers when possible and retry unfinished jobs. Hook attempts may execute more than once: provide stable file/batch IDs so hooks can implement idempotency. Never promise exactly-once side effects.

### Hooks and deletion

- Hooks run on `file.stored` or `batch.closed` (batch closes after 120 seconds without transfer activity; configurable).
- Hooks can be commands (argument array; no automatic shell) or HTTP POST webhooks. Shell scripts are allowed as explicitly mounted executables.
- `required` failures block that file's or batch's processing success and retry with backoff; `best_effort` failures are visible but nonblocking. A bounded retry policy with a durable `needs_attention` state is sufficient.
- Run commands as a non-root user with configurable timeout, minimal environment, and mounted secrets; capture bounded stderr/stdout for diagnostics.
- **Default retention: keep.** If `delete_after_delivery` is enabled, require at least one **required file-level delivery hook**. Do not delete until that hook positively checks its destination, every other required file hook has succeeded, and no pending file hook requires the bytes. A zero exit status is the script's attestation that its verification succeeded; the core cannot inspect arbitrary external systems.
- Batch hooks must operate on metadata; they cannot assume source files remain after successful file-level delivery. Batch failures do not change file status.
- If no hooks exist, local storage itself is the successful destination; keep the files.

### Configuration

YAML on disk is the **only** settings authority in the MVP. Restarting the container to apply changes is acceptable. The dashboard reads configuration but does not mutate it. No authentication is needed for a strictly read-only, LAN-restricted dashboard; editing settings later must require authentication. Administrative recovery may use SSH/Docker CLI rather than web buttons.

Small illustrative configuration (exact field names finalized in code):

```yaml
storage:
    root: /data/photos
    layout: "{year}/{month}/{filename}"
    delete_after_delivery: false

batch:
    idle_timeout_seconds: 120

hooks:
    - name: nextcloud
      on: file.stored
      type: command
      argv: ["/hooks/nextcloud-upload.sh", "{manifest_path}"]
      required: true
      confirms_delivery: true
      enabled: true
```

The Nextcloud script reads a JSON manifest, uploads via WebDAV to the desired archive location, verifies remote receipt and exits nonzero on failure. Credentials come from a mounted secret or environment, **never** committed to Git. No direct writes into Nextcloud's private data directory.

### Dashboard

A compact page with:

- Receiver health and camera **last seen** (do not claim "connected" without a reliable signal).
- Current transfer progress, queued/processing/failed counts.
- Recent imports: filename, size, time, destination, transfer status, processing status.
- Batch history, hook attempts, actionable error messages.

The UI is observational only. Basic periodic polling is fine; do not add SSE/WebSockets unless polling proves inadequate. No thumbnails or configuration editor.

## 6. Deployment and network boundaries

**Do this only after the Mac proof of concept passes.** Camera Wi-Fi and Pi Ethernet can communicate through the router, provided they are routable and Wi-Fi client isolation is off. Then inspect the existing Nextcloud setup, ports 53/443, DNS support, certificate handling and available storage **before changing anything on the Pi or home network**. Prefer the least invasive camera-specific DNS override. If Nextcloud already uses port 443, use hostname routing in the existing reverse proxy rather than stealing its listener. Keep the dashboard LAN-only and prevent access from the public Internet.

Use a dedicated local CA; keep its private key out of the container and repository. TLS keys and camera/auth tokens must not appear in logs. Make DNS and certificate changes easy to reverse. Keep the Mac proof-of-concept environment disposable and isolated; consolidate into Compose only after M1 passes and the Pi/network assessment is complete.

## 7. Completion criteria

### M1: Mac-only feasibility gate

Completely offline pairing plus a byte-identical RAF and JPEG uploaded **directly to the Mac**, with camera completion confirmation and documented test-only DNS/TLS setup. No Pi/Nextcloud changes.

### M2: Pi deployment plan

With M1 proven, assess Pi storage, Docker, DNS and reverse proxy, and document safe production routing and rollback.

### M3: usable personal application

Multiple new images arrive in `Photos/YYYY/MM/` without manual PC involvement. Normal reconnections and service restarts do not corrupt or overwrite files. A simple dashboard reports success or failure accurately.

### M4: our end-to-end workflow

The configured Nextcloud delivery hook puts an original in the correct Nextcloud folder. A transient Nextcloud failure leaves the Pi copy available for retry. Configured deletion happens only after verified delivery. The Mac receives the photo through its existing Nextcloud sync.

### Later: public repository

Independent setup instructions, clear supported-camera statement, basic tests and license; no private hostnames, credentials, photos or packet captures.

## 8. Key risks and intentional compromises

1. **X-E5 protocol:** an X100VI proof of concept does not guarantee X-E5 compatibility. Solve this **on the Mac first**, without touching the Pi or production network.
2. **Frame.io hostnames/TLS:** a root-certificate setting does not, by itself, prove arbitrary local impersonation works. Validate on a temporary Mac-hosted endpoint with Internet blocked; do not treat this as production network setup.
3. **Asset identity:** suppress only identifiable repeats; favor an extra file over possible data loss.
4. **Arbitrary hooks:** retries can repeat side effects. Keep scripts idempotent; no general workflow engine.
5. **Pi storage:** SD-card-only operation may be slow and wear-prone; inspect before purchasing or redesigning.
6. **Unlicensed reference code:** consult Roach to understand behavior, but do not assume permission to copy it into a published product.

**Design principle:** ship the smallest reliable solution to our own problem, then make publication easy—not the other way around.
