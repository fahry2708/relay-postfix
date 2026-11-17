#!/bin/bash
# relay-metrics.sh: metrik untuk node_exporter textfile collector (dijalankan cron tiap menit).
# - antrian Postfix per queue + umur email tertua
# - peta transport outN -> IP (dibaca dari master.cf) + transport aktif rotasi
# - status blacklist (DNSBL) tiap IP keluar, dicek tiap DNSBL_INTERVAL detik
set -euo pipefail

OUT_DIR=${OUT_DIR:-/var/lib/prometheus/node-exporter}
OUT="$OUT_DIR/relay.prom"
DNSBL_CACHE=/var/lib/relay-metrics/dnsbl.prom
DNSBL_INTERVAL=${DNSBL_INTERVAL:-900}
DNSBL_RESOLVER=${DNSBL_RESOLVER:-127.0.0.1}   # resolver rekursif lokal (unbound); Spamhaus menolak resolver publik
DNSBL_LISTS=${DNSBL_LISTS:-"zen.spamhaus.org b.barracudacentral.org bl.spamcop.net psbl.surriel.com"}
MASTER=/etc/postfix/master.cf
TRANSPORT_FILE=/etc/postfix/transport_rotation

mkdir -p "$OUT_DIR" "$(dirname "$DNSBL_CACHE")"
TMP=$(mktemp "$OUT_DIR/.relay.prom.XXXXXX")
trap 'rm -f "$TMP"' EXIT

{
  echo "# HELP relay_postfix_queue_messages Jumlah email di antrian Postfix per queue."
  echo "# TYPE relay_postfix_queue_messages gauge"
  echo "# HELP relay_postfix_queue_oldest_seconds Umur email tertua di antrian (detik)."
  echo "# TYPE relay_postfix_queue_oldest_seconds gauge"
  postqueue -j 2>/dev/null | python3 -c '
import sys, json, time
now = time.time()
cnt = {"active": 0, "deferred": 0, "hold": 0, "incoming": 0, "maildrop": 0}
oldest = 0
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    q = m.get("queue_name", "unknown")
    cnt[q] = cnt.get(q, 0) + 1
    oldest = max(oldest, now - m.get("arrival_time", now))
for q, n in sorted(cnt.items()):
    print("relay_postfix_queue_messages{queue=\"%s\"} %d" % (q, n))
print("relay_postfix_queue_oldest_seconds %d" % oldest)
'

  echo "# HELP relay_transport_info Peta transport outN ke IP keluar (dari master.cf)."
  echo "# TYPE relay_transport_info gauge"
  awk '
    /^out[0-9]+[ \t]+unix/ { t=$1; next }
    t && /smtp_bind_address=/ { split($0, a, "smtp_bind_address="); split(a[2], b, /[ \t]/);
                                printf "relay_transport_info{transport=\"%s\",ip=\"%s\"} 1\n", t, b[1]; t="" }
    /^[^ \t#]/ { t="" }
  ' "$MASTER"

  echo "# HELP relay_transport_current Transport yang sedang aktif di rotasi."
  echo "# TYPE relay_transport_current gauge"
  cur=$(awk '/^\*/{print $2}' "$TRANSPORT_FILE" 2>/dev/null | tr -d ':')
  [ -n "$cur" ] && echo "relay_transport_current{transport=\"$cur\"} 1"
} > "$TMP"

# ---- DNSBL (di-cache, dicek ulang tiap DNSBL_INTERVAL) ----
age=$(( $(date +%s) - $(stat -c %Y "$DNSBL_CACHE" 2>/dev/null || echo 0) ))
if [ "$age" -ge "$DNSBL_INTERVAL" ]; then
  DTMP=$(mktemp "$DNSBL_CACHE.XXXXXX")
  {
    echo "# HELP relay_dnsbl_listed 1 bila IP keluar terdaftar di DNSBL."
    echo "# TYPE relay_dnsbl_listed gauge"
    echo "# HELP relay_dnsbl_error 1 bila query ke DNSBL ditolak/diblokir (mis. resolver publik ke Spamhaus)."
    echo "# TYPE relay_dnsbl_error gauge"
    for ip in $(awk '/smtp_bind_address=/{split($0,a,"smtp_bind_address="); split(a[2],b,/[ \t]/); print b[1]}' "$MASTER" | sort -u); do
      rev=$(awk -F. '{print $4"."$3"."$2"."$1}' <<< "$ip")
      for l in $DNSBL_LISTS; do
        ans=$(dig +short +time=3 +tries=1 @"$DNSBL_RESOLVER" "$rev.$l" A 2>/dev/null | grep -E '^127\.' | head -1 || true)
        listed=0; err=0
        if [ -n "$ans" ]; then
          # 127.255.255.x (Spamhaus) dan 127.0.0.255 = error/akses ditolak, bukan listing
          if [[ "$ans" =~ ^127\.255\.255\. ]] || [ "$ans" = "127.0.0.255" ]; then err=1; else listed=1; fi
        fi
        echo "relay_dnsbl_listed{ip=\"$ip\",list=\"$l\"} $listed"
        echo "relay_dnsbl_error{ip=\"$ip\",list=\"$l\"} $err"
      done
    done
    echo "relay_dnsbl_last_check_timestamp_seconds $(date +%s)"
  } > "$DTMP"
  mv "$DTMP" "$DNSBL_CACHE"
fi
[ -f "$DNSBL_CACHE" ] && cat "$DNSBL_CACHE" >> "$TMP"

chmod 644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
