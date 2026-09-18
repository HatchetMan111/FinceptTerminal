#!/usr/bin/env python3
"""Fincept LXC Web-Portal (stdlib only, keine pip-Abhängigkeiten).

Läuft als systemd-Service auf 0.0.0.0:8080 und erlaubt:
- Status von FinceptTerminal (.deb) + Services einsehen
- Start/Stop/Restart, Update (.deb neu installieren), Logs ansehen
- Einstellungen ändern (Port, Release-Pin, noVNC an/aus, Autostart)
- Link zum noVNC-Desktop (Fincept Qt-GUI im Browser)

Konfiguration: /etc/fincept/portal.conf (KEY=VALUE)
"""
import html
import json
import os
import socket
import subprocess
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF_PATH = "/etc/fincept/portal.conf"
APP_NAME = "FinceptTerminal"
DEB_VERSION_DEFAULT = "4.5.0"


def load_conf() -> dict:
    conf = {
        "PORT": "8080",
        "FINCEPT_VERSION": DEB_VERSION_DEFAULT,
        "NOVNC_ENABLED": "1",
        "NOVNC_PORT": "6080",
    }
    try:
        with open(CONF_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    # ENV überschreibt Datei (für systemd EnvironmentFile + Tests)
    for k in list(conf):
        if k in os.environ:
            conf[k] = os.environ[k]
    return conf


def save_conf(conf: dict) -> None:
    os.makedirs(os.path.dirname(CONF_PATH), exist_ok=True)
    with open(CONF_PATH, "w") as f:
        f.write("# Fincept LXC Portal Konfiguration (wird vom Web-UI verwaltet)\n")
        for k in ("PORT", "FINCEPT_VERSION", "NOVNC_ENABLED", "NOVNC_PORT"):
            f.write(f"{k}={conf.get(k, '')}\n")


def run(cmd: list, timeout: int = 30) -> dict:
    """Führt ein Kommando aus, gibt IMMER volle Kette zurück (stdout/stderr/code)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"cmd": " ".join(cmd), "code": p.returncode,
                "stdout": p.stdout[-4000:], "stderr": p.stderr[-4000:]}
    except Exception as e:
        return {"cmd": " ".join(cmd), "code": -1, "stdout": "",
                "stderr": f"{e}\n{traceback.format_exc()[-2000:]}"}


def svc_active(unit: str) -> str:
    r = run(["systemctl", "is-active", unit])
    return (r["stdout"] or r["stderr"]).strip() or "unknown"


def fincept_version() -> str:
    r = run(["dpkg-query", "-W", "-f=${Version}", "finceptterminal"])
    v = (r["stdout"] or "").strip()
    if v and r["code"] == 0:
        return v
    r2 = run(["/usr/bin/FinceptTerminal", "--version"])
    if r2["code"] != 0:
        return "nicht installiert"
    out = (r2["stdout"] + r2["stderr"]).strip()
    return out.splitlines()[0][:120] if out else "nicht installiert"


def local_ips() -> list:
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except Exception:
        pass
    r = run(["hostname", "-I"])
    for ip in (r["stdout"] or "").split():
        if ip not in ips:
            ips.append(ip)
    return ips or ["<unbekannt>"]


PAGE = """<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FinceptTerminal · LXC Portal</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0b1220;color:#e5e9f0;margin:0}
header{background:#0f1b33;border-bottom:1px solid #22314f;padding:16px 24px}
h1{margin:0;font-size:20px}h1 small{color:#8ea0c2;font-weight:400}
main{max-width:960px;margin:0 auto;padding:24px;display:grid;gap:16px}
.card{background:#111d36;border:1px solid #22314f;border-radius:12px;padding:18px}
.card h2{margin:0 0 10px;font-size:15px;color:#9db4dd;text-transform:uppercase;letter-spacing:.06em}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
button,a.btn{background:#2563eb;color:#fff;border:0;border-radius:8px;padding:9px 16px;cursor:pointer;text-decoration:none;font-size:14px}
button.sec{background:#1e2b4a}button.danger{background:#b91c1c}
code,pre{background:#0a1122;border:1px solid #22314f;border-radius:8px;padding:8px;display:block;overflow:auto;font-size:12.5px;white-space:pre-wrap}
label{display:grid;gap:4px;font-size:13px;color:#9db4dd}
input,select{background:#0a1122;color:#fff;border:1px solid #2b3d63;border-radius:8px;padding:8px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px}@media(max-width:700px){.grid2{grid-template-columns:1fr}}
.ok{color:#4ade80}.err{color:#f87171}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:6px 4px;border-bottom:1px solid #1d2a48}td:first-child{color:#9db4dd}
</style></head><body>
<header><h1>FinceptTerminal · LXC Portal <small>lokal · systemd · reboot-sicher</small></h1></header>
<main>
<div class="card"><h2>Status</h2><div id="status">lädt …</div></div>
<div class="card"><h2>Aktionen</h2><div class="row">
<button onclick="act('restart-portal')">Portal neu starten</button>
<button class="sec" onclick="act('restart-vnc')">noVNC neu starten</button>
<button class="sec" onclick="act('update')">Fincept Update (.deb)</button>
<button class="sec" onclick="logs('fincept-portal')">Portal-Logs</button>
<button class="sec" onclick="logs('fincept-vnc')">VNC-Logs</button>
</div><pre id="out">Bereit.</pre></div>
<div class="card"><h2>Einstellungen (alles im Browser änderbar)</h2>
<div class="grid2">
<label>Portal-Port<input id="PORT" value="8080"></label>
<label>Fincept Release-Pin<input id="FINCEPT_VERSION" value="4.5.0"></label>
<label>noVNC aktiviert<select id="NOVNC_ENABLED"><option value="1">an</option><option value="0">aus</option></select></label>
<label>noVNC-Port<input id="NOVNC_PORT" value="6080"></label>
</div><p></p><div class="row"><button onclick="save()">Speichern</button>
<a class="btn sec" href="/api/status" target="_blank">Status-JSON</a></div>
<p style="color:#8ea0c2;font-size:13px">Port-Änderung erfordert danach: <code>systemctl restart fincept-portal</code> (Button oben) + Firewall im LXC prüfen.</p></div>
<div class="card"><h2>Zugriff</h2><div id="links"></div></div>
</main>
<script>
async function j(u,o){const r=await fetch(u,o);const t=await r.text();try{return JSON.parse(t)}catch(e){return {raw:t}}}
async function refresh(){const s=await j('/api/status');const ok=c=>c==='active'?'<b class=ok>active</b>':'<b class=err>'+c+'</b>';
document.getElementById('status').innerHTML='<table>'
+'<tr><td>FinceptTerminal</td><td>'+s.fincept_version+'</td></tr>'
+'<tr><td>fincept-portal.service</td><td>'+ok(s.services['fincept-portal'])+'</td></tr>'
+'<tr><td>fincept-vnc.service</td><td>'+ok(s.services['fincept-vnc'])+'</td></tr>'
+'<tr><td>Container-IPs</td><td>'+s.ips.join(', ')+'</td></tr>'
+'<tr><td>Portal-Port</td><td>'+s.conf.PORT+'</td></tr>'
+'<tr><td>noVNC</td><td>'+(s.conf.NOVNC_ENABLED==='1'?'an (:'+s.conf.NOVNC_PORT+')':'aus')+'</td></tr></table>';
for(const k of ['PORT','FINCEPT_VERSION','NOVNC_ENABLED','NOVNC_PORT']){const el=document.getElementById(k);if(el&&s.conf[k])el.value=s.conf[k]}
const host=location.hostname;
document.getElementById('links').innerHTML='<div class=row>'
+'<a class=btn href="http://'+host+':'+s.conf.NOVNC_PORT+'/vnc.html" target=_blank>Fincept-Desktop öffnen (noVNC)</a>'
+'<a class=btn sec href="https://github.com/Fincept-Corporation/FinceptTerminal/releases" target=_blank>Releases</a></div>'
+'<p style=color:#8ea0c2>Portal: <code>http://'+host+':'+s.conf.PORT+'</code> · noVNC: <code>http://'+host+':'+s.conf.NOVNC_PORT+'/vnc.html</code></p>'}
async function act(a){document.getElementById('out').textContent='… '+a;const r=await j('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a})});document.getElementById('out').textContent=JSON.stringify(r,null,2).slice(0,4000);refresh()}
async function logs(u){const r=await j('/api/logs?unit='+u);document.getElementById('out').textContent=(r.stdout||'')+(r.stderr?'\nSTDERR:\n'+r.stderr:'')}
async function save(){const c={};for(const k of ['PORT','FINCEPT_VERSION','NOVNC_ENABLED','NOVNC_PORT'])c[k]=document.getElementById(k).value;const r=await j('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(c)});document.getElementById('out').textContent=JSON.stringify(r,null,2);refresh()}
refresh();setInterval(refresh,15000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "FinceptPortal/1.0"

    def _send(self, code: int, body: bytes, ctype: str = "text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj: dict):
        self._send(code, json.dumps(obj, ensure_ascii=False, indent=2).encode(),
                   "application/json; charset=utf-8")

    def do_GET(self):
        try:
            path = urllib.parse.urlparse(self.path).path
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if path in ("/", "/index.html"):
                self._send(200, PAGE.encode())
            elif path == "/api/status":
                conf = load_conf()
                self._json(200, {
                    "app": APP_NAME,
                    "fincept_version": fincept_version(),
                    "services": {
                        "fincept-portal": svc_active("fincept-portal.service"),
                        "fincept-vnc": svc_active("fincept-vnc.service"),
                    },
                    "ips": local_ips(),
                    "conf": conf,
                })
            elif path == "/api/logs":
                unit = (qs.get("unit", ["fincept-portal.service"])[0])
                if not unit.endswith(".service"):
                    unit += ".service"
                # Allowlist gegen Command-Injection
                if unit not in ("fincept-portal.service", "fincept-vnc.service"):
                    self._json(400, {"error": "unit nicht erlaubt", "unit": unit})
                    return
                self._json(200, run(["journalctl", "-u", unit, "-n", "100", "--no-pager"]))
            elif path == "/healthz":
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "not found", "path": path})
        except Exception:
            self._json(500, {"error": "exception", "trace": traceback.format_exc()[-3000:]})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            data = json.loads(raw.decode() or "{}")
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/action":
                action = data.get("action", "")
                if action == "restart-portal":
                    # verzögert, damit die HTTP-Antwort noch rausgeht
                    subprocess.Popen(["bash", "-lc",
                                      "sleep 1; systemctl restart fincept-portal.service"])
                    self._json(200, {"ok": True, "action": action,
                                     "note": "Portal startet neu – Seite in 3s neu laden"})
                elif action == "restart-vnc":
                    self._json(200, {"result": run(["systemctl", "restart", "fincept-vnc.service"])})
                elif action == "update":
                    conf = load_conf()
                    ver = conf.get("FINCEPT_VERSION", DEB_VERSION_DEFAULT)
                    url = (f"https://github.com/Fincept-Corporation/FinceptTerminal"
                           f"/releases/download/v{ver}/FinceptTerminal-{ver}-linux-x64.deb")
                    res = run(["bash", "-lc",
                               f"set -x; wget -qO /tmp/fincept.deb '{url}' && "
                               f"apt-get install -y /tmp/fincept.deb && rm -f /tmp/fincept.deb"])
                    self._json(200, {"url": url, "result": res})
                else:
                    self._json(400, {"error": "unbekannte action", "action": action,
                                     "erlaubt": ["restart-portal", "restart-vnc", "update"]})
            elif path == "/api/settings":
                conf = load_conf()
                for k in ("PORT", "FINCEPT_VERSION", "NOVNC_ENABLED", "NOVNC_PORT"):
                    if k in data and str(data[k]).strip():
                        conf[k] = str(data[k]).strip()
                # Validierung mit voller Fehlerkette statt stiller Korrektur
                try:
                    port = int(conf["PORT"])
                    assert 1 <= port <= 65535
                    assert conf["NOVNC_ENABLED"] in ("0", "1")
                    int(conf["NOVNC_PORT"])
                except Exception as e:
                    self._json(400, {"error": "ungültige Einstellungen",
                                     "detail": f"{e}\n{traceback.format_exc()[-1500:]}",
                                     "conf": conf})
                    return
                save_conf(conf)
                # noVNC-Service ggf. (de)aktivieren
                if conf["NOVNC_ENABLED"] == "1":
                    run(["systemctl", "enable", "--now", "fincept-vnc.service"])
                else:
                    run(["systemctl", "disable", "--now", "fincept-vnc.service"])
                self._json(200, {"ok": True, "conf": conf,
                                 "note": "Bei Port-Änderung danach 'Portal neu starten' klicken."})
            else:
                self._json(404, {"error": "not found"})
        except Exception:
            self._json(500, {"error": "exception", "trace": traceback.format_exc()[-3000:]})

    def log_message(self, *a):
        pass


def main():
    conf = load_conf()
    port = int(conf.get("PORT", "8080"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"Fincept-Portal auf 0.0.0.0:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
