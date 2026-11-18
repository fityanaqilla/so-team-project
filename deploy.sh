#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Master Idempotent Installer (Multi-Tier: Nginx -> App -> MariaDB)
#
# Pemakaian:
#   ./deploy.sh --init-env   # buat .env dari env.example (password acak)
#   ./deploy.sh --check      # validasi .env & distro, tanpa mengubah sistem
#   ./deploy.sh              # deploy penuh (aman dijalankan berulang kali)
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
# shellcheck source=scripts/01_setup_users.sh
source "${SCRIPT_DIR}/scripts/01_setup_users.sh"
# shellcheck source=scripts/02_install_deps.sh
source "${SCRIPT_DIR}/scripts/02_install_deps.sh"
# shellcheck source=scripts/03_configure_sec.sh
source "${SCRIPT_DIR}/scripts/03_configure_sec.sh"
# shellcheck source=scripts/04_deploy_stack.sh
source "${SCRIPT_DIR}/scripts/04_deploy_stack.sh"

enable_strict_mode

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE="deploy"
for arg in "$@"; do
  case $arg in
    --init-env) MODE="init-env" ;;
    --check)    MODE="check" ;;
    -h | --help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: ${arg} (lihat --help)" ;;
  esac
done

if [[ $MODE == "init-env" ]]; then
  init_env_file
  exit 0
fi

# Eskalasi ke root sekali di awal, agar modul tidak perlu sudo satu per satu
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Harus dijalankan sebagai root atau sudo harus tersedia."
  log_info "Mengeskalasi ke root via sudo..."
  exec sudo -E bash "${SCRIPT_DIR}/deploy.sh" "$@"
fi

TMP_DIR=$(mktemp -d)
detect_distro
load_env
validate_env
log_info "Distro: ${OS_ID} (${PKG_FAMILY}) | Port backend: ${APP_PORT} | Domain: ${DOMAIN_NAME}"

if [[ $MODE == "check" ]]; then
  log_ok "Validasi lingkungan OK (tidak ada perubahan pada sistem)."
  exit 0
fi

acquire_lock
setup_users
install_deps
configure_security
deploy_stack

log_ok "=== DEPLOY SELESAI ==="
log_info "Uji: curl http://127.0.0.1/health   |   ./tests/health_check.sh"
