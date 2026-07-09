# androiddevenv — Android dev on GCP, builds pushed to your desk over Tailscale

A cloud Android build environment you reach over Chrome Remote Desktop, driven with
Claude Code, wired to GitHub — that can install cloud-built APKs on a phone plugged
into your **laptop** over Tailscale. Pause it to near-zero (`stop`) or literal $0
(`nuke`) whenever you want.

```
┌─ Phone (tailnet node) ─┐        ┌─ GCE VM: android-dev (bare-metal, no Docker) ─┐
│ adb TCP :5555          │◀─ Tailscale ─▶ JDK17 · Android SDK · gh · tmux ·       │
│ Tailscale ON           │ direct  │   Claude · Chrome · your repo in ~/work       │
└────────────────────────┘        └───────────────────────────────────────────────┘
   `adb install` lands here            build here; VM connects straight to the phone
```

Everything (a self-sufficient headless Android SDK, Gradle, Claude, your checkout) is
installed **bare-metal on the VM** and baked into a **golden GCE image** for ~1-min spin-up
— no Docker, and **no Android Studio**: builds run from the CLI and device-checking is
`push-build` to a real phone over Tailscale. The intended loop: spin up a node per GitHub
issue (repo auto-cloned + Gradle pre-warmed), SSH in (you land in a shared tmux), push, then
`nuke` to $0.

## Prerequisites (one-time)

- A **Tailscale** account with a reusable auth key:
  https://login.tailscale.com/admin/settings/keys
- `gcloud` authenticated on a billing-enabled project (already: `reclamation-game`).
- Configure secrets/overrides once in a gitignored `.env`:
  ```bash
  cp .env.example .env      # then edit: TAILSCALE_AUTHKEY, PHONE_TS_HOST
  ```
  Every `vm/` script auto-loads `.env` (via `vm/config.sh`). `.env` is the source of
  truth — it overrides the shell environment; the built-in defaults fill anything
  left unset.

## Phone setup (adb over Tailscale)

The VM installs builds by connecting **straight to your phone** over Tailscale — the phone
is a tailnet node running adb in TCP mode, so no laptop adb server is involved (Android
Studio on your laptop is left alone).

```bash
./laptop/setup-macos.sh          # installs Tailscale + adb (adb only for the one-time flip)
# 1. Tailscale ON on the phone (same account); note its tailnet IP -> PHONE_TS_HOST in .env
# 2. enable USB debugging, plug in once, then flip adb to TCP:
adb tcpip 5555                   # resets on reboot; or use Android "Wireless debugging"
```
Keep Tailscale on the phone whenever you want builds. Lock it down so only the dev nodes
reach the phone's adb — see `laptop/tailscale-acl-example.json`. The golden image ships a
shared adb key, so you tap **"Always allow"** on the phone once and all nodes are trusted.

## Cloud: bake the golden image once, then spin up fast

New nodes boot from a pre-baked **golden image** with everything installed bare-metal:
Tailscale + CRD + XFCE, JDK 17 + a self-sufficient Android SDK (platform-tools, several
recent platforms + build-tools, emulator), **Google Chrome**, **Claude Code**, `gh`, and
`tmux` — all baked in, so they're ready in ~1 min instead of ~7. No Android Studio. Build
it once:

```bash
./vm/install.sh          # bakes the base image; optionally spins up a seed to bake
                         # graphical config (browser sign-ins, dotfiles), then re-bakes
```

`install.sh` bakes the base image from a throwaway builder, then *optionally* offers a
**seed** node to bake graphical/home-dir state (browser sign-ins, dotfiles — builds are
headless, so this is optional). Press Enter and it re-bakes the golden image from that
configured seed and deletes it. Skip it (answer `n`, or no TTY / no `TAILSCALE_AUTHKEY`) and
you just get the base image.

Then create nodes from it (needs a **reusable** `TAILSCALE_AUTHKEY`, since every node is
its own tailnet member):

```bash
./vm/create.sh              # primary node (prompts for the one-time CRD desktop code)
./vm/create.sh android-dev-2   # another node
```

### Fleet: spin many up / down

```bash
./vm/fleet.sh up 4          # 4 headless workers android-dev-w-1..4 (no desktop), in parallel
./vm/fleet.sh list          # show them
./vm/fleet.sh down          # delete them all
```
Workers are headless (SSH/Claude only); the desktop (CRD) is registered on your primary
node only. Set `ANTHROPIC_API_KEY` in `.env` so `claude` works non-interactively on workers.

Re-run `./vm/install.sh` whenever you change `vm/startup-script.sh` (the provisioner) or the
helper scripts. To iterate on `push-build`/`warm-repo` on a live node without a full
re-bake, use `./vm/push-repo.sh [name]`.

### Re-bake later without a full reinstall

`install.sh` already handles the first configure-and-stamp. To change the baked setup
afterward *without* rebuilding the whole image, configure any live node and re-bake from it:

```bash
./vm/create.sh seed        # (or reuse an existing node)
# connect at remotedesktop.google.com/access and change whatever you want baked in
./vm/reimage.sh seed       # re-bake the golden image from that node
./vm/create.sh             # new nodes now stamp the new state
```

`reimage.sh` keeps the configured home dir (`~/Android/Sdk`, `~/.config/Google/…`, AVDs)
and strips only per-machine identity. (CRD registration is single-use, so each node still
does its one-time code.) The same trick stamps *any* GUI/home-dir setup you configure.

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

**One code per node.** CRD registration lives on the boot disk and the service auto-starts
on boot, so it survives `stop`→`start` with no re-auth. A fresh node from `create.sh` (or
after a `nuke`) needs its own one-time code — registration is single-use and can't be baked.

Open a terminal on the desktop (or `./vm/ssh.sh`) — the toolchain is right there on the
VM: `claude`, `gh`, `adb`, `sdkmanager`, `./gradlew`, and your checkout in `~/work`. Claude
and GitHub auth are wired automatically from `.env` (`CLAUDE_CODE_OAUTH_TOKEN`/`GH_TOKEN`).
SSH lands you in a **shared `tmux`** session (`main`) that survives disconnects — reconnect
from anywhere and pick up where you left off.

## Per-node: auto-clone your app + warm Gradle

Point the environment at an Android repo and every node comes up ready to build:

```bash
# in .env
GIT_REPO=https://github.com/you/your-android-app.git
GIT_BRANCH=main                 # optional
GRADLE_WARM_TASK=assembleDebug  # optional (default)
```

On `./vm/create.sh`, the node:
1. gets a **GitHub token** — from `GITHUB_TOKEN` in `.env`, or your local `gh auth token`
   (non-interactive, so fleet workers get it too) — passed via instance metadata and wired
   into git (`gh auth setup-git`), so private clones/pushes just work;
2. **clones `GIT_REPO`** into `~/work` on the VM (the desktop user's home); and
3. **warms Gradle** (`GRADLE_WARM_TASK`) in the background — downloads dependencies and
   spins up the daemon so your first real build is fast.

Steps 2–3 run in the background (log: `~/work/.warm.log`), so the node is usable
immediately while the build warms. Nothing set? The node just skips this. Edit `~/work/<repo>`
right on the VM — with Claude, `$EDITOR`, or a browser IDE like code-server — and build with
`./gradlew` (the SDK is self-sufficient; no Studio needed).

## The magic loop — build in cloud, install on your phone

On the VM, in your project (e.g. `~/work/<repo>`):

```bash
push-build                              # assembleDebug + adb connect $PHONE_TS_HOST:5555 + install
# or manually (PHONE_TS_HOST is set from .env at boot):
adb connect $PHONE_TS_HOST:5555         # the phone over tailscale
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Admin webapp

A tidy, self-contained local dashboard (Python 3 stdlib only, no deps):

```bash
./admin                         # opens http://127.0.0.1:8787  (ADMIN_PORT=... to change)
```

Shows all instances (status, machine, IP, and a running $/hr total), plus images,
snapshots, and orphan disks. Buttons: **create a headless node**, **start / stop / nuke**
per instance, **fleet up/down**, and **cleanup** — with live command output streamed into
the page. It's **localhost-only** (it runs the `vm/` scripts, so never expose it) and reads
`PROJECT`/`ZONE` from your `.env` via `config.sh`.

Interactive one-offs stay in the terminal: nodes created from the webapp are **headless**
(no CRD desktop), and the image bake (`install.sh`) and CRD registration need a TTY.

## Pause / kill

| Command            | Cost after   | Come back with           | State kept |
|--------------------|--------------|--------------------------|------------|
| `./vm/stop.sh`     | ~$0.10/GB·mo disk (≈$15/mo at 150GB) | `./vm/start.sh` (seconds) | everything (disk intact) |
| `./vm/nuke.sh`     | $0           | `./vm/create.sh` (fresh node) | none — see below |

**`stop`** is a pause: the disk (your `~/work`, home-dir config, CRD registration) stays,
so `start` resumes in seconds. **`nuke`** is the end of a job: it deletes the instance and
its disk outright. Nothing is snapshotted — the durable state is the **golden image** plus
your **pushed git work**. The intended loop is: spin up a node for one GitHub issue, do the
work, push, then `nuke` all the way down to $0.

**`./vm/cleanup.sh`** goes further: it wipes *everything* billable in the project — all
instances, disks, the **golden image**, and any snapshots — after showing you the list and
asking to confirm (`-y` to skip). Use it to zero out completely; the next start then needs
a full `./vm/install.sh`.

## Files

- `vm/` — lifecycle: `install · create · fleet · reimage · start · stop · nuke · cleanup · ssh · push-repo · crd-setup`; `startup-script.sh` (bare-metal provisioner, baked) and `startup-golden.sh` (per-node boot wiring); `lib-bake.sh` (shared generalize + image helpers for `install`/`reimage`).
- `scripts/` — `push-build.sh` (build + install-over-tailnet) and `warm-repo.sh` (clone + Gradle warm), both baked to `/usr/local/bin` on the VM.
- `web/admin.py` — self-contained local admin dashboard (Python stdlib only; wraps the `vm/` scripts).
- `laptop/` — one-time phone/adb-over-Tailscale setup (`setup-macos.sh`) and an ACL example.

## Emulators (KVM / nested virtualization)

Android emulators need KVM. On GCP, nested virtualization is **Intel-only (VT-x)** — AMD
(N2D/C2D/C3D), E2, and Arm (T2A) never expose virtualization to the guest, *even though
the `--enable-nested-virtualization` flag is accepted on them*. Use an Intel N2/C-series:

```bash
# in .env
NESTED_VIRT=1
MACHINE=n2-standard-4        # or n2-standard-8 for a grid; must be Intel — NOT n2d/e2/t2
```

Then `./vm/create.sh` adds `--enable-nested-virtualization`, the node loads the KVM module
and opens `/dev/kvm` (udev rule, 0666) — so the baked `emulator` + `android-34` AVD
hardware-accelerate (headless, e.g. `emulator @android34 -no-window`). **Cost:** nested
virt adds no surcharge; you only pay the pricier machine (see below). Heads-up: even
accelerated, modern emulators are sluggish on GCP (no GPU → software rendering) — the
real-device Tailscale/adb loop (`push-build`) is the better path, which is why there's no
Studio and device-checking defaults to a real phone.

### Does it cost more?

Nested virt is free; the machine is the only difference. Rough us-west1 on-demand $/hr:

| Machine | vCPU / RAM | ~$/hr | Nested virt? |
|---|---|---|---|
| `e2-standard-4` (default) | 4 / 16 GB | 0.134 | ❌ E2 |
| `n2d-standard-4` (AMD) | 4 / 16 GB | ~0.17 | ❌ AMD (flag lies) |
| `n2-standard-4` (Intel) | 4 / 16 GB | ~0.19 | ✅ |
| `n2-standard-8` (Intel) | 8 / 32 GB | ~0.39 | ✅ |

The cheapest option that actually works is **`n2-standard-4`** (~45% more than the E2
default for the same size); `n2-standard-8` is ~2.9× but twice the machine — better for a
multi-emulator grid. You only pay while running.
