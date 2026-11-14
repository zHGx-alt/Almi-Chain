#!/usr/bin/env bash
# Installs Docker and deploys Odoo + PostgreSQL on a headless Debian 13 server.
#
# Usage (from the folder that holds docker-compose.yml):
#   sudo ./deploy-odoo.sh
# Safe to run again: it never regenerates passwords or recreates the database if they exist.
set -euo pipefail

TARGET=/opt/odoo
SOURCE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }
random_secret() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

[[ $EUID -eq 0 ]] || { echo "Run the script with sudo: sudo $0" >&2; exit 1; }

log "1/6 Installing Docker (Debian's own packages)"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  docker.io docker-cli docker-compose openssl curl ca-certificates >/dev/null
systemctl enable --now docker
docker --version
docker compose version

log "2/6 Copying the project to ${TARGET} (readable by root only)"
install -d -m 750 "$TARGET" "$TARGET/config"
install -m 644 "$SOURCE/docker-compose.yml" "$TARGET/docker-compose.yml"
cd "$TARGET"

log "3/6 Generating secrets (first run only)"
if [[ ! -f .env ]]; then
  umask 077
  cat > .env <<EOF
ODOO_VERSION=19.0
POSTGRES_USER=odoo
POSTGRES_PASSWORD=$(random_secret)
ODOO_DB=shop
ODOO_ADMIN_PASSWORD=$(random_secret)
ODOO_MASTER_PASSWORD=$(random_secret)
EOF
  umask 022
  echo "  .env created (mode 600)"
else
  echo "  .env already exists: kept"
fi
chmod 600 .env
set -a; source .env; set +a

if [[ ! -f config/odoo.conf ]]; then
  cat > config/odoo.conf <<EOF
[options]
; Master password (database management). Random.
admin_passwd = ${ODOO_MASTER_PASSWORD}
; Security: no database list or web database manager, and only the shop's database
list_db = False
dbfilter = ^${ODOO_DB}\$
data_dir = /var/lib/odoo
; Threaded mode (workers = 0): enough for a small restaurant, and real-time chat/notifications
; need no extra proxy route. With more users: workers = 2 and send /websocket to port 8072.
workers = 0
EOF
  echo "  config/odoo.conf created"
fi
# The container reads the file as user "odoo"; /opt/odoo (750, root) keeps other system users out
chmod 644 config/odoo.conf

log "4/6 Pulling images and starting PostgreSQL"
docker compose pull -q
docker compose up -d db
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q db)")" == healthy ]]; do sleep 2; done
echo "  PostgreSQL ready"

log "5/6 Creating the '${ODOO_DB}' database (Spanish locale, no demo data)"
if docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='${ODOO_DB}'" | grep -q 1; then
  echo "  The database already exists: kept"
else
  docker compose run --rm -T odoo -d "$ODOO_DB" -i base --without-demo=all \
    --load-language=es_ES --stop-after-init --no-http
  # Replace the default admin/admin password with the one from .env
  docker compose run --rm -T odoo odoo shell -d "$ODOO_DB" --no-http <<EOF
admin = env.ref('base.user_admin')
admin.write({'password': '${ODOO_ADMIN_PASSWORD}', 'lang': 'es_ES', 'tz': 'Europe/Madrid'})
env.cr.commit()
print('admin password changed')
EOF
fi

log "6/6 Starting Odoo"
docker compose up -d odoo
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null http://127.0.0.1:8069/web/login && break
  sleep 2
done
docker compose ps
echo
if curl -fsS -o /dev/null http://127.0.0.1:8069/web/login; then
  echo "Odoo running at http://<server-ip>:8069  ·  database: ${ODOO_DB}  ·  user: admin"
  echo "The admin password is in ${TARGET}/.env (ODOO_ADMIN_PASSWORD):  sudo grep ODOO_ADMIN ${TARGET}/.env"
else
  echo "Odoo is not answering yet. Check:  sudo docker compose -f ${TARGET}/docker-compose.yml logs odoo" >&2
  exit 1
fi
