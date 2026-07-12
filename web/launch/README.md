# Launch nodes from CI (and a button page)

Boot golden-image nodes on GCP without your laptop: a GitHub Actions workflow
(`.github/workflows/launch.yml`) does the `./vm/create.sh --headless` run on a hosted
runner, and a token-gated web page (`web/launch/index.html`, deployed to GitHub Pages by
`.github/workflows/pages.yml`) dispatches it with one click.

```
button page (Pages) ──REST──▶ launch.yml (Actions) ──WIF──▶ gcloud ─▶ new GCE node
   your PAT, in-browser         repo secrets/vars        keyless      from golden image
```

The golden image must already exist — bake it once locally (`./vm/bake.sh`). CI only
creates nodes from it; it never bakes and never registers a Chrome Remote Desktop desktop
(those need a TTY). Every CI node is headless: SSH / Claude only.

## 1. Keyless GCP auth (Workload Identity Federation)

One-time, run locally with an owner-level `gcloud`. Replace `PROJECT_ID`, and keep `REPO`
as `bmander/android-dev-env`.

```bash
PROJECT_ID=reclamation-game
REPO=bmander/android-dev-env
PROJECT_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# Service account the workflow acts as
gcloud iam service-accounts create android-dev-ci \
  --project="$PROJECT_ID" --display-name="androiddevenv CI launcher"
SA="android-dev-ci@${PROJECT_ID}.iam.gserviceaccount.com"

# It creates/deletes instances and attaches the default compute SA (for --scopes)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role="roles/compute.instanceAdmin.v1"
gcloud iam service-accounts add-iam-policy-binding \
  "${PROJECT_NUM}-compute@developer.gserviceaccount.com" --project="$PROJECT_ID" \
  --member="serviceAccount:$SA" --role="roles/iam.serviceAccountUser"

# WIF pool + GitHub provider, restricted to this repo
gcloud iam workload-identity-pools create github \
  --project="$PROJECT_ID" --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc github \
  --project="$PROJECT_ID" --location=global --workload-identity-pool=github \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'"

# Let only this repo impersonate the SA
gcloud iam service-accounts add-iam-policy-binding "$SA" --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

# Print the two values you'll paste into repo Variables below
echo "GCP_WIF_PROVIDER=projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github/providers/github"
echo "GCP_SERVICE_ACCOUNT=${SA}"
```

> The workflow's post-create steps `gcloud compute ssh` into the new node (over its external
> IP — same as your laptop already does), so the runner needs SSH reach: keep the default
> `allow-ssh` firewall (tcp:22) in place, and if the project uses **OS Login**, also grant the
> SA `roles/compute.osAdminLogin`. If SSH is blocked the job fails at its 30-min timeout
> rather than hanging (the node is still created).

## 2. Repo Variables and Secrets

Settings → Secrets and variables → Actions.

**Variables** (not sensitive):

| Name | Example | Notes |
|---|---|---|
| `GCP_PROJECT` | `reclamation-game` | required |
| `GCP_ZONE` | `us-west1-b` | required |
| `GCP_WIF_PROVIDER` | *(from step 1)* | required |
| `GCP_SERVICE_ACCOUNT` | *(from step 1)* | required |
| `PHONE_TS_HOST` | `100.x.y.z` | phone's tailnet IP for `push-build` |
| `MACHINE` | `e2-standard-4` | default machine (input can override) |
| `DISK_GB` | `60` | optional |
| `GIT_REPO` | `https://github.com/you/app.git` | optional: auto-clone + Gradle warm |
| `GIT_BRANCH` / `GRADLE_WARM_TASK` | | optional |

**Secrets** (sensitive):

| Name | Notes |
|---|---|
| `TAILSCALE_AUTHKEY` | required — **reusable** key (each node joins the tailnet) |
| `GH_CLONE_TOKEN` | optional — PAT to clone a **private** `GIT_REPO` (this repo's built-in token can't read other repos) |
| `CLAUDE_CODE_OAUTH_TOKEN` | optional — from `claude setup-token`; preferred over the API key |
| `ANTHROPIC_API_KEY` | optional — alternative Claude auth for workers |

## 3. The button page (GitHub Pages)

1. Push these files to `main`. `pages.yml` builds the page.
2. Settings → **Pages → Source: GitHub Actions**. The deploy publishes to
   `https://bmander.github.io/android-dev-env/`.
3. Open it, expand **Setup**, and paste a **fine-grained PAT**: repo access
   `bmander/android-dev-env`, permission **Actions: Read and write**. It's stored only in
   your browser's `localStorage` and sent only to `api.github.com`.

> **Pages is public on non-Enterprise accounts** — the URL is reachable by anyone, but the
> page holds no secrets and can't do anything without your PAT. Prefer nothing public? Skip
> step 2 and just open `web/launch/index.html` as a local `file://` — the same buttons work.

## Triggering without the page

- **Actions tab:** *Launch android-dev node* → *Run workflow*, fill the inputs.
- **CLI:** `gh workflow run launch.yml -f action=create -f name=issue-1234 -f issue=1234`
- **REST:** `POST /repos/OWNER/REPO/actions/workflows/launch.yml/dispatches` with
  `{"ref":"main","inputs":{...}}` — exactly what the page does.

## Prefer GCP-native? Instance template + MIG

Most of what a launcher/dashboard would do already exists in Google Cloud — you don't have to
drive it from here. Bake the config into GCP primitives once:

```bash
./vm/template.sh          # build instance template android-dev-tmpl (mirrors create.sh)
./vm/mig.sh up 3          # a Managed Instance Group of 3 headless workers (target size)
./vm/mig.sh down          # target size 0
```

Then launch and manage without this repo at all:

- **Create a node:** Console → *Compute Engine → Instance templates → android-dev-tmpl → Create VM*,
  or `gcloud compute instances create NAME --source-instance-template=android-dev-tmpl`.
- **Fleet size:** Console → *Instance groups → android-dev-mig → Edit → Number of instances*
  (a slider), or `./vm/mig.sh up N`. A MIG **self-heals** — to shrink, resize down; deleting a
  member just respawns it.
- **Start / stop / delete / SSH:** the Console instances list and the **Google Cloud mobile app**.
- **Cost:** *Billing → Reports* (real numbers) and a **Budget alert** — better than any estimate here.
- **No laptop, no CI:** run `./vm/create.sh` straight from **Cloud Shell** (browser, pre-authed gcloud).

The page's **Manage on GCP** card deep-links to these. Re-run `./vm/template.sh --force` after
changing `.env`/`startup-golden.sh`, then `./vm/mig.sh set-template` to roll the fleet forward.
The template stores the reusable Tailscale key + tokens in its metadata (in your private GCP
project, not the public repo) — rotate the template when those keys change.

**When to still use the workflow/page:** per-issue workers (`--issue N`) — the template can't
carry per-instance metadata or do the SSH kick that starts the worker without a human login.

## Teardown

`launch.yml` covers `create` / `fleet-up` / `fleet-down`; `./vm/mig.sh down` zeroes the fleet.
To `stop`/`nuke` a specific node or do a full `cleanup`, use the Console, the `./admin`
dashboard, or `./vm/*.sh` — those read live instance state, which a fire-and-forget page can't.
