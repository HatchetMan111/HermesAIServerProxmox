#!/usr/bin/env bash
# Proxmox Host: Hermes LXC mit Direkt-WebUI erstellen (für dein eigenes GitHub-Repo)
# Auf dem PROXMOX HOST als root ausführen:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/ct/create-lxc.sh | bash
# Alternativ interaktiv mit Variablen unten.
set -euo pipefail

# --- Einstellungen ---------------------------------------------------------------
CTID="${CTID:-112}"
HOSTNAME="${HOSTNAME:-hermes-webui}"
TEMPLATE="${TEMPLATE:-debian-13-standard_13.1-1_amd64.tar.zst}"
STORAGE="${STORAGE:-local-lvm}"     # Container-Disks
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # CT-Templates
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                    # z.B. 192.168.1.50/24 + GATEWAY=192.168.1.1
GATEWAY="${GATEWAY:-}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
DISK="${DISK:-20}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/install.sh}"

echo "→ Template prüfen..."
if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}"; then
  echo "→ Lade Template ${TEMPLATE}..."
  pveam update && pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi

echo "→ Erstelle LXC ${CTID} (${HOSTNAME})..."
ARGS=(pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
  --hostname "${HOSTNAME}" --cores "${CORES}" --memory "${MEMORY}"
  --rootfs "${STORAGE}:${DISK}" --net0 "name=eth0,bridge=${BRIDGE},firewall=0,ip=${IP}"
  --unprivileged "${UNPRIVILEGED}" --features nesting=1 --onboot 1 --start 1)
[ -n "${GATEWAY}" ] && ARGS+=(--gateway "${GATEWAY}")
"${ARGS[@]}"

echo "→ Warte auf Netzwerk..."
sleep 8
pct exec "${CTID}" -- bash -c "until ping -c1 1.1.1.1 >/dev/null 2>&1; do sleep 2; done; echo OK"

echo "→ Installiere Hermes (direkt-WebUI) im Container..."
pct exec "${CTID}" -- bash -c "curl -fsSL '${INSTALL_URL}' | bash"

echo ""
echo "✓ Fertig. Container-IP:"
pct exec "${CTID}" -- hostname -I
echo "WebUI: http://<IP>:8787  |  Dashboard: http://<IP>:9119  |  API: http://<IP>:8642/v1"
echo "Passwörter stehen am Ende des Install-Logs + in /home/hermes/hermes-webui/.env"
