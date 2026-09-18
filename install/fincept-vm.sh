#!/usr/bin/env bash
# =====================================================================
# FinceptTerminal · Proxmox VM Installer (für leistungshungrige Setups)
# Erstellt eine Debian-12 VM (Standard 4 vCPU / 8 GB RAM / 30 GB Disk),
# bootet sie via Cloud-Init und installiert darin dasselbe wie die
# LXC-Variante: FinceptTerminal (.deb) + Web-Portal (:8080) + noVNC.
# Einzeiler: bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main/install/fincept-vm.sh)"
# =====================================================================
set -euo pipefail

# ---------------- Variablen (oben) ----------------
VMID_ARG=""; STORAGE_ARG=""; BRIDGE_ARG=""; UNATTENDED=0
DEFAULT_CPU=4; DEFAULT_RAM=8192; DEFAULT_DISK=30
DEFAULT_VERSION="4.5.0"; DEFAULT_PORT=8080
CLOUD_IMG="debian-12-generic-amd64.qcow2"
CLOUD_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${CLOUD_IMG}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/HatchetMan111/FinceptTerminal/main}"
UPSTREAM_REPO="https://github.com/Fincept-Corporation/FinceptTerminal"

while [ $# -gt 0 ]; do case "$1" in
  --vmid) VMID_ARG="$2"; shift 2;; --storage) STORAGE_ARG="$2"; shift 2;;
  --bridge) BRIDGE_ARG="$2"; shift 2;; --unattended) UNATTENDED=1; shift;;
  --help|-h) echo "Usage: fincept-vm.sh [--vmid ID --storage STOR --bridge vmbr0 --unattended]"; exit 0;;
  *) echo "Unbekannt: $1" >&2; exit 1;;
esac; done

fail() { local c=$?; echo "FEHLER Schritt ${STEP:-init} (code $c): ${BASH_COMMAND}" >&2;
  echo "Debug: bash -x $0" >&2; exit $c; }
trap fail ERR
msg() { echo -e "\033[1;32m[fincept-vm]\033[0m $*"; }
ask() { if [ "$UNATTENDED" -eq 1 ]; then echo "$3"; return; fi
  if command -v whiptail >/dev/null && [ -t 0 ]; then whiptail --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3 || echo "$3";
  else read -rp "$2 [$3]: " v; echo "${v:-$3}"; fi; }

[ "$(id -u)" -eq 0 ] || { echo "Als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v qm >/dev/null || { echo "qm nicht gefunden – kein Proxmox-Host?" >&2; exit 1; }

STEP="Konfig"
next_vmid() { local id=200; while qm status "$id" >/dev/null 2>&1; do id=$((id+1)); done; echo "$id"; }
VMID="${VMID_ARG:-$(ask VMID 'VM-ID' "$(next_vmid)")}"
STORAGE="${STORAGE_ARG:-$(ask STORAGE 'Storage' "local-lvm")}"
BRIDGE="${BRIDGE_ARG:-$(ask BRIDGE 'Bridge' "vmbr0")}"
VERSION="$(ask VERSION 'Fincept Version' "$DEFAULT_VERSION")"
PORT="$(ask PORT 'Portal-Port' "$DEFAULT_PORT")"

STEP="Cloud-Image"
mkdir -p /var/lib/vz/template/iso
[ -f "/var/lib/vz/template/iso/${CLOUD_IMG}" ] || { msg "Lade Debian-12 Cloud-Image ..."; wget -qO "/var/lib/vz/template/iso/${CLOUD_IMG}" "$CLOUD_URL"; }

STEP="VM erstellen"
msg "Erstelle VM $VMID (${DEFAULT_CPU}c/${DEFAULT_RAM}MB/${DEFAULT_DISK}G, onboot=1) ..."
qm create "$VMID" --name fincept --memory "$DEFAULT_RAM" --cores "$DEFAULT_CPU" \
  --net0 "virtio,bridge=${BRIDGE}" --onboot 1 --agent enabled=1 \
  --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${DEFAULT_DISK},import-from=/var/lib/vz/template/iso/${CLOUD_IMG}" \
  --ide2 "${STORAGE}:cloudinit" --boot c --bootdisk scsi0 --serial0 socket --vga serial0 \
  --ipconfig0 ip=dhcp --ciuser fincept --cipassword fincept --sshkeys /root/.ssh/authorized_keys 2>/dev/null || \
qm create "$VMID" --name fincept --memory "$DEFAULT_RAM" --cores "$DEFAULT_CPU" \
  --net0 "virtio,bridge=${BRIDGE}" --onboot 1 --agent enabled=1 \
  --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${DEFAULT_DISK},import-from=/var/lib/vz/template/iso/${CLOUD_IMG}" \
  --ide2 "${STORAGE}:cloudinit" --boot c --bootdisk scsi0 --serial0 socket --vga serial0 \
  --ipconfig0 ip=dhcp
qm resize "$VMID" scsi0 "+${DEFAULT_DISK}G" 2>/dev/null || true
qm start "$VMID"

cat <<EOF
━━━━━━━━━━━━━━━━ VM ERSTELLT ━━━━━━━━━━━━━━━━
VM $VMID startet (Cloud-Init braucht 1–3 Min).
Danach in der VM als root ausführen:

  bash -c "\$(wget -qLO - ${REPO_RAW}/install/fincept.sh)" -- --unattended --port ${PORT} --version ${VERSION}

Tipp: IP herausfinden mit:  qm guest cmd $VMID network-get-interfaces
Portal danach: http://<VM-IP>:${PORT}
Deinstall: qm stop $VMID && qm destroy $VMID
EOF
