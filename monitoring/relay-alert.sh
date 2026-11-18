#!/bin/bash
# relay-alert.sh: deteksi akun dibobol / masalah relay, kirim alert ke Telegram (cron tiap 5 menit).
# Konfigurasi: /etc/relay-alert.conf (chmod 600), contoh di relay-alert.conf.example.
# Tanpa token Telegram, alert hanya ditulis ke /var/log/relay-alert.log dan syslog (tag relay-alert).
#
# Deteksi akun dibobol butuh baris header_checks Postfix (dipasang install_monitoring.sh):
#   /^Received: from .*\[([0-9a-fA-F.:]+)\]\)?[[:space:]]+by [^[:space:]]+ \(Postfix\) with ESMTPSA/ WARN auth-origin $1
# yang mencatat IP asal login SMTP di server upstream (mis. Zimbra) per pengirim.
set -uo pipefail

CONF=${CONF:-/etc/relay-alert.conf}
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
ALERT_SENDER_PER_HOUR=150      # email/jam per pengirim (batas keras rspamd 300/jam)
ALERT_AUTH_IPS_24H=3           # IP login SMTP berbeda per akun dalam 24 jam
ALERT_DEFERRED=200             # email deferred di antrian
ALERT_REPEAT_SECONDS=3600      # alert yang sama tidak diulang sebelum ini
PROM=${PROM:-http://127.0.0.1:9090}
MAILLOG=${MAILLOG:-/var/log/mail.log}
STATE_DIR=${STATE_DIR:-/var/lib/relay-alert}
LOG=${LOG:-/var/log/relay-alert.log}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

mkdir -p "$STATE_DIR"
HOST=$(hostname -f 2>/dev/null || hostname)
ALERTS=()

prom() {  # prom <promql> -> baris "nilai-label... nilai"
  curl -s -m 10 -G "$PROM/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[]? | [(.metric | to_entries | map(.value) | join(" ")), .value[1]] | join(" ")' 2>/dev/null
}

add() {  # add <kunci-dedup> <pesan>
  local key f
  key=$(printf '%s' "$1" | md5sum | cut -c1-16); f="$STATE_DIR/$key"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt "$ALERT_REPEAT_SECONDS" ]; then return; fi
  touch "$f"; ALERTS+=("$2")
}

# 1) Volume per pengirim (1 jam terakhir, metrik mtail dari log rspamd)
while read -r sender n; do
  [ -z "${n:-}" ] && continue
  add "vol:$sender:$(date +%Y%m%d%H)" "📈 Pengirim <b>$sender</b> mengirim <b>${n%.*}</b> email dalam 1 jam terakhir (ambang $ALERT_SENDER_PER_HOUR)."
done < <(prom "sum by (sender) (increase(rspamd_relay_messages_total{sender!=\"\"}[1h])) > $ALERT_SENDER_PER_HOUR")

# 2) Kena ratelimit (soft reject) dalam 15 menit terakhir
while read -r sender n; do
  [ -z "${n:-}" ] && continue
  add "rl:$sender:$(date +%Y%m%d%H)" "⛔ Pengirim <b>$sender</b> melewati batas kirim per jam: ${n%.*} email ditahan sementara (soft reject) dalam 15 menit."
done < <(prom 'sum by (sender) (increase(rspamd_relay_messages_total{action="soft reject",sender!=""}[15m])) > 0')

# 3) Akun login SMTP dari banyak IP dalam 24 jam -> indikasi password bocor
since=$(date -d '-24 hours' +%s)
mapfile -t AUTH < <({ cat "$MAILLOG.1" 2>/dev/null; cat "$MAILLOG"; } | grep -a 'auth-origin' |
  awk -v since="$since" -v y="$(date +%Y)" '
    BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) mon[m[i]] = i }
    { split($3, t, ":"); ts = mktime(y " " mon[$1] " " $2 " " t[1] " " t[2] " " t[3]); if (ts < since) next
      if (!match($0, /from=<[^>]*>/)) next
      s = substr($0, RSTART + 6, RLENGTH - 7); ip = $NF
      if (!seen[s, ip]++) { cnt[s]++; ips[s] = ips[s] " " ip } }
    END { for (s in cnt) print s, cnt[s], ips[s] }')
for line in "${AUTH[@]}"; do
  read -r sender n iplist <<< "$line"
  [ "${n:-0}" -gt "$ALERT_AUTH_IPS_24H" ] || continue
  last=$(echo "$iplist" | tr ' ' '\n' | grep . | tail -10 | xargs)
  add "auth:$sender:$n" "🚨 Akun <b>$sender</b> login SMTP dari <b>$n IP berbeda</b> dalam 24 jam — kemungkinan password bocor. IP: <code>$last</code>. Ganti password di server email; tahan di relay bila perlu (/etc/postfix/sender_hold)."
done

# 4) IP relay masuk blacklist
while read -r ip list v; do
  [ -z "${v:-}" ] && continue
  add "dnsbl:$ip:$list:$(date +%Y%m%d)" "🛑 IP relay <b>$ip</b> terdaftar di blacklist <b>$list</b>."
done < <(prom 'relay_dnsbl_listed == 1')

# 5) Antrian deferred menumpuk
d=$(prom 'relay_postfix_queue_messages{queue="deferred"}' | awk '{print $NF}')
if [ -n "$d" ] && [ "${d%.*}" -gt "$ALERT_DEFERRED" ]; then
  add "queue:$(date +%Y%m%d%H)" "📬 Antrian deferred relay menumpuk: <b>${d%.*}</b> email (ambang $ALERT_DEFERRED)."
fi

# 6) Layanan penting mati
for s in postfix rspamd unbound; do
  systemctl is-active --quiet "$s" || add "svc:$s:$(date +%Y%m%d%H)" "❌ Layanan <b>$s</b> di relay tidak berjalan."
done

[ ${#ALERTS[@]} -eq 0 ] && exit 0
plain=$(printf '%s | ' "${ALERTS[@]}" | sed 's/<[^>]*>//g')
printf '%s %s\n' "$(date '+%F %T')" "$plain" >> "$LOG"
logger -t relay-alert -- "$plain"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  msg="<b>[relay] $HOST</b>"$'\n'"$(printf '%s\n' "${ALERTS[@]}")"
  for chat in $TELEGRAM_CHAT_ID; do   # boleh beberapa chat ID dipisah spasi (grup dan/atau pribadi)
    curl -s -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=$chat" --data-urlencode "parse_mode=HTML" \
      --data-urlencode "disable_web_page_preview=true" --data-urlencode "text=$msg" | grep -q '"ok":true' ||
      logger -t relay-alert "gagal kirim Telegram ke chat $chat"
  done
fi
exit 0
