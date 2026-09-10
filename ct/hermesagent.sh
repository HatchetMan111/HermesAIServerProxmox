#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/
# Modified: Direkt-WebUI für Heimnetz (0.0.0.0, kein SSH-Tunnel nötig)

APP="Hermes Agent"
var_tags="${var_tags:-ai;automation;agent}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /home/hermes/.local/bin/hermes && ! -x /usr/local/bin/hermes ]]; then
    msg_error "No Hermes Agent Installation Found!"
    exit
  fi
  HERMES_BIN="/home/hermes/.local/bin/hermes"
  [[ -x "$HERMES_BIN" ]] || HERMES_BIN="/usr/local/bin/hermes"

  msg_info "Stopping Services"
  systemctl stop hermes-webui hermes-dashboard hermes-gateway 2>/dev/null || true
  msg_ok "Stopped Services"

  msg_info "Updating Hermes Agent"
  $STD setsid --wait bash -c '
    set -a; source /etc/default/hermes 2>/dev/null; set +a
    /home/hermes/.local/bin/hermes update --yes 2>/dev/null || /usr/local/bin/hermes update --yes
  '
  # See https://github.com/community-scripts/ProxmoxVE/issues/17123
  mapfile -t root_gateway_pids < <(ps -eo user=,pid=,args= | awk '$1 == "root" && $0 ~ /\/home\/hermes\/\.hermes\/hermes-agent\/venv\/bin\/python -m hermes_cli\.main gateway run --replace$/ { print $2 }')
  if ((${#root_gateway_pids[@]})); then
    kill -TERM "${root_gateway_pids[@]}" 2>/dev/null || true
    for pid in "${root_gateway_pids[@]}"; do
      while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
    done
  fi
  chown -R hermes:hermes /home/hermes
  msg_ok "Updated Hermes Agent"

  if [[ -d /home/hermes/hermes-webui/.git ]]; then
    msg_info "Updating Hermes WebUI"
    $STD su - hermes -c 'git -C ~/hermes-webui pull --ff-only'
    chown -R hermes:hermes /home/hermes/hermes-webui
    msg_ok "Updated Hermes WebUI"
  fi

  msg_info "Starting Services"
  systemctl start hermes-gateway hermes-dashboard hermes-webui 2>/dev/null || \
    systemctl start hermes-dashboard hermes-webui 2>/dev/null || true
  msg_ok "Started Services"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}Hermes (Heimnetz-Server) ist fertig — WebUI direkt im Browser!${CL}"
echo -e "${INFO}${YW} 💬 WebUI Chat (ohne SSH-Tunnel):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8787${CL}"
echo -e "${INFO}${YW} Login-Passwort steht in:${CL}"
echo -e "${TAB}${BGN}/home/hermes/hermes-webui/.env  (HERMES_WEBUI_PASSWORD)${CL}"
echo -e "${INFO}${YW} 📊 Dashboard (direkt):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:9119${CL}"
echo -e "${INFO}${YW} 🔌 OpenAI-kompatibler Gateway-Endpunkt (kein Provider-Limit):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8642/v1${CL}"
echo -e "${INFO}${YW} API-Key steht in:${CL}"
echo -e "${TAB}${BGN}/home/hermes/.hermes/.env  (API_SERVER_KEY)${CL}"
echo -e "${INFO}${YW} Setup ganz normal per Terminal (alle Provider/Optionen wie sonst auch):${CL}"
echo -e "${TAB}${BGN}hermes-setup  (= volles 'hermes setup', danach autom. Service-Restart)${CL}"
