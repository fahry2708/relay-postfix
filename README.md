# relay-postfix

Script deploy Postfix SMTP relay khusus kirim (outbound) dengan rotasi IP sumber,
dipakai di depan mailbox server sebagai smarthost.

## Arsitektur

```
mailbox server (mynetworks) --SMTP 25/587--> relay Postfix --out1..outN (bind IP berbeda)--> Internet
```

- Hanya host di `mynetworks` yang boleh relay; `mydestination` kosong (relay tidak menerima mail lokal).
- Setiap IP keluar punya transport sendiri (`outN` di `master.cf`, `smtp_bind_address`).
- `/usr/local/bin/rotate_postfix_transport.sh` dijalankan cron tiap menit dan memutar
  `transport_maps` (`* outN:`) secara round-robin ke IP berikutnya.
- RBL di `smtpd_recipient_restrictions`, blokir pengirim via `sender_access` dan `header_checks`.
- fail2ban jail `postfix` dan `sshd` dengan aksi `route`.
- DKIM opsional: default ditandatangani di mailbox server upstream; bila selector dan key
  diisi saat deploy, relay ikut menandatangani via OpenDKIM.

## Pemakaian

```bash
sudo bash deploy_full_relay-update.sh
# atau tanpa prompt, isi via env:
sudo NONINTERACTIVE=1 RELAY_IPS="192.0.2.10 192.0.2.11" \
  DKIM_SELECTOR="sel1" DKIM_KEY_PATH=/root/sel1.private \
  bash deploy_full_relay-update.sh
```

| Variabel        | Default                                                        |
|-----------------|----------------------------------------------------------------|
| `DOMAIN`        | `serverkencang.com`                                            |
| `RELAY_FQDN`    | `relay.serverkencang.com`                                      |
| `RELAY_IPS`     | **wajib diisi manual**, urutan menentukan `out1`, `out2`, ...  |
| `MYNETWORKS`    | `127.0.0.0/8, [::1]/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16` |
| `RATE_DELAY`    | `1s`                                                           |
| `ROTATE_CRON`   | `* * * * *`                                                    |
| `DKIM_SELECTOR` | **diisi manual**; kosong = relay tidak menandatangani          |
| `DKIM_DOMAIN`   | sama dengan `DOMAIN`                                           |
| `DKIM_KEY_PATH` | **wajib diisi manual** bila `DKIM_SELECTOR` diisi (private key PEM) |

`MYNETWORKS` default hanya berisi jaringan private. Bila mailbox server upstream memakai
IP publik, tambahkan IP-nya (`/32`) saat deploy, kalau tidak relay akan menolak mail darinya.

IP rotasi dan DKIM sengaja tidak punya nilai bawaan di repo. Private key DKIM jangan
pernah di-commit; simpan di server dan berikan path-nya saat script dijalankan.
Bila DKIM diisi, relay menandatangani lewat OpenDKIM (`inet:127.0.0.1:8891`) dan
script mencetak record TXT yang harus ada di DNS.

Script idempotent: `main.cf` dan `master.cf` di-backup (`*.bak-<timestamp>`), blok `outN`
dibuat ulang, sedangkan `sender_access`/`header_checks` yang sudah ada tidak ditimpa.

## Filter spam keluar (Rspamd)

Rspamd dipasang sebagai milter (`inet:127.0.0.1:11332`). Bila rspamd mati, email tetap
lewat (`milter_default_action = accept`).

| Variabel        | Default   | Keterangan |
|-----------------|-----------|------------|
| `RSPAMD_MODE`   | `observe` | `observe`: skor dan tanda saja, tidak ada yang ditolak. `enforce`: skor ≥ `RSPAMD_REJECT` ditolak, kelebihan rate ditahan (4xx, upstream retry). `off`: tanpa rspamd. |
| `RL_DEFAULT`    | `100`     | Batas email per jam per pengirim envelope |
| `RL_OVERRIDES`  | **diisi manual** | Batas khusus, mis. `"cs@domain.tld=300 marketing@domain.tld=250"` |
| `RSPAMD_REJECT` | `15`      | Ambang skor reject pada mode `enforce` |

Alur yang disarankan: jalankan `observe` beberapa hari, lihat skor email asli di web UI,
lalu deploy ulang dengan `RSPAMD_MODE=enforce`.

- Semua port rspamd (11332/11333/11334) hanya di `127.0.0.1`; script berhenti bila tidak.
- Web UI: `ssh -L 11334:127.0.0.1:11334 root@<relay>` lalu buka `http://127.0.0.1:11334`.
  Password ada di `/root/.rspamd_ui_password` (dibuat acak, hanya root) dan **selalu wajib**,
  juga dari localhost (`secure_ip = []` di `override.d`).
- Rspamd 2.7 (paket Ubuntu) dipakai karena rspamd 3.x butuh CPU dengan SSE4.2/SSSE3.
- String uji GTUBE selalu memaksa reject, juga pada mode `observe`.
- Ratelimit tidak menghitung pemindaian manual via `rspamc`; uji lewat HTTP
  `curl -H "From: a@b" -H "IP: x" --data-binary @mail.eml http://127.0.0.1:11333/checkv2`.

## Keamanan

- **Firewall ufw:** port 25/587 hanya terbuka untuk host di `MYNETWORKS` (selain loopback),
  SSH (22) dan HTTP (80, untuk perpanjangan certbot) terbuka. Saat ufw pertama kali
  diaktifkan, ada pengaman yang otomatis mematikannya setelah 5 menit; uji SSH dari terminal
  lain lalu jalankan `systemctl stop ufw-failsafe.timer`. Lewati dengan `SKIP_FIREWALL=1`.
- **Ganti IP upstream:** jalankan ulang script dengan `MYNETWORKS` baru; aturan
  `smtp upstream` di ufw dibuat ulang. Atau manual:
  `ufw allow proto tcp from <IP> to any port 25,587 comment "smtp upstream"` dan
  sesuaikan `postconf -e "mynetworks = ..."`.
- **Jangan pasang proxy (HAProxy dll.) di depan port 25.** Postfix akan melihat semua
  klien sebagai `127.0.0.1` (anggota `mynetworks`) dan relay menjadi open relay. Script
  berhenti bila haproxy aktif.
- **Kirim lewat IPv4 saja** (`inet_protocols = ipv4`): `smtp_bind_address` hanya IPv4,
  sehingga IPv6 lolos dari rotasi dan ditolak Gmail (`550 5.7.25`, tanpa PTR).
- Web UI apa pun (rspamd, Grafana) hanya di-bind ke `127.0.0.1`; akses lewat SSH tunnel
  atau reverse proxy dengan HTTPS + login.

## Monitoring (Grafana)

```bash
sudo bash monitoring/install_monitoring.sh
```

Memasang Prometheus, Grafana, mtail, node_exporter, dan unbound. **Semua hanya listen di
`127.0.0.1`**; script berhenti bila ada port monitoring yang terbuka ke luar.

Buka dashboard:

- **Publik lewat domain** (opsional): `sudo PUBLIC_DOMAIN=relay.domain.tld bash monitoring/install_monitoring.sh`
  lalu buka `https://relay.domain.tld`. Butuh sertifikat Let's Encrypt untuk domain itu.
  nginx hanya meneruskan Grafana (HTTPS wajib, HTTP dialihkan), login dibatasi 10/menit per IP,
  cookie hanya HTTPS. Prometheus, mtail, dan rspamd tetap hanya `127.0.0.1`.
- **Tanpa domain**: lewat SSH tunnel
  ```bash
  ssh -L 3000:127.0.0.1:3000 root@<relay>
  # lalu buka http://127.0.0.1:3000
  ```

User `admin`, password: `cat /root/.grafana_admin_password`. Dashboard: **Relay > Relay Postfix**.

| Komponen | Port | Isi |
|---|---|---|
| mtail (`monitoring/*.mtail`) | 3903 | sent/deferred/bounced per `outN` dan per penyedia (Gmail/Yahoo/Microsoft), email baru per pengirim, skor rspamd, `RATELIMITED`, reject |
| `relay-metrics.sh` (cron tiap menit) | textfile | antrian Postfix, peta `outN` -> IP (dari `master.cf`), DNSBL tiap 15 menit (Spamhaus, Barracuda, SpamCop, PSBL) |
| node_exporter | 9100 | CPU, RAM, disk |
| Prometheus | 9090 | retensi 30 hari (`RETENTION`) |
| Grafana | 3000 | dashboard `monitoring/grafana-relay-dashboard.json` (provisioned) |
| unbound | 53 | resolver lokal untuk rspamd dan DNSBL; Spamhaus menolak resolver publik |

Catatan:
- Log Postfix tidak boleh tercatat dua kali (mtail dan fail2ban menghitung per baris). Script
  memindahkan aturan rsyslog kustom yang menulis `mail.log` + `stop` ke urutan `10-`.
- Jangan uji login Grafana dengan password salah berulang kali: Grafana mengunci akun sekitar 5 menit.

Perintah cepat:

```bash
tail -f /var/log/mail.log
postqueue -p
grep -oE 'postfix/out[0-9]+' /var/log/mail.log | sort | uniq -c   # distribusi per IP
```
