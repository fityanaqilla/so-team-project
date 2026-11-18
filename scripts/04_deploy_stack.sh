#!/usr/bin/env bash
# 04 — Deploy tier 3 (DB), tier 2 (app + systemd), tier 1 (nginx). Idempoten.

APP_RESTART_NEEDED=0

_mysql_bin() { command -v mariadb || command -v mysql; }

deploy_database() {
  log_info "[04a] Database (MariaDB)..."
  local cnf_dir mysql_bin pass
  case $PKG_FAMILY in
    debian) cnf_dir="/etc/mysql/mariadb.conf.d" ;;
    rhel)   cnf_dir="/etc/my.cnf.d" ;;
  esac
  install -d -m 0755 "$cnf_dir"
  install_if_changed "${PROJECT_ROOT}/configs/database.cnf" "${cnf_dir}/99-webapp-hardening.cnf" 0644 root:root
  local cnf_changed=$FILE_CHANGED

  systemctl enable --now mariadb
  if [[ $cnf_changed -eq 1 ]]; then
    systemctl restart mariadb
  fi

  mysql_bin=$(_mysql_bin) || die "Klien mariadb/mysql tidak ditemukan."
  wait_until 30 "MariaDB siap menerima koneksi" "$mysql_bin" -e 'SELECT 1'

  pass=$(sql_escape "$DB_PASS")
  # SQL dikirim via stdin: password tidak muncul di daftar proses.
  "$mysql_bin" <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${pass}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  log_ok "[04a] Database '${DB_NAME}' & user '${DB_USER}' siap."
}

deploy_app() {
  log_info "[04b] Aplikasi backend & environment runtime..."
  install_if_changed "${PROJECT_ROOT}/app/app.py" "${APP_HOME}/app.py" 0640 "root:${APP_GROUP}"
  local app_changed=$FILE_CHANGED

  # File env runtime: berisi secret, hanya root (systemd membacanya sebagai root)
  local rendered="${TMP_DIR}/webapp.env"
  (
    umask 077
    {
      printf 'APP_HOST=%s\n' "$(systemd_quote "127.0.0.1")"
      printf 'APP_PORT=%s\n' "$(systemd_quote "$APP_PORT")"
      printf 'DB_HOST=%s\n'  "$(systemd_quote "$DB_HOST")"
      printf 'DB_PORT=%s\n'  "$(systemd_quote "$DB_PORT")"
      printf 'DB_NAME=%s\n'  "$(systemd_quote "$DB_NAME")"
      printf 'DB_USER=%s\n'  "$(systemd_quote "$DB_USER")"
      printf 'DB_PASS=%s\n'  "$(systemd_quote "$DB_PASS")"
    } > "$rendered"
  )
  install_if_changed "$rendered" "$APP_ENV_FILE" 0600 root:root
  local env_changed=$FILE_CHANGED

  if [[ $app_changed -eq 1 || $env_changed -eq 1 ]]; then
    APP_RESTART_NEEDED=1
  fi
  log_ok "[04b] Selesai."
}

deploy_systemd() {
  log_info "[04c] Systemd unit ${SERVICE_NAME}..."
  install_if_changed "${PROJECT_ROOT}/systemd/webapp.service" "/etc/systemd/system/${SERVICE_NAME}" 0644 root:root
  local unit_changed=$FILE_CHANGED
  if [[ $unit_changed -eq 1 ]]; then
    systemctl daemon-reload
  fi

  local was_active=0
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    was_active=1
  fi
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
  systemctl enable --now "$SERVICE_NAME"
  if [[ $was_active -eq 1 && ( $unit_changed -eq 1 || $APP_RESTART_NEEDED -eq 1 ) ]]; then
    systemctl restart "$SERVICE_NAME"
  fi

  if ! wait_until 30 "backend sehat di 127.0.0.1:${APP_PORT}" \
      curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/health"; then
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
    die "Backend tidak sehat setelah start. Periksa: journalctl -u ${SERVICE_NAME}"
  fi
  log_ok "[04c] Service aktif & sehat."
}

deploy_nginx() {
  log_info "[04d] Nginx reverse proxy..."
  local tmpl="${PROJECT_ROOT}/configs/nginx.conf.template"
  local rendered="${TMP_DIR}/webapp.conf" backup="${TMP_DIR}/webapp.conf.bak"
  local dst="/etc/nginx/conf.d/webapp.conf" had_old=0 changed=0

  # shellcheck disable=SC2016  # '${...}' sengaja literal: daftar variabel untuk envsubst
  envsubst '${APP_PORT} ${DOMAIN_NAME}' < "$tmpl" > "$rendered"

  if [[ -f $dst ]]; then
    had_old=1
    cp -p "$dst" "$backup"
  fi
  install_if_changed "$rendered" "$dst" 0644 root:root
  changed=$FILE_CHANGED

  # Situs default Debian/Ubuntu akan menimpa server block kita
  if [[ -e /etc/nginx/sites-enabled/default || -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    changed=1
  fi

  if ! nginx -t; then
    if [[ $had_old -eq 1 ]]; then cp -p "$backup" "$dst"; else rm -f "$dst"; fi
    die "Konfigurasi nginx tidak valid; dikembalikan ke kondisi sebelumnya."
  fi

  systemctl enable --now nginx
  if [[ $changed -eq 1 ]]; then
    systemctl reload nginx
  fi
  log_ok "[04d] Nginx aktif."
}

deploy_stack() {
  deploy_database
  deploy_app
  deploy_systemd
  deploy_nginx
  log_ok "[04] Selesai."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  enable_strict_mode
  [[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
  TMP_DIR=$(mktemp -d)
  detect_distro
  load_env
  deploy_stack
fi
