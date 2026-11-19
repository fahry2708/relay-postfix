#!/bin/bash
# deploy_full_relay-update.sh
# Deploy / re-sync Postfix SMTP relay (outbound only) dengan rotasi IP sumber.
# Disinkronkan dengan konfigurasi produksi relay.serverkencang.com (Ubuntu 22.04, Postfix 3.6).
#
# Pemakaian:
#   sudo bash deploy_full_relay-update.sh                  # interaktif, Enter = pakai default
#   sudo NONINTERACTIVE=1 bash deploy_full_relay-update.sh # langsung pakai default / env var
#
# Semua nilai bisa di-override lewat env var: DOMAIN, RELAY_FQDN, RELAY_IPS, MYNETWORKS,
# RATE_DELAY, ROTATE_CRON, RSPAMD_MODE, RL_MODE, RL_DEFAULT, RL_OVERRIDES, RL_EXEMPT, RSPAMD_REJECT,
# DKIM_SELECTOR, DKIM_DOMAIN, DKIM_KEY_PATH, SKIP_FIREWALL.
#
# IP rotasi (RELAY_IPS) dan DKIM SENGAJA tidak punya nilai bawaan: wajib diisi manual
# saat dijalankan (atau lewat env var), supaya tidak tersimpan di repo.
# DKIM opsional: kosongkan DKIM_SELECTOR untuk melewati (DKIM ditandatangani upstream).
#
# Script ini idempotent: aman dijalankan ulang. Blok transport outN di master.cf
# dibuat ulang dari awal, file map (sender_access, header_checks) tidak ditimpa bila sudah ada.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: jalankan sebagai root." >&2
  exit 1
fi

# ---------- Default (sesuai produksi) ----------
DEF_DOMAIN="serverkencang.com"
DEF_RELAY_FQDN="relay.serverkencang.com"
# Hanya host ini yang boleh relay (mailbox server upstream)
# Default hanya jaringan private. Upstream ber-IP publik WAJIB ditambahkan manual
# saat deploy (mis. "..., 198.51.100.25/32"), kalau tidak relay akan menolaknya.
DEF_MYNETWORKS="127.0.0.0/8, [::1]/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
DEF_RATE_DELAY="1s"
DEF_ROTATE_CRON="* * * * *"

ask() { # ask VAR "prompt" default
  local var="$1" prompt="$2" def="$3" val
  if [ -n "${!var:-}" ]; then return; fi
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    printf -v "$var" '%s' "$def"; return
  fi
  read -r -p "$prompt [$def]: " val
  printf -v "$var" '%s' "${val:-$def}"
}

ask_manual() { # ask_manual VAR "prompt" [optional]  -- tanpa default, wajib diisi manual
  local var="$1" prompt="$2" optional="${3:-}" val
  if [ -n "${!var:-}" ]; then return; fi
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    if [ -z "$optional" ]; then
      echo "ERROR: $var wajib diisi (set env $var=...)." >&2
      exit 1
    fi
    printf -v "$var" '%s' ""; return
  fi
  while :; do
    read -r -p "$prompt: " val
    if [ -n "$val" ] || [ -n "$optional" ]; then break; fi
    echo "  -> wajib diisi." >&2
  done
  printf -v "$var" '%s' "$val"
}

echo "=== SMTP Relay Deploy (Ubuntu 22.04 / Postfix) ==="
ask DOMAIN      "Domain"                             "$DEF_DOMAIN"
ask RELAY_FQDN  "Relay FQDN"                         "$DEF_RELAY_FQDN"
ask_manual RELAY_IPS "IP keluar untuk rotasi (pisah spasi, urutan = out1, out2, ...)"
ask MYNETWORKS  "mynetworks (host yang boleh relay)" "$DEF_MYNETWORKS"
ask RATE_DELAY  "default_destination_rate_delay"     "$DEF_RATE_DELAY"
ask ROTATE_CRON "Jadwal cron rotasi IP"              "$DEF_ROTATE_CRON"
ask RSPAMD_MODE "Mode rspamd (observe/enforce/off)" "observe"
case "$RSPAMD_MODE" in observe|enforce|off) ;; *) echo "ERROR: RSPAMD_MODE harus observe, enforce, atau off." >&2; exit 1;; esac
if [ "$RSPAMD_MODE" != "off" ]; then
  ask RL_MODE       "Mode rate limit (observe/enforce)" "$([ "$RSPAMD_MODE" = enforce ] && echo enforce || echo observe)"
  case "$RL_MODE" in observe|enforce) ;; *) echo "ERROR: RL_MODE harus observe atau enforce." >&2; exit 1;; esac
  ask RL_DEFAULT    "Batas email/jam per pengirim"   "100"
  ask RSPAMD_REJECT "Skor reject (mode enforce)"     "15"
  ask_manual RL_OVERRIDES "Batas khusus per alamat, mis. 'cs@domain.tld=300' (kosongkan bila tidak ada)" optional
  ask_manual RL_EXEMPT "Pengirim tanpa batas kirim, mis. akun broadcast (pisah spasi, kosongkan bila tidak ada)" optional
  [[ "$RL_DEFAULT" =~ ^[0-9]+$ ]] || { echo "ERROR: RL_DEFAULT harus angka." >&2; exit 1; }
  [[ "$RSPAMD_REJECT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: RSPAMD_REJECT harus angka." >&2; exit 1; }
  for o in $RL_OVERRIDES; do
    [[ "$o" =~ ^[^=@[:space:]]+@[^=@[:space:]]+=[0-9]+$ ]] || { echo "ERROR: RL_OVERRIDES '$o' harus format alamat=angka." >&2; exit 1; }
  done
fi
ask_manual DKIM_SELECTOR "DKIM selector (kosongkan = relay tidak menandatangani)" optional
if [ -n "$DKIM_SELECTOR" ]; then
  ask DKIM_DOMAIN "DKIM domain (d=)" "$DOMAIN"
  ask_manual DKIM_KEY_PATH "Path private key DKIM (PEM) untuk selector $DKIM_SELECTOR"
  if [ ! -f "$DKIM_KEY_PATH" ]; then
    echo "ERROR: file private key '$DKIM_KEY_PATH' tidak ditemukan." >&2
    exit 1
  fi
  if ! openssl pkey -in "$DKIM_KEY_PATH" -noout 2>/dev/null; then
    echo "ERROR: '$DKIM_KEY_PATH' bukan private key PEM yang valid." >&2
    exit 1
  fi
fi

read -r -a IPS <<< "$RELAY_IPS"
N=${#IPS[@]}
if [ "$N" -lt 1 ]; then
  echo "ERROR: minimal 1 IP." >&2
  exit 1
fi
for ip in "${IPS[@]}"; do
  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: '$ip' bukan alamat IPv4 yang valid." >&2
    exit 1
  fi
done
if [ "$(printf '%s\n' "${IPS[@]}" | sort | uniq -d | wc -l)" -gt 0 ]; then
  echo "ERROR: ada IP duplikat di daftar rotasi." >&2
  exit 1
fi

# Peringatkan bila IP belum terpasang di interface (bind akan gagal)
for ip in "${IPS[@]}"; do
  if ! ip -4 -o addr show | grep -qw "$ip"; then
    echo "WARNING: IP $ip belum terpasang di interface mana pun." >&2
  fi
done

export DEBIAN_FRONTEND=noninteractive

echo ">> Install paket..."
apt-get update -y
apt-get install -y postfix pflogsumm dnsutils rsyslog fail2ban cron openssl ufw

# JANGAN pasang proxy (HAProxy dll.) di depan port 25: Postfix akan melihat semua klien
# sebagai 127.0.0.1 (anggota mynetworks) sehingga relay menjadi open relay.
if systemctl is-active --quiet haproxy 2>/dev/null; then
  echo "ERROR: haproxy aktif. Matikan dulu (systemctl disable --now haproxy)." >&2
  exit 1
fi

# localhost wajib resolve (rspamd/opendkim bind ke localhost)
if ! getent hosts localhost >/dev/null; then
  echo ">> Menambahkan '127.0.0.1 localhost' ke /etc/hosts"
  sed -i '1i 127.0.0.1 localhost' /etc/hosts
fi
if [ -n "$DKIM_SELECTOR" ]; then
  apt-get install -y opendkim opendkim-tools
fi

echo ">> Hostname/mailname -> $RELAY_FQDN"
hostnamectl set-hostname "$RELAY_FQDN"
echo "$RELAY_FQDN" > /etc/mailname

# ---------- main.cf ----------
echo ">> Konfigurasi main.cf..."
BACKUP_TS=$(date +%Y%m%d%H%M%S)
cp -a /etc/postfix/main.cf   "/etc/postfix/main.cf.bak-$BACKUP_TS"
cp -a /etc/postfix/master.cf "/etc/postfix/master.cf.bak-$BACKUP_TS"

postconf -e "myhostname = $RELAY_FQDN"
postconf -e "myorigin = $DOMAIN"
postconf -e "mydestination ="
postconf -e "relayhost ="
postconf -e "mynetworks = $MYNETWORKS"
postconf -e "inet_interfaces = all"
# IPv4 saja: smtp_bind_address hanya IPv4, sehingga IPv6 lolos dari rotasi dan
# ditolak Gmail (550 5.7.25) karena tidak punya PTR.
postconf -e "inet_protocols = ipv4"
postconf -e "compatibility_level = 3.6"

# TLS (snakeoil default Ubuntu; ganti dengan sertifikat asli bila ada)
postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_loglevel = 1"
postconf -e "smtp_tls_CApath = /etc/ssl/certs"
postconf -e "smtp_tls_security_level = may"
postconf -e 'smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache'

# Restriksi: hanya mynetworks yang boleh relay
postconf -e "smtpd_helo_required = yes"
postconf -e "smtpd_delay_reject = yes"
postconf -e "disable_vrfy_command = yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_rbl_client zen.spamhaus.org, reject_rbl_client bl.spamcop.net, reject_rbl_client b.barracudacentral.org"
# sender_hold dicek PALING DEPAN (sebelum permit_mynetworks) agar akun upstream yang dibobol bisa ditahan.
postconf -e "smtpd_sender_restrictions = check_sender_access hash:/etc/postfix/sender_hold, permit_mynetworks, permit_sasl_authenticated, check_sender_access hash:/etc/postfix/sender_access, reject_unknown_sender_domain, reject_non_fqdn_sender"
postconf -e "header_checks = regexp:/etc/postfix/header_checks"

# Rate limit
postconf -e "default_destination_rate_delay = $RATE_DELAY"
postconf -e "smtp_destination_concurrency_limit = 30"
postconf -e "smtp_extra_recipient_limit = 100"
postconf -e "max_use = 200"

# ---------- DKIM (opsional, diisi manual) ----------
DKIM_TXT=""
if [ -n "$DKIM_SELECTOR" ]; then
  echo ">> Konfigurasi OpenDKIM: selector $DKIM_SELECTOR, d=$DKIM_DOMAIN"
  KEYDIR="/etc/opendkim/keys/$DKIM_DOMAIN"
  install -d -m 750 -o opendkim -g opendkim /etc/opendkim /etc/opendkim/keys "$KEYDIR"
  install -m 600 -o opendkim -g opendkim "$DKIM_KEY_PATH" "$KEYDIR/$DKIM_SELECTOR.private"

  echo "$DKIM_SELECTOR._domainkey.$DKIM_DOMAIN $DKIM_DOMAIN:$DKIM_SELECTOR:$KEYDIR/$DKIM_SELECTOR.private" \
    > /etc/opendkim/KeyTable
  echo "*@$DKIM_DOMAIN $DKIM_SELECTOR._domainkey.$DKIM_DOMAIN" > /etc/opendkim/SigningTable
  # Sign semua mail dari mynetworks
  { echo "127.0.0.1"; echo "::1"
    tr ',' '\n' <<< "$MYNETWORKS" | sed 's/[][ ]//g' | grep -v '^$'
  } | sort -u > /etc/opendkim/TrustedHosts

  [ -f /etc/opendkim.conf.orig ] || cp -a /etc/opendkim.conf /etc/opendkim.conf.orig
  cat > /etc/opendkim.conf <<'ODK'
Syslog                  yes
SyslogSuccess           yes
UMask                   007
UserID                  opendkim
Mode                    s
Canonicalization        relaxed/simple
OversignHeaders         From
SignatureAlgorithm      rsa-sha256
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
Socket                  inet:8891@127.0.0.1
PidFile                 /run/opendkim/opendkim.pid
TrustAnchorFile         /usr/share/dns/root.key
ODK
  systemctl enable opendkim >/dev/null 2>&1 || true
  systemctl restart opendkim

  DKIM_P=$(openssl pkey -in "$KEYDIR/$DKIM_SELECTOR.private" -pubout 2>/dev/null \
    | grep -v -- '-----' | tr -d '\n')
  DKIM_TXT="$DKIM_SELECTOR._domainkey.$DKIM_DOMAIN. TXT \"v=DKIM1; k=rsa; p=$DKIM_P\""
fi

# ---------- Rspamd (filter spam keluar + rate limit per pengirim) ----------
# RSPAMD_MODE: observe (default) = skor & tanda saja, tidak ada yang ditolak
#              enforce            = skor >= RSPAMD_REJECT ditolak
# RL_MODE     : observe = kelebihan rate hanya ditandai; enforce = kelebihan ditahan (4xx, upstream retry)
#              off                = rspamd tidak dipasang/dilepas dari Postfix
# RL_DEFAULT  : batas email per jam per pengirim envelope (default 100)
# RL_OVERRIDES: batas khusus, format "alamat=angka alamat2=angka" (diisi manual, tanpa default)
# RL_EXEMPT   : pengirim yang dilewati ratelimit sama sekali (settings rspamd), mis. akun broadcast
if [ "$RSPAMD_MODE" != "off" ]; then
  echo ">> Konfigurasi rspamd (mode: $RSPAMD_MODE)..."
  apt-get install -y rspamd redis-server unbound
  # Resolver rekursif lokal: rspamd butuh DNS yang tidak diblokir Spamhaus/SURBL
  # (resolver publik 1.1.1.1/8.8.8.8 ditolak). DNS sistem tidak diubah.
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
  unbound-checkconf >/dev/null
  systemctl enable unbound >/dev/null 2>&1 || true
  systemctl restart unbound
  RD=/etc/rspamd/local.d
  [ -d "$RD.bak-$BACKUP_TS" ] || cp -a "$RD" "$RD.bak-$BACKUP_TS"

  # Semua worker HANYA di localhost. Dulu controller bind 0.0.0.0:11334 dan disalahgunakan.
  # Dua password acak: lihat (history/skor) dan admin (ubah setelan/learn). Bila password lihat
  # bocor (mis. UI dibuka publik), setelan filter tetap tidak bisa diubah.
  for f in /root/.rspamd_ui_password /root/.rspamd_ui_enable_password; do
    [ -s "$f" ] || ( umask 077; openssl rand -base64 24 | tr -d '/+=' | cut -c1-24 > "$f" )
  done
  # rspamadm mencetak peringatan CPU ke stdout; ambil baris hash saja
  rspamd_hash() { rspamadm pw -p "$(cat "$1")" 2>/dev/null | grep -E '^\$[0-9]+\$' | tail -1; }
  RSPAMD_VIEW_HASH=$(rspamd_hash /root/.rspamd_ui_password)
  RSPAMD_ADMIN_HASH=$(rspamd_hash /root/.rspamd_ui_enable_password)
  cat > $RD/worker-controller.inc <<EOF
# Web UI hanya localhost. Akses: ssh -L 11334:127.0.0.1:11334 root@<relay>
# atau https://<domain>/rspamd/ (monitoring/install_monitoring.sh, RSPAMD_UI_PUBLIC=1)
# password        = hanya lihat  -> /root/.rspamd_ui_password
# enable_password = admin        -> /root/.rspamd_ui_enable_password
bind_socket = "127.0.0.1:11334";
password = "$RSPAMD_VIEW_HASH";
enable_password = "$RSPAMD_ADMIN_HASH";
EOF
  chmod 640 $RD/worker-controller.inc; chown root:_rspamd $RD/worker-controller.inc
  # Bawaan rspamd: 127.0.0.1 boleh masuk UI tanpa password (secure_ip). Akses lewat SSH tunnel
  # atau reverse proxy selalu tampak dari 127.0.0.1, jadi kosongkan agar password selalu wajib.
  mkdir -p /etc/rspamd/override.d
  cat > /etc/rspamd/override.d/worker-controller.inc <<'EOF'
secure_ip = [];
EOF
  echo 'bind_socket = "127.0.0.1:11333";' > $RD/worker-normal.inc
  cat > $RD/worker-proxy.inc <<'EOF'
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF
  echo 'count = -1;' > $RD/worker-fuzzy.inc
  echo 'servers = "127.0.0.1";' > $RD/redis.conf
  echo 'enabled = false;' > $RD/greylist.conf
  echo 'use = [];' > $RD/milter_headers.conf   # jangan tambah header rspamd ke email keluar
  echo 'nrows = 2000;' > $RD/history_redis.conf  # history web UI 2000 email (default 200 = beberapa jam)

  # Upstream (MYNETWORKS) = lokal: cek berbasis IP (SPF/RBL) dilewati, konten tetap dicek
  LOCAL_ADDRS=$(tr ',' '\n' <<< "$MYNETWORKS" | sed 's/[][ ]//g' | grep -v '^$' | paste -sd, | sed 's/,/, /g')
  cat > $RD/options.inc <<EOF
local_addrs = [$LOCAL_ADDRS];
dns {
  nameserver = ["127.0.0.1"];
}
EOF

  if [ "$RSPAMD_MODE" = "enforce" ]; then
    cat > $RD/actions.conf <<EOF
reject = $RSPAMD_REJECT;
add_header = null;
rewrite_subject = null;
greylist = null;
EOF
  else
    cat > $RD/actions.conf <<'EOF'
# Observasi: semua aksi dimatikan; skor tetap dicatat di log/history.
# Catatan: string uji GTUBE tetap memaksa reject (pre-result bawaan rspamd).
reject = null;
add_header = null;
rewrite_subject = null;
greylist = null;
EOF
  fi

  # Rate limit per pengirim envelope. rspamd 2.7: 'symbol' hanya bisa di tingkat modul.
  # RL_MODE terpisah dari RSPAMD_MODE: batas kirim bisa enforce walau skor spam masih observasi.
  if [ "$RL_MODE" = "enforce" ]; then RL_SYMBOL_LINE=""; else RL_SYMBOL_LINE='symbol = "RATELIMITED";'; fi
  OVR_ADDRS=""; OVR_RATES=""
  for o in $RL_OVERRIDES; do
    a=${o%%=*}; n=${o##*=}
    a=$(tr 'A-Z' 'a-z' <<< "$a")
    OVR_ADDRS+="${OVR_ADDRS:+, }'$a'"
    key=$(tr -c 'a-z0-9\n' '_' <<< "$a")
    OVR_RATES+="  sender_${key} = {
    selector = \"from:addr.lower.in('$a')\";
    bucket = { burst = $n; rate = \"$n / 1h\"; }
  }
"
  done
  if [ -n "$OVR_ADDRS" ]; then
    DEF_SELECTOR="from:addr.lower.not_in($OVR_ADDRS)"
  else
    DEF_SELECTOR="from:addr.lower"
  fi
  cat > $RD/ratelimit.conf <<EOF
# Rate limit mode $RL_MODE. observe: hanya simbol RATELIMITED; enforce: kelebihan ditahan (4xx, upstream retry).
$RL_SYMBOL_LINE
rates {
  sender_default = {
    selector = "$DEF_SELECTOR";
    bucket = { burst = $RL_DEFAULT; rate = "$RL_DEFAULT / 1h"; }
  }
$OVR_RATES}
EOF

  # Pengecualian ratelimit lewat modul settings: RATELIMIT_CHECK/UPDATE dimatikan untuk pengirim ini.
  if [ -n "$RL_EXEMPT" ]; then
    EX_LIST=$(for a in $RL_EXEMPT; do printf '"%s", ' "$(tr 'A-Z' 'a-z' <<< "$a")"; done | sed 's/, $//')
    cat > $RD/settings.conf <<EOF
# Pengirim tanpa ratelimit (RL_EXEMPT). Alert volume Telegram tetap bisa diatur terpisah.
ratelimit_exempt {
  priority = high;
  from = [$EX_LIST];
  apply {
    symbols_disabled = ["RATELIMIT_CHECK", "RATELIMIT_UPDATE"];
  }
}
EOF
  else
    rm -f $RD/settings.conf
  fi

  rspamadm configtest 2>&1 | grep -vE 'hyperscan|SSSE3' || true
  rspamadm configtest >/dev/null 2>&1 || { echo "ERROR: konfigurasi rspamd tidak valid." >&2; exit 1; }
  systemctl enable rspamd redis-server >/dev/null 2>&1 || true
  systemctl restart rspamd
  sleep 3
  if ss -ltnp | grep rspamd | awk '{print $4}' | grep -vq '^127\.0\.0\.1:'; then
    echo "ERROR: ada port rspamd yang tidak di 127.0.0.1!" >&2
    ss -ltnp | grep rspamd >&2
    exit 1
  fi
fi

# ---------- Milter Postfix (rspamd lalu opendkim, agar tanda tangan paling akhir) ----------
MILTERS=""
[ "$RSPAMD_MODE" != "off" ] && MILTERS="inet:127.0.0.1:11332"
[ -n "$DKIM_SELECTOR" ] && MILTERS="${MILTERS:+$MILTERS, }inet:127.0.0.1:8891"
if [ -n "$MILTERS" ]; then
  postconf -e "milter_default_action = accept"   # milter mati = email tetap lewat
  postconf -e "milter_protocol = 6"
  postconf -e "milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}"
  postconf -e "smtpd_milters = $MILTERS"
  postconf -e "non_smtpd_milters = $MILTERS"
else
  postconf -X smtpd_milters non_smtpd_milters milter_default_action milter_protocol milter_mail_macros 2>/dev/null || true
fi

# ---------- Map blokir pengirim ----------
# Tidak ditimpa bila sudah ada (berisi daftar blokir operasional).
if [ ! -f /etc/postfix/sender_access ]; then
  cat > /etc/postfix/sender_access <<'EOF'
# alamat@domain.tld    REJECT Sending temporarily disabled
EOF
fi
if [ ! -f /etc/postfix/header_checks ]; then
  cat > /etc/postfix/header_checks <<'EOF'
# /^From:.*alamat@domain\.tld/i REJECT sender blocked
EOF
fi
if [ ! -f /etc/postfix/sender_hold ]; then
  cat > /etc/postfix/sender_hold <<'EOF'
# Akun yang dibobol: email ditahan di hold queue, tidak dikirim keluar.
# alamat@domain.tld    HOLD akun dibobol, ditahan sementara
# Lihat: postqueue -p | grep '!'   Lepas: postsuper -H <id>   Hapus: postsuper -d <id>
EOF
fi
# Catat IP asal login SMTP (ESMTPSA) di server upstream -> deteksi akun dibobol (monitoring/relay-alert.sh)
grep -q 'auth-origin' /etc/postfix/header_checks || cat >> /etc/postfix/header_checks <<'EOF'
/^Received: from .*\[([0-9a-fA-F.:]+)\]\)?[[:space:]]+by [^[:space:]]+ \(Postfix\) with ESMTPSA/ WARN auth-origin $1
EOF
postmap hash:/etc/postfix/sender_access
postmap hash:/etc/postfix/sender_hold

# ---------- master.cf ----------
echo ">> Konfigurasi master.cf (submission + transport out1..out$N)..."
MASTER=/etc/postfix/master.cf

# Buang blok outN lama (baris "outN unix ..." beserta baris lanjutan "  -o ...")
# serta komentar penanda dari versi script lama.
awk '
  /^out[0-9]+[ \t]+unix/ { skip=1; next }
  skip && /^[ \t]+/      { next }
  { skip=0 }
  /^# transport out[0-9]+ binds to / { next }
  { print }
' "$MASTER" > "$MASTER.tmp"
# Hapus baris kosong di akhir file
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$MASTER.tmp"
cat "$MASTER.tmp" > "$MASTER"
rm -f "$MASTER.tmp"

# Submission (587): wajib TLS
postconf -M submission/inet="submission inet n - y - - smtpd"
postconf -P "submission/inet/syslog_name=postfix/submission"
postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
postconf -P "submission/inet/smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
postconf -P "submission/inet/smtpd_relay_restrictions=permit_mynetworks,reject_unauth_destination"
postconf -P "submission/inet/smtpd_client_restrictions="

{
  echo
  for i in $(seq 1 "$N"); do
    ip="${IPS[$((i-1))]}"
    cat <<EOF
out${i} unix - - n - - smtp
  -o smtp_bind_address=${ip}
  -o syslog_name=postfix/out${i}
  -o smtp_connect_timeout=30s
  -o smtp_helo_timeout=30s
EOF
  done
} >> "$MASTER"

# ---------- Rotasi transport ----------
TRANSPORT_FILE=/etc/postfix/transport_rotation
[ -f "$TRANSPORT_FILE" ] || echo "*    out1:" > "$TRANSPORT_FILE"
# Bila transport aktif di luar jangkauan (jumlah IP berkurang), reset ke out1
cur=$(awk '/^\*/{print $2}' "$TRANSPORT_FILE" | sed -E 's/^out([0-9]+):?$/\1/')
if ! [[ "$cur" =~ ^[0-9]+$ ]] || [ "$cur" -gt "$N" ]; then
  echo "*    out1:" > "$TRANSPORT_FILE"
fi
postmap hash:$TRANSPORT_FILE
postconf -e "transport_maps = hash:$TRANSPORT_FILE"

ROTATOR=/usr/local/bin/rotate_postfix_transport.sh
cat > "$ROTATOR" <<ROT
#!/bin/bash
TRANSPORT_FILE="/etc/postfix/transport_rotation"
MAX=${N}
ROT
cat >> "$ROTATOR" <<'ROT'
if [ ! -f "$TRANSPORT_FILE" ]; then
  echo "*    out1:" > "$TRANSPORT_FILE"
  postmap hash:$TRANSPORT_FILE
  exit 0
fi
cur=$(awk '/^\*/{print $2}' "$TRANSPORT_FILE" 2>/dev/null || echo "out1:")
cur=${cur%%:}
num=$(echo "$cur" | sed -E 's/out([0-9]+)/\1/')
if ! [[ $num =~ ^[0-9]+$ ]]; then num=1; fi
next=$(( (num % MAX) + 1 ))
echo "*    out${next}:" > "$TRANSPORT_FILE"
postmap hash:$TRANSPORT_FILE
/sbin/postfix reload >/dev/null 2>&1 || /usr/sbin/postfix reload >/dev/null 2>&1 || true
ROT
chmod 755 "$ROTATOR"

cat > /etc/cron.d/postfix-rotate <<CRON
# rotate postfix transport every minute
${ROTATE_CRON} root ${ROTATOR} >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/postfix-rotate

# ---------- Firewall (ufw) ----------
# 25/587 hanya dari host di MYNETWORKS (selain loopback). SSH dan 80 (certbot) terbuka.
# Ganti IP upstream: jalankan ulang script dengan MYNETWORKS baru (aturan smtp dibuat ulang).
if [ "${SKIP_FIREWALL:-0}" != "1" ]; then
  echo ">> Konfigurasi firewall ufw..."
  SMTP_CLIENTS=$(tr ',' '\n' <<< "$MYNETWORKS" | sed 's/[][ ]//g' \
    | grep -vE '^$|^127\.|^::1' | grep -E '^[0-9.]+(/[0-9]+)?$' || true)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment "ssh" >/dev/null
  ufw allow 80/tcp comment "http (certbot renew)" >/dev/null
  # Hapus aturan smtp lama lalu buat ulang dari MYNETWORKS
  while n=$(ufw status numbered | grep -m1 "# smtp upstream" | grep -oP '^\[\s*\K[0-9]+'); [ -n "$n" ]; do
    ufw --force delete "$n" >/dev/null
  done
  for c in $SMTP_CLIENTS; do
    ufw allow proto tcp from "$c" to any port 25,587 comment "smtp upstream" >/dev/null
  done
  if ! ufw status | grep -q "Status: active"; then
    # Pengaman: bila SSH terkunci, ufw otomatis dimatikan setelah 5 menit.
    # Batalkan setelah login SSH baru berhasil: systemctl stop ufw-failsafe.timer
    systemd-run --unit=ufw-failsafe --on-active=300 /usr/sbin/ufw --force disable >/dev/null 2>&1 || true
    ufw --force enable
    echo "   ufw baru diaktifkan. Uji SSH dari terminal lain lalu: systemctl stop ufw-failsafe.timer"
  fi
  [ -z "$SMTP_CLIENTS" ] && echo "WARNING: tidak ada IP upstream di MYNETWORKS; port 25/587 tertutup untuk semua host luar." >&2
  ufw status numbered
fi

# ---------- fail2ban ----------
echo ">> Konfigurasi fail2ban (postfix + sshd, aksi route)..."
cat > /etc/fail2ban/jail.d/postfix.conf <<'F2B'
[postfix]
enabled  = true
port     = 25,465,587
filter   = postfix
logpath  = /var/log/mail.log
maxretry = 3
bantime  = 86400
findtime = 600
action   = route
F2B
cat > /etc/fail2ban/jail.d/sshd.conf <<'F2B'
[sshd]
backend=systemd
enabled = true
port = 22
filter = sshd
logpath = /var/log/secure
maxretry = 10
findtime = 3600
bantime = 31536000
banaction = route
F2B
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban || true

# ---------- Validasi & restart ----------
echo ">> Validasi konfigurasi Postfix..."
postfix check
systemctl enable postfix >/dev/null 2>&1 || true
systemctl restart postfix

echo
echo "=== DEPLOY SELESAI ==="
echo "Relay      : $RELAY_FQDN ($N IP keluar, rotasi out1..out$N via cron: $ROTATE_CRON)"
echo "mynetworks : $MYNETWORKS"
echo "Backup     : /etc/postfix/main.cf.bak-$BACKUP_TS, /etc/postfix/master.cf.bak-$BACKUP_TS"
echo
echo "Checklist DNS:"
echo "  - PTR tiap IP -> $RELAY_FQDN, dan A $RELAY_FQDN mengarah ke IP tsb (FCrDNS)"
echo "  - SPF domain pengirim harus mencakup IP relay, mis.: include:_spf.$DOMAIN atau a:$RELAY_FQDN"
if [ -n "$DKIM_TXT" ]; then
  echo "  - DKIM: relay menandatangani d=$DKIM_DOMAIN. Pastikan TXT ini ada di DNS:"
  echo "    $DKIM_TXT"
  echo "    Cek: opendkim-testkey -d $DKIM_DOMAIN -s $DKIM_SELECTOR -vvv"
else
  echo "  - DKIM ditandatangani di mailbox server upstream (relay tidak menandatangani)"
fi
echo
echo "Monitoring:"
echo "  tail -f /var/log/mail.log"
echo "  postqueue -p"
echo "  pflogsumm /var/log/mail.log"
echo "  cat $TRANSPORT_FILE"
