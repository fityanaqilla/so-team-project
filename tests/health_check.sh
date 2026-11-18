#!/usr/bin/env bash
# tests/health_check.sh — Smoke test pasca-deploy.
# Pakai:  ./tests/health_check.sh [--self-heal]
# --self-heal : kill -9 proses backend dan pastikan systemd menghidupkannya kembali (butuh root)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PORT="${APP_PORT:-}"
if [[ -z $APP_PORT && -r "$ROOT/.env" ]]; then
  APP_PORT=$(grep -E '^APP_PORT=' "$ROOT/.env" | head -n1 | cut -d= -f2 | tr -d '"' || true)
fi
APP_PORT="${APP_PORT:-8000}"

PASS=0; FAIL=0
check() {  # check "deskripsi" perintah...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [PASS] %s\n' "$desc"; PASS=$((PASS + 1))
  else
    printf '  [FAIL] %s\n' "$desc"; FAIL=$((FAIL + 1))
  fi
}

echo "== Layanan =="
for svc in mariadb webapp nginx; do check "$svc aktif" systemctl is-active --quiet "$svc"; done

echo "== Isolasi jaringan =="
check "backend hanya listen di 127.0.0.1:${APP_PORT}" \
  bash -c "ss -ltnH | awk '{print \$4}' | grep -qx '127.0.0.1:${APP_PORT}'"
check "backend TIDAK listen di 0.0.0.0/[::]" \
  bash -c "! ss -ltnH | awk '{print \$4}' | grep -Eq '^(0\\.0\\.0\\.0|\\*|\\[::\\]):${APP_PORT}\$'"
check "database TIDAK terekspos publik (3306)" \
  bash -c "! ss -ltnH | awk '{print \$4}' | grep -Eq '^(0\\.0\\.0\\.0|\\*|\\[::\\]):3306\$'"

echo "== Gateway & aplikasi =="
check "GET / via nginx = 200" curl -fsS --max-time 5 http://127.0.0.1/
check "GET /health via nginx = 200 (DB up)" curl -fsS --max-time 5 http://127.0.0.1/health
check "nginx meneruskan X-Real-IP ke backend" \
  bash -c "curl -fsS --max-time 5 http://127.0.0.1/whoami | grep -q '\"x_real_ip\": \"127.0.0.1\"'"
check "nginx meneruskan X-Forwarded-Proto" \
  bash -c "curl -fsS --max-time 5 http://127.0.0.1/whoami | grep -q '\"x_forwarded_proto\": \"http\"'"

echo "== Least privilege & sandbox =="
MAIN_PID=$(systemctl show --property MainPID --value webapp.service 2>/dev/null || echo 0)
check "proses backend berjalan sebagai user webapp (non-root)" \
  bash -c "[ \"\$(ps -o user= -p ${MAIN_PID} | tr -d ' ')\" = webapp ]"
check "ProtectSystem=strict aktif" bash -c "systemctl show -p ProtectSystem --value webapp.service | grep -qx strict"
check "NoNewPrivileges aktif" bash -c "systemctl show -p NoNewPrivileges --value webapp.service | grep -qx yes"
check "shell user webapp = nologin" bash -c "getent passwd webapp | grep -q 'nologin'"
if [[ -e /etc/webapp/webapp.env ]]; then
  check "env runtime berizin 600" bash -c "[ \"\$(stat -c %a /etc/webapp/webapp.env)\" = 600 ]"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "== Exposure score (informasional) =="
  systemd-analyze security webapp.service --no-pager 2>/dev/null | tail -n 1 || true
fi

if [[ ${1:-} == "--self-heal" ]]; then
  echo "== Uji self-healing =="
  if [[ $EUID -ne 0 ]]; then
    echo "  [SKIP] butuh root"
  else
    OLD_PID=$(systemctl show --property MainPID --value webapp.service)
    kill -9 "$OLD_PID"
    sleep 7
    NEW_PID=$(systemctl show --property MainPID --value webapp.service)
    check "systemd menghidupkan ulang (PID ${OLD_PID} -> ${NEW_PID})" \
      bash -c "systemctl is-active --quiet webapp.service && [ '${OLD_PID}' != '${NEW_PID}' ]"
  fi
fi

echo "------------------------------------------"
echo "Hasil: ${PASS} lulus, ${FAIL} gagal"
[[ $FAIL -eq 0 ]]
