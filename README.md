# androiddevenv — Android dev on GCP, builds pushed to your desk over Tailscale

A cloud Android build environment you reach over Chrome Remote Desktop, driven with
Claude Code, wired to GitHub — that can install cloud-built APKs on a phone plugged
into your **laptop** over Tailscale. Pause it to near-zero (`stop`) or literal $0
(`nuke`) whenever you want.

```
┌─ Laptop ───────────────┐        ┌─ GCE VM: android-dev (e2-standard-4) ─────────┐
│ Tailscale node         │        │ host: Tailscale + Chrome Remote Desktop + XFCE│
│ adb server :5037       │◀─ Tailscale ─▶ docker (--network=host):                │
│ USB → phone            │ MagicDNS│   JDK17 · Android SDK · Gradle · gh · claude  │
└────────────────────────┘        └───────────────────────────────────────────────┘
      install here                       build here; `adb install` streams down
```

**POC scope (this repo):** build pipeline + desktop + Claude + GitHub + the Tailscale
adb loop on an e2-standard-4. **Phase 2 (later):** emulator/instrumented device grid
(needs nested virtualization + a bigger machine).

## Prerequisites (one-time)

- A **Tailscale** account with a reusable auth key:
  https://login.tailscale.com/admin/settings/keys
- `gcloud` authenticated on a billing-enabled project (already: `reclamation-game`).
- Configure secrets/overrides once in a gitignored `.env`:
  ```bash
  cp .env.example .env      # then edit: TAILSCALE_AUTHKEY, LAPTOP_TS_HOST
  ```
  Every `vm/` script auto-loads `.env` (via `vm/config.sh`). `.env` is the source of
  truth — it overrides the shell environment; the built-in defaults fill anything
  left unset.

## Laptop setup

```bash
./laptop/setup-macos.sh          # installs Tailscale + adb
# sign into Tailscale, then:
tailscale ip -4                  # note this laptop's tailnet IP  -> LAPTOP_TS_HOST
# plug in phone, enable USB debugging, then:
./laptop/adb-server.sh           # exposes adb to the tailnet (read the SECURITY note)
```
Lock the tailnet so only the VM can reach adb — see `laptop/tailscale-acl-example.json`.

## Cloud: create the VM

With `.env` filled in (`TAILSCALE_AUTHKEY`, `LAPTOP_TS_HOST`):

```bash
./vm/create.sh
```
This provisions the VM, installs Docker + Tailscale + CRD, syncs this repo, and builds
the `android-dev` container.

### First boot: register Chrome Remote Desktop (one-time per fresh VM)

The CRD host must be registered once with a Google auth code. The code is single-use
and needs an interactive "Authorize" click — that part can't be automated. Everything
else is: the PIN comes from `.env` (`CRD_PIN`), and the registration then persists.

```bash
# 1. open https://remotedesktop.google.com/headless -> Begin -> Next -> Authorize
# 2. copy the value inside --code="..." from the command it shows, then:
./vm/crd-setup.sh '4/0Axxxxxxxx...'      # runs start-host on the VM, PIN from .env
```
Then open https://remotedesktop.google.com/access — the `android-dev` desktop appears;
enter your `CRD_PIN` to connect.

**You only do this for a brand-new VM.** CRD registration lives on the boot disk and the
service auto-starts on boot, so it comes back on its own after `stop`→`start` and after
`nuke`→`restore` (the snapshot includes it). No re-auth needed for those.

Open a terminal on that desktop (or over SSH) and enter the container:

```bash
sudo docker exec -it -u dev android-dev bash
claude                    # Claude Code (first run: authenticate)
gh auth login             # GitHub
```

## The magic loop — build in cloud, install on your desk

Inside the container, in any Gradle project:

```bash
export LAPTOP_TS_HOST=100.x.y.z         # already set if passed at create time
push-build                              # ./gradlew assembleDebug + adb install over tailnet
# or manually:
export ADB_SERVER_SOCKET=tcp:$LAPTOP_TS_HOST:5037
adb devices                             # shows the phone plugged into your laptop
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Pause / resume / kill

| Command            | Cost while paused | Resume        | State kept |
|--------------------|-------------------|---------------|------------|
| `./vm/stop.sh`     | ~$2–3/mo (disk)   | `./vm/start.sh` (seconds) | everything |
| `./vm/nuke.sh`     | ~$0 (snapshot)    | `./vm/restore.sh` (minutes) | everything (from snapshot) |

Your work lives in Docker volumes (`android-dev-work`, `android-dev-home`) on the boot
disk, which both `stop` and `nuke`-snapshot preserve.

## Files

- `Dockerfile`, `container/` — the reproducible Android + Claude + gh toolchain.
- `vm/` — lifecycle: `create · start · stop · nuke · restore · ssh · push-repo · crd-setup` + `startup-script.sh`.
- `laptop/` — Tailscale + adb server setup and an ACL example.
- `scripts/push-build.sh` — build-and-install-over-tailnet (installed as `push-build` in the container).

## Phase 2 (not yet built): emulator/device grid

Emulators need KVM. On GCE that means a machine type with **nested virtualization**
(e.g. `n2-standard-8` + a licensed image) and `--enable-nested-virtualization`. Add an
emulator layer to the image (`emulator`, `system-images;android-34;google_apis;x86_64`)
and run headless AVDs, or wire up a grid (e.g. Android Emulator Container / STF).
