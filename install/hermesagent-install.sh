#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/
# Modified: Heimnetz-Server — WebUI + Dashboard direkt auf 0.0.0.0 (kein SSH-Tunnel),
#           systemd-Services für Gateway/Dashboard/WebUI, Bootstrap vorab,
#           damit nach dem Install SOFORT http://<IP>:8787 geht.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

WEBUI_PORT="8787"
DASHBOARD_PORT="9119"
API_PORT="8642"
WEBUI_REPO="https://github.com/nesquena/hermes-webui.git"

msg_info "Installing Dependencies"
$STD apt install -y git curl ca-certificates sudo openssl python3 python3-venv python3-pip build-essential
msg_ok "Installed Dependencies"

NODE_VERSION="22" setup_nodejs

msg_info "Creating Hermes User"
useradd -m -s /bin/bash hermes
loginctl enable-linger hermes 2>/dev/null || true
echo 'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"' >>/home/hermes/.profile
msg_ok "Created Hermes User"

msg_info "Configuring Service Environment"
cat <<EOF >/etc/default/hermes
HOME=/home/hermes
PATH=/home/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NODE_OPTIONS=${NODE_OPTIONS}
EOF
msg_ok "Configured Service Environment"

msg_warn "WARNING: This script will run an external installer from a third-party source (https://hermes-agent.nousresearch.com/)."
msg_warn "The following code is NOT maintained or audited by our repository."
msg_warn "If you have any doubts or concerns, please review the installer code before proceeding:"
msg_custom "${TAB3}${GATEWAY}${BGN}${CL}" "\e[1;34m" "→  https://hermes-agent.nousresearch.com/install.sh"
echo
read -r -p "${TAB3}Do you want to continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  msg_error "Aborted by user. No changes have been made."
  exit 10
fi

msg_info "Installing Hermes Agent"
$STD setsid --wait bash -c '
  set -a; source /etc/default/hermes; set +a
  export npm_config_yes=true
  bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh) --skip-setup --hermes-home /home/hermes/.hermes --dir /home/hermes/.hermes/hermes-agent
'
chown -R hermes:hermes /home/hermes
chmod 750 /home/hermes
chmod 700 /home/hermes/.hermes
git config --system --add safe.directory /home/hermes/.hermes/hermes-agent 2>/dev/null || true
msg_ok "Installed Hermes Agent"

HERMES_BIN="/home/hermes/.local/bin/hermes"
[[ -x "$HERMES_BIN" ]] || HERMES_BIN="/usr/local/bin/hermes"

msg_info "Installing Web Extras (web,pty)"
$STD su - hermes -c "VIRTUAL_ENV=/home/hermes/.hermes/hermes-agent/venv ${HERMES_BIN%/*}/uv pip install 'hermes-agent[web,pty]' || /home/hermes/.hermes/hermes-agent/venv/bin/pip install 'hermes-agent[web,pty]'"
msg_ok "Installed Web Extras"

msg_info "Configuring API Server (LAN, 0.0.0.0)"
API_SERVER_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-32)
mkdir -p /home/hermes/.hermes
cat <<EOF >/home/hermes/.hermes/.env
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_PORT=${API_PORT}
API_SERVER_KEY=${API_SERVER_KEY}
EOF
chmod 600 /home/hermes/.hermes/.env
chown hermes:hermes /home/hermes/.hermes/.env
msg_ok "Configured API Server"

# ---------------------------------------------------------------- WebUI ---
msg_info "Installing Hermes WebUI (direkt, ohne Tunnel)"
$STD su - hermes -c "git clone --depth 1 ${WEBUI_REPO} ~/hermes-webui"
chown -R hermes:hermes /home/hermes/hermes-webui

# WebUI .env: Direktzugriff + Pflicht-Passwort (Heimnetz)
# hex statt base64|tr|head: keine SIGPIPE-Abbrüche
WEBUI_PASSWORD=$(openssl rand -hex 12 | cut -c1-16)
[ "${#WEBUI_PASSWORD}" -ge 16 ] || WEBUI_PASSWORD=$(openssl rand -hex 16)
WEBUI_PASSWORD=${WEBUI_PASSWORD:0:16}
cat <<EOF >/home/hermes/hermes-webui/.env
HERMES_WEBUI_HOST=0.0.0.0
HERMES_WEBUI_PORT=${WEBUI_PORT}
HERMES_WEBUI_PASSWORD=${WEBUI_PASSWORD}
EOF
chmod 600 /home/hermes/hermes-webui/.env
chown hermes:hermes /home/hermes/hermes-webui/.env
msg_ok "Installed Hermes WebUI"

# Bootstrap VORAB, damit venv/Deps fertig sind und /health sofort geht.
# Läuft als hermes auf 127.0.0.1, danach übernimmt systemd auf 0.0.0.0.
msg_info "Bootstrapping WebUI (einmalig, 2-5 Min — danach sofort verfügbar)"
WEBUI_PYTHON="/home/hermes/.hermes/hermes-agent/venv/bin/python"
[[ -x "$WEBUI_PYTHON" ]] || WEBUI_PYTHON="$(command -v python3)"
$STD setsid --wait bash -c "
  su - hermes -c 'cd ~/hermes-webui && HERMES_HOME=/home/hermes/.hermes HERMES_WEBUI_HOST=127.0.0.1 HERMES_WEBUI_PORT=${WEBUI_PORT} ${WEBUI_PYTHON} bootstrap.py --no-browser --foreground' &
  SRV=\$!
  for i in \$(seq 1 60); do
    sleep 5
    curl -fsS http://127.0.0.1:${WEBUI_PORT}/health >/dev/null 2>&1 && break
    kill -0 \$SRV 2>/dev/null || break
  done
  kill \$SRV 2>/dev/null || true
  sleep 2
  pkill -f 'hermes-webui/bootstrap.py' 2>/dev/null || true
  pkill -f 'hermes-webui/server.py' 2>/dev/null || true
  sleep 2
  true
"
msg_ok "Bootstrapped WebUI"

# ------------------------------------------------------- systemd Services ---
msg_info "Creating Gateway Service (System, Autostart)"
cat <<EOF >/etc/systemd/system/hermes-gateway.service
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
UMask=0077
WorkingDirectory=/home/hermes
ExecStart=${HERMES_BIN} gateway run --replace
EnvironmentFile=/etc/default/hermes
Environment=HERMES_HOME=/home/hermes/.hermes
Restart=on-failure
RestartSec=5
ProtectProc=invisible
ProcSubset=pid

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q hermes-gateway
systemctl restart hermes-gateway
msg_ok "Created Gateway Service"

msg_info "Creating Dashboard Service (direkt auf 0.0.0.0 — kein Tunnel)"
cat <<EOF >/etc/systemd/system/hermes-dashboard.service
[Unit]
Description=Hermes Agent Web Dashboard (direkt)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
UMask=0077
WorkingDirectory=/home/hermes
ExecStart=${HERMES_BIN} dashboard --host 0.0.0.0 --port ${DASHBOARD_PORT} --no-open
EnvironmentFile=/etc/default/hermes
Environment=HERMES_HOME=/home/hermes/.hermes
Restart=on-failure
RestartSec=5
ProtectProc=invisible
ProcSubset=pid

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q hermes-dashboard
systemctl restart hermes-dashboard
msg_ok "Created Dashboard Service"

msg_info "Creating WebUI Service (direkt auf 0.0.0.0)"
cat <<EOF >/etc/systemd/system/hermes-webui.service
[Unit]
Description=Hermes WebUI Chat (direkt, ohne Tunnel)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
UMask=0077
WorkingDirectory=/home/hermes/hermes-webui
EnvironmentFile=/home/hermes/hermes-webui/.env
Environment=HERMES_HOME=/home/hermes/.hermes
Environment=HOME=/home/hermes
Environment=HERMES_WEBUI_PRESERVE_ENV=1
ExecStart=${WEBUI_PYTHON} /home/hermes/hermes-webui/bootstrap.py --no-browser --foreground --host 0.0.0.0 ${WEBUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q hermes-webui
systemctl restart hermes-webui
msg_ok "Created WebUI Service"

msg_info "Creating Setup Helper"
cat <<'SETUP' >/usr/bin/hermes-setup
#!/usr/bin/env bash
set -a; source /etc/default/hermes; set +a
/home/hermes/.local/bin/hermes setup 2>/dev/null || /usr/local/bin/hermes setup
chown -R hermes:hermes /home/hermes
chmod 750 /home/hermes
chmod 700 /home/hermes/.hermes
systemctl restart hermes-gateway hermes-dashboard hermes-webui 2>/dev/null || true
echo "Hermes setup complete. Services restarted."
SETUP
chmod +x /usr/bin/hermes-setup
# /usr/bin/hermes Shim (hermes setup auch als root möglich)
cat <<SHIM >/usr/bin/hermes
#!/bin/bash
cd /home/hermes || exit 1
if [[ -x /home/hermes/.local/bin/hermes ]]; then
  exec runuser -u hermes -- /home/hermes/.local/bin/hermes "\$@"
else
  exec runuser -u hermes -- /usr/local/bin/hermes "\$@"
fi
SHIM
chmod +x /usr/bin/hermes
msg_ok "Created Setup Helper"

# Zugangsdaten sichern (geht beim Update nicht verloren)
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF >/home/hermes/ACCESS.txt
Hermes Heimnetz-Server — Direktzugriff (kein SSH-Tunnel)
========================================================
WebUI Chat : http://${LOCAL_IP:-<IP>}:${WEBUI_PORT}
  Passwort : ${WEBUI_PASSWORD}  (auch in ~/hermes-webui/.env)
Dashboard  : http://${LOCAL_IP:-<IP>}:${DASHBOARD_PORT}
OpenAI-API : http://${LOCAL_IP:-<IP>}:${API_PORT}/v1
  API-Key  : ${API_SERVER_KEY}  (auch in ~/.hermes/.env)

Provider einmal einrichten (ganz normal, alles wie sonst auch):
  'hermes-setup' im Container — ruft das volle 'hermes setup' auf
  (alle Provider: Nous Portal, Anthropic, OpenAI, OpenRouter, lokale
  Endpunkte wie Ollama/LM Studio, Gateway, Messaging etc.).
:8642/v1 ist nur der OpenAI-kompatible Gateway-Endpunkt, kein Provider-Limit.
Die WebUI nutzt danach dieselbe Agent-Config (Onboarding-Wizard optional).
Nur für Heimnetz/LAN — nicht ins Internet stellen!
EOF
chown hermes:hermes /home/hermes/ACCESS.txt
chmod 600 /home/hermes/ACCESS.txt
cp /home/hermes/ACCESS.txt /root/hermes-access.txt 2>/dev/null || true

msg_info "Configuring Login Hints"
cat <<'HINT' >/etc/profile.d/hermes-hint.sh
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  Hermes WebUI direkt: http://$(hostname -I | awk '{print $1}'):8787  (Passwort: ~/ACCESS.txt bzw. /home/hermes/hermes-webui/.env)"
  echo "  Setup ganz normal: 'hermes-setup' (volles 'hermes setup' mit allen Providern/Optionen wie sonst auch)."
fi
HINT
msg_ok "Configured Login Hints"

motd_ssh
customize
cleanup_lxc
