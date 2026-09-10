# Hermes Heimnetz-Server — Direkt-WebUI (ohne SSH-Tunnel)

Privater Server fürs Heimnetz: Nach dem Install geht **sofort** im Browser:

- 💬 WebUI Chat: `http://<LXC-IP>:8787` (mit Passwort, auto-generiert)
- 📊 Dashboard: `http://<LXC-IP>:9119`
- 🔌 OpenAI-API: `http://<LXC-IP>:8642/v1`

Kein `ssh -L 9119:...`, kein `HERMES_WEBUI_HOST=... ./ctl.sh start` per Hand — alles läuft als systemd-Service mit Autostart.

## Install auf Proxmox (Host-Shell)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/ct/hermesagent.sh)"
```

Das ist Community-Scripts-kompatibel (`build.func`, `update_script` inklusive).
Update später: Script erneut laufen lassen → updated Agent + WebUI + startet Services neu.

## Bereits ein Debian-LXC? (ohne Proxmox-Helper)

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HermesAIServerProxmox/main/install.sh | bash
```

## Nach dem Install (EINMALIG)

Entweder im Browser: WebUI öffnen → Onboarding-Wizard → Provider wählen.
Oder im Container:

```bash
hermes-setup   # Provider + Gateway, danach automatischer Service-Restart
```

Zugangsdaten stehen in:

- `/home/hermes/hermes-webui/.env` → `HERMES_WEBUI_PASSWORD`
- `/home/hermes/.hermes/.env` → `API_SERVER_KEY`
- `/home/hermes/ACCESS.txt` + `/root/hermes-access.txt` → Übersicht

## Dienste

```bash
systemctl status hermes-gateway hermes-dashboard hermes-webui
journalctl -u hermes-webui -f
su - hermes -c "cd ~/hermes-webui && ./ctl.sh status"
```

## Sicherheit

Nur für LAN/Heimnetz. Nicht ohne Reverse-Proxy + TLS ins Internet stellen.
Passwort ist Pflicht, sobald auf `0.0.0.0` gebunden wird (wird automatisch gesetzt).

## Struktur

```
ct/hermesagent.sh            → Proxmox-Container-Erstellung (Host)
install/hermesagent-install.sh → Installer im Container (build.func-Stil)
install.sh                   → Standalone für bestehende Debian-LXC/VM
```

`HatchetMan111/HermesAIServerProxmox` oben durch deine GitHub-Werte ersetzen und pushen:

```bash
git init && git add -A && git commit -m "Hermes Heimnetz-Server mit Direkt-WebUI"
gh repo create HatchetMan111/HermesAIServerProxmox --public --source=. --push
```
