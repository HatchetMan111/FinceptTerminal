#!/usr/bin/env bash
# Startet Fincept-Desktop headless: Xvfb -> openbox -> Fincept -> x11vnc -> noVNC.
# Wird von fincept-vnc.service aufgerufen. Volle Fehlerkette dank set -x.
set -euo pipefail
[ -f /etc/fincept/portal.conf ] && . /etc/fincept/portal.conf
NOVNC_PORT="${NOVNC_PORT:-6080}"

echo "[fincept-vnc] Starte Xvfb :99 ..."
Xvfb :99 -screen 0 1600x900x24 &
XVFB_PID=$!
sleep 2

echo "[fincept-vnc] Starte openbox ..."
DISPLAY=:99 openbox-session &
sleep 1

echo "[fincept-vnc] Starte FinceptTerminal ..."
DISPLAY=:99 /usr/bin/FinceptTerminal &
APP_PID=$!
sleep 2

echo "[fincept-vnc] Starte x11vnc auf :99 ..."
x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -quiet &
VNC_PID=$!
sleep 1

echo "[fincept-vnc] Starte websockify/noVNC auf 0.0.0.0:${NOVNC_PORT} ..."
exec websockify --web=/usr/share/novnc/ "0.0.0.0:${NOVNC_PORT}" localhost:5900
