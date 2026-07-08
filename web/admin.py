#!/usr/bin/env python3
"""Tidy local admin webapp for the androiddevenv utility.

Runs on your laptop, serves a dashboard on 127.0.0.1, and shells out to the vm/
scripts + gcloud. No dependencies (Python 3 stdlib only), single file.

    python3 web/admin.py            # -> opens http://127.0.0.1:8787
    ADMIN_PORT=9000 python3 web/admin.py

Localhost-only by design: it executes lifecycle commands, so it must never be
network-exposed. Interactive one-offs (install/bake, CRD desktop registration)
still belong in a terminal; this covers day-to-day lifecycle: status, create a
headless node, start/stop/nuke, fleet up/down, and full cleanup.
"""
import json, os, re, subprocess, threading, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VM = ROOT / "vm"
PORT = int(os.environ.get("ADMIN_PORT", "8787"))
NAME_RE = re.compile(r"^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$")  # GCE instance-name rules

# Approx on-demand $/hr (us-west1); only used for a rough "running cost" readout.
PRICE = {
    "e2-standard-2": 0.067, "e2-standard-4": 0.134, "e2-standard-8": 0.268,
    "e2-standard-16": 0.536, "n2-standard-4": 0.194, "n2-standard-8": 0.388,
    "n2-standard-16": 0.776, "c3-standard-8": 0.42,
}

JOBS = {}                      # id -> {lines:[...], done:bool, rc:int|None, title:str}
LOCK = threading.Lock()


def sh_config():
    """Read PROJECT/ZONE the same way the scripts do (source vm/config.sh)."""
    p = subprocess.run(
        ["bash", "-c", f'source "{VM}/config.sh" >/dev/null 2>&1; printf "%s\\n%s\\n" "$PROJECT" "$ZONE"'],
        capture_output=True, text=True)
    out = (p.stdout or "").splitlines()
    return (out[0] if out else ""), (out[1] if len(out) > 1 else "")


PROJECT, ZONE = sh_config()


def gcloud_json(args):
    p = subprocess.run(["gcloud"] + args + ["--project", PROJECT, "--format=json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return []
    try:
        data = json.loads(p.stdout or "[]")
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def base(v):
    return str(v).rsplit("/", 1)[-1] if v else ""


def status():
    insts = []
    running_cost = 0.0
    for i in gcloud_json(["compute", "instances", "list"]):
        mt = base(i.get("machineType"))
        st = i.get("status", "")
        ip = ""
        for ni in i.get("networkInterfaces", []):
            for ac in ni.get("accessConfigs", []):
                ip = ac.get("natIP", "") or ip
        price = PRICE.get(mt)
        if st == "RUNNING" and price:
            running_cost += price
        insts.append({"name": i.get("name"), "zone": base(i.get("zone")), "machine": mt,
                      "status": st, "ip": ip, "price": price})
    imgs = [{"name": x.get("name"), "sizeGb": x.get("diskSizeGb")}
            for x in gcloud_json(["compute", "images", "list", "--no-standard-images"])]
    snaps = [{"name": x.get("name")} for x in gcloud_json(["compute", "snapshots", "list"])]
    disks = [{"name": x.get("name"), "zone": base(x.get("zone")), "sizeGb": x.get("sizeGb"),
              "users": [base(u) for u in (x.get("users") or [])]}
             for x in gcloud_json(["compute", "disks", "list"])]
    return {"project": PROJECT, "zone": ZONE, "instances": insts, "images": imgs,
            "snapshots": snaps, "disks": disks, "runningCostHr": round(running_cost, 3)}


def start_job(title, argv, env=None):
    jid = uuid.uuid4().hex[:12]
    with LOCK:
        JOBS[jid] = {"lines": ["$ " + " ".join(argv)], "done": False, "rc": None, "title": title}

    def worker():
        try:
            proc = subprocess.Popen(argv, cwd=str(ROOT), text=True, bufsize=1,
                                    stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    env={**os.environ, **(env or {})})
            for line in proc.stdout or ():
                with LOCK:
                    JOBS[jid]["lines"].append(line.rstrip("\n"))
            proc.wait()
            with LOCK:
                JOBS[jid]["rc"], JOBS[jid]["done"] = proc.returncode, True
        except Exception as e:  # noqa: BLE001
            with LOCK:
                JOBS[jid]["lines"].append(f"error: {e}")
                JOBS[jid]["rc"], JOBS[jid]["done"] = 1, True

    threading.Thread(target=worker, daemon=True).start()
    return jid


def dispatch(action, name, count):
    """Map a UI action to a fixed vm/ script invocation (no shell, validated args)."""
    def vm(script, *a):
        return ["bash", str(VM / script), *a]
    if action in ("start", "stop", "nuke"):
        if not NAME_RE.match(name or ""):
            return None, "invalid instance name"
        return start_job(f"{action} {name}", vm(f"{action}.sh", name)), None
    if action == "create":
        if not NAME_RE.match(name or ""):
            return None, "invalid instance name"
        # Headless from the webapp (no TTY): create.sh skips CRD/token prompts.
        return start_job(f"create {name}", vm("create.sh", name), env={"SKIP_CRD": "1"}), None
    if action == "fleet-up":
        if not (1 <= count <= 16):
            return None, "count must be 1-16"
        return start_job(f"fleet up {count}", vm("fleet.sh", "up", str(count))), None
    if action == "fleet-down":
        return start_job("fleet down", vm("fleet.sh", "down")), None
    if action == "cleanup":
        return start_job("cleanup (delete everything)", vm("cleanup.sh", "-y")), None
    return None, "unknown action"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):  # noqa: A002 — match base signature; stay quiet
        pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/api/status":
            return self._send(200, json.dumps(status()))
        if self.path.startswith("/api/job"):
            jid = self.path.split("id=")[-1]
            with LOCK:
                job = JOBS.get(jid)
                return self._send(200 if job else 404, json.dumps(job or {"error": "no such job"}))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path != "/api/action":
            return self._send(404, json.dumps({"error": "not found"}))
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or "{}")
        except json.JSONDecodeError:
            return self._send(400, json.dumps({"error": "bad json"}))
        jid, err = dispatch(body.get("action", ""), body.get("name", ""), int(body.get("count", 0) or 0))
        if err:
            return self._send(400, json.dumps({"error": err}))
        return self._send(200, json.dumps({"jobId": jid}))


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>androiddevenv admin</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--mut:#6b7280;--line:#e5e7eb;--accent:#2563eb;
 --run:#16a34a;--stop:#9ca3af;--danger:#dc2626;--term:#0b0f14;--termfg:#d7e0ea}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--mut:#8b949e;
 --line:#30363d;--accent:#4d8bf0;--term:#010409;--termfg:#c9d4e0}}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;
 background:var(--bg);color:var(--fg)}
header{display:flex;align-items:center;gap:16px;padding:14px 20px;border-bottom:1px solid var(--line);
 background:var(--card);position:sticky;top:0;flex-wrap:wrap}
h1{font-size:16px;margin:0;font-weight:650}
.meta{color:var(--mut);font-size:12.5px}
.cost{margin-left:auto;font-weight:650}
main{max-width:1000px;margin:0 auto;padding:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:18px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--mut);margin:0 0 12px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{font-size:12px;color:var(--mut);font-weight:600}td{font-size:13.5px}
tr:last-child td{border-bottom:0}
.badge{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11.5px;font-weight:600}
.b-run{background:color-mix(in srgb,var(--run) 18%,transparent);color:var(--run)}
.b-stop{background:color-mix(in srgb,var(--stop) 22%,transparent);color:var(--mut)}
.b-other{background:color-mix(in srgb,var(--accent) 16%,transparent);color:var(--accent)}
button{font:inherit;font-size:12.5px;padding:5px 11px;border:1px solid var(--line);border-radius:8px;
 background:var(--card);color:var(--fg);cursor:pointer}button:hover{border-color:var(--accent)}
button:disabled{opacity:.45;cursor:default}
.btn-danger{color:var(--danger);border-color:color-mix(in srgb,var(--danger) 40%,var(--line))}
.btn-primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
input{font:inherit;padding:5px 9px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg)}
input[type=number]{width:64px}.grow{flex:1}
.muted{color:var(--mut)}.tools .row{margin-bottom:10px}
#term{background:var(--term);color:var(--termfg);font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;
 padding:12px 14px;border-radius:10px;white-space:pre-wrap;max-height:320px;overflow:auto;margin-top:8px}
.hint{font-size:12px;color:var(--mut);margin-top:6px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px;background:var(--stop)}
.dot.on{background:var(--run)}
.empty{color:var(--mut);padding:6px 10px}
</style></head><body>
<header>
  <h1>🤖 androiddevenv</h1>
  <div class="meta"><span id="proj">…</span> · <span id="zone"></span></div>
  <div class="cost"><span class="dot" id="dot"></span><span id="cost">$0/hr</span></div>
  <button onclick="refresh()">↻ Refresh</button>
</header>
<main>
  <div class="card">
    <h2>Instances</h2>
    <table><thead><tr><th>Name</th><th>Machine</th><th>Status</th><th>IP</th><th>$/hr</th><th></th></tr></thead>
    <tbody id="insts"></tbody></table>
    <div class="empty" id="insts-empty" hidden>No instances.</div>
  </div>

  <div class="card tools">
    <h2>Actions</h2>
    <div class="row"><input id="newname" class="grow" placeholder="new node name (e.g. issue-1234)">
      <button class="btn-primary" onclick="create()">Create headless node</button></div>
    <div class="hint">Webapp-created nodes are headless (no desktop). For a CRD desktop / Studio, use <code>./vm/create.sh</code> in a terminal.</div>
    <div class="row" style="margin-top:12px"><span class="muted">Fleet:</span>
      <input id="fleetn" type="number" value="3" min="1" max="16">
      <button onclick="act('fleet-up',null,+document.getElementById('fleetn').value)">Up</button>
      <button onclick="act('fleet-down')">Down all</button></div>
    <div class="row" style="margin-top:12px"><span class="muted">Danger:</span>
      <button class="btn-danger" onclick="cleanup()">Cleanup — delete EVERYTHING ($0)</button></div>
  </div>

  <div class="card">
    <h2>Images &amp; snapshots</h2>
    <table><tbody id="artifacts"></tbody></table>
    <div class="empty" id="art-empty" hidden>No images or snapshots.</div>
  </div>

  <div class="card">
    <h2>Output</h2>
    <div id="term" class="muted">Idle. Run an action to see live output here.</div>
  </div>
</main>
<script>
let poll=null;
function esc(s){return (s??'').toString().replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
function badge(s){const c=s==='RUNNING'?'b-run':s==='TERMINATED'?'b-stop':'b-other';return `<span class="badge ${c}">${esc(s||'?')}</span>`;}

async function refresh(){
  const s=await (await fetch('/api/status')).json();
  document.getElementById('proj').textContent=s.project||'(set PROJECT in .env)';
  document.getElementById('zone').textContent=s.zone||'';
  document.getElementById('cost').textContent='$'+(s.runningCostHr||0)+'/hr';
  document.getElementById('dot').className='dot'+(s.runningCostHr>0?' on':'');
  const tb=document.getElementById('insts');tb.innerHTML='';
  document.getElementById('insts-empty').hidden=s.instances.length>0;
  for(const i of s.instances){
    const run=i.status==='RUNNING',term=i.status==='TERMINATED';
    const btns=`${term?`<button onclick="act('start','${i.name}')">Start</button>`:''}`
      +`${run?`<button onclick="act('stop','${i.name}')">Stop</button>`:''}`
      +`<button class="btn-danger" onclick="nuke('${i.name}')">Nuke</button>`;
    tb.insertAdjacentHTML('beforeend',`<tr><td><b>${esc(i.name)}</b><div class="muted" style="font-size:11.5px">${esc(i.zone)}</div></td>
      <td>${esc(i.machine)}</td><td>${badge(i.status)}</td><td class="muted">${esc(i.ip||'—')}</td>
      <td>${i.price?('$'+i.price):'<span class="muted">?</span>'}</td><td><div class="row">${btns}</div></td></tr>`);
  }
  const ar=document.getElementById('artifacts');ar.innerHTML='';
  const rows=[...s.images.map(x=>['image',x.name,(x.sizeGb||'?')+' GB']),
              ...s.snapshots.map(x=>['snapshot',x.name,'']),
              ...s.disks.filter(d=>!d.users.length).map(d=>['disk (orphan)',d.name,(d.sizeGb||'?')+' GB'])];
  document.getElementById('art-empty').hidden=rows.length>0;
  for(const [t,n,sz] of rows)
    ar.insertAdjacentHTML('beforeend',`<tr><td class="muted" style="width:130px">${t}</td><td><b>${esc(n)}</b></td><td class="muted">${esc(sz)}</td></tr>`);
}

async function act(action,name,count){
  const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({action,name,count})});
  const j=await r.json();
  if(j.error){alert(j.error);return;}
  watch(j.jobId);
}
function create(){const n=document.getElementById('newname').value.trim();
  if(!n){alert('enter a node name');return;} act('create',n);}
function nuke(n){if(confirm(`Nuke ${n}? This deletes the instance and its disk.`))act('nuke',n);}
function cleanup(){if(confirm('Delete ALL instances, disks, images and snapshots in this project? This cannot be undone.'))act('cleanup');}

async function watch(jid){
  const term=document.getElementById('term');term.classList.remove('muted');
  if(poll)clearInterval(poll);
  const tick=async()=>{
    const j=await (await fetch('/api/job?id='+jid)).json();
    term.textContent=(j.lines||[]).join('\n');term.scrollTop=term.scrollHeight;
    if(j.done){clearInterval(poll);poll=null;term.textContent+=`\n\n[exit ${j.rc}]`;refresh();}
  };
  poll=setInterval(tick,1000);tick();
}
refresh();setInterval(()=>{if(!poll)refresh();},5000);
</script></body></html>"""


if __name__ == "__main__":
    if not PROJECT:
        print("Warning: PROJECT is empty — set it in .env (see .env.example).")
    url = f"http://127.0.0.1:{PORT}"
    print(f"androiddevenv admin → {url}  (project: {PROJECT or 'UNSET'}, zone: {ZONE})")
    print("Ctrl-C to stop.")
    try:
        webbrowser.open(url)
    except Exception:  # noqa: BLE001
        pass
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
