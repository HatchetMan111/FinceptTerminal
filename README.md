# FinceptTerminal · Proxmox LXC Installer

Lokale Installation von [FinceptTerminal](https://github.com/Fincept-Corporation/FinceptTerminal)
(Finance-Analytics, Qt6/C++ Desktop-App) als **LXC auf Proxmox VE** – im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/),
mit **Einzeiler**, interaktivem Setup-Menü und **Weboberfläche zur Konfiguration**.

> Wichtig: FinceptTerminal ist nativ eine **Desktop-GUI ohne eigene Web-UI**.
> Dieser Installer legt deshalb zwei Web-Zugänge in den Container:
> - **Portal `:8080`** (eigener Code in `portal/`) – Status, Start/Stop, Logs,
>   Update, **alle Einstellungen im Browser änderbar** (Port, Release-Pin, noVNC an/aus)
> - **Desktop `:6080`** (noVNC) – die echte Fincept-GUI im Browser
>   (Xvfb + openbox + x11vnc + websockify)

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main/install/fincept.sh)"
```

Mit Parametern (ohne Dialoge):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main/install/fincept.sh)" -- --unattended --ctid 150 --port 8080 --version 4.5.0
```

VM-Variante (leistungshungrig, 4 vCPU / 8 GB RAM / 30 GB):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main/install/fincept-vm.sh)"
```

> Vor dem ersten Gebrauch: `HatchetMan111/FinceptTerminal` oben + `REPO_RAW` in
> `install/fincept.sh` durch **dein** Repo ersetzen und diesen Ordner pushen.
> Das Install-Script lädt Portal + Units per `wget` von dort in den LXC
> (GitHub-first, keine externen Cloud-Dienste zur Laufzeit).

## Was der Installer fragt (alles einstellbar)

CTID (nächste freie vorgeschlagen) · Hostname · Storage · vCPU (Std. 2) ·
RAM (Std. 2048 MB) · Disk (Std. 8 GB) · IP (`dhcp` oder `IP/CIDR,gw=...`) ·
Portal-Port (Std. 8080) · Release-Version (Std. 4.5.0) · noVNC an/aus

## Was am Ende läuft

| Dienst | Was | Erreichbar |
|---|---|---|
| `fincept-portal.service` | Web-Portal (Python stdlib, keine pip-Deps) | `http://<LXC-IP>:8080` |
| `fincept-vnc.service` | Fincept-Desktop im Browser | `http://<LXC-IP>:6080/vnc.html` |

- Bind an `0.0.0.0`, `Restart=always`, `After=network-online.target`,
  `systemctl enable` (reboot-sicher), Container `onboot: 1`
- Selbst-Verifikation: `systemctl is-active` + `curl localhost:8080/healthz`
- Volle Fehlerkette bei Problemen; Debug mit `bash -x install/fincept.sh`

## Dateien

```
install/fincept.sh          Host-Script: CT erstellen + alles installieren + verifizieren
install/fincept-vm.sh       Host-Script: VM-Variante (Cloud-Init Debian 12)
portal/app.py               Web-Portal (stdlib only, :8080)
portal/fincept-vnc-start.sh Xvfb/openbox/x11vnc/websockify-Starter
systemd/fincept-portal.service
systemd/fincept-vnc.service
README.md
```

## Update / Deinstallieren

- **Update:** Portal → Button „Fincept Update“ (installiert `.deb` der
  gepinnten Version neu). Das Script selbst ist bewusst **nicht** idempotent
  gegenüber bestehenden CTs: Ist die CTID belegt, nimmt es automatisch die
  nächste freie (kein Überschreiben, kein Abbruch).
- **Deinstallieren:** `pct stop <CTID> && pct destroy <CTID>`
  (VM: `qm stop <VMID> && qm destroy <VMID>`).

## Testdurchlauf (Erwartung)

```
[fincept] Konfiguration: CTID=150 host=fincept cpu=2 ram=2048MB disk=8G ...
[1/6] apt + Abhängigkeiten ...
[2/6] FinceptTerminal .deb (4.5.0) ...
[5/6] systemd enable + start ...
● fincept-portal.service - active (running)
{"ok": true}
━━━━━━━━━━━━━━━━ FERTIG ━━━━━━━━━━━━━━━━
  Portal : http://192.168.1.150:8080
  Desktop: http://192.168.1.150:6080/vnc.html
```

Reboot-Test: `pct reboot <CTID>` → nach ~30 s beide URLs wieder erreichbar
(`curl http://<IP>:8080/healthz`).

## Lizenz-Hinweis

FinceptTerminal steht unter **AGPL-3.0** (strong copyleft). Wer den Container
als Service für Dritte betreibt oder verändert verteilt, muss Änderungen unter
gleicher Lizenz veröffentlichen. Portal-Code in diesem Ordner: eigene Ergänzung –
Lizenz deines Repos beachten.
