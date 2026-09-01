#!/usr/bin/env bash
# One-command MindFS VPS migration.
#
# Usage:
#   bash migrate-vps.sh backup [options]
#   bash migrate-vps.sh restore --archive /path/to/archive.tar.gz [options]
#
# The archive contains MindFS project metadata/conversations, MindFS config,
# E2EE/TLS/Relay credentials, and the service user's external agent sessions.
# The binary and init files are recreated on restore for the target VPS.
set -Eeuo pipefail

umask 077

MODE="${1:-}"
if [[ -n "$MODE" ]]; then
  shift
fi

REPO="${MINDFS_REPO:-a9gent/mindfs}"
PREFIX="${MINDFS_PREFIX:-/opt/mindfs}"
DATA_DIR="${MINDFS_DATA_DIR:-/var/lib/mindfs}"
HOME_DIR="${MINDFS_HOME_DIR:-}"
CONFIG_DIR="${MINDFS_CONFIG_DIR:-}"
SERVICE_SCRIPT="${MINDFS_SERVICE_SCRIPT:-}"
SERVICE_UNIT="${MINDFS_SERVICE_UNIT:-}"
PROJECT_DIR="${MINDFS_PROJECT_DIR:-}"
PROJECTS_DIR="${MINDFS_PROJECTS_DIR:-}"
SERVICE_NAME="${MINDFS_SERVICE_NAME:-mindfs}"
SERVICE_USER="${MINDFS_SERVICE_USER:-mindfs}"
BACKUP_DIR="${MINDFS_BACKUP_DIR:-/root/mindfs-backups}"
ARCHIVE_PATH="${MINDFS_ARCHIVE:-}"
VERSION="${MINDFS_VERSION:-}"
INIT_MODE="${MINDFS_INIT_MODE:-auto}"
BIND_ADDR="${MINDFS_BIND_ADDR:-}"
PORT="${MINDFS_PORT:-}"
ENABLE_TLS="${MINDFS_ENABLE_TLS:-}"
ENABLE_E2EE="${MINDFS_ENABLE_E2EE:-}"
NO_RELAYER="${MINDFS_NO_RELAYER:-}"
METADATA_ONLY="${MINDFS_METADATA_ONLY:-0}"
INCLUDE_AGENT_DATA="${MINDFS_INCLUDE_AGENT_DATA:-0}"
DEPLOY_BRANCH="${MINDFS_DEPLOY_BRANCH:-custom/mindfs-local}"
DEPLOY_SCRIPT_URL="${MINDFS_DEPLOY_SCRIPT_URL:-}"
DRY_RUN=0
YES=0
ENCRYPT=0

PREFIX_SET=0
DATA_DIR_SET=0
HOME_DIR_SET=0
CONFIG_DIR_SET=0
PROJECT_DIR_SET=0
SERVICE_NAME_SET=0
SERVICE_USER_SET=0
INIT_MODE_SET=0
BIND_ADDR_SET=0
PORT_SET=0
ENABLE_TLS_SET=0
ENABLE_E2EE_SET=0
NO_RELAYER_SET=0
SERVICE_SCRIPT_SET=0

[[ -n "${MINDFS_PREFIX:-}" ]] && PREFIX_SET=1
[[ -n "${MINDFS_DATA_DIR:-}" ]] && DATA_DIR_SET=1
[[ -n "${MINDFS_HOME_DIR:-}" ]] && HOME_DIR_SET=1
[[ -n "${MINDFS_CONFIG_DIR:-}" ]] && CONFIG_DIR_SET=1
[[ -n "${MINDFS_PROJECT_DIR:-}" ]] && PROJECT_DIR_SET=1
[[ -n "${MINDFS_SERVICE_NAME:-}" ]] && SERVICE_NAME_SET=1
[[ -n "${MINDFS_SERVICE_USER:-}" ]] && SERVICE_USER_SET=1
[[ -n "${MINDFS_INIT_MODE:-}" ]] && INIT_MODE_SET=1
[[ -n "${MINDFS_BIND_ADDR:-}" ]] && BIND_ADDR_SET=1
[[ -n "${MINDFS_PORT:-}" ]] && PORT_SET=1
[[ -n "${MINDFS_ENABLE_TLS:-}" ]] && ENABLE_TLS_SET=1
[[ -n "${MINDFS_ENABLE_E2EE:-}" ]] && ENABLE_E2EE_SET=1
[[ -n "${MINDFS_NO_RELAYER:-}" ]] && NO_RELAYER_SET=1
[[ -n "${MINDFS_SERVICE_SCRIPT:-}" ]] && SERVICE_SCRIPT_SET=1

START_SCRIPT=""
CONTROL_SCRIPT=""
SERVICE_MODE=""
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_MODE=""
SERVICE_GROUP=""
RUNTIME_PID=""
RUNTIME_EXE=""
RUNTIME_CWD=""
RUNTIME_SERVICE_SCRIPT=""
RUNTIME_PID_FILE=""
RUNTIME_UNIT=""
RUNTIME_SOURCE=""
RUNTIME_USER=""
RUNTIME_XDG_CONFIG_HOME=""
RUNTIME_XDG_DATA_HOME=""
RUNTIME_AGENT_CONFIG=""
RUNTIME_CMD=()
RUNTIME_ENV_HOME=""
RUNTIME_DISCOVERED=0
AGENT_CONFIG_PATH=""
STAGE_DIR=""
TEMP_ARCHIVE=""
DEPLOY_TEMP=""
ARCHIVE_INPUT=""
RESTORE_ARCHIVE_ROOT=""
RESTORE_PLAN=""
ROLLBACK_DIR=""
HEALTH_URL=""
LOG_FILE=""

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

log() {
  printf '[mindfs-migrate] %s\n' "$*"
}

warn() {
  printf '[mindfs-migrate] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[mindfs-migrate] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
MindFS VPS migration

Modes:
  backup                         Backup the old VPS and restart MindFS
  restore                       Restore an archive on the new VPS

Backup options:
  --output PATH                 Archive path
  --backup-dir PATH             Default output directory (/root/mindfs-backups)
  --encrypt                     Encrypt archive with GnuPG AES-256
  --metadata-only               Include config and metadata, not project source
  --include-agent-data          Include Codex/Claude config and conversation files
  --exclude-agent-data          Exclude Codex/Claude data (default)
  --full-data                   Include project source and DATA_DIR contents

Restore options:
  --archive PATH                Backup archive (required)
  --projects-dir PATH           Destination for projects outside DATA_DIR
                                (default: DATA_DIR/projects)
  --yes                         Skip the restore confirmation prompt

Common options:
  --repo OWNER/REPO             Release repository (default: a9gent/mindfs)
  --version VERSION             Release to install on the new VPS
  --prefix PATH                 Binary prefix (default: /opt/mindfs)
  --data-dir PATH               Persistent data (default: /var/lib/mindfs)
  --home-dir PATH               Service/user HOME (default: DATA_DIR)
  --config-dir PATH             MindFS config directory (default: DATA_DIR/config/mindfs)
  --project-dir PATH            Backup source or restore startup project
  --service-script PATH         Existing service controller for backup
  --service-unit NAME           Existing systemd unit for backup
  --service-name NAME           Service name (default: mindfs)
  --service-user NAME           Service user (default: mindfs)
  --init MODE                   auto, systemd, or background
  --no-systemd                  Force background mode on restore
  --bind ADDRESS                Listen address on restore
  --port PORT                   Listen port on restore
  --private                     Bind to 127.0.0.1 on restore
  --tls                         Enable TLS on restore
  --no-tls                      Disable TLS on restore
  --e2ee                        Enable E2EE on restore
  --no-e2ee                     Disable E2EE on restore
  --relayer                     Enable Relay integration on restore
  --no-relayer                  Disable Relay integration on restore
  --dry-run                     Print the plan without changing the host
  -h, --help                    Show this help

Restore preserves source runtime settings unless a target option is supplied.
The archive contains secrets; protect it and delete it after verification.
EOF
}

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|--archive)
        need_value "$@"
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --backup-dir)
        need_value "$@"
        BACKUP_DIR="$2"
        shift 2
        ;;
      --projects-dir)
        need_value "$@"
        PROJECTS_DIR="$2"
        shift 2
        ;;
      --repo)
        need_value "$@"
        REPO="$2"
        shift 2
        ;;
      --version)
        need_value "$@"
        VERSION="$2"
        shift 2
        ;;
      --prefix)
        need_value "$@"
        PREFIX="$2"
        PREFIX_SET=1
        shift 2
        ;;
      --data-dir)
        need_value "$@"
        DATA_DIR="$2"
        DATA_DIR_SET=1
        shift 2
        ;;
      --home-dir)
        need_value "$@"
        HOME_DIR="$2"
        HOME_DIR_SET=1
        shift 2
        ;;
      --config-dir)
        need_value "$@"
        CONFIG_DIR="$2"
        CONFIG_DIR_SET=1
        shift 2
        ;;
      --service-script)
        need_value "$@"
        SERVICE_SCRIPT="$2"
        SERVICE_SCRIPT_SET=1
        shift 2
        ;;
      --service-unit)
        need_value "$@"
        SERVICE_UNIT="$2"
        shift 2
        ;;
      --project-dir)
        need_value "$@"
        PROJECT_DIR="$2"
        PROJECT_DIR_SET=1
        shift 2
        ;;
      --service-name)
        need_value "$@"
        SERVICE_NAME="$2"
        SERVICE_NAME_SET=1
        shift 2
        ;;
      --service-user)
        need_value "$@"
        SERVICE_USER="$2"
        SERVICE_USER_SET=1
        shift 2
        ;;
      --init)
        need_value "$@"
        INIT_MODE="$2"
        INIT_MODE_SET=1
        shift 2
        ;;
      --no-systemd)
        INIT_MODE="background"
        INIT_MODE_SET=1
        shift
        ;;
      --bind)
        need_value "$@"
        BIND_ADDR="$2"
        BIND_ADDR_SET=1
        shift 2
        ;;
      --port)
        need_value "$@"
        PORT="$2"
        PORT_SET=1
        shift 2
        ;;
      --private)
        BIND_ADDR="127.0.0.1"
        BIND_ADDR_SET=1
        shift
        ;;
      --tls)
        ENABLE_TLS=1
        ENABLE_TLS_SET=1
        shift
        ;;
      --no-tls)
        ENABLE_TLS=0
        ENABLE_TLS_SET=1
        shift
        ;;
      --e2ee)
        ENABLE_E2EE=1
        ENABLE_E2EE_SET=1
        shift
        ;;
      --no-e2ee)
        ENABLE_E2EE=0
        ENABLE_E2EE_SET=1
        shift
        ;;
      --relayer)
        NO_RELAYER=0
        NO_RELAYER_SET=1
        shift
        ;;
      --no-relayer)
        NO_RELAYER=1
        NO_RELAYER_SET=1
        shift
        ;;
      --encrypt)
        ENCRYPT=1
        shift
        ;;
      --metadata-only)
        METADATA_ONLY=1
        shift
        ;;
      --include-agent-data)
        INCLUDE_AGENT_DATA=1
        shift
        ;;
      --exclude-agent-data)
        INCLUDE_AGENT_DATA=0
        shift
        ;;
      --full-data)
        METADATA_ONLY=0
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

require_absolute_path() {
  local name="$1"
  local value="$2"
  [[ "$value" == /* && "$value" != "/" ]] || die "$name must be an absolute non-root path: $value"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || die "$name contains a control character"
}

validate_common() {
  [[ "$MODE" == "backup" || "$MODE" == "restore" ]] || {
    usage >&2
    die "first argument must be backup or restore"
  }
  require_absolute_path PREFIX "$PREFIX"
  require_absolute_path DATA_DIR "$DATA_DIR"
  if [[ "$MODE" == "backup" ]]; then
    # These are only fallback values. discover_runtime() replaces them with
    # the values used by the running instance before any files are copied.
    [[ -n "$HOME_DIR" ]] || HOME_DIR="$DATA_DIR"
    [[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="${HOME_DIR}/.config/mindfs"
    [[ -n "$SERVICE_SCRIPT" ]] || SERVICE_SCRIPT="${PREFIX}/bin/mindfs-service"
  else
    [[ -n "$HOME_DIR" ]] || HOME_DIR="$DATA_DIR"
    [[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="${DATA_DIR}/config/mindfs"
  fi
  require_absolute_path HOME_DIR "$HOME_DIR"
  require_absolute_path CONFIG_DIR "$CONFIG_DIR"
  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "invalid repository: $REPO"
  [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "invalid service name: $SERVICE_NAME"
  [[ "$SERVICE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid service user: $SERVICE_USER"
  [[ "$INIT_MODE" == "auto" || "$INIT_MODE" == "systemd" || "$INIT_MODE" == "background" ]] || die "invalid init mode: $INIT_MODE"

  START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
  CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"

  if [[ "$MODE" == "backup" ]]; then
    [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="${DATA_DIR}/workspace"
    require_absolute_path PROJECT_DIR "$PROJECT_DIR"
    require_absolute_path BACKUP_DIR "$BACKUP_DIR"
    [[ -n "$ARCHIVE_PATH" ]] || ARCHIVE_PATH="${BACKUP_DIR}/mindfs-migration-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    require_absolute_path ARCHIVE_PATH "$ARCHIVE_PATH"
    [[ "$ENCRYPT" == 1 || "$ARCHIVE_PATH" != *.gpg ]] || die "a .gpg archive requires --encrypt"
    [[ "$METADATA_ONLY" == 0 || "$METADATA_ONLY" == 1 ]] || die "--metadata-only must be 0 or 1"
    [[ "$INCLUDE_AGENT_DATA" == 0 || "$INCLUDE_AGENT_DATA" == 1 ]] || die "--include-agent-data must be 0 or 1"
    if [[ "$SERVICE_SCRIPT_SET" == 1 ]]; then
      [[ -x "$SERVICE_SCRIPT" ]] || die "service script is not executable: $SERVICE_SCRIPT"
    fi
  else
    [[ -n "$ARCHIVE_PATH" ]] || die "restore requires --archive PATH"
    require_absolute_path ARCHIVE_PATH "$ARCHIVE_PATH"
    [[ -f "$ARCHIVE_PATH" ]] || die "archive not found: $ARCHIVE_PATH"
    [[ -n "$PROJECTS_DIR" ]] || PROJECTS_DIR="${DATA_DIR}/projects"
    require_absolute_path PROJECTS_DIR "$PROJECTS_DIR"
    [[ -n "$DEPLOY_SCRIPT_URL" ]] || DEPLOY_SCRIPT_URL="https://raw.githubusercontent.com/linbmv/mindfs/${DEPLOY_BRANCH}/scripts/deploy-vps.sh"
  fi
}

is_absolute_path() {
  [[ "${1:-}" == /* && "${1:-}" != "/" && "${1:-}" != *$'\n'* && "${1:-}" != *$'\r'* && "${1:-}" != *$'\t'* ]]
}

canonical_path() {
  local value="$1"
  if [[ -e "$value" || -L "$value" ]]; then
    readlink -f -- "$value" 2>/dev/null || printf '%s\n' "$value"
  else
    printf '%s\n' "${value%/}"
  fi
}

proc_value() {
  local pid="$1" name="$2"
  [[ -r "/proc/$pid/$name" ]] || return 1
  if [[ "$name" == "cmdline" || "$name" == "environ" ]]; then
    tr '\0' '\n' <"/proc/$pid/$name"
  else
    cat "/proc/$pid/$name"
  fi
}

pid_is_mindfs() {
  local pid="$1" line exe
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [[ "$(basename -- "$exe")" == "mindfs" ]] && return 0
  while IFS= read -r line; do
    [[ "$line" == *"mindfs"* ]] && return 0
  done < <(proc_value "$pid" cmdline 2>/dev/null || true)
  return 1
}

read_pid_file() {
  local path="$1" pid
  [[ -f "$path" ]] || return 1
  pid="$(tr -d '[:space:]' <"$path" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  pid_is_mindfs "$pid" || return 1
  printf '%s\n' "$pid"
}

split_listen_address() {
  local address="$1"
  if [[ "$address" == \[*\]:* ]]; then
    BIND_ADDR="${address#\[}"
    BIND_ADDR="${BIND_ADDR%%\]:*}"
    PORT="${address##*]:}"
  elif [[ "$address" == *:* ]]; then
    BIND_ADDR="${address%:*}"
    PORT="${address##*:}"
  else
    BIND_ADDR="$address"
  fi
}

parse_runtime_cmdline() {
  local arg next
  RUNTIME_CMD=()
  while IFS= read -r -d '' arg; do
    RUNTIME_CMD+=("$arg")
  done <"/proc/$RUNTIME_PID/cmdline"
  for ((i=0; i<${#RUNTIME_CMD[@]}; i++)); do
    arg="${RUNTIME_CMD[$i]}"
    next="${RUNTIME_CMD[$((i + 1))]:-}"
    case "$arg" in
      -addr|--addr)
        [[ -n "$next" ]] && split_listen_address "$next"
        ;;
      -addr=*|--addr=*)
        split_listen_address "${arg#*=}"
        ;;
      -e2ee|--e2ee) ENABLE_E2EE=1 ;;
      -no-e2ee|--no-e2ee) ENABLE_E2EE=0 ;;
      -tls|--tls) ENABLE_TLS=1 ;;
      -no-tls|--no-tls) ENABLE_TLS=0 ;;
      -no-relayer|--no-relayer) NO_RELAYER=1 ;;
      -agent-config|--agent-config)
        [[ -n "$next" ]] && RUNTIME_AGENT_CONFIG="$next"
        ;;
      -agent-config=*|--agent-config=*) RUNTIME_AGENT_CONFIG="${arg#*=}" ;;
    esac
  done
}

discover_from_process() {
  local pid="$1" env_line candidate
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  RUNTIME_PID="$pid"
  RUNTIME_EXE="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  RUNTIME_CWD="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  RUNTIME_USER="$(stat -c '%U' "/proc/$pid" 2>/dev/null || true)"
  RUNTIME_ENV_HOME=""
  RUNTIME_XDG_CONFIG_HOME=""
  RUNTIME_XDG_DATA_HOME=""
  while IFS= read -r env_line; do
    case "$env_line" in
      HOME=*) RUNTIME_ENV_HOME="${env_line#HOME=}" ;;
      XDG_CONFIG_HOME=*) RUNTIME_XDG_CONFIG_HOME="${env_line#XDG_CONFIG_HOME=}" ;;
      XDG_DATA_HOME=*) RUNTIME_XDG_DATA_HOME="${env_line#XDG_DATA_HOME=}" ;;
    esac
  done < <(proc_value "$pid" environ 2>/dev/null || true)
  parse_runtime_cmdline
  [[ -n "$RUNTIME_ENV_HOME" ]] || RUNTIME_ENV_HOME="$(getent passwd "$RUNTIME_USER" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$RUNTIME_ENV_HOME" ]] || RUNTIME_ENV_HOME="${HOME_DIR:-$DATA_DIR}"
  [[ -n "$RUNTIME_XDG_CONFIG_HOME" ]] || RUNTIME_XDG_CONFIG_HOME="$RUNTIME_ENV_HOME/.config"
  [[ -n "$RUNTIME_XDG_DATA_HOME" ]] || RUNTIME_XDG_DATA_HOME="$RUNTIME_ENV_HOME/.local/share"

  [[ "$HOME_DIR_SET" == 1 ]] || HOME_DIR="$RUNTIME_ENV_HOME"
  [[ "$CONFIG_DIR_SET" == 1 ]] || CONFIG_DIR="${RUNTIME_XDG_CONFIG_HOME%/}/mindfs"
  [[ "$PROJECT_DIR_SET" == 1 ]] || PROJECT_DIR="$RUNTIME_CWD"
  [[ "$PREFIX_SET" == 1 ]] || {
    if [[ "$RUNTIME_EXE" == */bin/mindfs ]]; then
      PREFIX="${RUNTIME_EXE%/bin/mindfs}"
    fi
  }
  [[ "$DATA_DIR_SET" == 1 ]] || {
    # MindFS has no single data directory in local mode. Use the runtime cwd
    # for registry discovery, while retaining DATA_DIR only for deployed mode.
    DATA_DIR="$RUNTIME_CWD"
  }
  if [[ -n "$RUNTIME_AGENT_CONFIG" && "$RUNTIME_AGENT_CONFIG" == /* ]]; then
    AGENT_CONFIG_PATH="$RUNTIME_AGENT_CONFIG"
  fi
  if [[ "$PROJECT_DIR_SET" != 1 ]]; then
    for candidate in \
      "$RUNTIME_CWD/mindfs-service.sh" \
      "$RUNTIME_CWD/mindfs-service" \
      "$RUNTIME_ENV_HOME/mindfs/mindfs-service.sh" \
      "$RUNTIME_ENV_HOME/mindfs/mindfs-service"; do
      if [[ -f "$candidate" ]]; then
        RUNTIME_SERVICE_SCRIPT="$candidate"
        SERVICE_SCRIPT="$candidate"
        break
      fi
    done
  fi
  RUNTIME_SOURCE="running PID $pid (/proc)"
  RUNTIME_DISCOVERED=1
  return 0
}

discover_from_running_process() {
  local proc pid exe
  local -a pids=()
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/exe" ]] || continue
    pid="${proc##*/}"
    exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
    [[ "$(basename -- "$exe")" == "mindfs" ]] || continue
    pids+=("$pid")
  done
  if ((${#pids[@]} == 1)); then
    discover_from_process "${pids[0]}"
    return 0
  fi
  if ((${#pids[@]} > 1)); then
    warn "发现多个运行中的 MindFS 进程 (${pids[*]})；请使用 --service-unit、--service-script 或 --port 指定目标"
  fi
  return 1
}

discover_from_pid_files() {
  local candidate pid
  local -a candidates=()
  [[ -n "$SERVICE_SCRIPT" ]] && candidates+=("$(dirname -- "$SERVICE_SCRIPT")/.mindfs-service/mindfs.pid")
  [[ -n "$SERVICE_SCRIPT" ]] && candidates+=("$(dirname -- "$SERVICE_SCRIPT")/mindfs.pid")
  [[ -n "$DATA_DIR" ]] && candidates+=("$DATA_DIR/mindfs.pid" "$DATA_DIR/.mindfs-service/mindfs.pid")
  [[ -n "$HOME_DIR" ]] && candidates+=("$HOME_DIR/mindfs/mindfs.pid" "$HOME_DIR/mindfs/.mindfs-service/mindfs.pid")
  for candidate in "${candidates[@]}"; do
    pid="$(read_pid_file "$candidate" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    discover_from_process "$pid"
    RUNTIME_PID_FILE="$candidate"
    return 0
  done
  return 1
}

discover_from_systemd() {
  local unit unit_path value
  local -a units=()
  if [[ -n "$SERVICE_UNIT" ]]; then
    units+=("$SERVICE_UNIT")
  elif command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r unit; do
      [[ "$unit" == *.service ]] && units+=("${unit%.service}")
    done < <(systemctl list-unit-files 'mindfs*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')
    [[ ${#units[@]} -gt 0 ]] || units+=("$SERVICE_NAME")
  fi
  for unit in "${units[@]}"; do
    unit_path="$(systemctl show -p FragmentPath --value "$unit.service" 2>/dev/null || true)"
    [[ -n "$unit_path" && -f "$unit_path" ]] || continue
    SERVICE_UNIT="${unit%.service}.service"
    SERVICE_NAME="${unit%.service}"
    value="$(systemctl show -p MainPID --value "$SERVICE_UNIT" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]+$ ]] && pid_is_mindfs "$value"; then
      discover_from_process "$value"
      RUNTIME_UNIT="$SERVICE_UNIT"
      RUNTIME_SOURCE="systemd unit $SERVICE_UNIT + PID $value"
      return 0
    fi
    # Inactive units still provide authoritative paths and arguments for a
    # future restore, but must not be stopped as if they were active.
    value="$(systemctl show -p WorkingDirectory --value "$SERVICE_UNIT" 2>/dev/null || true)"
    [[ "$value" == /* ]] && { [[ "$PROJECT_DIR_SET" == 1 ]] || PROJECT_DIR="$value"; }
    value="$(systemctl show -p User --value "$SERVICE_UNIT" 2>/dev/null || true)"
    [[ -n "$value" && "$value" != "root" ]] && { SERVICE_USER="$value"; SERVICE_USER_SET=1; }
    value="$(systemctl show -p Environment --value "$SERVICE_UNIT" 2>/dev/null || true)"
    for env_line in $value; do
      case "$env_line" in
        HOME=*) [[ "$HOME_DIR_SET" == 1 ]] || HOME_DIR="${env_line#HOME=}" ;;
        XDG_CONFIG_HOME=*) [[ "$CONFIG_DIR_SET" == 1 ]] || CONFIG_DIR="${env_line#XDG_CONFIG_HOME=}/mindfs" ;;
      esac
    done
    RUNTIME_UNIT="$SERVICE_UNIT"
    RUNTIME_SOURCE="systemd unit $SERVICE_UNIT"
    RUNTIME_DISCOVERED=1
    return 0
  done
  return 1
}

discover_from_service_script() {
  local candidate dir line value
  local -a candidates=()
  [[ -n "$SERVICE_SCRIPT" ]] && candidates+=("$SERVICE_SCRIPT")
  [[ -n "$HOME_DIR" ]] && candidates+=("$HOME_DIR/mindfs/mindfs-service.sh" "$HOME_DIR/mindfs/mindfs-service")
  [[ -n "$PROJECT_DIR" ]] && candidates+=("$PROJECT_DIR/mindfs-service.sh" "$PROJECT_DIR/mindfs-service")
  candidates+=("/opt/mindfs/bin/mindfs-service" "/usr/local/bin/mindfs-service")
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    SERVICE_SCRIPT="$candidate"
    dir="$(cd -- "$(dirname -- "$candidate")" && pwd -P)"
    while IFS= read -r line; do
      case "$line" in
        MINDFS_BIN=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}"; [[ "$value" == /* ]] && PREFIX="$(dirname "$(dirname "$value")")" ;;
        WORKSPACE_ROOT=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}"; [[ "$PROJECT_DIR_SET" == 0 && "$value" == /* ]] && PROJECT_DIR="$value" ;;
        SAFE_UPDATE_REPO_DIR=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}" ;;
        MINDFS_CONFIG_DIR=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}"; [[ "$CONFIG_DIR_SET" == 0 && "$value" == /* ]] && CONFIG_DIR="$value" ;;
        PID_FILE=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}"; RUNTIME_PID_FILE="$value" ;;
      esac
    done <"$candidate"
    [[ "$PROJECT_DIR_SET" == 1 || -n "$PROJECT_DIR" ]] || PROJECT_DIR="$dir"
    [[ "$HOME_DIR_SET" == 1 ]] || HOME_DIR="$(awk -F= '/^export HOME=|^HOME=/{gsub(/[\"'"'"' ]/, "", $2); print $2; exit}' "$candidate" 2>/dev/null || true)"
    [[ -n "$HOME_DIR" ]] || HOME_DIR="$dir"
    [[ "$CONFIG_DIR_SET" == 1 ]] || CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/mindfs"
    if [[ -n "$RUNTIME_PID_FILE" ]]; then
      local pid
      pid="$(read_pid_file "$RUNTIME_PID_FILE" 2>/dev/null || true)"
      [[ -n "$pid" ]] && discover_from_process "$pid"
    fi
    RUNTIME_SERVICE_SCRIPT="$candidate"
    RUNTIME_SOURCE="service script $candidate"
    RUNTIME_DISCOVERED=1
    return 0
  done
  return 1
}

discover_runtime() {
  RUNTIME_DISCOVERED=0
  if [[ "$MODE" == "backup" ]]; then
    if [[ -n "$SERVICE_UNIT" ]] || systemd_is_running; then
      discover_from_systemd || true
    fi
    [[ "$RUNTIME_DISCOVERED" == 1 ]] || discover_from_running_process || true
    [[ "$RUNTIME_DISCOVERED" == 1 ]] || discover_from_pid_files || true
    [[ "$RUNTIME_DISCOVERED" == 1 ]] || discover_from_service_script || true
    if [[ "$RUNTIME_DISCOVERED" == 0 ]]; then
      # A supplied path remains valid even when the service is currently down.
      RUNTIME_SOURCE="explicit/default paths"
    fi
  fi
  [[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="${HOME_DIR}/.config/mindfs"
  [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="${DATA_DIR}/workspace"
  [[ -n "$SERVICE_SCRIPT" ]] || SERVICE_SCRIPT="$RUNTIME_SERVICE_SCRIPT"
  [[ -n "$AGENT_CONFIG_PATH" ]] || AGENT_CONFIG_PATH="$(dirname -- "$SERVICE_SCRIPT")/mindfs-agents.json"
  require_absolute_path DATA_DIR "$DATA_DIR"
  require_absolute_path HOME_DIR "$HOME_DIR"
  require_absolute_path CONFIG_DIR "$CONFIG_DIR"
  require_absolute_path PROJECT_DIR "$PROJECT_DIR"
}

systemd_is_running() {
  local pid1_comm=""
  if [[ -r /proc/1/comm ]]; then
    IFS= read -r pid1_comm < /proc/1/comm || true
  fi
  [[ "$pid1_comm" == "systemd" ]] || return 1
  [[ -d /run/systemd/system || -S /run/systemd/private ]] || return 1
  local system_state
  system_state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$system_state" != "" && "$system_state" != "offline" && "$system_state" != "unknown" ]]
}

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

ensure_dependencies() {
  local missing=()
  local command_name
  for command_name in awk chown cp find grep id mkdir mv python3 sha256sum sort stat tar useradd du; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  if [[ "$ENCRYPT" == 1 || "$ARCHIVE_PATH" == *.gpg ]]; then
    command -v gpg >/dev/null 2>&1 || missing+=(gpg)
  fi
  if ((${#missing[@]} > 0)); then
    command -v apt-get >/dev/null 2>&1 || die "missing commands: ${missing[*]}"
    log "Installing required packages"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip python3 gnupg
  fi
  check_dependencies
}

check_dependencies() {
  local missing=()
  local command_name
  for command_name in cp find python3 sha256sum stat tar; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if [[ "$MODE" == "backup" || "$MODE" == "restore" ]]; then
    command -v awk >/dev/null 2>&1 || missing+=(awk)
    command -v grep >/dev/null 2>&1 || missing+=(grep)
  fi
  if [[ "$MODE" == "restore" && ( "$DRY_RUN" != 1 || "$ARCHIVE_PATH" == *.gpg ) ]]; then
    command -v curl >/dev/null 2>&1 || missing+=(curl)
  fi
  if [[ "$ENCRYPT" == 1 || "$ARCHIVE_PATH" == *.gpg ]]; then
    command -v gpg >/dev/null 2>&1 || missing+=(gpg)
  fi
  ((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"
}

select_service_mode() {
  local pid1_comm=""
  if [[ -r /proc/1/comm ]]; then
    IFS= read -r pid1_comm < /proc/1/comm || true
  fi
  local systemd_available=0
  if command -v systemctl >/dev/null 2>&1 && systemd_is_running; then
    systemd_available=1
  fi
  case "$INIT_MODE" in
    systemd)
      [[ "$systemd_available" == 1 ]] || die "systemd is not running"
      SERVICE_MODE="systemd"
      ;;
    background)
      SERVICE_MODE="background"
      ;;
    auto)
      [[ "$systemd_available" == 1 ]] && SERVICE_MODE="systemd" || SERVICE_MODE="background"
      ;;
  esac
}

stop_existing_service() {
  local service_status
  SERVICE_WAS_ACTIVE=0
  SERVICE_WAS_MODE=""
  if [[ -n "$RUNTIME_UNIT" ]] && command -v systemctl >/dev/null 2>&1 \
    && systemd_is_running \
    && systemctl is-active --quiet "$RUNTIME_UNIT" 2>/dev/null; then
    SERVICE_WAS_ACTIVE=1
    SERVICE_WAS_MODE="systemd"
    systemctl stop "$RUNTIME_UNIT"
    return
  fi
  if [[ -x "$SERVICE_SCRIPT" && "$SERVICE_SCRIPT" != "$CONTROL_SCRIPT" ]]; then
    service_status="$($SERVICE_SCRIPT status 2>/dev/null || true)"
    if [[ "$service_status" == *"正在运行"* || "$service_status" == *"active (pid "* || "$service_status" == *"is running"* ]]; then
      SERVICE_WAS_ACTIVE=1
      SERVICE_WAS_MODE="custom-script"
      "$SERVICE_SCRIPT" stop
      return
    fi
  fi
  if [[ -x "$CONTROL_SCRIPT" ]]; then
    service_status="$($CONTROL_SCRIPT status 2>/dev/null || true)"
  else
    service_status=""
  fi
  if [[ "$service_status" == *" is active (pid "* ]]; then
    SERVICE_WAS_ACTIVE=1
    SERVICE_WAS_MODE="background"
    "$CONTROL_SCRIPT" stop
    return
  fi
  # A discovered PID without a trustworthy controller is intentionally not
  # killed. The archive can still be created after the user stops it, but the
  # migration script must never guess at a process based only on its name.
}

restart_previous_service() {
  [[ "$SERVICE_WAS_ACTIVE" == 1 ]] || return 0
  case "$SERVICE_WAS_MODE" in
    systemd)
      systemctl start "${RUNTIME_UNIT:-${SERVICE_NAME}.service}"
      ;;
    background)
      [[ -x "$CONTROL_SCRIPT" ]] && "$CONTROL_SCRIPT" start
      ;;
    custom-script)
      [[ -x "$SERVICE_SCRIPT" ]] && "$SERVICE_SCRIPT" start
      ;;
  esac
}

cleanup() {
  [[ -z "$STAGE_DIR" || ! -d "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
  [[ -z "$TEMP_ARCHIVE" || ! -f "$TEMP_ARCHIVE" ]] || rm -f -- "$TEMP_ARCHIVE"
  [[ -z "$DEPLOY_TEMP" || ! -f "$DEPLOY_TEMP" ]] || rm -f -- "$DEPLOY_TEMP"
}

on_backup_exit() {
  local code=$?
  if [[ "$MODE" == "backup" ]]; then
    restart_previous_service || warn "MindFS was not restarted automatically"
  elif [[ "$MODE" == "restore" && "$code" != 0 && -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" && ! -d "$DATA_DIR" ]]; then
    warn "restore failed before target data was recreated; restoring rollback copy"
    mv -- "$ROLLBACK_DIR" "$DATA_DIR" || warn "automatic rollback failed; original data remains at $ROLLBACK_DIR"
  fi
  cleanup
  exit "$code"
}

trap on_backup_exit EXIT

backup_archive() {
  local final_archive="$ARCHIVE_PATH"
  if [[ "$ENCRYPT" == 1 && "$final_archive" != *.gpg ]]; then
    final_archive="${final_archive}.gpg"
  fi
  [[ ! -e "$final_archive" ]] || die "archive exists: $final_archive"
  [[ ! -e "${final_archive}.sha256" ]] || die "checksum exists: ${final_archive}.sha256"
  mkdir -p -- "$BACKUP_DIR" "$(dirname "$final_archive")"
  STAGE_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" mindfs-migration.XXXXXX)"
  mkdir -p "$STAGE_DIR/mindfs-migration/payload/data"
  : > "$STAGE_DIR/root-list.tsv"

  select_service_mode
  detect_runtime
  discover_runtime
  log "Runtime discovery: ${RUNTIME_SOURCE}"
  stop_existing_service
  if [[ "$RUNTIME_DISCOVERED" == 1 && "$SERVICE_WAS_ACTIVE" != 1 ]]; then
    die "发现运行中的 MindFS (PID ${RUNTIME_PID:-unknown})，但没有可验证的 service controller；为避免误停进程，请先停止它或提供 --service-script/--service-unit"
  fi
  [[ -d "$HOME_DIR" ]] || die "MindFS HOME directory not found: $HOME_DIR"
  [[ -d "$CONFIG_DIR" ]] || die "MindFS config directory not found: $CONFIG_DIR"
  write_manifest
  if [[ "$METADATA_ONLY" == 1 ]]; then
    copy_metadata_payload
  else
    [[ -d "$DATA_DIR" ]] || die "MindFS data directory not found: $DATA_DIR"
    cp -a -- "$DATA_DIR/." "$STAGE_DIR/mindfs-migration/payload/data/"
    rm -f -- "$STAGE_DIR/mindfs-migration/payload/data/mindfs.pid"
    while IFS=$'\t' read -r archive_path source_path; do
      [[ -n "$archive_path" && -n "$source_path" ]] || continue
      mkdir -p "$STAGE_DIR/mindfs-migration/$archive_path"
      cp -a -- "$source_path/." "$STAGE_DIR/mindfs-migration/$archive_path/"
    done < "$STAGE_DIR/root-list.tsv"
  fi
  rm -f -- "$STAGE_DIR/root-list.tsv"

  local raw_archive="$STAGE_DIR/mindfs-migration.tar.gz"
  tar --xattrs --acls --numeric-owner -C "$STAGE_DIR" -czf "$raw_archive" mindfs-migration
  if [[ "$ENCRYPT" == 1 ]]; then
    gpg --pinentry-mode loopback --symmetric --cipher-algo AES256 --output "$final_archive" "$raw_archive"
  else
    [[ "$final_archive" != *.gpg ]] || die "use --encrypt for a .gpg archive"
    cp -- "$raw_archive" "$final_archive"
  fi
  ARCHIVE_PATH="$final_archive"
  chmod 0600 "$ARCHIVE_PATH"
  (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum "$(basename "$ARCHIVE_PATH")") > "${ARCHIVE_PATH}.sha256"
  chmod 0600 "${ARCHIVE_PATH}.sha256"
  printf '\nMindFS backup complete.\n\n'
  printf '  Archive:  %s\n' "$ARCHIVE_PATH"
  printf '  Checksum: %s\n' "${ARCHIVE_PATH}.sha256"
  printf '  Transfer: scp %q root@<new-vps>:%q\n' "$ARCHIVE_PATH" "$ARCHIVE_PATH"
  printf '  Restore:  migrate-vps.sh restore --archive %q --yes\n' "$ARCHIVE_PATH"
  printf '  Warning:  this archive contains credentials and pairing keys.\n'
}

copy_dir_contents() {
  local source="$1"
  local archive_path="$2"
  local destination="$STAGE_DIR/mindfs-migration/$archive_path"
  [[ -d "$source" ]] || return 0
  mkdir -p "$destination"
  cp -a -- "$source/." "$destination/"
}

copy_file_if_present() {
  local source="$1"
  local archive_path="$2"
  local destination="$STAGE_DIR/mindfs-migration/$archive_path"
  [[ -f "$source" || -L "$source" ]] || return 0
  mkdir -p "$(dirname "$destination")"
  cp -a -- "$source" "$destination"
}

copy_metadata_payload() {
  local archive_path source_path

  copy_dir_contents "$CONFIG_DIR" "payload/data/config/mindfs"
  copy_file_if_present "$SCRIPT_DIR/../mindfs/mindfs-agents.json" "payload/data/mindfs-agents.json"
  copy_file_if_present "$(dirname "$SERVICE_SCRIPT")/mindfs-agents.json" "payload/data/mindfs-agents.json"

  while IFS=$'\t' read -r archive_path source_path; do
    [[ -n "$archive_path" && -n "$source_path" ]] || continue
    [[ -d "$source_path/.mindfs" ]] || continue
    copy_dir_contents "$source_path/.mindfs" "$archive_path/.mindfs"
  done < "$STAGE_DIR/root-list.tsv"

  [[ "$INCLUDE_AGENT_DATA" == 1 ]] || return 0

  # Codex: retain credentials/configuration and real sessions, but not the
  # multi-gigabyte package cache, operational log database, or temp files.
  local codex="$HOME_DIR/.codex"
  copy_dir_contents "$codex/sessions" "payload/data/.codex/sessions"
  copy_dir_contents "$codex/agents" "payload/data/.codex/agents"
  copy_dir_contents "$codex/rules" "payload/data/.codex/rules"
  copy_dir_contents "$codex/skills" "payload/data/.codex/skills"
  for source_path in "$codex"/auth*.json "$codex"/config*.toml "$codex"/AGENTS.md \
    "$codex"/history.jsonl "$codex"/installation_id "$codex"/version.json; do
    [[ -e "$source_path" ]] || continue
    copy_file_if_present "$source_path" "payload/data/.codex/$(basename "$source_path")"
  done

  # Claude: retain project conversation JSONL files and user configuration;
  # exclude file-history, caches, plugins, downloads, and session environments.
  local claude="$HOME_DIR/.claude"
  copy_dir_contents "$claude/projects" "payload/data/.claude/projects"
  copy_dir_contents "$claude/agents" "payload/data/.claude/agents"
  copy_dir_contents "$claude/commands" "payload/data/.claude/commands"
  copy_dir_contents "$claude/hooks" "payload/data/.claude/hooks"
  copy_dir_contents "$claude/rules" "payload/data/.claude/rules"
  copy_dir_contents "$claude/skills" "payload/data/.claude/skills"
  for source_path in "$HOME_DIR"/.claude.json "$claude"/history.jsonl "$claude"/settings.json; do
    copy_file_if_present "$source_path" "payload/data/.claude/$(basename "$source_path")"
  done

  # Keep only the Grok configuration when present; the rest of ~/.grok may
  # contain a large installed binary/cache tree.
  copy_file_if_present "$HOME_DIR/.grok/config.toml" "payload/data/.grok/config.toml"

}

print_backup_plan() {
  select_service_mode
  detect_runtime
  discover_runtime
  cat <<EOF
MindFS backup plan (dry run)

  source data:   ${DATA_DIR}
  runtime source: ${RUNTIME_SOURCE}
  runtime PID:    ${RUNTIME_PID:-not running}
  startup root:  ${PROJECT_DIR}
  archive:       ${ARCHIVE_PATH}
  service mode:  ${SERVICE_MODE}
  listen:        ${BIND_ADDR}:${PORT}
  TLS / E2EE:    ${ENABLE_TLS} / ${ENABLE_E2EE}
  Relay:         $([[ "${NO_RELAYER}" == 1 ]] && printf 'disabled' || printf 'enabled')
  mode:          $([[ "${METADATA_ONLY}" == 1 ]] && printf 'metadata-only' || printf 'full data')
  agent data:    $([[ "${INCLUDE_AGENT_DATA}" == 1 ]] && printf 'included' || printf 'excluded')

  config size:   $(du -sh "$CONFIG_DIR" 2>/dev/null | awk '{print $1}' || printf 'unknown')
  home:          ${HOME_DIR}
  config:        ${CONFIG_DIR}
  service script:${SERVICE_SCRIPT:-not found}
  service unit:  ${RUNTIME_UNIT:-not found}
  excluded:      source code, .git, dependencies, caches, .codex/packages, .codex/logs_2.sqlite*

No service, data, archive, package, or user changes will be made.
EOF
}

validate_archive() {
  local archive="$1"
  local checksum="${ARCHIVE_PATH}.sha256"
  if [[ -f "$checksum" ]]; then
    (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum --check --status "$(basename "$checksum")") || die "archive checksum verification failed"
  fi
  if [[ "$archive" == *.gpg ]]; then
    TEMP_ARCHIVE="$(mktemp -p "${TMPDIR:-/tmp}" mindfs-migration-decrypted.XXXXXX.tar.gz)"
    rm -f -- "$TEMP_ARCHIVE"
    gpg --pinentry-mode loopback --decrypt --output "$TEMP_ARCHIVE" "$archive"
    archive="$TEMP_ARCHIVE"
  fi
  ARCHIVE_INPUT="$archive"
  python3 - "$archive" <<'PY'
import posixpath
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    names = set()
    for member in archive.getmembers():
        name = member.name
        normalized = posixpath.normpath(name)
        parts = [part for part in name.split("/") if part]
        if name.startswith("/") or not parts or parts[0] != "mindfs-migration" or any(part == ".." for part in parts):
            raise SystemExit(f"unsafe archive member: {name}")
        if not member.isfile() and not member.isdir() and not member.issym() and not member.islnk():
            raise SystemExit(f"unsupported archive member type: {name}")
        if member.issym() or member.islnk():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if member.linkname.startswith("/") or not target.startswith("mindfs-migration/"):
                raise SystemExit(f"unsafe archive link: {name} -> {member.linkname}")
        names.add(name)
    if "mindfs-migration/manifest.json" not in names:
        raise SystemExit("archive does not contain mindfs-migration/manifest.json")
PY
}

print_restore_plan() {
  python3 - "$RESTORE_PLAN" "$ROLLBACK_DIR" "$DATA_DIR" "$PROJECT_DIR" "$SERVICE_NAME" "$PORT" "$BIND_ADDR" "$ENABLE_TLS" "$ENABLE_E2EE" "$NO_RELAYER" <<'PY'
import json
import sys

plan_path, rollback, target_data, target_project, service_name, port, bind, tls, e2ee, no_relayer = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
print("MindFS restore plan")
print("")
print(f"  source data:       {plan['old_data_dir']}")
print(f"  target data:       {target_data}")
print(f"  startup project:   {target_project}")
print(f"  external projects: {plan['projects_dir']}")
print(f"  rollback copy:     {rollback}")
print(f"  service:           {service_name}")
print(f"  listen:            {bind}:{port}")
print(f"  TLS / E2EE:        {'on' if tls == '1' else 'off'} / {'on' if e2ee == '1' else 'off'}")
print(f"  Relay:             {'disabled' if no_relayer == '1' else 'enabled'}")
print("")
for item in plan.get("roots", []):
    print(f"  project: {item.get('original_path', '')} -> {item.get('destination', '')}")
PY
}

load_restore_runtime() {
  local values
  values="$(python3 - "$RESTORE_PLAN" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    plan = json.load(stream)
runtime = plan["manifest"]["runtime"]
mode = str(runtime.get("service_mode", "")).strip()
if mode not in ("systemd", "background"):
    mode = "auto"
print("\t".join([
    str(plan["runtime_project_dir"]),
    str(runtime.get("prefix", "/opt/mindfs")),
    str(runtime.get("service_name", "mindfs")),
    str(runtime.get("service_user", "mindfs")),
    mode,
    str(runtime.get("bind", "0.0.0.0")),
    str(runtime.get("port", 7331)),
    "1" if runtime.get("tls", True) else "0",
    "1" if runtime.get("e2ee", True) else "0",
    "1" if runtime.get("no_relayer", False) else "0",
]))
PY
  )"
  local source_project source_prefix source_service source_user source_mode
  local source_bind source_port source_tls source_e2ee source_no_relayer
  IFS=$'\t' read -r source_project source_prefix source_service source_user source_mode \
    source_bind source_port source_tls source_e2ee source_no_relayer <<<"$values"
  : "$source_mode"

  [[ "$PROJECT_DIR_SET" == 1 ]] || PROJECT_DIR="$source_project"
  [[ "$PREFIX_SET" == 1 ]] || PREFIX="$source_prefix"
  [[ "$SERVICE_NAME_SET" == 1 ]] || SERVICE_NAME="$source_service"
  [[ "$SERVICE_USER_SET" == 1 ]] || SERVICE_USER="$source_user"
  [[ "$INIT_MODE_SET" == 1 ]] || INIT_MODE="auto"
  [[ "$BIND_ADDR_SET" == 1 ]] || BIND_ADDR="$source_bind"
  [[ "$PORT_SET" == 1 ]] || PORT="$source_port"
  [[ "$ENABLE_TLS_SET" == 1 ]] || ENABLE_TLS="$source_tls"
  [[ "$ENABLE_E2EE_SET" == 1 ]] || ENABLE_E2EE="$source_e2ee"
  [[ "$NO_RELAYER_SET" == 1 ]] || NO_RELAYER="$source_no_relayer"

  START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
  CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"
  ROLLBACK_DIR="/var/backups/mindfs-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  local health_host="127.0.0.1"
  [[ "$BIND_ADDR" == "::1" || "$BIND_ADDR" == "[::1]" ]] && health_host="[::1]"
  if [[ "$ENABLE_TLS" == 1 ]]; then
    HEALTH_URL="https://${health_host}:${PORT}/health"
  else
    HEALTH_URL="http://${health_host}:${PORT}/health"
  fi
  require_absolute_path PREFIX "$PREFIX"
  require_absolute_path DATA_DIR "$DATA_DIR"
  require_absolute_path PROJECT_DIR "$PROJECT_DIR"
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "invalid restored port: $PORT"
  [[ "$ENABLE_TLS" == 0 || "$ENABLE_TLS" == 1 ]] || die "invalid restored TLS setting"
  [[ "$ENABLE_E2EE" == 0 || "$ENABLE_E2EE" == 1 ]] || die "invalid restored E2EE setting"
  [[ "$NO_RELAYER" == 0 || "$NO_RELAYER" == 1 ]] || die "invalid restored Relay setting"
  [[ "$ENABLE_E2EE" == 0 || "$ENABLE_TLS" == 1 ]] || die "restored archive disables TLS while E2EE is enabled; use --no-e2ee or --tls"
  [[ "$BIND_ADDR" != *[[:space:]]* ]] || die "restored bind address contains whitespace"
  [[ "$BIND_ADDR" != /* ]] || die "restored bind address must not be a path"
  if [[ "$ENABLE_TLS" == 0 && "$BIND_ADDR" != "127.0.0.1" && "$BIND_ADDR" != "localhost" && "$BIND_ADDR" != "::1" ]]; then
    die "refusing restored public plaintext HTTP; use --private or --tls"
  fi
}

verify_archive_checksum() {
  local checksum="${ARCHIVE_PATH}.sha256"
  if [[ ! -f "$checksum" ]]; then
    warn "checksum file not found beside archive: $checksum"
    return 0
  fi
  (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum --check --status "$(basename "$checksum")") \
    || die "archive checksum verification failed"
  log "Archive checksum verified"
}

extract_archive() {
  STAGE_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" mindfs-restore.XXXXXX)"
  tar --xattrs --acls --same-owner -C "$STAGE_DIR" -xzf "$ARCHIVE_INPUT"
  RESTORE_ARCHIVE_ROOT="$STAGE_DIR/mindfs-migration"
  [[ -f "$RESTORE_ARCHIVE_ROOT/manifest.json" ]] || die "archive manifest is missing"
}

download_deploy_script() {
  DEPLOY_TEMP="$(mktemp -p "${TMPDIR:-/tmp}" mindfs-deploy.XXXXXX.sh)"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/deploy-vps.sh" ]]; then
    cp -- "${SCRIPT_DIR}/deploy-vps.sh" "$DEPLOY_TEMP"
  else
    curl -fsSL "$DEPLOY_SCRIPT_URL" -o "$DEPLOY_TEMP"
  fi
  chmod 0700 "$DEPLOY_TEMP"
  bash -n "$DEPLOY_TEMP" || die "downloaded deploy script has invalid shell syntax"
}

ensure_service_account() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
}

backup_target_data() {
  if [[ ! -e "$DATA_DIR" ]]; then
    return 0
  fi
  [[ ! -e "$ROLLBACK_DIR" ]] || die "rollback directory already exists: $ROLLBACK_DIR"
  mkdir -p "$(dirname "$ROLLBACK_DIR")"
  mv -- "$DATA_DIR" "$ROLLBACK_DIR"
  log "Moved existing target data to $ROLLBACK_DIR"
}

restore_external_projects() {
  local projects_root="$RESTORE_ARCHIVE_ROOT/payload/projects"
  [[ -d "$projects_root" ]] || return 0
  mkdir -p "$PROJECTS_DIR"
  while IFS= read -r -d '' source_dir; do
    local project_name destination project_kind
    project_name="$(basename "$source_dir")"
    IFS=$'\t' read -r project_kind destination < <(python3 - "$RESTORE_PLAN" "$project_name" "$PROJECTS_DIR" <<'PY'
import json
import os
import sys

plan_path, archive_name, projects_dir = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
for item in plan.get("roots", []):
    if os.path.basename(item.get("archive_path", "")) == archive_name:
        print("\t".join((str(item.get("kind", "")), item["destination"])))
        break
else:
    print("\t".join(("", os.path.join(projects_dir, archive_name))))
PY
    )
    [[ "$project_name" == root-* ]] || continue
    [[ -n "$destination" && "$destination" == /* ]] || die "invalid external project destination"
    if [[ -e "$destination" ]]; then
      [[ -d "$destination" ]] || die "external project destination is not a directory: $destination"
      if [[ "$project_kind" == "metadata" ]]; then
        # Metadata-only projects carry just .mindfs; the user re-provisions the
        # source tree, so a populated destination is expected — but never
        # overwrite existing MindFS metadata.
        [[ ! -e "$destination/.mindfs" ]] || die "external project destination already has .mindfs metadata: $destination"
      else
        [[ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "external project destination is not empty: $destination"
      fi
    else
      mkdir -p "$destination"
    fi
    cp -a -- "$source_dir/." "$destination/"
    if [[ "$project_kind" == "metadata" && -d "$destination/.mindfs" ]]; then
      chown -R "$SERVICE_USER:$SERVICE_GROUP" "$destination/.mindfs"
    else
      chown -R "$SERVICE_USER:$SERVICE_GROUP" "$destination"
    fi
  done < <(find "$projects_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

rewrite_json_paths() {
  local json_path="$1"
  python3 - "$json_path" "$RESTORE_PLAN" <<'PY'
import json
import os
import sys

path, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
old_data = plan["old_data_dir"]
roots = plan.get("roots", [])

def mapped(value):
    if not isinstance(value, str):
        return value
    value = value.strip()
    if not value or not os.path.isabs(value):
        return value
    value = os.path.normpath(value)
    for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
        old = os.path.normpath(item["original_path"])
        if value == old or value.startswith(old + os.sep):
            suffix = os.path.relpath(value, old)
            destination = item["destination"]
            return destination if suffix == "." else os.path.join(destination, suffix)
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        new_data = plan["new_data_dir"]
        return new_data if suffix == "." else os.path.join(new_data, suffix)
    return value

PATH_KEYS = {
    "root_path", "working_dir", "repo_path", "path", "cwd", "projectPath",
    "originalPath", "project_dir", "runtime_root_path", "worktree_path",
    "project-order", "electron-saved-workspace-roots",
}

def rewrite(value, key=""):
    if isinstance(value, dict):
        return {k: rewrite(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite(v, key) for v in value]
    if isinstance(value, str) and (key in PATH_KEYS or key.endswith("_path")):
        return mapped(value)
    return value

try:
    with open(path, encoding="utf-8") as stream:
        payload = json.load(stream)
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
rewritten = rewrite(payload)
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(rewritten, stream, indent=2, ensure_ascii=False)
    stream.write("\n")
os.replace(temporary, path)
PY
}

rewrite_jsonl_paths() {
  local jsonl_path="$1"
  python3 - "$jsonl_path" "$RESTORE_PLAN" <<'PY'
import json
import os
import sys

path, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
old_data = plan["old_data_dir"]
roots = plan.get("roots", [])

def mapped(value):
    if not isinstance(value, str) or not os.path.isabs(value):
        return value
    value = os.path.normpath(value)
    for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
        old = os.path.normpath(item["original_path"])
        if value == old or value.startswith(old + os.sep):
            suffix = os.path.relpath(value, old)
            destination = item["destination"]
            return destination if suffix == "." else os.path.join(destination, suffix)
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        new_data = plan["new_data_dir"]
        return new_data if suffix == "." else os.path.join(new_data, suffix)
    return value

PATH_KEYS = {
    "cwd", "working_dir", "root_path", "repo_path", "path", "projectPath",
    "originalPath", "project_dir", "worktree_path", "runtime_root_path",
}

def rewrite(value, key=""):
    if isinstance(value, dict):
        return {k: rewrite(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite(v, key) for v in value]
    if isinstance(value, str) and (key in PATH_KEYS or key.endswith("_path")):
        return mapped(value)
    return value

temporary = path + ".tmp"
with open(path, encoding="utf-8") as source, open(temporary, "w", encoding="utf-8") as target:
    for line in source:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            target.write(line)
            continue
        json.dump(rewrite(payload), target, ensure_ascii=False, separators=(",", ":"))
        target.write("\n")
os.replace(temporary, path)
PY
}

rewrite_sqlite_paths() {
  local database="$1"
  python3 - "$database" "$RESTORE_PLAN" <<'PY'
import json
import os
import shutil
import sqlite3
import sys

path, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
old_data = plan["old_data_dir"]
roots = plan.get("roots", [])

def mapped(value):
    if not isinstance(value, str) or not os.path.isabs(value):
        return value
    value = os.path.normpath(value)
    for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
        old = os.path.normpath(item["original_path"])
        if value == old or value.startswith(old + os.sep):
            suffix = os.path.relpath(value, old)
            destination = item["destination"]
            return destination if suffix == "." else os.path.join(destination, suffix)
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        new_data = plan["new_data_dir"]
        return new_data if suffix == "." else os.path.join(new_data, suffix)
    return value

def rewrite_paths(value):
    if isinstance(value, dict):
        return {key: rewrite_paths(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rewrite_paths(item) for item in value]
    if isinstance(value, str):
        return mapped(value)
    return value

backup = path + ".before-path-rewrite"
shutil.copy2(path, backup)
connection = sqlite3.connect(path)
try:
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "sessions" in tables:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(sessions)")}
        for column in ("working_dir", "related_files_json", "related_worktree_json"):
            if column not in columns:
                continue
            rows = connection.execute(f"SELECT rowid, {column} FROM sessions").fetchall()
            for rowid, value in rows:
                if column == "working_dir":
                    replacement = mapped(value)
                else:
                    try:
                        parsed = json.loads(value) if value else ({} if column == "related_worktree_json" else [])
                    except (TypeError, json.JSONDecodeError):
                        continue
                    replacement = json.dumps(rewrite_paths(parsed), ensure_ascii=False, separators=(",", ":"))
                if replacement != value:
                    connection.execute(f"UPDATE sessions SET {column}=? WHERE rowid=?", (replacement, rowid))
    connection.commit()
finally:
    connection.close()
os.unlink(backup)
PY
}

rewrite_restored_paths() {
  local target_config="${DATA_DIR}/config/mindfs"
  local registry="${target_config}/registry.json"
  [[ ! -f "$registry" ]] || rewrite_json_paths "$registry"

  while IFS= read -r -d '' path; do
    case "$path" in
      *.jsonl) rewrite_jsonl_paths "$path" ;;
      *.json) rewrite_json_paths "$path" ;;
    esac
  done < <(find "$DATA_DIR" -type f \( -name '*.jsonl' -o -name '*.json' \) -print0)

  rewrite_session_db_links "$DATA_DIR"
  rewrite_session_db_links "$PROJECTS_DIR"

  while IFS= read -r -d '' database; do
    rewrite_sqlite_paths "$database"
  done < <(find "$DATA_DIR" -type f -name '*.db' -print0)

  while IFS= read -r -d '' external_root; do
    while IFS= read -r -d '' path; do
      case "$path" in
        *.jsonl) rewrite_jsonl_paths "$path" ;;
        *.json) rewrite_json_paths "$path" ;;
      esac
    done < <(find "$external_root" -type f \( -name '*.jsonl' -o -name '*.json' \) -print0)
    while IFS= read -r -d '' database; do
      rewrite_sqlite_paths "$database"
    done < <(find "$external_root" -type f -name '*.db' -print0)
  done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  rewrite_agent_path_indexes

  log "Rewrote restored project and session paths"
}

rewrite_session_db_links() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' link_file; do
    local linked_db linked_target
    linked_db="$(<"$link_file")"
    [[ "$linked_db" == /* ]] || continue
    linked_target="$(python3 - "$linked_db" "$RESTORE_PLAN" <<'PY'
import json
import os
import sys

value, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
old_data = os.path.normpath(plan["old_data_dir"])
new_data = os.path.normpath(plan["new_data_dir"])
value = os.path.normpath(value.strip())
roots = plan.get("roots", [])
for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
    old = os.path.normpath(item["original_path"])
    if value == old or value.startswith(old + os.sep):
        suffix = os.path.relpath(value, old)
        destination = item["destination"]
        print(destination if suffix == "." else os.path.join(destination, suffix))
        break
else:
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        print(new_data if suffix == "." else os.path.join(new_data, suffix))
    else:
        print(value)
PY
    )"
    printf '%s\n' "$linked_target" >"$link_file"
  done < <(find "$root" -type f -name 'session-list.db.link' -print0)
}

rewrite_agent_path_indexes() {
  local service_home="$DATA_DIR"
  rename_claude_project_dirs
  local index_file
  for index_file in \
    "$service_home/.codex/config.toml" \
    "$service_home/.codex/.codex-global-state.json" \
    "$service_home/.codex/session_index.jsonl" \
    "$service_home/.claude/projects"/*/sessions-index.json; do
    [[ -f "$index_file" ]] || continue
    case "$index_file" in
      *.json) rewrite_json_paths "$index_file" ;;
      *.jsonl) rewrite_jsonl_paths "$index_file" ;;
      *.toml) rewrite_codex_config_paths "$index_file" ;;
    esac
  done
}

rename_claude_project_dirs() {
  local projects_root="$DATA_DIR/.claude/projects"
  [[ -d "$projects_root" ]] || return 0
  python3 - "$projects_root" "$RESTORE_PLAN" <<'PY'
import hashlib
import json
import os
import sys

projects_root, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)

def slug(value):
    value = os.path.normpath(value)
    for char in ("/", "\\", ":", ".", "_"):
        value = value.replace(char, "-")
    return value

pairs = []
for item in plan.get("roots", []):
    source_name = slug(item["original_path"])
    target_name = slug(item["destination"])
    if source_name == target_name:
        continue
    source = os.path.join(projects_root, source_name)
    target = os.path.join(projects_root, target_name)
    if os.path.exists(source):
        if not os.path.isdir(source) or os.path.islink(source):
            raise SystemExit(f"Claude project entry is not a real directory: {source}")
        pairs.append((source, target))

sources = {source for source, _ in pairs}
for source, target in pairs:
    if os.path.exists(target) and target not in sources:
        raise SystemExit(f"Claude project destination already exists: {target}")

staged = []
for source, target in pairs:
    temporary = os.path.join(projects_root, ".mindfs-migration-" + hashlib.sha256(source.encode()).hexdigest()[:16])
    os.rename(source, temporary)
    staged.append((temporary, target))
for temporary, target in staged:
    os.rename(temporary, target)
PY
}

rewrite_codex_config_paths() {
  local config_path="$1"
  python3 - "$config_path" "$RESTORE_PLAN" <<'PY'
import json
import os
import sys

path, plan_path = sys.argv[1:]
with open(plan_path, encoding="utf-8") as stream:
    plan = json.load(stream)
old_data = plan["old_data_dir"]
roots = plan.get("roots", [])

def mapped(value):
    value = os.path.normpath(value)
    for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
        old = os.path.normpath(item["original_path"])
        if value == old or value.startswith(old + os.sep):
            suffix = os.path.relpath(value, old)
            destination = item["destination"]
            return destination if suffix == "." else os.path.join(destination, suffix)
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        new_data = plan["new_data_dir"]
        return new_data if suffix == "." else os.path.join(new_data, suffix)
    return value

with open(path, encoding="utf-8") as stream:
    lines = stream.readlines()
rewritten = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[projects.") and stripped.endswith("]"):
        raw = stripped[len("[projects."):-1].strip().strip("'\"")
        if os.path.isabs(raw):
            line = line.replace(raw, mapped(raw), 1)
    rewritten.append(line)
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    stream.writelines(rewritten)
os.replace(temporary, path)
PY
}

restore_service() {
  local deploy_args=(
    --repo "$REPO"
    --prefix "$PREFIX"
    --data-dir "$DATA_DIR"
    --project-dir "$PROJECT_DIR"
    --service-name "$SERVICE_NAME"
    --service-user "$SERVICE_USER"
    --init "$SERVICE_MODE"
    --bind "$BIND_ADDR"
    --port "$PORT"
    --skip-start
  )
  [[ -n "$VERSION" ]] && deploy_args+=(--version "$VERSION")
  [[ "$ENABLE_TLS" == 1 ]] && deploy_args+=(--tls) || deploy_args+=(--no-tls)
  [[ "$ENABLE_E2EE" == 1 ]] && deploy_args+=(--e2ee) || deploy_args+=(--no-e2ee)
  [[ "$NO_RELAYER" == 1 ]] && deploy_args+=(--no-relayer)
  log "Installing MindFS binary and service files"
  bash "$DEPLOY_TEMP" "${deploy_args[@]}"
}

start_restored_service() {
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
  else
    [[ -x "$CONTROL_SCRIPT" ]] || die "background service controller was not installed: $CONTROL_SCRIPT"
    "$CONTROL_SCRIPT" restart
  fi
}

wait_for_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if [[ "$ENABLE_TLS" == 1 ]]; then
      curl -kfsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1 && return 0
    elif curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    [[ "$attempt" -lt 30 ]] && sleep 1
  done
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true
  elif [[ -n "$LOG_FILE" ]]; then
    tail -n 80 "$LOG_FILE" || true
  fi
  die "restored MindFS did not become healthy"
}

restore_archive() {
  extract_archive
  RESTORE_PLAN="$STAGE_DIR/restore-plan.json"
  create_restore_plan "$RESTORE_ARCHIVE_ROOT" "$RESTORE_PLAN"
  load_restore_runtime
  select_service_mode
  print_restore_plan
  if [[ "$YES" != 1 ]]; then
    read -r -p "Proceed with restore? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "restore cancelled"
  fi

  stop_existing_service
  backup_target_data
  download_deploy_script
  ensure_service_account
  restore_service
  [[ -d "$DATA_DIR" ]] || die "deployment did not create data directory: $DATA_DIR"
  cp -a -- "$RESTORE_ARCHIVE_ROOT/payload/data/." "$DATA_DIR/"
  restore_agent_payload
  restore_external_projects
  rewrite_restored_paths
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
  LOG_FILE="${DATA_DIR}/mindfs.log"
  start_restored_service
  wait_for_health

  printf '\nMindFS restore complete.\n\n'
  printf '  Data:      %s\n' "$DATA_DIR"
  printf '  Project:   %s\n' "$PROJECT_DIR"
  printf '  Rollback:  %s\n' "$ROLLBACK_DIR"
  printf '  Health:    %s\n' "$HEALTH_URL"
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    printf '  Service:   systemctl status %s\n' "$SERVICE_NAME"
  else
    printf '  Service:   %s status\n' "$CONTROL_SCRIPT"
  fi
  printf '  Warning:   verify conversations, credentials, and agent CLI access before removing rollback data.\n'
}

restore_agent_payload() {
  local target_home="$HOME_DIR"
  [[ -d "$RESTORE_ARCHIVE_ROOT/payload/data/.codex" ]] || return 0
  mkdir -p "$target_home"
  cp -a -- "$RESTORE_ARCHIVE_ROOT/payload/data/.codex" "$target_home/"
  [[ ! -d "$RESTORE_ARCHIVE_ROOT/payload/data/.claude" ]] || cp -a -- "$RESTORE_ARCHIVE_ROOT/payload/data/.claude" "$target_home/"
  [[ ! -f "$RESTORE_ARCHIVE_ROOT/payload/data/.claude.json" ]] || cp -a -- "$RESTORE_ARCHIVE_ROOT/payload/data/.claude.json" "$target_home/"
  [[ ! -d "$RESTORE_ARCHIVE_ROOT/payload/data/.grok" ]] || cp -a -- "$RESTORE_ARCHIVE_ROOT/payload/data/.grok" "$target_home/"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$target_home/.codex" "$target_home/.claude" "$target_home/.grok" "$target_home/.claude.json" 2>/dev/null || true
}

main() {
  if [[ "$MODE" == "-h" || "$MODE" == "--help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi
  parse_args "$@"
  validate_common
  ensure_root
  if [[ "$MODE" == "backup" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      check_dependencies
      print_backup_plan
      return 0
    fi
    ensure_dependencies
    backup_archive
  else
    if [[ "$DRY_RUN" == 1 ]]; then
      check_dependencies
    else
      ensure_dependencies
    fi
    verify_archive_checksum
    validate_archive "$ARCHIVE_PATH"
    if [[ "$DRY_RUN" == 1 ]]; then
      extract_archive
      RESTORE_PLAN="$STAGE_DIR/restore-plan.json"
      create_restore_plan "$RESTORE_ARCHIVE_ROOT" "$RESTORE_PLAN"
      load_restore_runtime
      select_service_mode
      print_restore_plan
      return 0
    fi
    restore_archive
  fi
}

create_restore_plan() {
  local extract_root="$1"
  local plan_path="$2"
  python3 - "$extract_root/manifest.json" "$DATA_DIR" "$PROJECTS_DIR" "$plan_path" <<'PY'
import json
import os
import sys

manifest_path, new_data, projects_dir, plan_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
if manifest.get("format") != "mindfs-vps-migration" or manifest.get("format_version") != 1:
    raise SystemExit("unsupported MindFS migration archive")

def absolute(value, label):
    value = str(value).strip()
    if not os.path.isabs(value):
        raise SystemExit(f"{label} must be absolute")
    return os.path.abspath(os.path.normpath(value))

new_data = absolute(new_data, "target data directory")
projects_dir = absolute(projects_dir, "target projects directory")
old_data = absolute(manifest["runtime"]["data_dir"], "source data directory")
roots = []
for item in manifest.get("roots", []):
    original = absolute(item["original_path"], "original project path")
    archive_path = str(item.get("archive_path", ""))
    if any(char in archive_path for char in ("\n", "\r", "\t")):
        raise SystemExit(f"unsafe project archive path: {archive_path}")
    if archive_path and (archive_path.startswith("/") or ".." in archive_path.replace("\\", "/").split("/")):
        raise SystemExit(f"unsafe project archive path: {archive_path}")
    if archive_path:
        normalized_archive = os.path.normpath(archive_path).replace(os.sep, "/")
        if normalized_archive != archive_path or not normalized_archive.startswith("payload/projects/"):
            raise SystemExit(f"unsafe project archive path: {archive_path}")
        name = str(item.get("name", "")).strip()
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            name = os.path.basename(archive_path)
        destination = os.path.join(projects_dir, name)
        if os.path.commonpath([destination, projects_dir]) != projects_dir:
            raise SystemExit(f"unsafe project destination: {destination}")
    else:
        relative = str(item.get("relative_path", "."))
        if os.path.isabs(relative) or ".." in relative.replace("\\", "/").split("/"):
            raise SystemExit(f"unsafe project relative path: {relative}")
        destination = new_data if relative in ("", ".") else os.path.join(new_data, relative)
    roots.append({
        "id": str(item.get("id", "")),
        "name": str(item.get("name", "")),
        "registered": bool(item.get("registered", False)),
        "original_path": original,
        "kind": item.get("kind", ""),
        "archive_path": archive_path,
        "destination_name": os.path.basename(destination),
        "destination": os.path.abspath(os.path.normpath(destination)),
    })

def mapped(value):
    value = str(value).strip()
    if not value:
        return os.path.join(new_data, "workspace")
    value = absolute(value, "runtime path")
    for item in sorted(roots, key=lambda entry: len(entry["original_path"]), reverse=True):
        old = item["original_path"]
        if value == old or value.startswith(old + os.sep):
            suffix = os.path.relpath(value, old)
            return item["destination"] if suffix == "." else os.path.join(item["destination"], suffix)
    if value == old_data or value.startswith(old_data + os.sep):
        suffix = os.path.relpath(value, old_data)
        return new_data if suffix == "." else os.path.join(new_data, suffix)
    return os.path.join(new_data, "workspace")

plan = {
    "manifest": manifest,
    "old_data_dir": old_data,
    "new_data_dir": new_data,
    "projects_dir": projects_dir,
    "runtime_project_dir": mapped(manifest["runtime"]["project_dir"]),
    "roots": roots,
}
with open(plan_path, "w", encoding="utf-8") as stream:
    json.dump(plan, stream, indent=2, ensure_ascii=False)
    stream.write("\n")
PY
}

detect_runtime() {
  BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
  PORT="${PORT:-7331}"
  ENABLE_TLS="${ENABLE_TLS:-1}"
  ENABLE_E2EE="${ENABLE_E2EE:-1}"
  NO_RELAYER="${NO_RELAYER:-0}"
  if [[ -r "$START_SCRIPT" ]]; then
    local values
    values="$(python3 - "$START_SCRIPT" <<'PY'
import shlex
import sys

bind, port, tls, e2ee, relayer, project = "0.0.0.0", "7331", "0", "0", "0", ""
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
    args = shlex.split(lines[-1]) if lines else []
    for index, value in enumerate(args):
        if value == "--addr" and index + 1 < len(args):
            address = args[index + 1]
            if address.startswith("[") and "]:" in address:
                bind, port = address[1:].split("]:", 1)
            elif ":" in address:
                bind, port = address.rsplit(":", 1)
            else:
                bind = address
        elif value == "--tls":
            tls = "1"
        elif value == "--e2ee":
            e2ee = "1"
        elif value == "--no-relayer":
            relayer = "1"
    if args:
        project = args[-1]
except (OSError, ValueError, IndexError):
    pass
print("\t".join((bind, port, tls, e2ee, relayer, project)))
PY
    )"
    IFS=$'\t' read -r BIND_ADDR PORT ENABLE_TLS ENABLE_E2EE NO_RELAYER detected_project <<<"$values"
    if [[ "$PROJECT_DIR_SET" != 1 && -n "$detected_project" ]]; then
      PROJECT_DIR="$detected_project"
    fi
  fi
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || PORT=7331
  [[ "$ENABLE_TLS" == 0 || "$ENABLE_TLS" == 1 ]] || ENABLE_TLS=1
  [[ "$ENABLE_E2EE" == 0 || "$ENABLE_E2EE" == 1 ]] || ENABLE_E2EE=1
  [[ "$NO_RELAYER" == 0 || "$NO_RELAYER" == 1 ]] || NO_RELAYER=0
  [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="${DATA_DIR}/workspace"
}

write_manifest() {
  python3 - "$DATA_DIR" "$HOME_DIR" "$CONFIG_DIR" "$PROJECT_DIR" "$PREFIX" "$SERVICE_NAME" "$SERVICE_USER" "$SERVICE_MODE" "$BIND_ADDR" "$PORT" "$ENABLE_TLS" "$ENABLE_E2EE" "$NO_RELAYER" "$METADATA_ONLY" "$INCLUDE_AGENT_DATA" "$STAGE_DIR/mindfs-migration/manifest.json" "$STAGE_DIR/root-list.tsv" <<'PY'
import datetime
import json
import os
import sys

(data_dir, home_dir, config_dir, project_dir, prefix, service_name, service_user,
 service_mode, bind, port, tls, e2ee, no_relayer, metadata_only,
 include_agent_data, manifest_path, root_list) = sys.argv[1:]
data_dir = os.path.abspath(os.path.normpath(data_dir))
home_dir = os.path.abspath(os.path.normpath(home_dir))
config_dir = os.path.abspath(os.path.normpath(config_dir))
project_dir = os.path.abspath(os.path.normpath(project_dir))
metadata_only = metadata_only == "1"

def within(path, parent):
    try:
        return os.path.commonpath([path, parent]) == parent
    except ValueError:
        return False

def checked_path(value, label):
    if any(char in value for char in ("\n", "\r", "\t")):
        raise SystemExit(f"{label} contains a control character")
    if not os.path.isabs(value):
        raise SystemExit(f"{label} must be absolute: {value}")
    return os.path.abspath(os.path.normpath(value))

registry_path = os.path.join(config_dir, "registry.json")
stored = {"dirs": [], "order": []}
if os.path.isfile(registry_path):
    with open(registry_path, encoding="utf-8") as stream:
        stored = json.load(stream)

roots = []
seen = set()
for item in stored.get("dirs", []):
    raw_path = str(item.get("root_path", "")).strip()
    if not raw_path:
        continue
    path = checked_path(raw_path, "project root")
    if path in seen:
        continue
    seen.add(path)
    roots.append({
        "id": str(item.get("id", "")),
        "name": str(item.get("name", "")),
        "path": path,
        "registered": True,
    })
if project_dir not in seen:
    roots.append({
        "id": "",
        "name": os.path.basename(project_dir),
        "path": checked_path(project_dir, "startup project"),
        "registered": False,
    })
roots.sort(key=lambda item: (len(item["path"]), item["path"]))

with open(root_list, "w", encoding="utf-8") as listing:
    for index, item in enumerate(roots, 1):
        if not os.path.isdir(item["path"]):
            raise SystemExit(f"project root does not exist: {item['path']}")
        if metadata_only:
            item["kind"] = "metadata"
            item["archive_path"] = f"payload/projects/root-{index:04d}"
            listing.write(f"{item['archive_path']}\t{item['path']}\n")
        else:
            relative = os.path.relpath(item["path"], data_dir)
            if within(item["path"], data_dir):
                item["kind"] = "data"
                item["archive_path"] = ""
            else:
                item["kind"] = "external"
                item["archive_path"] = f"payload/projects/root-{index:04d}"
                listing.write(f"{item['archive_path']}\t{item['path']}\n")
            item["relative_path"] = "." if relative == "." else relative

manifest = {
    "format": "mindfs-vps-migration",
    "format_version": 1,
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "scope": {
        "metadata_only": metadata_only,
        "include_agent_data": include_agent_data == "1",
        "excludes": ["project source", ".git", "dependencies", "caches", ".codex/packages", ".codex/logs_2.sqlite*"],
    },
    "runtime": {
        "data_dir": data_dir,
        "home_dir": home_dir,
        "config_dir": config_dir,
        "project_dir": project_dir,
        "prefix": prefix,
        "service_name": service_name,
        "service_user": service_user,
        "service_mode": service_mode,
        "bind": bind,
        "port": int(port),
        "tls": tls == "1",
        "e2ee": e2ee == "1",
        "no_relayer": no_relayer == "1",
    },
    "roots": [{
        "id": item["id"],
        "name": item["name"],
        "original_path": item["path"],
        "registered": item["registered"],
        "kind": item["kind"],
        "relative_path": item.get("relative_path", "."),
        "archive_path": item["archive_path"],
        "has_metadata": os.path.isdir(os.path.join(item["path"], ".mindfs")),
    } for item in roots],
}

os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, indent=2, ensure_ascii=False)
    stream.write("\n")
PY
}

main "$@"
