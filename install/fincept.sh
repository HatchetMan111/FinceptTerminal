#!/usr/bin/env bash
# =====================================================================
# FinceptTerminal · Proxmox LXC Installer (Community-Scripts-Stil)
# Läuft auf dem PROXMOX-HOST (nicht im Container).
# Erstellt einen LXC, installiert FinceptTerminal (.deb) + Web-Portal
# (0.0.0.0:8080) + optional noVNC-Desktop (:6080), alles systemd +
# reboot-sicher, mit Selbst-Verifikation am Ende.
#
# Einzeiler (nach Push in DEIN Repo):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main/install/fincept.sh)"
# Debug bei Fehlern:
#   bash -x fincept.sh
# =====================================================================
set -euo pipefail

# ---------------- Variablen (oben, alles einstellbar) ----------------
APP="fincept"
APP_NAME="FinceptTerminal"
DEFAULT_HOSTNAME="finceptterminal"
DEFAULT_CPU=2
DEFAULT_RAM=2048        # MB
DEFAULT_DISK=8          # GB
DEFAULT_PORT=8080
DEFAULT_NOVNC_PORT=6080
DEFAULT_VERSION="4.5.0"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
UPSTREAM_REPO="https://github.com/Fincept-Corporation/FinceptTerminal"
# RAW-Basis DEINES Repos (Portal + Units werden von hier in den LXC geladen).
# Nach dem Push anpassen, z. B. REPO_RAW="https://raw.githubusercontent.com/DEINUSER/DEINREPO/main"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main}"

# CLI-Overrides (alle optional; ohne Angaben -> interaktives Menü)
CTID_ARG=""; HOSTNAME_ARG=""; STORAGE_ARG=""; CPU_ARG=""; RAM_ARG=""
DISK_ARG=""; IP_ARG=""; PORT_ARG=""; VERSION_ARG=""; UNATTENDED=0

usage() {
  cat <<EOF
Usage: fincept.sh [Optionen]
  --ctid ID --hostname NAME --storage STOR --cpu N --ram MB --disk GB
  --ip dhcp|192.168.1.50/24,gw=192.168.1.1 --port 8080 --version 4.5.0
  --unattended   keine Dialoge, nur Defaults/Flags
  --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ctid) CTID_ARG="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --cpu) CPU_ARG="$2"; shift 2;;
    --ram) RAM_ARG="$2"; shift 2;;
    --disk) DISK_ARG="$2"; shift 2;;
    --ip) IP_ARG="$2"; shift 2;;
    --port) PORT_ARG="$2"; shift 2;;
    --version) VERSION_ARG="$2"; shift 2;;
    --unattended) UNATTENDED=1; shift;;
    --help|-h) usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1;;
  esac
done

# ------------- Fehlerkette: immer alles ausgeben, nie 1 Zeile --------
fail() {
  local code=$?
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━ FEHLER ━━━━━━━━━━━━━━━━" >&2
  echo "Schritt : ${STEP:-init} (Exit-Code: ${code})" >&2
  echo "Befehl  : ${BASH_COMMAND}" >&2
  echo "Stack   :" >&2
  local i=0; while caller $i >&2; do i=$((i+1)); done || true
  echo "" >&2
  echo "Debug: Script speichern + mit Trace laufen lassen:" >&2
  echo "  wget -qO /tmp/fincept-debug.sh ${REPO_RAW}/install/fincept.sh && bash -x /tmp/fincept-debug.sh" >&2
  echo "Logs im LXC: pct enter <CTID> -> journalctl -u fincept-portal -n 100 --no-pager" >&2
  exit "${code:-1}"
}
trap fail ERR

msg()  { echo -e "\033[1;32m[fincept]\033[0m $*"; }
warn() { echo -e "\033[1;33m[fincept]\033[0m $*"; }

STEP="Vorprüfung"
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden – kein Proxmox-Host?" >&2; exit 1; }

ask() { # ask VAR PROMPT DEFAULT (whiptail oder unattended)
  local var="$1" prompt="$2" def="$3" val=""
  if [ "$UNATTENDED" -eq 1 ]; then echo "$def"; return; fi
  if command -v whiptail >/dev/null && [ -t 0 ]; then
    val=$(whiptail --inputbox "$prompt" 10 70 "$def" 3>&1 1>&2 2>&3 || echo "$def")
    echo "$val"
  else
    read -rp "$prompt [$def]: " val; echo "${val:-$def}"
  fi
}

# ID-Belegung prüfen: Container (pct) UND VMs (qm) teilen sich den ID-Raum!
id_taken() {
  local id="$1"
  if pct status "$id" >/dev/null 2>&1; then return 0; fi
  if command -v qm >/dev/null && qm status "$id" >/dev/null 2>&1; then return 0; fi
  return 1
}

next_ctid() {
  local id=100
  while id_taken "$id"; do id=$((id+1)); done
  echo "$id"
}

STEP="Konfiguration"
CTID="${CTID_ARG:-$(ask CTID 'Container-ID (CTID)' "$(next_ctid)")}"
HOSTNAME="${HOSTNAME_ARG:-$(ask HOSTNAME 'Hostname' "$DEFAULT_HOSTNAME")}"
STORAGE="${STORAGE_ARG:-$(ask STORAGE 'Storage für Disk (pvesm status)' "$DEFAULT_STORAGE")}"
CPU="${CPU_ARG:-$(ask CPU 'vCPU Kerne' "$DEFAULT_CPU")}"
RAM="${RAM_ARG:-$(ask RAM 'RAM in MB' "$DEFAULT_RAM")}"
DISK="${DISK_ARG:-$(ask DISK 'Disk in GB' "$DEFAULT_DISK")}"
IPCFG="${IP_ARG:-$(ask IP 'IP: dhcp oder z.B. 192.168.1.50/24,gw=192.168.1.1' "dhcp")}"
PORT="${PORT_ARG:-$(ask PORT 'Web-Portal Port' "$DEFAULT_PORT")}"
VERSION="${VERSION_ARG:-$(ask VERSION 'Fincept Release-Version (z.B. 4.5.0)' "$DEFAULT_VERSION")}"

if [ "$IPCFG" = "dhcp" ]; then NETCONF="name=eth0,bridge=${DEFAULT_BRIDGE},ip=dhcp"; else NETCONF="name=eth0,bridge=${DEFAULT_BRIDGE},ip=${IPCFG}"; fi

NOVNC="1"
if [ "$UNATTENDED" -eq 0 ] && command -v whiptail >/dev/null && [ -t 0 ]; then
  whiptail --yesno "noVNC-Desktop (Fincept-GUI im Browser auf :${DEFAULT_NOVNC_PORT}) mit installieren? (empfohlen)" 10 70 && NOVNC="1" || NOVNC="0"
fi

echo ""
msg "Konfiguration: CTID=$CTID host=$HOSTNAME cpu=$CPU ram=${RAM}MB disk=${DISK}G ip=$IPCFG portal=:$PORT novnc=$NOVNC version=$VERSION"
msg "Raw-Quelle für Portal/Units: $REPO_RAW"
echo ""

# ------ Belegte CTID -> automatisch nächste freie nehmen (kein Abbruch) -----
# (prüft Container UND VMs, da beide denselben ID-Raum nutzen)
if id_taken "$CTID"; then
  warn "ID $CTID ist belegt (Container oder VM) – nehme automatisch die nächste freie ID."
  while id_taken "$CTID"; do CTID=$((CTID+1)); done
  msg "Neue CTID: $CTID"
fi
RECREATE=1

# ---------------- Template sicherstellen -----------------------------
if [ "$RECREATE" -eq 1 ]; then
  STEP="Template"
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$(echo "$TEMPLATE" | cut -d_ -f1)"; then
    msg "Aktualisiere Template-Liste + lade $TEMPLATE ..."
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi

  STEP="CT erstellen"
  msg "Erstelle LXC $CTID ($HOSTNAME, ${CPU}c/${RAM}MB/${DISK}G, onboot=1) ..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" --storage "$STORAGE" --rootfs "${STORAGE}:${DISK}" \
    --cores "$CPU" --memory "$RAM" --swap 512 \
    --net0 "$NETCONF" --onboot 1 --start 1 \
    --features nesting=1 --unprivileged 1 \
    --nameserver 1.1.1.1 --searchdomain local
  pct set "$CTID" --onboot 1
  msg "Warte auf Container-Netzwerk ..."
  for i in $(seq 1 30); do pct exec "$CTID" -- true 2>/dev/null && break; sleep 2; done
  pct start "$CTID" || true
  sleep 5
fi

# ---------------- Payload im Container installieren ------------------
STEP="Installation im Container"
msg "Installiere FinceptTerminal $VERSION + Portal (Port $PORT) in CT $CTID ..."
pct exec "$CTID" -- bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo '[1/6] apt + Abhängigkeiten ...'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl wget gnupg \
  python3 libglib2.0-0 libdbus-1-3 libfontconfig1 libfreetype6 libx11-6 \
  libxcb1 libxkbcommon0 libegl1 libgl1 \
  xvfb openbox x11vnc websockify novnc net-tools iproute2 \
  dbus-x11 xterm x11-xserver-utils procps \
  libxkbcommon-x11-0 libxcb-cursor0 python3-pyxdg menu
echo '[2/6] FinceptTerminal .deb ($VERSION) ...'
if dpkg -s finceptterminal 2>/dev/null | grep -q 'Version: $VERSION'; then
  echo '  bereits installiert: $VERSION – überspringe Download.'
else
  set -x
  wget -qO /tmp/fincept.deb '$UPSTREAM_REPO/releases/download/v$VERSION/FinceptTerminal-$VERSION-linux-x64.deb'
  apt-get install -y /tmp/fincept.deb
  rm -f /tmp/fincept.deb
  set +x
fi
echo '[2b/6] Qt 6.8.3 Laufzeit via aqtinstall (Upstream-Pin, wie Dockerfile) ...'
QT_ROOT=/opt/Qt/6.8.3/gcc_64
if [ -f \"\$QT_ROOT/lib/libQt6Core.so.6\" ]; then
  echo '  Qt 6.8.3 bereits vorhanden – überspringe Download.'
else
  apt-get install -y --no-install-recommends python3-pip
  pip3 install --break-system-packages --no-cache-dir aqtinstall
  for attempt in 1 2 3 4 5; do
    python3 -m aqt install-qt linux desktop 6.8.3 linux_gcc_64 \
      --outputdir /opt/Qt --modules qtcharts qtwebsockets qtmultimedia qtwebengine 2>&1 | tail -5 && break \
    || { echo \"  aqtinstall Versuch \$attempt fehlgeschlagen, retry in 10s ...\"; sleep 10; }
  done
  [ -f \"\$QT_ROOT/lib/libQt6Core.so.6\" ] || { echo 'FEHLER: Qt-Installation unvollstaendig' >&2; ls -R /opt/Qt 2>/dev/null | head -20 >&2 || true; exit 1; }
fi
cat > /etc/fincept/qt.env <<EOF2
QT_ROOT=\$QT_ROOT
LD_LIBRARY_PATH=\$QT_ROOT/lib:/usr/local/lib
QT_PLUGIN_PATH=\$QT_ROOT/plugins
QT_QPA_PLATFORM_PLUGIN_PATH=\$QT_ROOT/plugins/platforms
QTWEBENGINE_CHROMIUM_FLAGS=--no-sandbox --disable-gpu --disable-dev-shm-usage
EOF2
echo '[2c/6] ldd-Check auf fehlende Libs ...'
ldd /usr/bin/FinceptTerminal > /tmp/fincept-ldd.txt 2>&1 || true
if grep -q 'not found' /tmp/fincept-ldd.txt; then
  echo '  WARN: fehlende Libs, versuche Debian-Pakete:'
  grep 'not found' /tmp/fincept-ldd.txt || true
  apt-get install -y --no-install-recommends libgl1 libegl1 libopengl0 libgl1-mesa-dri libdbus-1-3 libfontconfig1 libfreetype6 libglib2.0-0 libx11-6 libxkbcommon0 libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-sync1 libxcb-xfixes0 libxcb-xinerama0 libxcb-xkb1 libxcb-util1 libpulse0 libasound2 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libatspi2.0-0 libxcursor1 || true
  ldd /usr/bin/FinceptTerminal > /tmp/fincept-ldd.txt 2>&1 || true
  if grep -q 'not found' /tmp/fincept-ldd.txt; then
    echo 'FEHLER: Libs fehlen weiterhin:' >&2; grep 'not found' /tmp/fincept-ldd.txt >&2 || true
  else
    echo '  alle Libs aufgeloest.'
  fi
else
  echo '  alle Libs aufgeloest.'
fi
echo '[3/6] Portal + Units von $REPO_RAW ...'
mkdir -p /opt/fincept-portal /etc/fincept /usr/local/bin
for f in portal/app.py portal/fincept-vnc-start.sh systemd/fincept-portal.service systemd/fincept-vnc.service; do
  wget -qO \"/tmp/\$(basename \$f)\" \"$REPO_RAW/\$f\" || echo \"WARN: \$f nicht ladbar (Repo noch nicht gepusht?) – nutze eingebetteten Fallback falls vorhanden\"
done
[ -s /tmp/app.py ] && cp /tmp/app.py /opt/fincept-portal/app.py
[ -s /tmp/fincept-vnc-start.sh ] && cp /tmp/fincept-vnc-start.sh /usr/local/bin/fincept-vnc-start.sh
[ -s /tmp/fincept-portal.service ] && cp /tmp/fincept-portal.service /etc/systemd/system/fincept-portal.service
[ -s /tmp/fincept-vnc.service ] && cp /tmp/fincept-vnc.service /etc/systemd/system/fincept-vnc.service
chmod +x /usr/local/bin/fincept-vnc-start.sh || true
python3 -m py_compile /opt/fincept-portal/app.py
echo '[4/6] Konfiguration ...'
FINCEPT_BIN=\"\$(command -v FinceptTerminal 2>/dev/null || dpkg -L finceptterminal 2>/dev/null | grep -m1 '/FinceptTerminal\$' || echo /usr/bin/FinceptTerminal)\"
echo \"  Fincept-Binary: \$FINCEPT_BIN\"
cat > /etc/fincept/portal.conf <<EOF2
PORT=$PORT
FINCEPT_VERSION=$VERSION
NOVNC_ENABLED=$NOVNC
NOVNC_PORT=$DEFAULT_NOVNC_PORT
FINCEPT_BIN=\$FINCEPT_BIN
EOF2
id fincept >/dev/null 2>&1 || useradd -r -m -s /usr/sbin/nologin fincept || true
echo '[5/6] systemd enable + start ...'
systemctl daemon-reload
systemctl enable --now fincept-portal.service
if [ '$NOVNC' = '1' ]; then systemctl enable --now fincept-vnc.service; else systemctl disable --now fincept-vnc.service || true; fi
echo '[6/6] done.'
"

# ---------------- Verifikation (vom Host aus) -------------------------
STEP="Verifikation"
msg "Verifiziere Service + Web UI ..."
pct exec "$CTID" -- systemctl is-active fincept-portal.service
if pct exec "$CTID" -- curl -sf "http://localhost:${PORT}/healthz"; then
  msg "Web UI antwortet auf localhost:${PORT}."
else
  echo "WARN: Portal antwortet (noch) nicht – Logs:" >&2
  pct exec "$CTID" -- journalctl -u fincept-portal.service -n 50 --no-pager >&2 || true
  exit 1
fi

msg "Warte auf Fincept-Prozess (Qt-Start braucht Sekunden) ..."
sleep 10
if pct exec "$CTID" -- pgrep -af FinceptTerminal | grep -v pgrep; then
  msg "Fincept-Prozess läuft – VNC sollte Bild zeigen."
else
  warn "Fincept-Prozess läuft NICHT – Diagnose:"
  pct exec "$CTID" -- journalctl -u fincept-vnc.service -n 30 --no-pager >&2 || true
  pct exec "$CTID" -- bash -c "ldd /usr/bin/FinceptTerminal 2>/dev/null | grep 'not found'" >&2 || true
fi

CTIP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "━━━━━━━━━━━━━━━━ FERTIG ━━━━━━━━━━━━━━━━"
echo "  $APP_NAME läuft in LXC $CTID ($HOSTNAME)"
echo "  Portal : http://${CTIP}:${PORT}   (lokal im LXC: http://localhost:${PORT})"
if [ "$NOVNC" = "1" ]; then
echo "  Desktop: http://${CTIP}:${DEFAULT_NOVNC_PORT}/vnc.html"
fi
echo "  Update : Portal öffnen -> 'Fincept Update' oder Script erneut laufen lassen"
echo "  Deinst.: pct stop $CTID && pct destroy $CTID"
echo "  Reboot : CT ist onboot=1, Services sind systemctl-enabled (Restart=always)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
