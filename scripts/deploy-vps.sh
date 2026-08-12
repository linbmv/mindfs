#!/usr/bin/env bash
# Install MindFS as an independent service on a Debian/Ubuntu VPS.
# The script does not use the current checkout directory. It downloads a
# released binary and keeps the executable, service data, and project root in
# separate configurable absolute paths. systemd is preferred; environments
# without a running systemd (for example containers) use a managed background
# process instead.
#
# Usage:
#   bash deploy-vps.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/a9gent/mindfs/main/scripts/deploy-vps.sh | sudo bash -s --
set -Eeuo pipefail

umask 077

REPO="${MINDFS_REPO:-a9gent/mindfs}"
VERSION="${MINDFS_VERSION:-}"
PREFIX="${MINDFS_PREFIX:-/opt/mindfs}"
DATA_DIR="${MINDFS_DATA_DIR:-/var/lib/mindfs}"
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
DRY_RUN=0
SKIP_START=0

CONFIG_HOME="${DATA_DIR}/config"
STATE_HOME="${DATA_DIR}/.local/share"
START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
PID_FILE="${DATA_DIR}/mindfs.pid"
LOG_FILE="${DATA_DIR}/mindfs.log"
CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"
SERVICE_GROUP=""
SERVICE_MODE=""
LISTEN_ADDR=""
HEALTH_URL=""

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

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

Installs the latest released MindFS binary and creates a service.
The service is independent of the directory from which this script is run.

Options:
  --version VERSION       Install a specific release, for example v0.4.5
  --repo OWNER/REPO       Release repository (default: a9gent/mindfs)
  --prefix PATH           Binary install prefix (default: /opt/mindfs)
  --data-dir PATH         Service home and persistent config (default: /var/lib/mindfs)
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
      --version)
        need_value "$@"
        VERSION="$2"
        shift 2
        ;;
      --repo)
        need_value "$@"
        REPO="$2"
        shift 2
        ;;
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
  CONFIG_HOME="${DATA_DIR}/config"
  STATE_HOME="${DATA_DIR}/.local/share"
  START_SCRIPT="${PREFIX}/bin/mindfs-vps-start"
  UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
  PID_FILE="${DATA_DIR}/mindfs.pid"
  LOG_FILE="${DATA_DIR}/mindfs.log"
  CONTROL_SCRIPT="${PREFIX}/bin/mindfs-service"

  require_absolute_path PREFIX "$PREFIX"
  require_absolute_path DATA_DIR "$DATA_DIR"
  require_absolute_path PROJECT_DIR "$PROJECT_DIR"

  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "invalid repository: $REPO"
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
  repository:    ${REPO}
  version:       ${VERSION:-latest}
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

ensure_dependencies() {
  local missing=()
  local command_name
  for command_name in curl tar install useradd id stat runuser; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if ((${#missing[@]} > 0)); then
    command -v apt-get >/dev/null 2>&1 || die "missing commands (${missing[*]}) and apt-get is unavailable"
    log "Installing required packages: curl ca-certificates tar util-linux"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar util-linux
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
  ensure_owned_dir "$CONFIG_HOME" 0700 "$service_uid" "$service_gid"
  ensure_owned_dir "$STATE_HOME" 0750 "$service_uid" "$service_gid"
  ensure_owned_dir "$PROJECT_DIR" 0750 "$service_uid" "$service_gid"
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

download_installer() {
  local output_path="$1"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/install.sh" ]]; then
    cp "${SCRIPT_DIR}/install.sh" "$output_path"
    chmod 0700 "$output_path"
    return
  fi
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh" -o "$output_path"
  chmod 0700 "$output_path"
}

installer_supports_repo() {
  local installer_path="$1"
  # Older published installers hard-code a9gent/mindfs and reject unknown
  # options. Keep the VPS deploy script usable while those installers are
  # still being served from a release branch or a gist.
  grep -Eq '^[[:space:]]*--repo[[:space:]]*\)' "$installer_path"
}

install_mindfs() {
  local installer_path
  installer_path="$(mktemp)"
  download_installer "$installer_path"

  local installer_args=(--prefix "$PREFIX")
  if installer_supports_repo "$installer_path"; then
    installer_args=(--repo "$REPO" "${installer_args[@]}")
  elif [[ "$REPO" != "a9gent/mindfs" ]]; then
    rm -f "$installer_path"
    die "the downloaded installer does not support --repo; use the current installer from ${REPO} or omit --repo"
  else
    log "Downloaded installer has no --repo option; using its default repository"
  fi
  if [[ -n "$VERSION" ]]; then
    installer_args+=(--version "$VERSION")
  fi
  log "Installing MindFS release ${VERSION:-latest} into ${PREFIX}"
  if ! PATH="${PREFIX}/bin:${PATH}" MINDFS_REPO="$REPO" bash "$installer_path" "${installer_args[@]}"; then
    rm -f "$installer_path"
    return 1
  fi
  rm -f "$installer_path"
  [[ -x "${PREFIX}/bin/mindfs" ]] || die "MindFS binary was not installed at ${PREFIX}/bin/mindfs"
}

write_start_script() {
  mkdir -p "${PREFIX}/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
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

write_background_control_script() {
  mkdir -p "${PREFIX}/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
    printf 'SERVICE_USER=%s\n' "$(shell_quote "$SERVICE_USER")"
    printf 'SERVICE_GROUP=%s\n' "$(shell_quote "$SERVICE_GROUP")"
    printf 'DATA_DIR=%s\n' "$(shell_quote "$DATA_DIR")"
    printf 'CONFIG_HOME=%s\n' "$(shell_quote "$CONFIG_HOME")"
    printf 'START_SCRIPT=%s\n' "$(shell_quote "$START_SCRIPT")"
    printf 'BIN_PATH=%s\n' "$(shell_quote "${PREFIX}/bin/mindfs")"
    printf 'PID_FILE=%s\n' "$(shell_quote "$PID_FILE")"
    printf 'LOG_FILE=%s\n' "$(shell_quote "$LOG_FILE")"
    printf 'PATH_VALUE=%s\n' "$(shell_quote "${PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
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
  local pid
  pid="$(read_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null && process_matches "$pid"
}

start_service() {
  require_root
  if is_running; then
    printf 'mindfs is already running (pid %s)\n' "$(read_pid)"
    return 0
  fi
  rm -f "$PID_FILE"
  touch "$LOG_FILE"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  nohup runuser -u "$SERVICE_USER" -- env \
    HOME="$DATA_DIR" \
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
  if is_running; then
    printf 'mindfs is active (pid %s)\n' "$(read_pid)"
  else
    printf 'mindfs is inactive\n'
  fi
}

logs_service() {
  exec tail -n 100 -f "$LOG_FILE"
}

case "${1:-status}" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  status) status_service ;;
  logs) logs_service ;;
  *)
    printf 'usage: %s {start|stop|restart|status|logs}\n' "$0" >&2
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
    printf 'Environment=HOME=%s\n' "$(systemd_quote "$DATA_DIR")"
    printf 'Environment=XDG_CONFIG_HOME=%s\n' "$(systemd_quote "$CONFIG_HOME")"
    printf 'Environment=PATH=%s\n' "$(systemd_quote "${PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
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
  die "MindFS did not become healthy; inspect: ${CONTROL_SCRIPT} logs"
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
  local config_file="${CONFIG_HOME}/mindfs/e2ee.json"
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
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    printf '  Service:     systemctl status %s\n' "$SERVICE_NAME"
    printf '  Logs:        journalctl -u %s -f\n' "$SERVICE_NAME"
  else
    printf '  Service:     sudo %s status\n' "$CONTROL_SCRIPT"
    printf '  Start/stop:  sudo %s {start|stop|restart}\n' "$CONTROL_SCRIPT"
    printf '  Logs:        sudo %s logs\n' "$CONTROL_SCRIPT"
    printf '  Note:        systemd is unavailable; this process will not auto-start after a host reboot\n'
  fi
  printf '  Data:        %s\n' "$DATA_DIR"
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
    printf '  Pairing file: %s/config/mindfs/e2ee.json\n' "$DATA_DIR"
    if [[ -n "$secret" ]]; then
      printf '  Pairing code: %s\n' "$secret"
      printf '  Keep this code private; it is required to unlock the web UI.\n'
    else
      warn "pairing code was not readable; inspect ${CONFIG_HOME}/mindfs/e2ee.json as root"
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
  ensure_dependencies
  ensure_service_user
  install_mindfs
  write_start_script
  if [[ "$SERVICE_MODE" == "systemd" ]]; then
    write_systemd_unit
  else
    write_background_control_script
  fi
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
