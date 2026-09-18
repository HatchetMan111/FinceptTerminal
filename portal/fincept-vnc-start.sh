#!/usr/bin/env bash
# Startet Fincept-Desktop headless: Xvfb -> openbox -> Fincept -> x11vnc -> noVNC.
# Wird von fincept-vnc.service aufgerufen. Alles landet im Journal
# (journalctl -u fincept-vnc.service) – volle Fehlerkette statt Blackbox.
set -euo pipefail
[ -f /etc/fincept/portal.conf ] && . /etc/fincept/portal.conf
[ -f /etc/fincept/qt.env ] && . /etc/fincept/qt.env || true
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" QT_PLUGIN_PATH="${QT_PLUGIN_PATH:-}" QT_QPA_PLATFORM_PLUGIN_PATH="${QT_QPA_PLATFORM_PLUGIN_PATH:-}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
FINCEPT_BIN="${FINCEPT_BIN:-/usr/bin/FinceptTerminal}"
export DISPLAY=:99
export QT_QPA_PLATFORM=xcb
export LIBGL_ALWAYS_SOFTWARE=1
export QT_XCB_GL_INTEGRATION=none
export XDG_RUNTIME_DIR=/run/fincept

log() { echo "[fincept-vnc] $*"; }

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# D-Bus (Qt/Openbox brauchen das, sonst stiller Absturz -> schwarz)
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)" 2>/dev/null || log "WARN: dbus-launch fehlgeschlagen"
fi

log "raume alte X-Reste auf ..."
pkill -f "Xvfb :99" 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99

log "starte Xvfb :99 ..."
Xvfb :99 -screen 0 1600x900x24 +extension GLX +render -noreset &
for _ in $(seq 1 30); do
  [ -e /tmp/.X11-unix/X99 ] && break
  sleep 1
done
if [ ! -e /tmp/.X11-unix/X99 ]; then
  log "FEHLER: Xvfb meldet kein Display nach 30s – breche ab"
  exit 1
fi

log "setze Hintergrund + Fallback-Terminal (falls App abstuerzt, kein Schwarz) ..."
xsetroot -solid "#1a2b4a" 2>/dev/null || true
xterm -geometry 100x30+20+20 -T "Fincept-Fallback" 2>/dev/null &

log "starte openbox ..."
openbox 2>/dev/null &
sleep 1

if [ -x "$FINCEPT_BIN" ]; then
  log "starte $FINCEPT_BIN ..."
  "$FINCEPT_BIN" &
  APP_PID=$!
  sleep 3
  if kill -0 "$APP_PID" 2>/dev/null; then
    log "Fincept-Prozess laeuft (PID $APP_PID)"
  else
    log "WARN: Fincept-Prozess sofort beendet – Binary manuell testen: DISPLAY=:99 $FINCEPT_BIN"
  fi
else
  log "WARN: $FINCEPT_BIN fehlt/nicht ausfuehrbar – suche: $(command -v FinceptTerminal 2>/dev/null || echo 'nicht im PATH')"
  log "WARN: installierte Dateien: $(dpkg -L finceptterminal 2>/dev/null | grep -m3 Fincept || echo 'paket unbekannt')"
fi

log "starte x11vnc auf Display :99 ..."
x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -quiet -noxdamage 2>/dev/null &
sleep 1

log "starte websockify/noVNC auf 0.0.0.0:${NOVNC_PORT} ..."
exec websockify --web=/usr/share/novnc/ "0.0.0.0:${NOVNC_PORT}" localhost:5900
