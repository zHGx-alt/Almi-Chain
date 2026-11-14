#!/usr/bin/env bash
# Server firewall (ufw). The staff network is flat: POS terminals, the manager's PC and the
# server share it, so the server has to protect itself.
#
#   Inbound blocked by default; outbound allowed (updates, Docker images, backups).
#   SSH (22)            only from the manager's PC.
#   HTTP/HTTPS (80/443) only from the staff LAN (Odoo behind the HTTPS proxy).
#
# Usage:  sudo ./server-firewall.sh
#         sudo LAN=192.168.10.0/24 MANAGER=192.168.10.20 ./server-firewall.sh   (the defaults)
# When run over SSH from another IP (e.g. a VirtualBox VM behind NAT), that IP is allowed too,
# with a warning, so you do not lock yourself out. Idempotent.
#
# Mind Docker: ports a container publishes (the proxy's 80 and 443) are opened by Docker in iptables
# ahead of ufw. That is why the proxy publishes 80/443 (meant to be open) and Odoo only 127.0.0.1:8069.
set -euo pipefail

LAN=${LAN:-192.168.10.0/24}
MANAGER=${MANAGER:-192.168.10.20}
log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run the script with sudo: sudo $0" >&2; exit 1; }

log "1/3 Installing ufw"
command -v ufw >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
ufw --version | head -1

log "2/3 Rules"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$MANAGER" to any port 22 proto tcp comment 'SSH from the manager PC only'
# Whoever runs the script over SSH from another IP is not locked out
ssh_source=${SSH_CLIENT:-}
ssh_source=${ssh_source%% *}
# sudo does not keep SSH_CLIENT: look for it in the parent processes (the SSH session's shell has it).
# "who -m" does not work with "ssh host 'sudo ...'": without a login shell there is no utmp entry.
pid=$$
while [[ -z $ssh_source && $pid -gt 1 ]]; do
  ssh_source=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^SSH_CLIENT=\([^ ]*\) .*/\1/p' || true)
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ' || true)
  [[ -n $pid ]] || pid=1
done
[[ -n $ssh_source ]] || ssh_source=$(who -m 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
if [[ -n $ssh_source && $ssh_source != "$MANAGER" ]]; then
  ufw allow from "$ssh_source" to any port 22 proto tcp comment 'SSH of whoever set up the firewall'
  echo "  WARNING: SSH is also allowed from $ssh_source (the current connection). Remove it when done:"
  echo "           sudo ufw delete allow from $ssh_source to any port 22 proto tcp"
fi
ufw allow from "$LAN" to any port 80,443 proto tcp comment 'Odoo over HTTPS from the LAN'

log "3/3 Enabling"
ufw --force enable
ufw status verbose
