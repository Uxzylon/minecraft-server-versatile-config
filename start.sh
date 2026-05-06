#!/usr/bin/env bash
# Versatile Minecraft launcher: one main server jar + multiple service jars.
#
# Features:
# - Loads Docker-Compose-style .env files from the current directory
# - Shared stdout for server and services
# - Minecraft stdin forwarding through a FIFO
# - Launcher commands always start with ! in the interactive console
# - External command mode for tools/plugins:
#     ./start.sh start   -> same as typing !start in the live launcher
#     ./start.sh stop    -> same as typing !stop in the live launcher
# - Per-service working directories
# - Single-instance lock
# - Ctrl+C behavior:
#     send SIGINT to Minecraft
#     send SIGINT to all services
#     exit when all tracked processes are closed

set -uo pipefail

########################################
# .env loading
########################################

# Reads .env from the current working directory by default.
# This is intentionally compatible with common Docker Compose .env files:
#   KEY=value
#   KEY="value with spaces"
#   KEY='value with spaces'
#   # comments
#
# Existing environment variables always win over .env values:
#   SERVER_JAR=custom.jar ./start.sh
# will not be overwritten by SERVER_JAR=... inside .env.
DOTENV_FILE="${DOTENV_FILE:-$PWD/.env}"
LOAD_DOTENV="${LOAD_DOTENV:-true}"

trim_string() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_dotenv_file() {
  local env_file="$1"

  case "${LOAD_DOTENV,,}" in
    1|true|yes|y|on) ;;
    *) return 0 ;;
  esac

  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'
'}"
    line="$(trim_string "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # Optional Docker/shell-friendly prefix.
    if [[ "$line" =~ ^export[[:space:]]+(.+)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi

    [[ "$line" == *=* ]] || continue

    key="$(trim_string "${line%%=*}")"
    value="$(trim_string "${line#*=}")"

    # Only valid environment variable names are loaded.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    # Real environment variables, even empty ones, have priority over .env.
    [[ -n "${!key+x}" ]] && continue

    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      # For unquoted values, support inline comments only when preceded by whitespace.
      value="${value%%[[:space:]]#*}"
      value="$(trim_string "$value")"
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$env_file"
}

load_dotenv_file "$DOTENV_FILE"

########################################
# Configuration
########################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR}"

JAVA_BIN="${JAVA_BIN:-java}"

# Main Minecraft server.
# SERVER_JAR is resolved relative to SERVER_WORKING_DIR when not absolute.
SERVER_NAME="${SERVER_NAME:-server}"
SERVER_WORKING_DIR="${SERVER_WORKING_DIR:-$BASE_DIR}"
SERVER_JAR="${SERVER_JAR:-fabric-server-launch.jar}"
SERVER_JAVA_OPTS="${SERVER_JAVA_OPTS:--Xms2G -Xmx4G}"
SERVER_ARGS="${SERVER_ARGS:-nogui}"

# Set to false when Velocity/AutoServer starts the Minecraft server on demand.
START_SERVER_ON_BOOT="${START_SERVER_ON_BOOT:-false}"

# Start all services listed below when this script starts.
START_SERVICES_ON_BOOT="${START_SERVICES_ON_BOOT:-true}"

# Prefix output lines with [server], [velocity], etc. Set false for raw combined stdout.
PREFIX_OUTPUT="${PREFIX_OUTPUT:-true}"

# Grace periods used by explicit launcher commands such as !stop and !exit.
SERVER_STOP_TIMEOUT="${SERVER_STOP_TIMEOUT:-60}"
SERVICE_STOP_TIMEOUT="${SERVICE_STOP_TIMEOUT:-15}"
EXIT_TERM_TIMEOUT="${EXIT_TERM_TIMEOUT:-5}"

# Runtime files.
RUNTIME_DIR="${RUNTIME_DIR:-$BASE_DIR/.runtime}"
SERVER_STDIN_FIFO="$RUNTIME_DIR/${SERVER_NAME}.stdin"
CONTROL_FIFO="$RUNTIME_DIR/launcher.control"
LOCK_FILE="$RUNTIME_DIR/launcher.lock"

# Service configuration can be provided from .env / environment variables.
# Docker-Compose-friendly single-variable format:
#
#   SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|
#
# Multiple services are separated with semicolons:
#
#   SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|;discordbot|discordbot|bot.jar|-Xmx512M|--example value
#
# Service format inside SERVICES_CONFIG:
#   name|working_dir|jar_path|java_opts|jar_args
#
# working_dir:
#   - Absolute path, or relative to BASE_DIR.
# jar_path:
#   - Absolute path, or relative to the service working_dir.
#
# If SERVICES_CONFIG is not set in the environment or .env, this default is used.
DEFAULT_SERVICES_CONFIG="velocity|velocity|velocity.jar|-Xms512M -Xmx1G|"
SERVICES_CONFIG="${SERVICES_CONFIG:-$DEFAULT_SERVICES_CONFIG}"

SERVICES=()

configure_services() {
  SERVICES=()

  local raw_config raw_service service
  raw_config="$SERVICES_CONFIG"

  # Semicolon-separated service declarations.
  IFS=';' read -r -a raw_services <<< "$raw_config"

  for raw_service in "${raw_services[@]}"; do
    service="$(trim_string "$raw_service")"
    [[ -z "$service" ]] && continue
    SERVICES+=("$service")
  done
}

configure_services

########################################
# State
########################################

declare -A SERVICE_PIDS=()
SERVER_PID=""
SERVER_STDIN_FD=""
CONTROL_FD=""
LOCK_FD=""
SHUTTING_DOWN="false"
EXTERNAL_COMMAND_MODE="false"

########################################
# Utility functions
########################################

bool_is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  printf '[launcher] %s
' "$*"
}

err() {
  printf '[launcher:error] %s
' "$*" >&2
}

resolve_from_base() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf '%s
' "$BASE_DIR"
  elif [[ "$path" = /* ]]; then
    printf '%s
' "$path"
  else
    printf '%s/%s
' "$BASE_DIR" "$path"
  fi
}

resolve_from_dir() {
  local dir="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    printf '%s
' "$path"
  else
    printf '%s/%s
' "$dir" "$path"
  fi
}

split_words() {
  # Simple shell-style splitting. Keep configured opts/args simple and space-separated.
  # shellcheck disable=SC2206
  SPLIT_RESULT=( $1 )
}

prefix_output() {
  local name="$1"
  if bool_is_true "$PREFIX_OUTPUT"; then
    while IFS= read -r line; do
      printf '[%s] %s
' "$name" "$line"
    done
  else
    cat
  fi
}

is_pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  # Avoid treating an unreaped zombie as alive on Linux.
  if command -v ps >/dev/null 2>&1; then
    local stat
    stat="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ "$stat" != *Z* ]] || return 1
  fi

  return 0
}

get_pgid() {
  local pid="$1"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true
}

signal_process() {
  local signal="$1"
  local pid="$2"
  [[ -n "$pid" ]] || return 0
  kill -"$signal" "$pid" 2>/dev/null || true
}

signal_process_and_safe_group() {
  local signal="$1"
  local pid="$2"
  [[ -n "$pid" ]] || return 0

  # Always signal the tracked Java PID directly.
  signal_process "$signal" "$pid"

  # If the process is in a different group from the launcher, signal that group too.
  # This is a safe fallback for wrappers/children, but avoids signaling our own shell group.
  local pgid self_pgid
  pgid="$(get_pgid "$pid")"
  self_pgid="$(get_pgid "$$")"

  if [[ -n "$pgid" && -n "$self_pgid" && "$pgid" != "$self_pgid" ]]; then
    kill -"$signal" -- "-$pgid" 2>/dev/null || true
  fi
}

wait_for_pid_to_exit() {
  local pid="$1"
  local timeout_seconds="$2"
  local elapsed=0

  while is_pid_alive "$pid" && (( elapsed < timeout_seconds )); do
    sleep 1
    elapsed=$((elapsed + 1))
  done

  ! is_pid_alive "$pid"
}

tracked_processes_alive_summary() {
  local parts=()
  local name pid

  if is_pid_alive "$SERVER_PID"; then
    parts+=("$SERVER_NAME:$SERVER_PID")
  fi

  for name in "${!SERVICE_PIDS[@]}"; do
    pid="${SERVICE_PIDS[$name]}"
    if is_pid_alive "$pid"; then
      parts+=("$name:$pid")
    fi
  done

  local IFS=', '
  printf '%s
' "${parts[*]}"
}

wait_for_all_tracked_processes_to_exit() {
  local name pid alive elapsed alive_summary
  elapsed=0

  while true; do
    alive=0
    alive_summary=""

    if [[ -n "$SERVER_PID" ]]; then
      if ps -p "$SERVER_PID" >/dev/null 2>&1; then
        alive=1
        alive_summary+="$SERVER_NAME:$SERVER_PID "
      else
        SERVER_PID=""
        log "$SERVER_NAME is closed"
      fi
    fi

    for name in "${!SERVICE_PIDS[@]}"; do
      pid="${SERVICE_PIDS[$name]}"
      if ps -p "$pid" >/dev/null 2>&1; then
        alive=1
        alive_summary+="$name:$pid "
      else
        unset 'SERVICE_PIDS[$name]'
        log "service '$name' is closed"
      fi
    done

    if (( alive == 0 )); then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))

    if (( elapsed % 5 == 0 )); then
      log "still waiting for: ${alive_summary:-none}"
    fi
  done
}

prepare_runtime() {
  mkdir -p "$RUNTIME_DIR"

  local fifo
  for fifo in "$SERVER_STDIN_FIFO" "$CONTROL_FIFO"; do
    if [[ ! -p "$fifo" ]]; then
      rm -f "$fifo"
      mkfifo "$fifo"
    fi
  done

  # Keep the Minecraft stdin FIFO open so Java does not receive EOF simply because
  # nobody is typing at that exact moment.
  if [[ -z "$SERVER_STDIN_FD" ]]; then
    exec {SERVER_STDIN_FD}<>"$SERVER_STDIN_FIFO"
  fi
}

open_control_fifo() {
  if [[ -z "$CONTROL_FD" ]]; then
    exec {CONTROL_FD}<>"$CONTROL_FIFO"
  fi
}

acquire_launcher_lock() {
  mkdir -p "$RUNTIME_DIR"

  if ! command -v flock >/dev/null 2>&1; then
    err "flock is not available; continuing without single-instance lock"
    return 0
  fi

  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    err "another launcher instance already appears to be running"
    err "if this is stale, stop old Java processes and remove: $LOCK_FILE"
    exit 1
  fi
}

send_external_command_to_launcher() {
  EXTERNAL_COMMAND_MODE="true"

  local command="$*"
  command="${command#!}"

  if [[ -z "$command" ]]; then
    err "usage: $0 <launcher-command>"
    err "example: $0 start"
    err "example: $0 stop"
    exit 2
  fi

  mkdir -p "$RUNTIME_DIR"

  if [[ ! -p "$CONTROL_FIFO" ]]; then
    err "no running launcher found at control FIFO: $CONTROL_FIFO"
    err "start the main launcher first with: $0"
    exit 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 5s bash -c 'printf "%s
" "$1" > "$2"' _ "$command" "$CONTROL_FIFO"; then
      err "could not contact running launcher through: $CONTROL_FIFO"
      err "the FIFO may be stale; restart the main launcher if needed"
      exit 1
    fi
  else
    printf '%s
' "$command" > "$CONTROL_FIFO" || {
      err "could not contact running launcher through: $CONTROL_FIFO"
      exit 1
    }
  fi

  # Intentionally quiet on success. AutoServer captures command output and may treat it as suspicious.
}

reap_dead_processes() {
  if [[ -n "$SERVER_PID" ]] && ! is_pid_alive "$SERVER_PID"; then
    wait "$SERVER_PID" 2>/dev/null || true
    log "$SERVER_NAME is no longer running"
    SERVER_PID=""
  fi

  local name pid
  for name in "${!SERVICE_PIDS[@]}"; do
    pid="${SERVICE_PIDS[$name]}"
    if ! is_pid_alive "$pid"; then
      wait "$pid" 2>/dev/null || true
      log "service '$name' is no longer running"
      unset 'SERVICE_PIDS[$name]'
    fi
  done
}

cleanup_runtime_files() {
  if [[ -n "${CONTROL_FD:-}" ]]; then
    exec {CONTROL_FD}>&- || true
    CONTROL_FD=""
  fi

  if [[ -n "${SERVER_STDIN_FD:-}" ]]; then
    exec {SERVER_STDIN_FD}>&- || true
    SERVER_STDIN_FD=""
  fi

  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    exec {LOCK_FD}>&- || true
    LOCK_FD=""
  fi

  rm -f "$SERVER_STDIN_FIFO" "$CONTROL_FIFO" 2>/dev/null || true
}

########################################
# Main server
########################################

start_server() {
  reap_dead_processes
  if is_pid_alive "$SERVER_PID"; then
    log "$SERVER_NAME is already running with PID $SERVER_PID"
    return 0
  fi

  local workdir jar
  workdir="$(resolve_from_base "$SERVER_WORKING_DIR")"
  jar="$(resolve_from_dir "$workdir" "$SERVER_JAR")"

  if [[ ! -d "$workdir" ]]; then
    err "server working directory not found: $workdir"
    return 1
  fi

  if [[ ! -f "$jar" ]]; then
    err "server jar not found: $jar"
    return 1
  fi

  prepare_runtime

  local java_opts app_args
  split_words "$SERVER_JAVA_OPTS"; java_opts=("${SPLIT_RESULT[@]}")
  split_words "$SERVER_ARGS"; app_args=("${SPLIT_RESULT[@]}")

  log "starting $SERVER_NAME"
  log "  working dir: $workdir"
  log "  jar: $jar"

  (
    # Bash may start background commands with SIGINT ignored in scripts.
    # Reset signal handling before exec so SIGINT can actually stop Java.
    trap - INT TERM QUIT HUP
    cd "$workdir" || exit 1
    exec "$JAVA_BIN" "${java_opts[@]}" -jar "$jar" "${app_args[@]}" < "$SERVER_STDIN_FIFO"
  ) > >(prefix_output "$SERVER_NAME") 2>&1 &

  SERVER_PID="$!"
  log "$SERVER_NAME started with PID $SERVER_PID"
}

send_to_server() {
  local line="$1"
  reap_dead_processes

  if ! is_pid_alive "$SERVER_PID"; then
    err "$SERVER_NAME is not running. Type '!start' to start it or '!help' for commands."
    return 1
  fi

  prepare_runtime
  printf '%s
' "$line" >&"$SERVER_STDIN_FD"
}

stop_server() {
  reap_dead_processes
  if ! is_pid_alive "$SERVER_PID"; then
    log "$SERVER_NAME is not running"
    SERVER_PID=""
    return 0
  fi

  local pid="$SERVER_PID"
  log "asking $SERVER_NAME to stop gracefully"
  printf 'stop
' >&"$SERVER_STDIN_FD" 2>/dev/null || true

  if ! wait_for_pid_to_exit "$pid" "$SERVER_STOP_TIMEOUT"; then
    err "$SERVER_NAME did not stop after ${SERVER_STOP_TIMEOUT}s; sending SIGTERM"
    signal_process_and_safe_group TERM "$pid"
    wait_for_pid_to_exit "$pid" "$EXIT_TERM_TIMEOUT" || true
  fi

  if is_pid_alive "$pid"; then
    err "$SERVER_NAME still did not stop; sending SIGKILL"
    signal_process_and_safe_group KILL "$pid"
    wait_for_pid_to_exit "$pid" 2 || true
  fi

  wait "$pid" 2>/dev/null || true
  SERVER_PID=""
  log "$SERVER_NAME stopped"
}

restart_server() {
  stop_server
  start_server
}

########################################
# Services
########################################

find_service_spec() {
  local requested="$1"
  local spec name workdir jar opts args
  for spec in "${SERVICES[@]}"; do
    IFS='|' read -r name workdir jar opts args <<< "$spec"
    if [[ "$name" == "$requested" ]]; then
      printf '%s
' "$spec"
      return 0
    fi
  done
  return 1
}

start_service() {
  local requested_name="$1"
  reap_dead_processes

  if [[ -z "$requested_name" ]]; then
    err "usage: start-service <name>"
    return 1
  fi

  if is_pid_alive "${SERVICE_PIDS[$requested_name]:-}"; then
    log "service '$requested_name' is already running with PID ${SERVICE_PIDS[$requested_name]}"
    return 0
  fi

  local spec name workdir_raw jar_raw opts args workdir jar
  if ! spec="$(find_service_spec "$requested_name")"; then
    err "unknown service: $requested_name"
    list_services
    return 1
  fi

  IFS='|' read -r name workdir_raw jar_raw opts args <<< "$spec"
  workdir="$(resolve_from_base "$workdir_raw")"
  jar="$(resolve_from_dir "$workdir" "$jar_raw")"

  if [[ ! -d "$workdir" ]]; then
    err "working directory not found for service '$name': $workdir"
    return 1
  fi

  if [[ ! -f "$jar" ]]; then
    err "jar not found for service '$name': $jar"
    return 1
  fi

  local java_opts app_args
  split_words "$opts"; java_opts=("${SPLIT_RESULT[@]}")
  split_words "$args"; app_args=("${SPLIT_RESULT[@]}")

  log "starting service '$name'"
  log "  working dir: $workdir"
  log "  jar: $jar"

  (
    # Reset signals so Ctrl+C/SIGINT sent by the launcher can terminate this Java process.
    trap - INT TERM QUIT HUP
    cd "$workdir" || exit 1
    exec "$JAVA_BIN" "${java_opts[@]}" -jar "$jar" "${app_args[@]}" < /dev/null
  ) > >(prefix_output "$name") 2>&1 &

  SERVICE_PIDS[$name]="$!"
  log "service '$name' started with PID ${SERVICE_PIDS[$name]}"
}

start_all_services() {
  local spec name workdir jar opts args
  for spec in "${SERVICES[@]}"; do
    IFS='|' read -r name workdir jar opts args <<< "$spec"
    [[ -n "$name" ]] && start_service "$name"
  done
}

stop_service() {
  local name="$1"
  reap_dead_processes

  if [[ -z "$name" ]]; then
    err "usage: stop-service <name>"
    return 1
  fi

  local pid="${SERVICE_PIDS[$name]:-}"
  if ! is_pid_alive "$pid"; then
    log "service '$name' is not running"
    unset 'SERVICE_PIDS[$name]'
    return 0
  fi

  log "stopping service '$name' with PID $pid using SIGTERM"
  signal_process_and_safe_group TERM "$pid"

  if ! wait_for_pid_to_exit "$pid" "$SERVICE_STOP_TIMEOUT"; then
    err "service '$name' did not stop after ${SERVICE_STOP_TIMEOUT}s; sending SIGKILL"
    signal_process_and_safe_group KILL "$pid"
    wait_for_pid_to_exit "$pid" 2 || true
  fi

  wait "$pid" 2>/dev/null || true
  unset 'SERVICE_PIDS[$name]'
  log "service '$name' stopped"
}

restart_service() {
  local name="$1"
  stop_service "$name"
  start_service "$name"
}

stop_all_services() {
  local name
  for name in "${!SERVICE_PIDS[@]}"; do
    stop_service "$name"
  done
}

########################################
# Command shell
########################################

print_help() {
  cat <<'EOF'
Launcher commands, used interactively with !:
  !help                         Show this help
  !start                        Start the main Minecraft server jar
  !stop                         Stop the main Minecraft server jar gracefully
  !restart                      Restart the main Minecraft server jar
  !status                       Show running PIDs
  !services                     List configured services
  !start-service <name>          Start a configured service
  !stop-service <name>           Stop a running service
  !restart-service <name>        Restart a configured service
  !stop-all-services             Stop every running service
  !send <minecraft command>      Send a command to the Minecraft server
  !quit | !exit                  Stop server/services and exit this launcher

External command mode, used by AutoServer or scripts:
  ./start.sh start               Same as typing !start in the live launcher
  ./start.sh stop                Same as typing !stop in the live launcher
  ./start.sh status              Same as typing !status in the live launcher

Environment loading:
  - By default, ./start.sh reads .env from the current working directory.
  - Existing environment variables override .env values.
  - Use DOTENV_FILE=/path/to/.env ./start.sh to load another file.
  - Use LOAD_DOTENV=false ./start.sh to disable .env loading.

Service env format:
  SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|

  Multiple services are separated with semicolons:
  SERVICES_CONFIG=velocity|velocity|velocity.jar|-Xms512M -Xmx1G|;discordbot|discordbot|bot.jar|-Xmx512M|--example value

  Each service uses:
  name|working_dir|jar_path|java_opts|jar_args

Input behavior:
  - Launcher commands always start with ! in the interactive console.
  - When the server is running, normal input is sent directly to Minecraft.
  - When the server is stopped, normal input is ignored.
  - To send a literal line starting with ! to Minecraft, type !!your command.
EOF
}

list_services() {
  if ((${#SERVICES[@]} == 0)); then
    log "no services configured"
    return 0
  fi

  local spec name workdir_raw jar_raw opts args pid state
  printf '%-20s %-14s %-28s %s
' "SERVICE" "STATE" "WORKDIR" "JAR"
  for spec in "${SERVICES[@]}"; do
    IFS='|' read -r name workdir_raw jar_raw opts args <<< "$spec"
    pid="${SERVICE_PIDS[$name]:-}"
    if is_pid_alive "$pid"; then
      state="running:$pid"
    else
      state="stopped"
    fi
    printf '%-20s %-14s %-28s %s
' "$name" "$state" "$workdir_raw" "$jar_raw"
  done
}

status() {
  reap_dead_processes

  if is_pid_alive "$SERVER_PID"; then
    log "$SERVER_NAME: running with PID $SERVER_PID"
  else
    log "$SERVER_NAME: stopped"
  fi

  list_services
}

handle_local_command() {
  local raw="$1"
  local cmd="${raw%% *}"
  local rest=""
  [[ "$raw" == *" "* ]] && rest="${raw#* }"

  case "$cmd" in
    ""|help) print_help ;;
    start) start_server ;;
    stop) stop_server ;;
    restart) restart_server ;;
    status) status ;;
    services) list_services ;;
    start-service) start_service "$rest" ;;
    stop-service) stop_service "$rest" ;;
    restart-service) restart_service "$rest" ;;
    stop-all-services) stop_all_services ;;
    send) send_to_server "$rest" ;;
    quit|exit)
      cleanup
      exit 0
      ;;
    *)
      err "unknown launcher command: $raw"
      err "type '!help' for launcher commands, or '!start' to start the Minecraft server"
      return 1
      ;;
  esac
}

handle_console_line() {
  local line="$1"

  if [[ "$line" == !!* ]]; then
    send_to_server "${line:1}"
    return 0
  fi

  if [[ "$line" == !* ]]; then
    handle_local_command "${line:1}"
    return 0
  fi

  if is_pid_alive "$SERVER_PID"; then
    send_to_server "$line"
  else
    [[ -n "$line" ]] && err "$SERVER_NAME is not running. Launcher commands must start with !, for example: !start or !help"
  fi
}

poll_external_commands() {
  local line

  # Drain every pending AutoServer/script command before returning to keyboard polling.
  while IFS= read -r -t 0.001 -u "$CONTROL_FD" line; do
    [[ -z "$line" ]] && continue
    line="${line#!}"
    log "received external launcher command: !$line"
    handle_local_command "$line"
  done
}

input_loop() {
  log "launcher ready. Type '!help' for launcher commands."
  open_control_fifo

  local line
  while true; do
    poll_external_commands
    reap_dead_processes

    # Read keyboard input directly from the main process. This is intentionally not
    # done through a background reader, because background stdin readers can get
    # stuck or lose terminal input depending on how the launcher is started.
    if IFS= read -r -t 0.2 line; then
      handle_console_line "$line"
    else
      # Avoid a tight loop if stdin is closed or unavailable.
      sleep 0.05
    fi
  done
}

########################################
# Shutdown
########################################

force_exit_during_shutdown() {
  printf '
' >&2
  err "second interrupt received; force-killing tracked processes and exiting"

  local name pid

  if is_pid_alive "$SERVER_PID"; then
    signal_process_and_safe_group KILL "$SERVER_PID"
  fi

  for name in "${!SERVICE_PIDS[@]}"; do
    pid="${SERVICE_PIDS[$name]}"
    if is_pid_alive "$pid"; then
      signal_process_and_safe_group KILL "$pid"
    fi
  done

  cleanup_runtime_files
  trap - EXIT
  exit 130
}

ctrl_c_shutdown() {
  # External command mode is only a lightweight client. It must never stop processes
  # or remove FIFOs owned by the already-running launcher.
  [[ "$EXTERNAL_COMMAND_MODE" == "true" ]] && exit 130

  [[ "$SHUTTING_DOWN" == "true" ]] && return 0
  SHUTTING_DOWN="true"

  # First Ctrl+C follows the requested behavior: SIGINT all tracked processes and
  # wait for them to close. A second Ctrl+C is an escape hatch in case a process
  # refuses to close or reaping behaves unexpectedly.
  trap force_exit_during_shutdown INT TERM

  printf '
' >&2
  log "Ctrl+C received; sending SIGINT to Minecraft and all services"

  local name pid

  if is_pid_alive "$SERVER_PID"; then
    signal_process INT "$SERVER_PID"
  fi

  for name in "${!SERVICE_PIDS[@]}"; do
    pid="${SERVICE_PIDS[$name]}"
    if is_pid_alive "$pid"; then
      signal_process INT "$pid"
    fi
  done

  log "waiting for Minecraft and all services to close"
  wait_for_all_tracked_processes_to_exit
  log "Minecraft and all services are closed"

  cleanup_runtime_files

  # Disable traps and force the launcher shell itself to terminate. This avoids
  # Bash lingering because of interrupted reads or process-substitution helper jobs.
  trap - INT TERM EXIT
  exit 130
}

cleanup() {
  # External command mode is only a lightweight client. It must never stop processes
  # or remove FIFOs owned by the already-running launcher.
  [[ "$EXTERNAL_COMMAND_MODE" == "true" ]] && return 0

  [[ "$SHUTTING_DOWN" == "true" ]] && return 0
  SHUTTING_DOWN="true"

  trap '' INT TERM

  log "shutting down launcher"

  # !exit / normal cleanup remains stronger than Ctrl+C: it tries graceful Minecraft
  # stop and escalates to TERM/KILL if needed.
  stop_server || true
  stop_all_services || true
  cleanup_runtime_files
}

trap cleanup EXIT
trap ctrl_c_shutdown INT
trap ctrl_c_shutdown TERM

########################################
# Main
########################################

main() {
  if (($# > 0)); then
    send_external_command_to_launcher "$@"
    exit 0
  fi

  acquire_launcher_lock
  prepare_runtime

  if bool_is_true "$START_SERVICES_ON_BOOT"; then
    start_all_services
  fi

  if bool_is_true "$START_SERVER_ON_BOOT"; then
    start_server
  else
    log "START_SERVER_ON_BOOT=false, so $SERVER_NAME was not started"
  fi

  input_loop
}

main "$@"
