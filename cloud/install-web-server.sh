#!/usr/bin/env bash
# Installs the Almi-Chain web server on an EC2 instance with Ubuntu 24.04.
# nginx serves the site stored in the S3 bucket, and certbot gets the Let's Encrypt certificate.
# Usage: sudo BUCKET=almi-chain-web-2026 DOMAIN=almichain1.duckdns.org EMAIL=you@example.com ./install-web-server.sh
set -euo pipefail

: "${BUCKET:?BUCKET is not set (S3 bucket name)}"
: "${DOMAIN:?DOMAIN is not set (for example almichain1.duckdns.org)}"
: "${EMAIL:?EMAIL is not set (certificate expiry notices)}"
REGION="${REGION:-us-east-1}"
WEBROOT=/var/www/almichain

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

apt-get update
apt-get install -y nginx certbot python3-certbot-nginx
snap install aws-cli --classic

# Pull the site from S3; cron repeats it every 5 minutes to publish changes.
mkdir -p "$WEBROOT"
cat > /usr/local/bin/update-web <<EOF
#!/usr/bin/env bash
set -euo pipefail
/snap/bin/aws s3 sync "s3://$BUCKET/" "$WEBROOT/" --delete --only-show-errors --region "$REGION"
EOF
chmod 755 /usr/local/bin/update-web
/usr/local/bin/update-web
echo "*/5 * * * * root /usr/local/bin/update-web" > /etc/cron.d/update-web

# nginx site. certbot adds the HTTPS block and the HTTP redirect afterwards.
cat > /etc/nginx/sites-available/almichain <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    # CSP: only the site's own files, the inline favicon (data:) and the OpenStreetMap map are loaded.
    # No inline or third-party scripts or styles. Any new external resource on the site must be added here.
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src https://www.openstreetmap.org; connect-src 'self'; font-src 'self'; form-action 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; upgrade-insecure-requests" always;
    # Only the site itself may ask for geolocation (not the map iframe); camera, microphone and payments, nobody.
    add_header Permissions-Policy "geolocation=(self), camera=(), microphone=(), payment=(), usb=()" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sf /etc/nginx/sites-available/almichain /etc/nginx/sites-enabled/almichain
rm -f /etc/nginx/sites-enabled/default
# In the http block, so it also applies to the redirect certbot creates.
echo "server_tokens off;" > /etc/nginx/conf.d/hide-version.conf
# Ubuntu only compresses HTML; add CSS, JS and SVG.
printf 'gzip_vary on;\ngzip_types text/css application/javascript image/svg+xml;\n' > /etc/nginx/conf.d/compression.conf
nginx -t
systemctl reload nginx

certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive

echo "Done: https://$DOMAIN"
