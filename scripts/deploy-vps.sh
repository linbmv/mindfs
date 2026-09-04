#!/usr/bin/env bash
# Install MindFS as an independent service on a Debian/Ubuntu VPS.
# The script does not use the current checkout directory. It builds from a
# source checkout and keeps the executable, service data, and project root in
# separate configurable absolute paths. systemd is preferred; environments
# without a running systemd (for example containers) use a managed background
# process instead.
#
# Usage:
#   bash deploy-vps.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/linbmv/mindfs/custom/mindfs-local/scripts/deploy-vps.sh | sudo bash -s --
set -Eeuo pipefail

umask 077

PREFIX="${MINDFS_PREFIX:-/opt/mindfs}"
DATA_DIR="${MINDFS_DATA_DIR:-/var/lib/mindfs}"
HOME_DIR="${MINDFS_HOME_DIR:-${DATA_DIR}}"
CONFIG_DIR="${MINDFS_CONFIG_DIR:-${DATA_DIR}/config/mindfs}"
PROJECT_DIR="${MINDFS_PROJECT_DIR:-}"
SERVICE_NAME="${MINDFS_SERVICE_NAME:-mindfs}"
SERVICE_USER="${MINDFS_SERVICE_USER:-mindfs}"
BIND_ADDR="${MINDFS_BIND_ADDR:-0.0.0.0}"
PORT="${MINDFS_PORT:-7331}"
ENABLE_TLS="${MINDFS_ENABLE_TLS:-1}"
ENABLE_E2EE="${MINDFS_ENABLE_E2EE:-1}"
NO_RELAYER="${MINDFS_NO_RELAYER:-0}"
OPEN_FIREWALL="${MINDFS_OPEN_FIREWALL:-0}"
INIT_MODE="${MINDFS_INIT_MODE:-auto}"
SOURCE_REPO_URL="${MINDFS_SOURCE_REPO_URL:-https://github.com/linbmv/mindfs.git}"
SOURCE_BRANCH="${MINDFS_SOURCE_BRANCH:-custom/mindfs-local}"
SOURCE_DIR="${MINDFS_SOURCE_DIR:-/opt/mindfs-src}"
DRY_RUN=0
SKIP_START=0

CONFIG_HOME=""
STATE_HOME=""
START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
STATIC_DIR="${PREFIX}/share/mindfs/web"
USER_BIN_DIR="${HOME_DIR}/.local/bin"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
PID_FILE="${DATA_DIR}/mindfs.pid"
LOG_FILE="${DATA_DIR}/mindfs.log"
CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"
SERVICE_GROUP=""
SERVICE_MODE=""
LISTEN_ADDR=""
HEALTH_URL=""
RUNUSER_PATH=""
ENV_PATH=""
SYSTEMCTL_PATH=""

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

SOURCE_DIR_EXPLICIT=0
[[ -n "${MINDFS_SOURCE_DIR:-}" ]] && SOURCE_DIR_EXPLICIT=1
IN_TREE_BUILD=0
MIN_GO_MAJOR=1
MIN_GO_MINOR=25

log() {
  printf '[mindfs-vps] %s\n' "$*"
}

warn() {
  printf '[mindfs-vps] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[mindfs-vps] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
MindFS VPS deployment

Builds MindFS from source on this host and creates a service.
No prebuilt binary is ever downloaded. Requires Go 1.25+, Node.js 20+, git and make.
The service is independent of the directory from which this script is run.

Options:
  --source-repo URL       Git remote to build from
                          (default: https://github.com/linbmv/mindfs.git)
  --source-branch NAME    Branch to build (default: custom/mindfs-local)
  --source-dir PATH       Checkout location (default: /opt/mindfs-src)
  --prefix PATH           Binary install prefix (default: /opt/mindfs)
  --data-dir PATH         Service home and persistent config (default: /var/lib/mindfs)
  --home-dir PATH         HOME for the service user (default: DATA_DIR)
  --config-dir PATH       MindFS config directory (default: DATA_DIR/config/mindfs)
  --project-dir PATH      Initial managed project directory
                          (default: /var/lib/mindfs/workspace)
  --service-name NAME     service name (default: mindfs)
  --service-user NAME     Unix user running MindFS (default: mindfs)
  --init MODE             auto, systemd, or background (default: auto)
  --no-systemd            Use the background process mode explicitly
  --bind ADDRESS          Listen address (default: 0.0.0.0)
  --port PORT             Listen port (default: 7331)
  --private               Bind only to 127.0.0.1
  --no-tls                Disable HTTPS (only suitable behind an HTTPS proxy)
  --no-e2ee               Disable pairing protection (not recommended on a VPS)
  --no-relayer            Disable Relay integration
  --open-firewall         Add PORT/tcp to an existing UFW configuration
  --dry-run               Print the deployment plan without changing the host
  --skip-start            Install and configure without starting the service
  -h, --help              Show this help

Environment equivalents use the MINDFS_ prefix, e.g. MINDFS_PROJECT_DIR.
EOF
}

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        need_value "$@"
        PREFIX="$2"
        shift 2
        ;;
      --data-dir)
        need_value "$@"
        DATA_DIR="$2"
        shift 2
        ;;
      --home-dir)
        need_value "$@"
        HOME_DIR="$2"
        shift 2
        ;;
      --config-dir)
        need_value "$@"
        CONFIG_DIR="$2"
        shift 2
        ;;
      --project-dir)
        need_value "$@"
        PROJECT_DIR="$2"
        shift 2
        ;;
      --service-name)
        need_value "$@"
        SERVICE_NAME="$2"
        shift 2
        ;;
      --service-user)
        need_value "$@"
        SERVICE_USER="$2"
        shift 2
        ;;
      --init)
        need_value "$@"
        INIT_MODE="$2"
        shift 2
        ;;
      --no-systemd)
        INIT_MODE="background"
        shift
        ;;
      --bind)
        need_value "$@"
        BIND_ADDR="$2"
        shift 2
        ;;
      --port)
        need_value "$@"
        PORT="$2"
        shift 2
        ;;
      --private)
        BIND_ADDR="127.0.0.1"
        shift
        ;;
      --no-tls)
        ENABLE_TLS=0
        shift
        ;;
      --tls)
        ENABLE_TLS=1
        shift
        ;;
      --e2ee)
        ENABLE_E2EE=1
        shift
        ;;
      --no-e2ee)
        ENABLE_E2EE=0
        shift
        ;;
      --no-relayer)
        NO_RELAYER=1
        shift
        ;;
      --open-firewall)
        OPEN_FIREWALL=1
        shift
        ;;
      --from-source)
        # Accepted for compatibility; building from source is the only mode.
        shift
        ;;
      --source-repo)
        need_value "$@"
        SOURCE_REPO_URL="$2"
        shift 2
        ;;
      --source-branch)
        need_value "$@"
        SOURCE_BRANCH="$2"
        shift 2
        ;;
      --source-dir)
        need_value "$@"
        SOURCE_DIR="$2"
        SOURCE_DIR_EXPLICIT=1
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --skip-start)
        SKIP_START=1
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
  [[ "$value" == /* ]] || die "$name must be an absolute path: $value"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$name must not contain a newline"
}

validate_config() {
  [[ -n "$PROJECT_DIR" ]] && : || PROJECT_DIR="${DATA_DIR}/workspace"
  CONFIG_HOME="$(dirname "$CONFIG_DIR")"
  STATE_HOME="${HOME_DIR}/.local/share"
  START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
  STATIC_DIR="${PREFIX}/share/mindfs/web"
  USER_BIN_DIR="${HOME_DIR}/.local/bin"
  UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
  PID_FILE="${DATA_DIR}/mindfs.pid"
  LOG_FILE="${DATA_DIR}/mindfs.log"
  CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"

  # Build the checkout this script came from, unless the caller named a
  # different source directory. Piped runs (curl | bash) have no SCRIPT_DIR and
  # fall through to the clone path.
  if [[ "$SOURCE_DIR_EXPLICIT" == 0 && -n "$SCRIPT_DIR" ]]; then
    local in_tree_root
    in_tree_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -d "$in_tree_root/.git" && -f "$in_tree_root/Makefile" && -d "$in_tree_root/cli/cmd" ]]; then
      IN_TREE_BUILD=1
      SOURCE_DIR="$in_tree_root"
    fi
  fi

  require_absolute_path PREFIX "$PREFIX"
  require_absolute_path DATA_DIR "$DATA_DIR"
  require_absolute_path HOME_DIR "$HOME_DIR"
  require_absolute_path CONFIG_DIR "$CONFIG_DIR"
  require_absolute_path PROJECT_DIR "$PROJECT_DIR"

  require_absolute_path SOURCE_DIR "$SOURCE_DIR"
  [[ -n "$SOURCE_REPO_URL" ]] || die "--source-repo must not be empty"
  [[ -n "$SOURCE_BRANCH" ]] || die "--source-branch must not be empty"
  [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "invalid service name: $SERVICE_NAME"
  [[ "$SERVICE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid service user: $SERVICE_USER"
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "invalid port: $PORT"
  [[ "$BIND_ADDR" != *[[:space:]]* ]] || die "bind address must not contain whitespace"
  [[ "$ENABLE_TLS" == 0 || "$ENABLE_TLS" == 1 ]] || die "MINDFS_ENABLE_TLS must be 0 or 1"
  [[ "$ENABLE_E2EE" == 0 || "$ENABLE_E2EE" == 1 ]] || die "MINDFS_ENABLE_E2EE must be 0 or 1"
  [[ "$NO_RELAYER" == 0 || "$NO_RELAYER" == 1 ]] || die "MINDFS_NO_RELAYER must be 0 or 1"
  [[ "$OPEN_FIREWALL" == 0 || "$OPEN_FIREWALL" == 1 ]] || die "MINDFS_OPEN_FIREWALL must be 0 or 1"
  [[ "$SKIP_START" == 0 || "$SKIP_START" == 1 ]] || die "SKIP_START must be 0 or 1"
  [[ "$INIT_MODE" == "auto" || "$INIT_MODE" == "systemd" || "$INIT_MODE" == "background" ]] || die "init mode must be auto, systemd, or background"

  if [[ "$ENABLE_E2EE" == 1 && "$ENABLE_TLS" == 0 ]]; then
    die "E2EE requires HTTPS in a browser; remove --no-tls or disable E2EE explicitly"
  fi
  if [[ "$ENABLE_TLS" == 0 && "$BIND_ADDR" != "127.0.0.1" && "$BIND_ADDR" != "localhost" && "$BIND_ADDR" != "::1" ]]; then
    die "refusing public plaintext HTTP; use HTTPS or bind with --private"
  fi

  if [[ "$BIND_ADDR" == *:* && "$BIND_ADDR" != \[*\] ]]; then
    LISTEN_ADDR="[${BIND_ADDR}]:${PORT}"
  else
    LISTEN_ADDR="${BIND_ADDR}:${PORT}"
  fi
  local health_host="127.0.0.1"
  if [[ "$BIND_ADDR" == "::1" || "$BIND_ADDR" == "[::1]" ]]; then
    health_host="[::1]"
  fi
  if [[ "$ENABLE_TLS" == 1 ]]; then
    HEALTH_URL="https://${health_host}:${PORT}/health"
  else
    HEALTH_URL="http://${health_host}:${PORT}/health"
  fi
}

select_service_mode() {
  local pid1_comm=""
  if [[ -r /proc/1/comm ]]; then
    IFS= read -r pid1_comm < /proc/1/comm || true
  fi

  local systemd_available=0
  if command -v systemctl >/dev/null 2>&1 \
    && [[ "$pid1_comm" == "systemd" ]] \
    && { [[ -d /run/systemd/system ]] || [[ -S /run/systemd/private ]]; }; then
    systemd_available=1
  fi

  case "$INIT_MODE" in
    systemd)
      [[ "$systemd_available" == 1 ]] || die "systemd was requested but is not running; use --init background in this environment"
      SERVICE_MODE="systemd"
      ;;
    background)
      SERVICE_MODE="background"
      ;;
    auto)
      if [[ "$systemd_available" == 1 ]]; then
        SERVICE_MODE="systemd"
      else
        SERVICE_MODE="background"
      fi
      ;;
  esac
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

print_plan() {
  cat <<EOF
Deployment plan (dry run)
  install source: local build (no prebuilt binary is ever downloaded)
  build mode:    $(if [[ "$IN_TREE_BUILD" == 1 ]]; then printf 'in-tree (this checkout, git untouched)'; else printf 'clone/pull %s (%s)' "$SOURCE_REPO_URL" "$SOURCE_BRANCH"; fi)
  checkout dir:  ${SOURCE_DIR}
  version:       from git describe
  prefix:        ${PREFIX}
  data directory: ${DATA_DIR}
  project root:  ${PROJECT_DIR}
  service:       ${SERVICE_NAME} (user ${SERVICE_USER})
  service mode:  ${SERVICE_MODE}
  listen:        ${LISTEN_ADDR}
  TLS:           ${ENABLE_TLS}
  E2EE pairing:  ${ENABLE_E2EE}
  Relay:         $([[ "$NO_RELAYER" == 1 ]] && printf 'disabled' || printf 'enabled')
  UFW rule:      ${OPEN_FIREWALL}
  Start service: $([[ "$SKIP_START" == 1 ]] && printf 'no' || printf 'yes')

No files, packages, users, firewall rules, or systemd units will be changed.
EOF
}

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root, for example: curl ... | sudo bash -s --"
}

bootstrap_tool_path() {
  # sudo may reset PATH and hide a system-wide Go installation under
  # /usr/local/go/bin. Add standard installation locations before checking
  # dependencies so piped and interactive invocations behave identically.
  local go_bin
  for go_bin in /usr/local/go/bin /usr/local/bin /usr/bin /bin; do
    if [[ -x "$go_bin/go" ]]; then
      PATH="$go_bin:$PATH"
      break
    fi
  done
  export PATH
}

ensure_dependencies() {
  local missing=()
  local command_name
  local packages=(curl ca-certificates tar util-linux git make)
  local required=(curl tar install useradd id stat git make)
  [[ "$SERVICE_MODE" == "background" ]] && required+=(runuser)
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if ((${#missing[@]} > 0)); then
    command -v apt-get >/dev/null 2>&1 || die "missing commands (${missing[*]}) and apt-get is unavailable"
    log "Installing required packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi

  missing=()
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) ||
    die "required command(s) still missing after package installation: ${missing[*]}"

  for command_name in go node npm; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "building from source needs ${command_name}; install a current version (distro packages are often too old) before rerunning"
  done

  local go_version go_major go_minor
  go_version="$(go version | awk '{print $3}' | sed 's/^go//')"
  go_major="${go_version%%.*}"
  go_minor="${go_version#*.}"
  go_minor="${go_minor%%.*}"
  [[ "$go_major" =~ ^[0-9]+$ && "$go_minor" =~ ^[0-9]+$ ]] ||
    die "unable to determine Go version from: $(go version)"
  if ((go_major < MIN_GO_MAJOR || (go_major == MIN_GO_MAJOR && go_minor < MIN_GO_MINOR))); then
    die "MindFS requires Go >= ${MIN_GO_MAJOR}.${MIN_GO_MINOR}; found ${go_version}"
  fi

  local node_version node_major
  node_version="$(node --version | sed 's/^v//')"
  node_major="${node_version%%.*}"
  [[ "$node_major" =~ ^[0-9]+$ ]] ||
    die "unable to determine Node.js version from: $(node --version)"
  ((node_major >= 20)) || die "MindFS requires Node.js >= 20; found ${node_version}"
}

resolve_runtime_tools() {
  ENV_PATH="$(command -v env || true)"
  [[ -n "$ENV_PATH" ]] || die "env is required to launch MindFS"

  if [[ "$SERVICE_MODE" == "background" ]]; then
    RUNUSER_PATH="$(command -v runuser || true)"
    [[ -x "$RUNUSER_PATH" ]] ||
      die "background mode requires runuser; install util-linux and rerun deployment"
  else
    SYSTEMCTL_PATH="$(command -v systemctl || true)"
    [[ -x "$SYSTEMCTL_PATH" ]] ||
      die "systemd mode requires systemctl"
  fi
}

ensure_service_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Creating service user ${SERVICE_USER}"
    useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi

  local service_uid
  service_uid="$(id -u "$SERVICE_USER")"
  local service_gid
  service_gid="$(id -g "$SERVICE_USER")"
  SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

  ensure_owned_dir "$DATA_DIR" 0750 "$service_uid" "$service_gid"
  ensure_owned_dir "$HOME_DIR" 0750 "$service_uid" "$service_gid"
  ensure_owned_dir "$CONFIG_HOME" 0700 "$service_uid" "$service_gid"

  # mkdir -p on STATE_HOME would otherwise leave its intermediate .local
  # directory root-owned under umask 077, preventing the service user from
  # traversing /var/lib/mindfs/.local. This directory is internal service
  # state, so repair its ownership explicitly on reruns as well.
  local state_parent="${HOME_DIR}/.local"
  if [[ -e "$state_parent" && ! -d "$state_parent" ]]; then
    die "path exists but is not a directory: $state_parent"
  fi
  mkdir -p "$state_parent" "$STATE_HOME"
  chown "$service_uid:$service_gid" "$state_parent" "$STATE_HOME"
  chmod 0750 "$state_parent" "$STATE_HOME"
  ensure_owned_dir "$STATE_HOME" 0750 "$service_uid" "$service_gid"
  ensure_owned_dir "$PROJECT_DIR" 0750 "$service_uid" "$service_gid"
}

verify_service_user_paths() {
  [[ "$SERVICE_MODE" == "background" ]] || return 0
  "$RUNUSER_PATH" -u "$SERVICE_USER" -- "$ENV_PATH" \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$CONFIG_HOME" \
    /bin/sh -c 'umask 077; mkdir -p "$HOME/.local/share"; test -w "$HOME" && test -w "$HOME/.local/share" && test -w "$XDG_CONFIG_HOME"' ||
    die "service user ${SERVICE_USER} cannot write HOME/config state; check ownership of ${HOME_DIR} and ${CONFIG_HOME}"
}

ensure_owned_dir() {
  local path="$1"
  local mode="$2"
  local expected_uid="$3"
  local expected_gid="$4"

  if [[ -e "$path" && ! -d "$path" ]]; then
    die "path exists but is not a directory: $path"
  fi
  if [[ ! -e "$path" ]]; then
    mkdir -p "$path"
    chown "$expected_uid:$expected_gid" "$path"
  fi

  local actual_uid
  actual_uid="$(stat -c '%u' "$path")"
  local actual_gid
  actual_gid="$(stat -c '%g' "$path")"
  if [[ "$actual_uid" != "$expected_uid" || "$actual_gid" != "$expected_gid" ]]; then
    die "$path is not owned by ${SERVICE_USER}; refusing to change existing data ownership"
  fi
  chmod "$mode" "$path"
}

build_from_source() {
  local source_dir="$1"
  local command_name
  for command_name in git go npm make; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "building from source requires ${command_name}; install it before rerunning"
  done

  if [[ "$IN_TREE_BUILD" == 1 ]]; then
    log "Building the checkout this script came from: ${source_dir}"
    log "Leaving git alone; run 'git pull' yourself to change the revision"
  elif [[ ! -d "$source_dir/.git" ]]; then
    log "Cloning ${SOURCE_REPO_URL} (${SOURCE_BRANCH}) into ${source_dir}"
    git clone --branch "$SOURCE_BRANCH" -- "$SOURCE_REPO_URL" "$source_dir"
  else
    log "Updating existing checkout at ${source_dir}"
    git -C "$source_dir" fetch --prune origin
    git -C "$source_dir" checkout "$SOURCE_BRANCH"
    git -C "$source_dir" pull --ff-only
  fi

  # A fresh checkout has no node_modules, and `make build-web` invokes vite
  # directly, so install web dependencies first. Prefer `npm ci` for its
  # lockfile guarantees, falling back when the lockfile is absent.
  if [[ -f "$source_dir/web/package-lock.json" ]]; then
    log "Installing web dependencies with npm ci"
    (cd "$source_dir/web" && npm ci)
  else
    log "Installing web dependencies with npm install (no lockfile found)"
    (cd "$source_dir/web" && npm install)
  fi

  log "Building web assets and binary, then installing into ${PREFIX} (takes a few minutes)"
  make -C "$source_dir" install PREFIX="$PREFIX"
}

install_mindfs() {
  build_from_source "$SOURCE_DIR"
  [[ -x "${PREFIX}/bin/mindfs" ]] || die "MindFS binary was not installed at ${PREFIX}/bin/mindfs"

  [[ -f "${STATIC_DIR}/index.html" ]] ||
    die "frontend assets were not installed at ${STATIC_DIR}/index.html"
  [[ -f "${STATIC_DIR}/favicon.svg" ]] ||
    die "frontend assets were not installed at ${STATIC_DIR}/favicon.svg"

  # The installer runs with umask 077.  Static assets are public application
  # files, so make the complete installed tree traversable/readable by the
  # unprivileged service user before the first start.
  chmod 0755 "$PREFIX" "${PREFIX}/bin" "${PREFIX}/share" \
    "${PREFIX}/share/mindfs" "$STATIC_DIR"
  find "$STATIC_DIR" -type d -exec chmod 0755 {} +
  find "$STATIC_DIR" -type f -exec chmod 0644 {} +
}

write_start_script() {
  mkdir -p -m 0755 "${PREFIX}/bin"
  chmod 0755 "$PREFIX" "${PREFIX}/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'export MINDFS_STATIC_DIR=%s\n' "$(shell_quote "$STATIC_DIR")"
    printf 'exec %s --foreground --addr %s' \
      "$(shell_quote "${PREFIX}/bin/mindfs")" \
      "$(shell_quote "$LISTEN_ADDR")"
    [[ "$ENABLE_TLS" == 1 ]] && printf ' --tls'
    [[ "$ENABLE_E2EE" == 1 ]] && printf ' --e2ee'
    [[ "$NO_RELAYER" == 1 ]] && printf ' --no-relayer'
    printf ' %s\n' "$(shell_quote "$PROJECT_DIR")"
  } >"$START_SCRIPT"
  chmod 0755 "$START_SCRIPT"
}

write_control_script() {
  mkdir -p "${PREFIX}/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
    printf 'SERVICE_MODE=%s\n' "$(shell_quote "$SERVICE_MODE")"
    printf 'SERVICE_NAME=%s\n' "$(shell_quote "$SERVICE_NAME")"
    printf 'SERVICE_USER=%s\n' "$(shell_quote "$SERVICE_USER")"
    printf 'SERVICE_GROUP=%s\n' "$(shell_quote "$SERVICE_GROUP")"
    printf 'DATA_DIR=%s\n' "$(shell_quote "$DATA_DIR")"
    printf 'CONFIG_DIR=%s\n' "$(shell_quote "$CONFIG_DIR")"
    printf 'CONFIG_HOME=%s\n' "$(shell_quote "$CONFIG_HOME")"
    printf 'HOME_DIR=%s\n' "$(shell_quote "$HOME_DIR")"
    printf 'START_SCRIPT=%s\n' "$(shell_quote "$START_SCRIPT")"
    printf 'BIN_PATH=%s\n' "$(shell_quote "${PREFIX}/bin/mindfs")"
    printf 'PID_FILE=%s\n' "$(shell_quote "$PID_FILE")"
    printf 'LOG_FILE=%s\n' "$(shell_quote "$LOG_FILE")"
    printf 'PAIRING_FILE=%s\n' "$(shell_quote "${CONFIG_DIR}/e2ee.json")"
    printf 'PATH_VALUE=%s\n' "$(shell_quote "${PREFIX}/bin:${USER_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
    printf 'RUNUSER_PATH=%s\n' "$(shell_quote "$RUNUSER_PATH")"
    printf 'ENV_PATH=%s\n' "$(shell_quote "$ENV_PATH")"
    printf 'SYSTEMCTL_PATH=%s\n' "$(shell_quote "$SYSTEMCTL_PATH")"
    cat <<'EOF'

require_root() {
  [[ "${EUID}" -eq 0 ]] || {
    printf 'run this command as root\n' >&2
    exit 1
  }
}

read_pid() {
  [[ -r "$PID_FILE" ]] || return 1
  local pid
  pid="$(<"$PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$pid"
}

process_matches() {
  local pid="$1"
  local command_line
  command_line="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "$command_line" == *"$START_SCRIPT"* || "$command_line" == *"$BIN_PATH"* ]]
}

is_running() {
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    "$SYSTEMCTL_PATH" is-active --quiet "${SERVICE_NAME}.service"
    return
  fi
  local pid
  pid="$(read_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null && process_matches "$pid"
}

check_service_user_paths() {
  [[ "$SERVICE_MODE" == "background" ]] || return 0
  "$RUNUSER_PATH" -u "$SERVICE_USER" -- "$ENV_PATH" \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$CONFIG_HOME" \
    /bin/sh -c 'umask 077; mkdir -p "$HOME/.local/share"; test -w "$HOME" && test -w "$HOME/.local/share" && test -w "$XDG_CONFIG_HOME"'
}

start_service() {
  require_root
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    "$SYSTEMCTL_PATH" start "${SERVICE_NAME}.service"
    return
  fi
  if is_running; then
    printf 'mindfs is already running (pid %s)\n' "$(read_pid)"
    return 0
  fi
  rm -f "$PID_FILE"
  touch "$LOG_FILE"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  if ! check_service_user_paths; then
    printf 'mindfs cannot start: %s cannot write %s or %s\n' "$SERVICE_USER" "$HOME_DIR" "$CONFIG_HOME" >&2
    exit 1
  fi
  nohup "$RUNUSER_PATH" -u "$SERVICE_USER" -- "$ENV_PATH" \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$CONFIG_HOME" \
    PATH="$PATH_VALUE" \
    "$START_SCRIPT" >>"$LOG_FILE" 2>&1 </dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  chmod 0600 "$PID_FILE"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'mindfs failed to start; recent log:\n' >&2
    tail -n 80 "$LOG_FILE" >&2 || true
    exit 1
  fi
  printf 'mindfs started (pid %s)\n' "$pid"
}

stop_service() {
  require_root
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    "$SYSTEMCTL_PATH" stop "${SERVICE_NAME}.service"
    return
  fi
  local pid
  pid="$(read_pid 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null || ! process_matches "$pid"; then
    rm -f "$PID_FILE"
    printf 'mindfs is not running\n'
    return 0
  fi
  kill "$pid"
  local attempt
  for attempt in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      printf 'mindfs stopped\n'
      return 0
    fi
    [[ "$attempt" -lt 30 ]] && sleep 1
  done
  printf 'mindfs did not stop after 30 seconds; sending SIGKILL\n' >&2
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
}

status_service() {
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    "$SYSTEMCTL_PATH" --no-pager --full status "${SERVICE_NAME}.service" || true
  else
    if is_running; then
      printf 'mindfs is active (pid %s)\n' "$(read_pid)"
    else
      printf 'mindfs is inactive\n'
    fi
  fi
  pairing_service
}

pairing_service() {
  local secret
  if [[ ! -r "$PAIRING_FILE" ]]; then
    printf 'pairing code: unavailable (file not found: %s)\n' "$PAIRING_FILE"
    return 0
  fi
  secret="$(awk -F'"' '/"pairing_secret"[[:space:]]*:/ { print $4; exit }' "$PAIRING_FILE" 2>/dev/null || true)"
  if [[ -n "$secret" ]]; then
    printf 'pairing code: %s\n' "$secret"
    return 0
  fi
  printf 'pairing code: unavailable (E2EE may be disabled or config is incomplete: %s)\n' "$PAIRING_FILE"
}

case "${1:-status}" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  status) status_service ;;
  *)
    printf 'usage: %s {start|stop|restart|status}\n' "$0" >&2
    exit 2
    ;;
esac
EOF
  } >"$CONTROL_SCRIPT"
  chmod 0755 "$CONTROL_SCRIPT"
}

write_systemd_unit() {
  {
    printf '%s\n' '[Unit]' 'Description=MindFS AI agent gateway' 'After=network-online.target' 'Wants=network-online.target' '' '[Service]'
    printf 'Type=simple\n'
    printf 'User=%s\n' "$SERVICE_USER"
    printf 'Group=%s\n' "$SERVICE_GROUP"
    printf 'WorkingDirectory=%s\n' "$(systemd_quote "$PROJECT_DIR")"
    printf 'Environment=HOME=%s\n' "$(systemd_quote "$HOME_DIR")"
    printf 'Environment=XDG_CONFIG_HOME=%s\n' "$(systemd_quote "$CONFIG_HOME")"
    printf 'Environment=PATH=%s\n' "$(systemd_quote "${PREFIX}/bin:${USER_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
    printf 'ExecStart=%s\n' "$(systemd_quote "$START_SCRIPT")"
    printf '%s\n' 'Restart=on-failure' 'RestartSec=5s' 'TimeoutStopSec=30s' 'LimitNOFILE=65536' 'NoNewPrivileges=true' 'PrivateTmp=true' 'ProtectSystem=full' 'ProtectKernelTunables=true' 'ProtectControlGroups=true' 'RestrictSUIDSGID=true' '' '[Install]' 'WantedBy=multi-user.target'
  } >"$UNIT_PATH"
  chmod 0644 "$UNIT_PATH"
}

start_service() {
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    log "Enabling and starting ${SERVICE_NAME}.service"
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
  else
    log "Starting MindFS as a background process (systemd is unavailable)"
    "$CONTROL_SCRIPT" restart
  fi
}

wait_for_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if [[ "$ENABLE_TLS" == 1 ]]; then
      if curl -kfsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
        return 0
      fi
    elif curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$attempt" -lt 30 ]]; then
      sleep 1
    fi
  done

  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true
    die "MindFS did not become healthy; inspect: journalctl -u ${SERVICE_NAME} -e"
  fi
  tail -n 80 "$LOG_FILE" || true
  die "MindFS did not become healthy; inspect: ${LOG_FILE}"
}

configure_firewall() {
  [[ "$OPEN_FIREWALL" == 1 ]] || return 0
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null
    log "Added UFW rule for ${PORT}/tcp"
  else
    warn "UFW is not installed; open TCP ${PORT} in the VPS provider firewall if public access is intended"
  fi
}

pairing_secret() {
  local config_file="${CONFIG_DIR}/e2ee.json"
  [[ -r "$config_file" ]] || return 0
  awk -F'"' '/"pairing_secret"[[:space:]]*:/ { print $4; exit }' "$config_file"
}

print_summary() {
  local scheme="http"
  [[ "$ENABLE_TLS" == 1 ]] && scheme="https"

  local local_url="${scheme}://127.0.0.1:${PORT}"
  local host_ip=""
  if command -v hostname >/dev/null 2>&1; then
    host_ip="$(hostname -I 2>/dev/null | awk '$1 !~ /:/ {print; exit}')"
  fi

  printf '\nMindFS VPS deployment complete.\n\n'
  printf '  Service:     sudo %s status\n' "$CONTROL_SCRIPT"
  printf '  Start/stop:  sudo %s {start|stop|restart}\n' "$CONTROL_SCRIPT"
  printf '  Pairing:     included in sudo %s status\n' "$CONTROL_SCRIPT"
  if [[ "$SERVICE_MODE" == "background" ]]; then
    printf '  Note:        systemd is unavailable; this process will not auto-start after a host reboot\n'
  else
    printf '  Systemd:     sudo systemctl status %s\n' "$SERVICE_NAME"
  fi
  printf '  Data:        %s\n' "$DATA_DIR"
  printf '  HOME:        %s\n' "$HOME_DIR"
  printf '  Config:      %s\n' "$CONFIG_DIR"
  printf '  Project:     %s\n' "$PROJECT_DIR"
  printf '  Health:      %s\n' "$HEALTH_URL"

  if [[ "$BIND_ADDR" == "127.0.0.1" || "$BIND_ADDR" == "localhost" || "$BIND_ADDR" == "::1" ]]; then
    printf '  Local URL:   %s\n' "$local_url"
    printf '  SSH tunnel:  ssh -N -L %s:127.0.0.1:%s <user>@<vps-ip>\n' "$PORT" "$PORT"
    printf '  Then open:   %s\n' "${scheme}://localhost:${PORT}"
  else
    printf '  VPS URL:     %s://%s:%s\n' "$scheme" "${host_ip:-<vps-ip>}" "$PORT"
    printf '  Note:        the generated TLS certificate is self-signed; accept it once in the browser\n'
    printf '               and ensure TCP %s is allowed by the cloud firewall.\n' "$PORT"
  fi

  if [[ "$ENABLE_E2EE" == 1 ]]; then
    local secret
    secret="$(pairing_secret || true)"
    printf '  Pairing file: %s\n' "$CONFIG_DIR/e2ee.json"
    if [[ -n "$secret" ]]; then
      printf '  Pairing code: %s\n' "$secret"
      printf '  Keep this code private; it is required to unlock the web UI.\n'
    else
      warn "pairing code was not readable; inspect ${CONFIG_DIR}/e2ee.json as root"
    fi
  else
    warn "E2EE is disabled; do not expose this service directly to the public internet"
  fi

  printf '\nMindFS does not install an AI agent or its credentials. Configure an agent CLI\n'
  printf 'for the %s service user, or use the web UI after pairing.\n' "$SERVICE_USER"
}

main() {
  parse_args "$@"
  validate_config
  select_service_mode
  if [[ "$DRY_RUN" == 1 ]]; then
    print_plan
    return 0
  fi

  ensure_root
  bootstrap_tool_path
  ensure_dependencies
  resolve_runtime_tools
  ensure_service_user
  verify_service_user_paths
  install_mindfs
  write_start_script
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    write_systemd_unit
  fi
  write_control_script
  if [[ "$SKIP_START" == 0 ]]; then
    start_service
  else
    log "Service files installed; start skipped"
  fi
  configure_firewall
  if [[ "$SKIP_START" == 0 ]]; then
    wait_for_health
  fi
  print_summary
}

main "$@"
