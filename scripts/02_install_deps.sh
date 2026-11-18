#!/usr/bin/env bash
# 02 — Instalasi paket non-interaktif, multi-distro (idempoten)

install_deps() {
  log_info "[02] Instalasi dependensi (${OS_ID}, family ${PKG_FAMILY})..."

  local fw=()
  case $PKG_FAMILY in
    debian)
      [[ $ENABLE_FIREWALL == true ]] && fw+=(ufw)
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      apt-get update -y
      apt-get install -y nginx mariadb-server python3 python3-pymysql \
        gettext-base curl ca-certificates iproute2 "${fw[@]}"
      ;;
    rhel)
      [[ $ENABLE_FIREWALL == true ]] && fw+=(firewalld)
      dnf install -y nginx mariadb-server python3 python3-PyMySQL \
        gettext curl ca-certificates iproute policycoreutils "${fw[@]}"
      ;;
  esac

  log_ok "[02] Selesai."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  enable_strict_mode
  [[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
  detect_distro
  load_env
  install_deps
fi
