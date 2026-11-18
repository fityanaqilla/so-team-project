#!/usr/bin/env bash
# tests/idempotency_test.sh — Bukti idempotensi: jalankan deploy.sh 2x, bandingkan state akhir.
# Pakai: sudo ./tests/idempotency_test.sh   (hasil tersimpan di tests/evidence/)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "Jalankan dengan sudo." >&2; exit 1; }

OUT="$ROOT/tests/evidence"; mkdir -p "$OUT"

snapshot() {
  sha256sum /etc/nginx/conf.d/webapp.conf /etc/systemd/system/webapp.service \
            /etc/webapp/webapp.env /var/www/webapp/app.py
  id webapp; getent group webapp
  stat -c '%n %U:%G %a' /var/www/webapp /var/www/webapp/data /var/log/webapp /etc/webapp
  systemctl is-enabled webapp nginx mariadb
  systemctl is-active webapp nginx mariadb
  ls /etc/nginx/conf.d
  grep -c . /etc/nginx/conf.d/webapp.conf
}

echo "=== Run #1 ==="
"$ROOT/deploy.sh" 2>&1 | tee "$OUT/run1.log"; RC1=${PIPESTATUS[0]}
snapshot > "$OUT/state1.txt" 2>&1

echo "=== Run #2 ==="
"$ROOT/deploy.sh" 2>&1 | tee "$OUT/run2.log"; RC2=${PIPESTATUS[0]}
snapshot > "$OUT/state2.txt" 2>&1

echo "-----------------------------------------"
echo "Exit code run #1: $RC1 | run #2: $RC2"
if [[ $RC1 -eq 0 && $RC2 -eq 0 ]] && diff -u "$OUT/state1.txt" "$OUT/state2.txt"; then
  echo "[PASS] Idempoten: kedua eksekusi sukses dan state akhir identik."
else
  echo "[FAIL] Terdapat error atau perbedaan state antar eksekusi."; exit 1
fi
