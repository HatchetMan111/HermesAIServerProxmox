#!/usr/bin/env bash
#
# Hermes Agent + Hermes WebUI — Direkt-Zugriff Installer (ohne SSH-Tunnel)
# =============================================================================
# Für Debian 12/13 LXC oder VM. Als root ausführen:
#
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/install.sh | bash
#
# Danach direkt im Browser (kein SSH-Tunnel nötig):
#   WebUI Chat    : http://<CONTAINER-IP>:8787
#   Dashboard     : http://<CONTAINER-IP>:9119
#   OpenAI-API    : http://<CONTAINER-IP>:8642/v1  (Key in /home/hermes/.hermes/.env)
#
# Provider danach EINMAL einrichten — entweder im WebUI-Onboarding
# (Settings → Providers) oder per:  su - hermes -c "hermes setup"
#
# Sicherheit: Nur für Heimnetz / LAN gedacht. WebUI-Passwort ist Pflicht,
# sobald 0.0.0.0 gebunden wird (wird automatisch generiert).
#
set -euo pipefail

# --- Config (per ENV überschreibbar) ----------------------------------------
WEBUI_PORT="${WEBUI_PORT:-8787}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
API_PORT="${API_PORT:-8642}"
WEBUI_HOST="${WEBUI_HOST:-0.0.0.0}"          # <-- das ist der Direktzugriff-Trick
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME_DIR="/home/${HERMES_USER}/.hermes"
AGENT_DIR="${HERMES_HOME_DIR}/hermes-agent"
WEBUI_DIR="/home/${HERMES_USER}/hermes-webui"
WEBUI_REPO="${WEBUI_REPO:-https://github.com/nesquena/hermes-webui.git}"

# --- Helpers -----------------------------------------------------------------
msg()  { echo -e "\e[1;34m→\e[0m $*"; }
ok()   { echo -e "\e[1;32m✓\e[0m $*"; }
warn() { echo -e "\e[1;33m!\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m✗\e[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (sudo -i)."
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CONTAINER_IP="${CONTAINER_IP:-<CONTAINER-IP>}"

# --- 1. System-Abhängigkeiten --------------------------------------------------
msg "Installiere Systempakete (python3, git, nodejs optional)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl ca-certificates git sudo openssl \
  python3 python3-venv python3-pip \
  build-essential 2>&1 | tail -n 3 || true
ok "Systempakete bereit."

# --- 2. hermes User -------------------------------------------------------------
if ! id "${HERMES_USER}" >/dev/null 2>&1; then
  msg "Lege User '${HERMES_USER}' an..."
  useradd -m -s /bin/bash "${HERMES_USER}"
fi
ok "User '${HERMES_USER}' existiert."

# --- 3. Hermes Agent -------------------------------------------------------------
if [ ! -x "/home/${HERMES_USER}/.local/bin/hermes" ] && [ ! -x "/usr/local/bin/hermes" ]; then
  msg "Installiere Hermes Agent (offizieller Installer, --skip-setup)..."
  sudo -u "${HERMES_USER}" -H bash -c \
    "HOME=/home/${HERMES_USER} bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh) --skip-setup --hermes-home ${HERMES_HOME_DIR} --dir ${AGENT_DIR}"
  chown -R "${HERMES_USER}:${HERMES_USER}" "/home/${HERMES_USER}"
  git config --system --add safe.directory "${AGENT_DIR}" 2>/dev/null || true
else
  msg "Hermes Agent bereits vorhanden — aktualisiere..."
  sudo -u "${HERMES_USER}" -H bash -c "HOME=/home/${HERMES_USER} /home/${HERMES_USER}/.local/bin/hermes update --yes 2>/dev/null || /usr/local/bin/hermes update --yes 2>/dev/null || true"
fi

# hermes Binary finden (User-Install vs. FHS-Root-Install)
HERMES_BIN=""
for c in "/home/${HERMES_USER}/.local/bin/hermes" "/usr/local/bin/hermes"; do
  [ -x "$c" ] && HERMES_BIN="$c" && break
done
[ -n "$HERMES_BIN" ] || die "hermes Binary nicht gefunden."
ok "Hermes Agent: ${HERMES_BIN}"

# /usr/bin/hermes Shim (damit 'hermes setup' als root geht)
cat >/usr/bin/hermes <<EOF
#!/bin/bash
cd /home/${HERMES_USER} || exit 1
exec runuser -u ${HERMES_USER} -- ${HERMES_BIN} "\$@"
EOF
chmod +x /usr/bin/hermes

# Web/Dashboard Extras (uv pip)
msg "Installiere Hermes Web-Extras (web,pty)..."
sudo -u "${HERMES_USER}" -H bash -c \
  "VIRTUAL_ENV=${AGENT_DIR}/venv ${HERMES_BIN%/*}/uv pip install -q 'hermes-agent[web,pty]' 2>&1 | tail -n 2 || ${AGENT_DIR}/venv/bin/pip install -q 'hermes-agent[web,pty]' 2>&1 | tail -n 2 || true"

# --- 4. API-Server Key (.env) ----------------------------------------------------
HERMES_ENV_FILE="${HERMES_HOME_DIR}/.env"
mkdir -p "${HERMES_HOME_DIR}"
touch "${HERMES_ENV_FILE}"
chown "${HERMES_USER}:${HERMES_USER}" "${HERMES_HOME_DIR}" "${HERMES_ENV_FILE}"
chmod 600 "${HERMES_ENV_FILE}"

get_env() { grep -E "^$1=" "${HERMES_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true; }
set_env() { # $1=KEY $2=VALUE
  if grep -qE "^$1=" "${HERMES_ENV_FILE}"; then
    sed -i "s|^$1=.*|$1=$2|" "${HERMES_ENV_FILE}"
  else
    echo "$1=$2" >>"${HERMES_ENV_FILE}"
  fi
}

API_KEY="$(get_env API_SERVER_KEY)"
if [ -z "$API_KEY" ] || [ "${#API_KEY}" -lt 16 ]; then
  API_KEY="$(openssl rand -hex 24)"
  msg "Generiere neuen API_SERVER_KEY..."
fi
set_env "API_SERVER_ENABLED" "true"
set_env "API_SERVER_HOST" "0.0.0.0"
set_env "API_SERVER_PORT" "${API_PORT}"
set_env "API_SERVER_KEY" "${API_KEY}"
chown "${HERMES_USER}:${HERMES_USER}" "${HERMES_ENV_FILE}"
chmod 600 "${HERMES_ENV_FILE}"
ok "API-Server konfiguriert: 0.0.0.0:${API_PORT} (Key in ${HERMES_ENV_FILE})"

# --- 5. Hermes WebUI (nesquena/hermes-webui) --------------------------------------
if [ ! -d "${WEBUI_DIR}/.git" ]; then
  msg "Klone Hermes WebUI nach ${WEBUI_DIR}..."
  rm -rf "${WEBUI_DIR}"
  sudo -u "${HERMES_USER}" -H git clone --depth 1 "${WEBUI_REPO}" "${WEBUI_DIR}"
else
  msg "Aktualisiere Hermes WebUI (git pull)..."
  sudo -u "${HERMES_USER}" -H git -C "${WEBUI_DIR}" pull --ff-only || true
fi
chown -R "${HERMES_USER}:${HERMES_USER}" "${WEBUI_DIR}"

# WebUI .env mit DIREKTZUGRIFF + Passwort
WEBUI_ENV="${WEBUI_DIR}/.env"
if [ ! -f "${WEBUI_ENV}" ]; then
  sudo -u "${HERMES_USER}" -H touch "${WEBUI_ENV}"
fi
WEBUI_PASSWORD="$(grep -E '^HERMES_WEBUI_PASSWORD=' "${WEBUI_ENV}" 2>/dev/null | cut -d= -f2- || true)"
if [ -z "$WEBUI_PASSWORD" ]; then
  WEBUI_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
  msg "Generiere WebUI-Passwort..."
fi
# .env idempotent schreiben (nur unsere Keys anfassen)
for kv in "HERMES_WEBUI_HOST=${WEBUI_HOST}" "HERMES_WEBUI_PORT=${WEBUI_PORT}" "HERMES_WEBUI_PASSWORD=${WEBUI_PASSWORD}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  if grep -qE "^${k}=" "${WEBUI_ENV}"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${WEBUI_ENV}"
  else
    echo "${kv}" >>"${WEBUI_ENV}"
  fi
done
chown "${HERMES_USER}:${HERMES_USER}" "${WEBUI_ENV}"
chmod 600 "${WEBUI_ENV}"
ok "WebUI .env: HOST=${WEBUI_HOST} PORT=${WEBUI_PORT} + Passwort gesetzt."

# Python für WebUI bestimmen (Agent-venv bevorzugt)
WEBUI_PYTHON="${AGENT_DIR}/venv/bin/python"
command -v "${WEBUI_PYTHON}" >/dev/null 2>&1 || WEBUI_PYTHON="$(command -v python3)"
msg "WebUI Python: ${WEBUI_PYTHON}"

# Erster Bootstrap-Lauf (legt venv + Deps an, startet kurz, prüft /health)
msg "Bootstrap der WebUI (dauert beim ersten Mal 2-5 Min)..."
sudo -u "${HERMES_USER}" -H bash -c \
  "cd '${WEBUI_DIR}' && HERMES_HOME='${HERMES_HOME_DIR}' HERMES_WEBUI_HOST=127.0.0.1 HERMES_WEBUI_PORT=${WEBUI_PORT} '${WEBUI_PYTHON}' bootstrap.py --no-browser --foreground" &
BOOTSTRAP_PID=$!
# max 10 Min warten, bis /health antwortet, dann wieder stoppen (systemd übernimmt)
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null 2>&1; then
    ok "WebUI Bootstrap erfolgreich (/health antwortet)."
    break
  fi
  if ! kill -0 "${BOOTSTRAP_PID}" 2>/dev/null; then
    warn "Bootstrap-Prozess beendet — prüfe Log, fahre trotzdem fort."
    break
  fi
  sleep 5
done
kill "${BOOTSTRAP_PID}" 2>/dev/null || true
sleep 2
# Reste sauber beenden (bootstrap --foreground hinterlässt sonst Port-Belegung)
pkill -f "${WEBUI_DIR}/bootstrap.py" 2>/dev/null || true
pkill -f "${WEBUI_DIR}/server.py" 2>/dev/null || true
sleep 2

# --- 6. systemd Services ------------------------------------------------------------
msg "Richte systemd-Services ein (gateway, dashboard, webui)..."

cat >/etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=/home/${HERMES_USER}
ExecStart=${HERMES_BIN} gateway run --replace
Environment=HERMES_HOME=${HERMES_HOME_DIR}
Environment=HOME=/home/${HERMES_USER}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Dashboard DIREKT auf 0.0.0.0 (kein SSH-Tunnel mehr nötig)
cat >/etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent Web Dashboard (direkt)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=/home/${HERMES_USER}
ExecStart=${HERMES_BIN} dashboard --host 0.0.0.0 --port ${DASHBOARD_PORT} --no-open
Environment=HERMES_HOME=${HERMES_HOME_DIR}
Environment=HOME=/home/${HERMES_USER}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# WebUI DIREKT auf 0.0.0.0 + Passwort aus .env
cat >/etc/systemd/system/hermes-webui.service <<EOF
[Unit]
Description=Hermes WebUI Chat (direkt, ohne Tunnel)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=${WEBUI_DIR}
EnvironmentFile=${WEBUI_ENV}
Environment=HERMES_HOME=${HERMES_HOME_DIR}
Environment=HOME=/home/${HERMES_USER}
Environment=HERMES_WEBUI_HOST=${WEBUI_HOST}
Environment=HERMES_WEBUI_PORT=${WEBUI_PORT}
ExecStart=${WEBUI_PYTHON} ${WEBUI_DIR}/bootstrap.py --no-browser --foreground --host ${WEBUI_HOST} ${WEBUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hermes-gateway hermes-dashboard hermes-webui
ok "Services laufen."

# --- 7. Abschluss -------------------------------------------------------------------
sleep 3
systemctl is-active --quiet hermes-webui && WEBUI_STATE="aktiv ✅" || WEBUI_STATE="PRÜFEN ❌ (journalctl -u hermes-webui -e)"
systemctl is-active --quiet hermes-dashboard && DASH_STATE="aktiv ✅" || DASH_STATE="PRÜFEN ❌"
systemctl is-active --quiet hermes-gateway && GW_STATE="aktiv ✅" || GW_STATE="PRÜFEN ❌"

cat <<EOF

════════════════════════════════════════════════════════════
  🎉 Hermes fertig — DIREKT im Browser, ohne SSH-Tunnel!
════════════════════════════════════════════════════════════
  💬 WebUI Chat  :  http://${CONTAINER_IP}:${WEBUI_PORT}   [${WEBUI_STATE}]
     Login-Passwort: ${WEBUI_PASSWORD}

  📊 Dashboard   :  http://${CONTAINER_IP}:${DASHBOARD_PORT}   [${DASH_STATE}]

  🔌 OpenAI-API  :  http://${CONTAINER_IP}:${API_PORT}/v1   [Gateway: ${GW_STATE}]
     API-Key (Bearer): ${API_KEY}
     Datei: ${HERMES_ENV_FILE}

────────────────────────────────────────────────────────────
  Nächster Schritt (EINMALIG Provider wählen):
  1) Browser → WebUI öffnen → Onboarding-Wizard → Provider wählen,
     ODER im Container:
       su - ${HERMES_USER}
       hermes setup        # Model-Provider + Gateway
       hermes gateway restart  (falls nötig)
       sudo systemctl restart hermes-webui hermes-dashboard

  Nützlich:
    ./ctl.sh status   (in ${WEBUI_DIR} als ${HERMES_USER})
    journalctl -u hermes-webui -f
    journalctl -u hermes-gateway -f
────────────────────────────────────────────────────────────
  ⚠️  Nur für LAN / Heimnetz! Nicht ohne Reverse-Proxy + TLS
      ins Internet stellen.
════════════════════════════════════════════════════════════
EOF
