#!/usr/bin/env bash
#
# Hermes Heimnetz-Server — LXC erstellen (Proxmox Host, als root)
# =============================================================================
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/ct/hermesagent.sh)"
#
# HINWEIS: Bewusst KEIN community-scripts build.func — deren build_container
# lädt das Install-Script immer aus dem offiziellen ProxmoxVE-Repo (ohne WebUI).
# Darum erstellt dieses Script den LXC direkt per pct und führt DANACH unser
# install.sh im Container aus. So landet garantiert unser Code im Container.
#
# Bestehender Container? Einfach install.sh darin als root laufen lassen:
#   pct enter <CTID>
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/install.sh | bash
#
set -euo pipefail

SCRIPT_VERSION="2026-09-11-ct-hostname-curlfix"
echo "Hermes LXC-Ersteller ${SCRIPT_VERSION}"

# --- Einstellungen (per ENV überschreibbar, z.B. CTID=200 bash ...) ------------
CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 200)}"
# HINWEIS: heißt absichtlich CT_HOSTNAME — $HOSTNAME ist in jeder Shell bereits
# gesetzt (System-Hostname, hier "Prox") und würde den Default überschreiben!
CT_HOSTNAME="${CT_HOSTNAME:-hermes-agent}"
TEMPLATE="${TEMPLATE:-debian-13-standard_13.1-1_amd64.tar.zst}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                 # z.B. 192.168.178.167/24 (+ GATEWAY=192.168.178.1)
GATEWAY="${GATEWAY:-}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
DISK="${DISK:-20}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/install.sh}"

[ "$(id -u)" -eq 0 ] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "pct nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }

# --- Update-Modus: Container existiert schon ------------------------------------
if pct status "${CTID}" >/dev/null 2>&1; then
  echo "→ Container ${CTID} existiert — Update statt Neuerstellung."
  pct exec "${CTID}" -- bash -c "
    set -e
    unset VIRTUAL_ENV; cd /home/hermes
    if [[ -x /home/hermes/.local/bin/hermes ]]; then HB=/home/hermes/.local/bin/hermes; else HB=/usr/local/bin/hermes; fi
    systemctl stop hermes-webui hermes-dashboard hermes-gateway 2>/dev/null || true
    su - hermes -c \"\$HB update --yes\"
    [[ -d /home/hermes/hermes-webui/.git ]] && su - hermes -c 'git -C ~/hermes-webui pull --ff-only' || true
    chown -R hermes:hermes /home/hermes
    systemctl start hermes-gateway hermes-dashboard hermes-webui 2>/dev/null || systemctl start hermes-dashboard hermes-webui 2>/dev/null || true
  "
  echo "✓ Update fertig."
  exit 0
fi

# --- Template (Version nicht hart kodieren: Mirror ändert sie laufend) --------------
echo "→ Template prüfen (${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE})..."
if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}"; then
  echo "→ '${TEMPLATE}' nicht lokal — suche neueste Debian-13-Vorlage am Mirror..."
  pveam update >/dev/null 2>&1 || true
  NEWEST="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-13-standard_.*\.tar\.(zst|gz)$' | sort -V | tail -n 1 || true)"
  if [ -n "${NEWEST}" ]; then
    echo "→ Nehme stattdessen: ${NEWEST}"
    TEMPLATE="${NEWEST}"
  fi
fi
if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}"; then
  echo "→ Lade Template ${TEMPLATE}..."
  pveam update && pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi
pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}" \
  || { echo "FEHLER: Template '${TEMPLATE}' weder lokal noch am Mirror gefunden." >&2; exit 1; }

# --- LXC erstellen ----------------------------------------------------------------
echo "→ Erstelle LXC ${CTID} (${CT_HOSTNAME}, ${CORES}C/${MEMORY}MB/${DISK}GB)..."
NET0="name=eth0,bridge=${BRIDGE},firewall=0,ip=${IP}"
[ -n "${GATEWAY}" ] && NET0="${NET0},gw=${GATEWAY}"
pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "${CT_HOSTNAME}" --cores "${CORES}" --memory "${MEMORY}" \
  --rootfs "${STORAGE}:${DISK}" --net0 "${NET0}" \
  --unprivileged "${UNPRIVILEGED}" --features nesting=1 --onboot 1 --start 1

echo "→ Warte auf Container-Netzwerk (max. 3 Min)..."
for _i in $(seq 1 36); do
  pct status "${CTID}" 2>/dev/null | grep -q running || { sleep 5; continue; }
  pct exec "${CTID}" -- bash -c "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1" && break
  sleep 5
done
pct exec "${CTID}" -- bash -c "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1" \
  || { echo "FEHLER: Container hat kein Netzwerk." >&2; exit 1; }

# --- UNSER Installer im Container (das ist der entscheidende Schritt) --------------
# WICHTIG: curl ist in frischen Debian-Containern NICHT vorhanden → erst
# installieren. Und Installer als DATEI laden + ausführen statt
# "curl | bash": Bei "curl | bash" liefert ein fehlendes curl leeren Input,
# das innere bash beendet sich dann mit Exit 0 — der Fehler fällt durch und
# die Erfolgsmeldung druckt trotzdem (genau das ist passiert).
echo "→ Installiere curl im Container..."
pct exec "${CTID}" -- bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates" \
  || { echo "FEHLER: curl-Installation im Container schlug fehl." >&2; exit 1; }
echo "→ Installiere Hermes + Direkt-WebUI im Container (dauert einige Minuten)..."
pct exec "${CTID}" -- bash -c "curl -fsSL '${INSTALL_URL}' -o /root/hermes-install.sh && bash /root/hermes-install.sh" \
  || { echo "FEHLER: Install im Container schlug fehl — siehe Ausgabe oben." >&2; exit 1; }

CIP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
CIP="${CIP:-<IP>}"
cat <<EOF

════════════════════════════════════════════════════════════
  🎉 Hermes Heimnetz-Server fertig — direkt im Browser!
  💬 Chat-WebUI (HIER EINLOGGEN): http://${CIP}:8787  (mit http://, NICHT https)
     Passwort: im Container 'hermes-credentials' oder /root/hermes-access.txt
  📊 Agent-Dashboard (nur Status, KEIN Chat): http://${CIP}:9119
  🔌 API        : http://${CIP}:8642/v1
  Setup (EINMALIG): im Container 'hermes-setup' (volles 'hermes setup')
════════════════════════════════════════════════════════════
EOF
