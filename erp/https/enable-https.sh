#!/usr/bin/env bash
# Puts Odoo behind an HTTPS proxy (nginx) on the server set up by ../deploy-odoo.sh.
#
#   1. Creates a self-issued certificate for the server's IP (825 days; the server is its own CA).
#      With nameConstraints: even if odoo.key were stolen, it could not sign certificates for other sites.
#   2. Copies nginx.conf and docker-compose.https.yml to /opt/odoo.
#   3. Turns on proxy_mode in odoo.conf (Odoo trusts the proxy's X-Forwarded-* headers).
#   4. Pins COMPOSE_FILE in /opt/odoo/.env so any "docker compose up" includes the proxy.
#   5. Starts the proxy; Odoo stops listening on the LAN (127.0.0.1:8069 only).
#
# Usage (from this script's folder):  sudo ./enable-https.sh [SERVER_IP]
# Idempotent: an existing certificate is kept (the POS terminals already trust it).
set -euo pipefail

IP=${1:-192.168.10.10}
DIR=/opt/odoo
SOURCE=$(cd "$(dirname "$0")" && pwd)
log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run the script with sudo: sudo $0" >&2; exit 1; }
[[ -f $DIR/docker-compose.yml ]] || { echo "$DIR/docker-compose.yml not found: run ../deploy-odoo.sh first" >&2; exit 1; }
docker compose version --short | awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 24)) }' \
  || { echo "Docker Compose 2.24 or later is needed (for '!override')" >&2; exit 1; }

log "1/5 Certificate for $IP"
install -d -m 750 "$DIR/https/certs"
if [[ ! -f $DIR/https/certs/odoo.crt ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$DIR/https/certs/odoo.key" -out "$DIR/https/certs/odoo.crt" \
    -subj "/CN=Odoo Almi-Chain/O=Almi-Chain" \
    -addext "subjectAltName=IP:$IP,DNS:odoo.almichain.local" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "nameConstraints=critical,permitted;IP:$IP/255.255.255.255,permitted;DNS:odoo.almichain.local" 2>/dev/null
  chmod 640 "$DIR/https/certs/odoo.key"
  echo "  Created. SHA-256 fingerprint (to check it when installing it on the POS terminals):"
else
  echo "  Already exists: kept. SHA-256 fingerprint:"
fi
openssl x509 -in "$DIR/https/certs/odoo.crt" -noout -fingerprint -sha256 | sed 's/^/  /'

log "2/5 nginx and proxy configuration"
install -m 644 "$SOURCE/nginx.conf" "$DIR/https/nginx.conf"
install -m 644 "$SOURCE/docker-compose.https.yml" "$DIR/docker-compose.https.yml"

log "3/5 proxy_mode in odoo.conf"
if grep -q '^proxy_mode' "$DIR/config/odoo.conf"; then
  sed -i 's/^proxy_mode.*/proxy_mode = True/' "$DIR/config/odoo.conf"
else
  printf '; Behind the HTTPS proxy\nproxy_mode = True\n' >> "$DIR/config/odoo.conf"
fi
echo "  $(grep '^proxy_mode' "$DIR/config/odoo.conf")"

log "4/5 COMPOSE_FILE in .env"
sed -i '/^COMPOSE_FILE=/d' "$DIR/.env"
echo "COMPOSE_FILE=docker-compose.yml:docker-compose.https.yml" >> "$DIR/.env"

log "5/5 Starting Odoo and the proxy"
cd "$DIR"
docker compose up -d --remove-orphans
# install leaves nginx.conf as a new file and the container would keep the old mount: recreate the proxy
docker compose up -d --force-recreate --no-deps proxy
sleep 5
docker compose ps

log "Check"
echo "  HTTPS:       $(curl -sk -o /dev/null -w '%{http_code}' "https://$IP/web/login") (expected 200)"
echo "  HTTP -> 443: $(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$IP/web/login") (expected 301)"
echo "  8069 on LAN: $(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$IP:8069/web/login" || true) (expected 000: closed)"
echo
echo "Done. Next: install $DIR/https/certs/odoo.crt as a trusted root on the POS terminals and the"
echo "manager's PC (pos-hardening.ps1 -OdooCertificate) and point the kiosk at https://$IP/pos/ui."
