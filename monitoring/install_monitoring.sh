#!/bin/bash
# install_monitoring.sh: Prometheus + Grafana + mtail + node_exporter untuk relay Postfix.
# Semua layanan HANYA listen di 127.0.0.1. Akses dashboard lewat SSH tunnel:
#   ssh -L 3000:127.0.0.1:3000 root@<relay>   lalu buka http://127.0.0.1:3000
#
# Pemakaian (dari folder repo):  sudo bash monitoring/install_monitoring.sh
# Idempotent: aman dijalankan ulang (password Grafana yang sudah ada tidak diganti).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: jalankan sebagai root." >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
for f in postfix_relay.mtail rspamd_relay.mtail relay-metrics.sh relay-alert.sh relay-alert.conf.example grafana-relay-dashboard.json; do
  [ -f "$HERE/$f" ] || { echo "ERROR: $HERE/$f tidak ada." >&2; exit 1; }
done

RETENTION=${RETENTION:-30d}
# PUBLIC_DOMAIN (opsional, diisi manual): buka dashboard di https://<domain> lewat nginx.
# Butuh sertifikat Let's Encrypt di /etc/letsencrypt/live/<domain>/. Kosong = hanya SSH tunnel.
PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-}
# RSPAMD_UI_PUBLIC=1: web UI rspamd juga di https://<PUBLIC_DOMAIN>/rspamd/ (password wajib + fail2ban)
RSPAMD_UI_PUBLIC=${RSPAMD_UI_PUBLIC:-0}
if [ -n "$PUBLIC_DOMAIN" ] && [ ! -f "/etc/letsencrypt/live/$PUBLIC_DOMAIN/fullchain.pem" ]; then
  echo "ERROR: sertifikat untuk $PUBLIC_DOMAIN tidak ada. Buat dulu: certbot certonly --nginx -d $PUBLIC_DOMAIN" >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# ---------- Log Postfix tidak boleh dobel (mtail & fail2ban menghitung per baris) ----------
# Aturan rsyslog kustom yang menulis mail.log lalu 'stop' harus jalan SEBELUM 50-default.conf.
for f in /etc/rsyslog.d/*.conf; do
  b=$(basename "$f")
  if grep -q 'programname == .postfix.' "$f" && grep -q 'mail.log' "$f" && grep -q 'stop' "$f" \
     && [[ ! "$b" =~ ^[0-4][0-9]- ]]; then
    echo ">> rsyslog: $b dipindah ke 10-$b agar log Postfix tidak tercatat dua kali"
    mv "$f" "/etc/rsyslog.d/10-$b"
    systemctl restart rsyslog
  fi
done

# ---------- Paket ----------
echo ">> Install paket..."
apt-get update -y
apt-get install -y --no-install-recommends prometheus prometheus-node-exporter mtail \
  dnsutils python3 curl gnupg apt-transport-https

if ! command -v grafana-server >/dev/null 2>&1; then
  echo ">> Tambah repo Grafana (apt.grafana.com)..."
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -y
  apt-get install -y grafana
fi

# ---------- node_exporter (127.0.0.1:9100 + textfile) ----------
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
install -d -m 755 "$TEXTFILE_DIR"
cat > /etc/default/prometheus-node-exporter <<EOF
ARGS="--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=$TEXTFILE_DIR"
EOF
systemctl enable prometheus-node-exporter >/dev/null 2>&1 || true
systemctl restart prometheus-node-exporter

# ---------- Resolver lokal (unbound, 127.0.0.1:53) ----------
# Spamhaus menolak query DNSBL lewat resolver publik (1.1.1.1/8.8.8.8 -> 127.255.255.254).
# Dipakai rspamd dan cek DNSBL; DNS sistem (/etc/resolv.conf) tidak diubah.
if ! ss -lun | awk '{print $4}' | grep -q '^127\.0\.0\.1:53$'; then
  apt-get install -y unbound
  cat > /etc/unbound/unbound.conf.d/relay-local.conf <<'EOF'
server:
  interface: 127.0.0.1
  port: 53
  access-control: 127.0.0.0/8 allow
  do-ip6: no
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  prefetch: yes
  cache-min-ttl: 60
EOF
  unbound-checkconf
  systemctl enable unbound >/dev/null 2>&1 || true
  systemctl restart unbound
fi

# ---------- Metrik relay (antrian, transport->IP, blacklist) ----------
install -m 755 "$HERE/relay-metrics.sh" /usr/local/bin/relay-metrics.sh
cat > /etc/cron.d/relay-metrics <<'EOF'
# metrik relay untuk node_exporter (antrian, transport->IP, DNSBL tiap 15 menit)
* * * * * root /usr/local/bin/relay-metrics.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/relay-metrics
/usr/local/bin/relay-metrics.sh

# ---------- Alert (akun dibobol, ratelimit, blacklist, antrian) -> Telegram ----------
# Token & chat ID diisi manual di /etc/relay-alert.conf (tidak ditimpa bila sudah ada).
apt-get install -y jq >/dev/null
install -m 755 "$HERE/relay-alert.sh" /usr/local/bin/relay-alert.sh
[ -f /etc/relay-alert.conf ] || install -m 600 "$HERE/relay-alert.conf.example" /etc/relay-alert.conf
echo "*/5 * * * * root /usr/local/bin/relay-alert.sh >/dev/null 2>&1" > /etc/cron.d/relay-alert
chmod 644 /etc/cron.d/relay-alert

# ---------- mtail (127.0.0.1:3903) ----------
install -d -m 755 /etc/mtail
install -m 644 "$HERE/postfix_relay.mtail" /etc/mtail/postfix_relay.mtail
install -m 644 "$HERE/rspamd_relay.mtail"  /etc/mtail/rspamd_relay.mtail
# --port 0: validasi tanpa bentrok dengan daemon yang sedang jalan / tanpa listen ke luar
mtail --compile_only --progs /etc/mtail --address 127.0.0.1 --port 0 --logtostderr
MTAIL_USER=$(systemctl show -p User --value mtail 2>/dev/null || true)
if [ -n "$MTAIL_USER" ] && [ "$MTAIL_USER" != "root" ]; then
  usermod -aG adm "$MTAIL_USER"                       # /var/log/mail.log (syslog:adm 640)
  getent group _rspamd >/dev/null && usermod -aG _rspamd "$MTAIL_USER"
fi
LOGS="/var/log/mail.log"
[ -f /var/log/rspamd/rspamd.log ] && LOGS="$LOGS,/var/log/rspamd/rspamd.log"
cat > /etc/default/mtail <<EOF
ENABLED=1
PROGS=/etc/mtail
LOGS=$LOGS
HOST=127.0.0.1
PORT=3903
EOF
# Paket Ubuntu: pastikan unit memakai HOST/PORT/LOGS di atas
mkdir -p /etc/systemd/system/mtail.service.d
cat > /etc/systemd/system/mtail.service.d/override.conf <<'EOF'
[Service]
EnvironmentFile=/etc/default/mtail
ExecStart=
ExecStart=/usr/bin/mtail --progs ${PROGS} --logs ${LOGS} --address ${HOST} --port ${PORT} --logtostderr
EOF
systemctl daemon-reload
systemctl enable mtail >/dev/null 2>&1 || true
systemctl restart mtail

# ---------- Prometheus (127.0.0.1:9090) ----------
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s
scrape_configs:
  - job_name: prometheus
    static_configs: [{ targets: ['127.0.0.1:9090'] }]
  - job_name: node
    static_configs: [{ targets: ['127.0.0.1:9100'] }]
  - job_name: mtail
    static_configs: [{ targets: ['127.0.0.1:3903'] }]
EOF
cat > /etc/default/prometheus <<EOF
ARGS="--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=$RETENTION"
EOF
systemctl enable prometheus >/dev/null 2>&1 || true
systemctl restart prometheus

# ---------- Grafana (127.0.0.1:3000) ----------
if [ ! -s /root/.grafana_admin_password ]; then
  ( umask 077; openssl rand -base64 24 | tr -d '/+=' | cut -c1-24 > /root/.grafana_admin_password )
  GRAFANA_NEW_PW=1
fi
GINI=/etc/grafana/grafana.ini
[ -f "$GINI.orig" ] || cp -a "$GINI" "$GINI.orig"
cat > /etc/grafana/grafana.ini <<'EOF'
# [paths] wajib: tanpa ini 'grafana cli' menulis ke /usr/share/grafana/data (DB yang salah)
[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[server]
http_addr = 127.0.0.1
http_port = 3000

[security]
disable_initial_admin_creation = false
cookie_secure = false
disable_gravatar = true

[users]
allow_sign_up = false
allow_org_create = false

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
feedback_links_enabled = false

[snapshots]
external_enabled = false

[log]
mode = file
level = warn
EOF
if [ -n "$PUBLIC_DOMAIN" ]; then
  # Tetap listen 127.0.0.1; nginx yang membuka ke publik. Cookie hanya lewat HTTPS.
  sed -i "s|^http_port = 3000$|http_port = 3000\ndomain = $PUBLIC_DOMAIN\nroot_url = https://$PUBLIC_DOMAIN/|" "$GINI"
  sed -i 's|^cookie_secure = false$|cookie_secure = true\ncookie_samesite = strict|' "$GINI"
fi
chown root:grafana "$GINI"; chmod 640 "$GINI"

install -d -m 755 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF
cat > /etc/grafana/provisioning/dashboards/relay.yaml <<'EOF'
apiVersion: 1
providers:
  - name: relay
    folder: Relay
    type: file
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
EOF
install -m 644 "$HERE/grafana-relay-dashboard.json" /var/lib/grafana/dashboards/relay-postfix.json
chown -R grafana:grafana /var/lib/grafana/dashboards

systemctl enable grafana-server >/dev/null 2>&1 || true
systemctl restart grafana-server
for i in $(seq 1 30); do curl -sf http://127.0.0.1:3000/api/health >/dev/null && break; sleep 2; done
if [ "${GRAFANA_NEW_PW:-0}" = "1" ]; then
  grafana cli --homepath /usr/share/grafana --config "$GINI" admin reset-admin-password \
    "$(cat /root/.grafana_admin_password)" >/dev/null
fi
# Pastikan password admin dari /root/.grafana_admin_password berlaku (berarti admin/admin sudah tidak).
# Sengaja TIDAK mencoba admin/admin: login gagal memicu kunci brute-force Grafana (~5 menit).
if ! curl -s -o /dev/null -w '%{http_code}' -u "admin:$(cat /root/.grafana_admin_password)" \
     http://127.0.0.1:3000/api/user | grep -q '^200$'; then
  echo "ERROR: login admin dengan /root/.grafana_admin_password gagal. Reset password:" >&2
  echo "  grafana cli --homepath /usr/share/grafana --config $GINI admin reset-admin-password \"\$(cat /root/.grafana_admin_password)\"" >&2
  exit 1
fi

# ---------- Akses publik HTTPS (opsional) ----------
if [ -n "$PUBLIC_DOMAIN" ]; then
  echo ">> nginx: https://$PUBLIC_DOMAIN -> Grafana"
  apt-get install -y nginx
  cat > /etc/nginx/conf.d/relay-hardening.conf <<'EOF'
server_tokens off;
# Batasi percobaan login Grafana per IP (Grafana juga mengunci akun setelah login gagal berulang)
limit_req_zone $binary_remote_addr zone=grafana_login:10m rate=10r/m;
limit_req_status 429;
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
EOF
  cat > /etc/nginx/sites-available/relay-grafana.conf <<EOF
# Dashboard Grafana publik. Hanya Grafana yang diteruskan; Prometheus/mtail/rspamd tetap 127.0.0.1.
server {
    listen 80;
    server_name $PUBLIC_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$PUBLIC_DOMAIN\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $PUBLIC_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PUBLIC_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PUBLIC_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "same-origin" always;

    client_max_body_size 5m;

    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

__RSPAMD_LOCATION__
    location = /login {
        limit_req zone=grafana_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:3000;
    }
    location /api/live/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host       \$host;
        proxy_pass http://127.0.0.1:3000;
    }
    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/relay-grafana.conf /etc/nginx/sites-enabled/relay-grafana.conf
  rm -f /etc/nginx/sites-enabled/relay-acme.conf   # digantikan blok port 80 di atas
  NG=/etc/nginx/sites-available/relay-grafana.conf
  if [ "$RSPAMD_UI_PUBLIC" = "1" ]; then
    python3 -I - "$NG" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
block = '''    # Web UI rspamd (password wajib; password lihat != password admin). Gagal login berulang -> fail2ban.
    location = /rspamd { return 301 /rspamd/; }
    location /rspamd/ {
        proxy_pass http://127.0.0.1:11334/;
        proxy_set_header Host            $host;
        proxy_set_header X-Real-IP       $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        client_max_body_size 20m;
    }
'''
open(p, 'w').write(s.replace('__RSPAMD_LOCATION__\n', block))
PY
    # fail2ban: nginx mencatat 403 dari rspamd (password salah) dengan IP asli klien
    cat > /etc/fail2ban/filter.d/nginx-rspamd-auth.conf <<'EOF'
[Definition]
# 403 dari web UI rspamd = password salah / tanpa password
# (fail2ban membuang bagian tanggal [..] sebelum pencocokan, jadi jangan cocokkan \[...\])
failregex = ^<HOST> .*"(GET|POST) /rspamd/\S* HTTP/[0-9.]+" 403
ignoreregex =
EOF
    cat > /etc/fail2ban/jail.d/rspamd-ui.conf <<'EOF'
[rspamd-ui]
enabled  = true
port     = 80,443
filter   = nginx-rspamd-auth
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 600
bantime  = 3600
action   = route
EOF
    systemctl restart fail2ban || true
  else
    sed -i '/^__RSPAMD_LOCATION__$/d' "$NG"
    rm -f /etc/fail2ban/jail.d/rspamd-ui.conf
  fi
  nginx -t
  systemctl reload nginx
  command -v ufw >/dev/null && ufw allow 443/tcp comment "https grafana dashboard" >/dev/null || true
fi

# ---------- Verifikasi: semua port monitoring hanya di 127.0.0.1 ----------
sleep 2
BAD=$(ss -ltnp | awk 'NR>1{print $4}' | grep -E ':(3000|3903|9090|9100)$' | grep -v '^127\.0\.0\.1:' || true)
if [ -n "$BAD" ]; then
  echo "ERROR: port monitoring terbuka ke luar: $BAD" >&2
  exit 1
fi

echo
echo "=== MONITORING SIAP ==="
for s in prometheus prometheus-node-exporter mtail grafana-server; do printf "  %-26s %s\n" "$s" "$(systemctl is-active $s)"; done
echo
echo "Buka dashboard:"
if [ -n "$PUBLIC_DOMAIN" ]; then
  echo "  https://$PUBLIC_DOMAIN"
else
  echo "  ssh -L 3000:127.0.0.1:3000 root@<relay>"
  echo "  http://127.0.0.1:3000"
fi
echo "  user: admin, password: cat /root/.grafana_admin_password"
echo "  Dashboard: Relay > Relay Postfix"
