#!/bin/bash
# Daftar alamat penerima mati (bounce permanen / expired >1 hari) per pengirim.
# Output: /root/deadlist/deadlist-<sender>.txt (alamat saja) + deadlist-all.csv
# Tidak termasuk bounce karena kesalahan relay sendiri
# (5.7.25 PTR, 5.7.1 blok IP, 5.7.26/27 SPF/DMARC, 5.7.0).
# Alamat yang kemudian berhasil terkirim (status=sent) dikeluarkan dari daftar.
OUT=/root/deadlist
mkdir -p "$OUT"
LOGS="$(ls -1r /var/log/mail.log.*.gz 2>/dev/null) $(ls -1 /var/log/mail.log.1 /var/log/mail.log 2>/dev/null)"

for f in $LOGS; do
  case "$f" in *.gz) zcat "$f" ;; *) cat "$f" ;; esac
done | awk '
/qmgr\[[0-9]+\]: [0-9A-F]+: from=</ && !/status=expired/ {
  match($0, /\]: [0-9A-F]+:/); id = substr($0, RSTART+3, RLENGTH-4)
  match($0, /from=<[^>]*>/); snd[id] = tolower(substr($0, RSTART+6, RLENGTH-7))
  next
}
# pesan dibuang setelah 1 hari (maximal_queue_lifetime): tandai penerima yang masih deferred
/: from=<.*status=expired/ {
  match($0, /\]: [0-9A-F]+:/); id = substr($0, RSTART+3, RLENGTH-4)
  n = split(defr[id], L, "\t")
  for (i = 1; i <= n; i++) if (L[i] != "") {
    split(L[i], p, "\034"); key = p[1]
    if ((id SUBSEP key) in done) continue
    dead[key] = $1 " " $2 "\",\"expired_tidak_bisa_dihubungi\",\"" p[2] "\",\"" p[3]
  }
  delete defr[id]; next
}
/ to=<.* status=deferred/ {
  match($0, /\]: [0-9A-F]+:/); id = substr($0, RSTART+3, RLENGTH-4)
  match($0, /to=<[^>]*>/); rcpt = tolower(substr($0, RSTART+4, RLENGTH-5))
  s = snd[id]; if (s == "") s = "unknown"
  match($0, /dsn=[0-9.]+/); dsn = substr($0, RSTART+4, RLENGTH-4)
  r = $0; sub(/.*status=[a-z]+ \(/, "", r); gsub(/[",\t]/, " ", r); r = substr(r, 1, 140)
  if (tolower(r) ~ /spam|policy|rate limit|too many|ptr|reverse/) next
  if (index(defr[id], s "|" rcpt "\034") == 0) defr[id] = defr[id] s "|" rcpt "\034" dsn "\034" r "\t"
  next
}
/ to=<.* status=/ {
  match($0, /\]: [0-9A-F]+:/); id = substr($0, RSTART+3, RLENGTH-4)
  match($0, /to=<[^>]*>/); rcpt = tolower(substr($0, RSTART+4, RLENGTH-5))
  s = snd[id]; if (s == "") s = "unknown"
  key = s "|" rcpt
  if ($0 ~ /status=sent/) { delete dead[key]; done[id SUBSEP key] = 1; next }
  if ($0 !~ /status=(bounced|expired)/) next
  if ($0 ~ /dsn=5\.7\.(25|1|26|27|0),/) next
  if ($0 ~ /weren.t sent|PTR record|reverse lookup/) next
  # penolakan karena isi/kebijakan/reputasi, bukan alamat mati
  if (tolower($0) ~ /spam|policy|spf|dkim|dmarc|block|blacklist|listed|reputation|rate limit|too many|unsolicited|content/) next
  match($0, /dsn=[0-9.]+/); dsn = substr($0, RSTART+4, RLENGTH-4)
  r = $0; sub(/.*status=[a-z]+ \(/, "", r); gsub(/[",]/, " ", r); r = substr(r, 1, 140)
  lr = tolower(r)
  if ($0 ~ /status=expired/ || lr ~ /timed out|connection refused|no route/) cat = "expired_tidak_bisa_dihubungi"
  else if (lr ~ /quota|storage|full|exceeded/) cat = "mailbox_penuh"
  else cat = "alamat_atau_domain_tidak_ada"
  dead[key] = $1 " " $2 "\",\"" cat "\",\"" dsn "\",\"" r
}
END { for (k in dead) { split(k, a, "|"); print "\"" a[1] "\",\"" a[2] "\",\"" dead[k] "\"" } }
' | sort > "$OUT/.tmp"

{ echo "sender,recipient,last_date,kategori,dsn,reason"; cat "$OUT/.tmp"; } > "$OUT/deadlist-all.csv"
rm -f "$OUT"/deadlist-*.txt
cut -d, -f1,2 "$OUT/.tmp" | tr -d '"' | while IFS=, read -r s r; do
  echo "$r" >> "$OUT/deadlist-${s//[^a-zA-Z0-9@._-]/_}.txt"
done
rm -f "$OUT/.tmp"
