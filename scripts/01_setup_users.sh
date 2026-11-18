#!/usr/bin/env bash
# 01 — Provisioning user, group, dan direktori (idempoten, least privilege)

setup_users() {
  log_info "[01] Provisioning user, group, dan direktori..."

  local nologin
  nologin=$(command -v nologin || true)
  nologin=${nologin:-/usr/sbin/nologin}

  getent group "$APP_GROUP" >/dev/null || groupadd -r "$APP_GROUP"

  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd -r -g "$APP_GROUP" -s "$nologin" -d "$APP_HOME" -M -c "Web Application Daemon" "$APP_USER"
    log_ok "User ${APP_USER} berhasil dibuat."
  else
    log_info "User ${APP_USER} sudah tersedia."
  fi

  # Direktori kerja: 0750, dimiliki user aplikasi
  install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$APP_HOME" "$APP_DATA_DIR" "$APP_LOG_DIR"
  # Direktori konfigurasi rahasia: root menulis, group webapp hanya membaca/traverse
  install -d -m 0750 -o root -g "$APP_GROUP" "$APP_ETC_DIR"

  log_ok "[01] Selesai."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  enable_strict_mode
  [[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
  setup_users
fi
