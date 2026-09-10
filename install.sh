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
# Provider danach EINMAL ganz normal per Terminal einrichten:
#   su - hermes -c "hermes setup"   (voller Wizard wie sonst auch:
#   Nous Portal, Anthropic, OpenAI, OpenRouter, Ollama/LM Studio, Gateway etc.)
# :8642/v1 ist nur der OpenAI-kompatible Gateway-Endpunkt, kein Provider-Limit.
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
  curl ca-certificates git sudo openssl procps iproute2 \
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

# Web/Dashboard Extras (uv pip) — Fehler hier dürfen den Install nicht abbrechen
msg "Installiere Hermes Web-Extras (web,pty)..."
sudo -u "${HERMES_USER}" -H bash -c \
  "VIRTUAL_ENV=${AGENT_DIR}/venv ${HERMES_BIN%/*}/uv pip install -q 'hermes-agent[web,pty]' 2>&1 | tail -n 2 || ${AGENT_DIR}/venv/bin/pip install -q 'hermes-agent[web,pty]' 2>&1 | tail -n 2 || true" || true

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
  # hex statt base64|tr|head: keine SIGPIPE-Abbrüche unter 'set -o pipefail'
  WEBUI_PASSWORD="$(openssl rand -hex 12 | cut -c1-16)"
  [ "${#WEBUI_PASSWORD}" -ge 16 ] || WEBUI_PASSWORD="$(openssl rand -hex 16)"
  WEBUI_PASSWORD="${WEBUI_PASSWORD:0:16}"
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

# Python für WebUI bestimmen (Agent-venv bevorzugt, mehrere Layouts prüfen)
WEBUI_PYTHON=""
for _cand in "${AGENT_DIR}/venv/bin/python" \
             "/usr/local/lib/hermes-agent/venv/bin/python" \
             "/home/${HERMES_USER}/.hermes/hermes-agent/venv/bin/python"; do
  if [ -x "$_cand" ]; then WEBUI_PYTHON="$_cand"; break; fi
done
if [ -z "$WEBUI_PYTHON" ]; then
  WEBUI_PYTHON="$(command -v python3 || true)"
fi
[ -n "$WEBUI_PYTHON" ] && [ -x "$WEBUI_PYTHON" ] || die "Kein Python gefunden (weder Agent-venv noch python3). Log prüfen."
msg "WebUI Python: ${WEBUI_PYTHON}"
"${WEBUI_PYTHON}" --version || die "Python startet nicht: ${WEBUI_PYTHON}"

# Erster Bootstrap-Lauf (legt venv + Deps an, startet kurz, prüft /health).
# Log nach /tmp, damit Fehler sichtbar sind statt stumm zu scheitern.
BOOTSTRAP_LOG="/tmp/hermes-webui-bootstrap.log"
msg "Bootstrap der WebUI (dauert beim ersten Mal 2-5 Min, Log: ${BOOTSTRAP_LOG})..."
: >"${BOOTSTRAP_LOG}" || true
runuser -u "${HERMES_USER}" -- bash -c \
  "cd '${WEBUI_DIR}' && HERMES_HOME='${HERMES_HOME_DIR}' HERMES_WEBUI_HOST=127.0.0.1 HERMES_WEBUI_PORT=${WEBUI_PORT} '${WEBUI_PYTHON}' bootstrap.py --no-browser --foreground" \
  >>"${BOOTSTRAP_LOG}" 2>&1 &
BOOTSTRAP_PID=$!
# max 10 Min warten, bis /health antwortet, dann wieder stoppen (systemd übernimmt)
BOOTSTRAP_OK=0
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null 2>&1; then
    BOOTSTRAP_OK=1
    ok "WebUI Bootstrap erfolgreich (/health antwortet)."
    break
  fi
  if ! kill -0 "${BOOTSTRAP_PID}" 2>/dev/null; then
    warn "Bootstrap-Prozess beendet, bevor /health antwortete. Letzte Log-Zeilen:"
    tail -n 30 "${BOOTSTRAP_LOG}" >&2 || true
    warn "Fahre trotzdem fort (systemd versucht den Start erneut)."
    break
  fi
  sleep 5
done
if [ "${BOOTSTRAP_OK}" -ne 1 ] && kill -0 "${BOOTSTRAP_PID}" 2>/dev/null; then
  warn "Bootstrap antwortete nach 10 Min nicht — breche Wartezeit ab, fahre mit systemd fort."
  tail -n 20 "${BOOTSTRAP_LOG}" >&2 || true
fi
kill "${BOOTSTRAP_PID}" 2>/dev/null || true
sleep 2
# Reste sauber beenden (bootstrap --foreground hinterlässt sonst Port-Belegung)
pkill -f "${WEBUI_DIR}/bootstrap.py" 2>/dev/null || true
pkill -f "${WEBUI_DIR}/server.py" 2>/dev/null || true
sleep 2
# Port muss wieder frei sein, sonst blockiert der Bootstrap-Rest den systemd-Start
if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null 2>&1; then
  warn "Port ${WEBUI_PORT} noch belegt nach Bootstrap-Stopp — versuche erneut zu räumen..."
  pkill -f "bootstrap.py.*${WEBUI_PORT}" 2>/dev/null || true
  sleep 3
fi

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
Environment=HERMES_WEBUI_PRESERVE_ENV=1
ExecStart=${WEBUI_PYTHON} ${WEBUI_DIR}/bootstrap.py --no-browser --foreground --host ${WEBUI_HOST} ${WEBUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# enable + restart (nicht nur enable --now): --now startet bereits laufende
# Services NICHT neu, alte Prozesse mit alten Flags würden weiterlaufen.
systemctl enable hermes-gateway hermes-dashboard hermes-webui
systemctl restart hermes-gateway hermes-dashboard hermes-webui || \
  die "Services konnten nicht gestartet werden. Prüfe: journalctl -u hermes-webui -e"
ok "Services aktiviert."

# Auf /health warten (WebUI braucht beim ersten systemd-Start ggf. 1-3 Min)
msg "Warte auf WebUI /health (max. 3 Min)..."
for i in $(seq 1 36); do
  curl -fsS "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null 2>&1 && break
  sleep 5
done

# --- 7. Abschluss -------------------------------------------------------------------
systemctl is-active --quiet hermes-webui && WEBUI_STATE="aktiv ✅" || WEBUI_STATE="PRÜFEN ❌ (journalctl -u hermes-webui -e)"
systemctl is-active --quiet hermes-dashboard && DASH_STATE="aktiv ✅" || DASH_STATE="PRÜFEN ❌"
systemctl is-active --quiet hermes-gateway && GW_STATE="aktiv ✅" || GW_STATE="PRÜFEN ❌"
if ! curl -fsS "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null 2>&1; then
  warn "WebUI /health antwortet (noch) nicht. Diagnose:"
  echo "--- systemctl ---" >&2
  systemctl --no-pager status hermes-webui 2>&1 | head -n 20 >&2 || true
  echo "--- journal (letzte 40 Zeilen) ---" >&2
  journalctl -u hermes-webui --no-pager -e 2>&1 | tail -n 40 >&2 || true
  echo "--- Ports ---" >&2
  (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -E "8787|9119|8642" >&2 || echo "(keiner der Ports 8787/9119/8642 lauscht)" >&2
fi

# Bind-Check: hört die WebUI wirklich auf 0.0.0.0 (LAN) oder nur auf localhost?
# aktiv ✅ + lokal gesund, aber im LAN "nicht erreichbar" = fast immer das hier.
_WEBUI_LISTEN="$(ss -tln 2>/dev/null | grep -E ":${WEBUI_PORT}[[:space:]]" || true)"
if [ -n "${_WEBUI_LISTEN}" ]; then
  msg "WebUI lauscht auf: $(printf '%s' "${_WEBUI_LISTEN}" | awk '{print $4}' | tr '\n' ' ')"
  if ! printf '%s' "${_WEBUI_LISTEN}" | grep -Eq "0\.0\.0\.0:${WEBUI_PORT}|\*:${WEBUI_PORT}|:::${WEBUI_PORT}"; then
    warn "WebUI lauscht NUR auf localhost — aus dem LAN nicht erreichbar!"
    warn "Fix: 'systemctl restart hermes-webui', 30s warten, erneut prüfen."
    warn "Steht in ${WEBUI_ENV} wirklich HERMES_WEBUI_HOST=0.0.0.0?"
  fi
else
  warn "Port ${WEBUI_PORT} lauscht gar nicht — journalctl -u hermes-webui -e prüfen."
fi
# Dashboard + API ebenfalls melden: wo lauschen sie?
for _p in "${DASHBOARD_PORT}" "${API_PORT}"; do
  _l="$(ss -tln 2>/dev/null | grep -E ":${_p}[[:space:]]" | awk '{print $4}' | tr '\n' ' ' || true)"
  [ -n "$_l" ] && msg "Port ${_p} lauscht auf: ${_l}" || warn "Port ${_p} lauscht nicht!"
done

cat <<EOF

════════════════════════════════════════════════════════════
  🎉 Hermes fertig — DIREKT im Browser, ohne SSH-Tunnel!
════════════════════════════════════════════════════════════
  💬 WebUI Chat  :  http://${CONTAINER_IP}:${WEBUI_PORT}   [${WEBUI_STATE}]
     Login-Passwort: ${WEBUI_PASSWORD}

  📊 Dashboard   :  http://${CONTAINER_IP}:${DASHBOARD_PORT}   [${DASH_STATE}]

  🔌 OpenAI-kompatibel: http://${CONTAINER_IP}:${API_PORT}/v1   [Gateway: ${GW_STATE}]
     (nur Gateway-Endpunkt, kein Provider-Limit)
     API-Key (Bearer): ${API_KEY}
     Datei: ${HERMES_ENV_FILE}

────────────────────────────────────────────────────────────
  Nächster Schritt (EINMALIG, ganz normal per Terminal):
    su - ${HERMES_USER}
    hermes setup        # voller Wizard wie sonst auch: alle Provider,
                        # Gateway, Messaging etc. (Nous, Anthropic, OpenAI,
                        # OpenRouter, Ollama/LM Studio, ...)
    Danach: sudo systemctl restart hermes-gateway hermes-webui hermes-dashboard
    (WebUI-Onboarding im Browser geht alternativ, ist aber optional)

  Nützlich:
    ./ctl.sh status   (in ${WEBUI_DIR} als ${HERMES_USER})
    journalctl -u hermes-webui -f
    journalctl -u hermes-gateway -f
────────────────────────────────────────────────────────────
  ⚠️  Nur für LAN / Heimnetz! Nicht ohne Reverse-Proxy + TLS
      ins Internet stellen.
════════════════════════════════════════════════════════════
EOF
