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

## Monitoring

```bash
tail -f /var/log/mail.log
postqueue -p
pflogsumm /var/log/mail.log
grep -oE 'postfix/out[0-9]+' /var/log/mail.log | sort | uniq -c   # distribusi per IP
```
