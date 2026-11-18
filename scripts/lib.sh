#!/usr/bin/env bash
# scripts/lib.sh — fungsi bersama untuk seluruh modul.
# File ini di-source oleh deploy.sh dan modul 01-04, bukan dieksekusi langsung.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPTS_DIR")"

# ---- Konstanta deployment -------------------------------------------------
APP_USER="webapp"
APP_GROUP="webapp"
APP_HOME="/var/www/webapp"
APP_DATA_DIR="${APP_HOME}/data"
APP_LOG_DIR="/var/log/webapp"
APP_ETC_DIR="/etc/webapp"
APP_ENV_FILE="${APP_ETC_DIR}/webapp.env"
SERVICE_NAME="webapp.service"
LOCK_FILE="${LOCK_FILE:-/var/lock/webapp-deploy.lock}"

TMP_DIR=""
FILE_CHANGED=0
OS_ID=""
PKG_FAMILY=""

# ---- Logging ---------------------------------------------------------------
_log() { local level=$1; shift; printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*"; }
log_info()  { _log INFO "$@"; }
log_ok()    { _log SUCCESS "$@"; }
log_warn()  { _log WARN "$@" >&2; }
log_error() { _log ERROR "$@" >&2; }
die()       { log_error "$@"; exit 1; }

# ---- Error & signal trapping -----------------------------------------------
on_error() {
  local rc=$1 file=$2 line=$3 cmd=$4
  trap - ERR
  log_error "[CRITICAL ERROR] Perintah '${cmd}' gagal (exit ${rc}) di ${file##*/}:${line}"
  exit "$rc"
}

on_interrupt() {
  trap - INT TERM
  log_warn "[INFO] Skrip dibatalkan oleh pengguna/sinyal."
  exit 130
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

enable_strict_mode() {
  set -Eeuo pipefail          # -E: ERR trap ikut berlaku di dalam fungsi/subshell
  IFS=$'\n\t'
  trap 'on_error $? "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND"' ERR
  trap on_interrupt INT TERM
  trap cleanup EXIT
}

# ---- Deteksi distro ---------------------------------------------------------
detect_distro() {
  [[ -f /etc/os-release ]] || die "OS tidak dikenali: /etc/os-release tidak ditemukan."
  local id id_like
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  id_like=$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")
  OS_ID="$id"
  case " ${id} ${id_like} " in
    *" ubuntu "* | *" debian "*)
      PKG_FAMILY="debian" ;;
    *" rhel "* | *" fedora "* | *" centos "* | *" rocky "* | *" almalinux "*)
      PKG_FAMILY="rhel" ;;
    *)
      die "Distro '${id}' belum didukung (didukung: Ubuntu/Debian dan RHEL family)." ;;
  esac
}

# ---- Environment (.env) ------------------------------------------------------
random_secret() {
  local n=${1:-24} raw
  raw=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s' "${raw:0:n}"
}

init_env_file() {
  local target="${PROJECT_ROOT}/.env" pw
  if [[ -f $target ]]; then
    log_info ".env sudah ada, tidak ditimpa."
    return 0
  fi
  [[ -f "${PROJECT_ROOT}/env.example" ]] || die "env.example tidak ditemukan."
  pw=$(random_secret 24)
  ( umask 077; sed "s|^DB_PASS=.*|DB_PASS=\"${pw}\"|" "${PROJECT_ROOT}/env.example" > "$target" )
  chmod 0600 "$target"
  log_ok ".env dibuat (mode 0600) dengan password database acak. Tinjau sebelum deploy."
}

load_env() {
  local env_file="${ENV_FILE:-${PROJECT_ROOT}/.env}" mode
  [[ -f $env_file ]] || die "File .env tidak ditemukan! Salin dari env.example atau jalankan: ./deploy.sh --init-env"
  mode=$(stat -c '%a' "$env_file")
  if [[ $mode != "600" ]]; then
    log_warn "Permission ${env_file} adalah ${mode}; diperbaiki menjadi 0600."
    chmod 0600 "$env_file"
  fi
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a

  : "${DB_NAME:?Variabel DB_NAME wajib didefinisikan!}"
  : "${DB_USER:?Variabel DB_USER wajib didefinisikan!}"
  : "${DB_PASS:?Variabel DB_PASS wajib didefinisikan!}"
  : "${APP_PORT:=8000}"
  : "${DOMAIN_NAME:=_}"
  : "${DB_HOST:=127.0.0.1}"
  : "${DB_PORT:=3306}"
  : "${ENABLE_FIREWALL:=true}"
  : "${SSH_PORT:=22}"
  export APP_PORT DOMAIN_NAME DB_HOST DB_PORT
}

validate_env() {
  [[ $DB_NAME =~ ^[A-Za-z0-9_]{1,64}$ ]] || die "DB_NAME hanya boleh huruf/angka/underscore (maks 64)."
  [[ $DB_USER =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "DB_USER hanya boleh huruf/angka/underscore (maks 32)."
  [[ $APP_PORT =~ ^[0-9]+$ ]] && (( APP_PORT >= 1024 && APP_PORT <= 65535 )) \
    || die "APP_PORT harus angka 1024-65535."
  [[ $DB_PORT =~ ^[0-9]+$ ]] || die "DB_PORT harus angka."
  [[ $SSH_PORT =~ ^[0-9]+$ ]] || die "SSH_PORT harus angka."
  [[ $DOMAIN_NAME =~ ^[A-Za-z0-9._\ -]+$ ]] || die "DOMAIN_NAME mengandung karakter tidak valid."
  [[ $DB_HOST == "127.0.0.1" || $DB_HOST == "localhost" ]] \
    || die "DB_HOST harus loopback (127.0.0.1/localhost) agar database tidak terekspos publik."
  case $ENABLE_FIREWALL in true | false) ;; *) die "ENABLE_FIREWALL harus true atau false." ;; esac
  if [[ ${#DB_PASS} -lt 12 || $DB_PASS == CHANGE_ME* ]]; then
    die "DB_PASS terlalu lemah / masih placeholder. Gunakan >=12 karakter (atau ./deploy.sh --init-env)."
  fi
}

# ---- Helper escaping ----------------------------------------------------------
sql_escape() {          # escape untuk literal string SQL di dalam '...'
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\'/\\\'}
  printf '%s' "$s"
}

systemd_quote() {       # nilai untuk EnvironmentFile: "..." dengan \ dan " di-escape
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# ---- Helper idempoten -----------------------------------------------------------
# install_if_changed SRC DST MODE OWNER:GROUP  -> set FILE_CHANGED=1 bila isi berubah
install_if_changed() {
  local src=$1 dst=$2 mode=$3 owner=$4
  FILE_CHANGED=0
  if [[ ! -f $dst ]] || ! cmp -s "$src" "$dst"; then
    install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
    FILE_CHANGED=1
  else
    chmod "$mode" "$dst"
    chown "$owner" "$dst"
  fi
}

wait_until() {          # wait_until DETIK "deskripsi" perintah...
  local timeout=$1 desc=$2 i
  shift 2
  for (( i = 0; i < timeout; i++ )); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log_error "Timeout (${timeout}s) menunggu: ${desc}"
  return 1
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Instance deploy.sh lain sedang berjalan (lock: ${LOCK_FILE})."
}
