#!/bin/sh
set -eu

root_dir="${1:-/opt/expert-chat-edge}"
site=/etc/nginx/sites-available/expert-chat
enabled=/etc/nginx/sites-enabled/expert-chat

test -f "$root_dir/nginx-http-bootstrap.conf"
test -f "$root_dir/nginx-expert-chat.conf"
install -d -m 755 /var/www/certbot /etc/letsencrypt/renewal-hooks/deploy

install -m 644 "$root_dir/nginx-http-bootstrap.conf" "$site"
ln -sfn "$site" "$enabled"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

if [ ! -s /etc/letsencrypt/live/125.208.22.148/fullchain.pem ]; then
  certbot certonly --webroot -w /var/www/certbot \
    --preferred-profile shortlived --ip-address 125.208.22.148 \
    --non-interactive --agree-tos --register-unsafely-without-email
fi

install -m 644 "$root_dir/nginx-expert-chat.conf" "$site"
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx

cat > /etc/systemd/system/expert-chat-certbot-renew.service <<'EOF'
[Unit]
Description=Renew Expert Chat TLS certificates

[Service]
Type=oneshot
ExecStart=/usr/local/bin/certbot renew --quiet
EOF

cat > /etc/systemd/system/expert-chat-certbot-renew.timer <<'EOF'
[Unit]
Description=Twice-daily Expert Chat TLS renewal check

[Timer]
OnCalendar=*-*-* 03,15:27:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now expert-chat-certbot-renew.timer
nginx -t
systemctl reload nginx

curl -fsS https://125.208.22.148/gateway/health
