#!/usr/bin/env bash
# 03 — Firewall & SELinux (idempoten). Port 3306 sengaja TIDAK dibuka.

configure_security() {
  log_info "[03] Konfigurasi firewall & SELinux..."

  if [[ $ENABLE_FIREWALL == true ]]; then
    case $PKG_FAMILY in
      debian)
        # Izinkan SSH lebih dulu agar sesi remote tidak terputus
        ufw allow "${SSH_PORT}/tcp" >/dev/null
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ufw default deny incoming >/dev/null
        ufw --force enable >/dev/null
        ;;
      rhel)
        systemctl enable --now firewalld
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
        firewall-cmd --permanent --add-service=http >/dev/null
        firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null
        ;;
    esac
    log_ok "Firewall aktif: hanya SSH(${SSH_PORT}), 80, 443."
  else
    log_warn "ENABLE_FIREWALL=false — konfigurasi firewall dilewati."
  fi

  # SELinux: izinkan nginx (httpd_t) melakukan proxy ke backend lokal
  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) != "Disabled" ]]; then
    if command -v setsebool >/dev/null 2>&1; then
      setsebool -P httpd_can_network_connect on
      log_ok "SELinux boolean httpd_can_network_connect=on."
    fi
  fi

  log_ok "[03] Selesai."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  enable_strict_mode
  [[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
  detect_distro
  load_env
  configure_security
fi
