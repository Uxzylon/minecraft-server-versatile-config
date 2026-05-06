#!/usr/bin/env bash
# Minecraft backup helper.
#
# Usage:
#   ./mc-backup.sh full
#   ./mc-backup.sh worlds
#   ./mc-backup.sh restart
#   ./mc-backup.sh restore <archive>
#
# The script loads .env through mc-common.sh.
# Existing environment variables override .env values.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMMON_FILE="${COMMON_FILE:-$SCRIPT_DIR/mc-common.sh}"

if [[ ! -f "$COMMON_FILE" ]]; then
  printf '[backup:error] common file not found: %s\n' "$COMMON_FILE" >&2
  exit 1
fi

# shellcheck source=mc-common.sh
source "$COMMON_FILE"

LOG_PREFIX="backup"
load_dotenv_from_current_directory

########################################
# Configuration
########################################

MC_BACKUP_SERVER_DIR="${MC_BACKUP_SERVER_DIR:-$SCRIPT_DIR}"
MC_BACKUP_DIR="${MC_BACKUP_DIR:-$SCRIPT_DIR/backups}"
MC_BACKUP_NAME="${MC_BACKUP_NAME:-minecraft-server}"
MC_BACKUP_TIMEZONE="${MC_BACKUP_TIMEZONE:-Europe/Paris}"

# Comma-separated world directories, relative to MC_BACKUP_SERVER_DIR unless absolute.
MC_BACKUP_WORLDS="${MC_BACKUP_WORLDS:-world}"

# auto = zip when available, otherwise tar.gz.
MC_BACKUP_FORMAT="${MC_BACKUP_FORMAT:-auto}"

# Comma-separated exclude patterns for full backups.
# Patterns are passed to zip/tar from inside MC_BACKUP_SERVER_DIR.
MC_BACKUP_EXCLUDES="${MC_BACKUP_EXCLUDES:-.runtime,backups}"

MC_BACKUP_GRACE_SECONDS="${MC_BACKUP_GRACE_SECONDS:-10}"
MC_BACKUP_SAVE_WAIT_SECONDS="${MC_BACKUP_SAVE_WAIT_SECONDS:-5}"
MC_BACKUP_STOP_WAIT_SECONDS="${MC_BACKUP_STOP_WAIT_SECONDS:-20}"

# full backups stop the server by default; worlds backups default to hot backup.
MC_BACKUP_FULL_STOP_SERVER="${MC_BACKUP_FULL_STOP_SERVER:-true}"
MC_BACKUP_WORLDS_STOP_SERVER="${MC_BACKUP_WORLDS_STOP_SERVER:-false}"
MC_BACKUP_RESTART_AFTER_STOP="${MC_BACKUP_RESTART_AFTER_STOP:-true}"
MC_BACKUP_RESTART_AFTER_RESTORE="${MC_BACKUP_RESTART_AFTER_RESTORE:-true}"
MC_BACKUP_CONFIRM_RESTORE="${MC_BACKUP_CONFIRM_RESTORE:-true}"

# Notification/control methods:
#   auto         try start-script, then tmux
#   start-script use MC_BACKUP_CONTROL_SCRIPT, expected to support: send/start/stop
#   tmux         send keys directly to MC_BACKUP_TMUX_SESSION
#   none         do nothing
MC_BACKUP_NOTIFY_METHOD="${MC_BACKUP_NOTIFY_METHOD:-auto}"
MC_BACKUP_CONTROL_METHOD="${MC_BACKUP_CONTROL_METHOD:-auto}"
MC_BACKUP_CONTROL_SCRIPT="${MC_BACKUP_CONTROL_SCRIPT:-$SCRIPT_DIR/start.sh}"
MC_BACKUP_TMUX_SESSION="${MC_BACKUP_TMUX_SESSION:-minecraft}"

# Optional custom shell commands. When set, these override control-method start/stop.
MC_BACKUP_START_COMMAND="${MC_BACKUP_START_COMMAND:-}"
MC_BACKUP_STOP_COMMAND="${MC_BACKUP_STOP_COMMAND:-}"

MC_BACKUP_MESSAGE_START="${MC_BACKUP_MESSAGE_START:-Backup in {seconds}s. The server may pause or restart.}"
MC_BACKUP_MESSAGE_RUNNING="${MC_BACKUP_MESSAGE_RUNNING:-Backup in progress. Auto-save is temporarily disabled.}"
MC_BACKUP_MESSAGE_DONE="${MC_BACKUP_MESSAGE_DONE:-Backup finished in {elapsed}s. Auto-save is enabled again.}"
MC_BACKUP_MESSAGE_RESTART="${MC_BACKUP_MESSAGE_RESTART:-Server restarting for backup in {seconds}s.}"

########################################
# Helpers
########################################

usage() {
  cat <<'EOF'
Minecraft backup helper:
  full                         Backup the whole server directory
  worlds                       Backup only MC_BACKUP_WORLDS
  restart                      Warn players, stop the server, then start it again; no backup
  restore <archive>            Restore a zip or tar.gz backup into MC_BACKUP_SERVER_DIR
  help                         Show this help

Options:
  --stop                       Stop the server before the backup
  --no-stop                    Do a hot backup without stopping the server

Environment / .env variables:
  MC_BACKUP_SERVER_DIR=.                         Directory to back up
  MC_BACKUP_DIR=./backups                        Output directory
  MC_BACKUP_NAME=minecraft-server                Archive name prefix
  MC_BACKUP_WORLDS=world,world_nether            Worlds for the worlds command
  MC_BACKUP_FORMAT=auto|zip|tar.gz               Archive format
  MC_BACKUP_EXCLUDES=.runtime,backups            Full-backup exclude patterns

  MC_BACKUP_NOTIFY_METHOD=auto|start-script|tmux|none
  MC_BACKUP_CONTROL_METHOD=auto|start-script|tmux|none
  MC_BACKUP_CONTROL_SCRIPT=./start.sh
  MC_BACKUP_TMUX_SESSION=minecraft

  MC_BACKUP_START_COMMAND="docker compose exec minecraft ./start.sh start"
  MC_BACKUP_STOP_COMMAND="docker compose exec minecraft ./start.sh stop"

Notes:
  - Notifications are best-effort and never fail the backup.
  - start-script mode expects the script to support: send/start/stop.
  - With your current start.sh, this works: ./start.sh send say hello
EOF
}

resolve_from_server_dir() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$MC_BACKUP_SERVER_DIR" "$path"
  fi
}

render_message() {
  local template="$1"
  local elapsed="${2:-}"

  template="${template//\{seconds\}/$MC_BACKUP_GRACE_SECONDS}"
  template="${template//\{elapsed\}/$elapsed}"
  printf '%s\n' "$template"
}

run_best_effort() {
  "$@" >/dev/null 2>&1
}

send_with_start_script() {
  local minecraft_command="$1"
  [[ -x "$MC_BACKUP_CONTROL_SCRIPT" || -f "$MC_BACKUP_CONTROL_SCRIPT" ]] || return 1
  run_best_effort bash "$MC_BACKUP_CONTROL_SCRIPT" send "$minecraft_command"
}

send_with_tmux() {
  local minecraft_command="$1"
  require_command tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$MC_BACKUP_TMUX_SESSION" 2>/dev/null || return 1
  run_best_effort tmux send-keys -t "$MC_BACKUP_TMUX_SESSION" "$minecraft_command" ENTER
}

send_minecraft_command() {
  local minecraft_command="$1"
  local method="$MC_BACKUP_NOTIFY_METHOD"

  case "$method" in
    none) return 0 ;;
    start-script)
      send_with_start_script "$minecraft_command" || log "warning: could not send Minecraft command through start script: $minecraft_command"
      ;;
    tmux)
      send_with_tmux "$minecraft_command" || log "warning: could not send Minecraft command through tmux: $minecraft_command"
      ;;
    auto)
      send_with_start_script "$minecraft_command" || send_with_tmux "$minecraft_command" || log "warning: could not send Minecraft command: $minecraft_command"
      ;;
    *)
      log "warning: unknown MC_BACKUP_NOTIFY_METHOD=$method; skipping notification"
      ;;
  esac
}

say() {
  local message="$1"
  send_minecraft_command "say $message"
}

run_custom_shell_command() {
  local command="$1"
  [[ -n "$command" ]] || return 1
  bash -lc "$command"
}

control_with_start_script() {
  local command="$1"
  [[ -x "$MC_BACKUP_CONTROL_SCRIPT" || -f "$MC_BACKUP_CONTROL_SCRIPT" ]] || return 1
  bash "$MC_BACKUP_CONTROL_SCRIPT" "$command"
}

control_with_tmux() {
  local command="$1"
  require_command tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$MC_BACKUP_TMUX_SESSION" 2>/dev/null || return 1

  case "$command" in
    stop)
      tmux send-keys -t "$MC_BACKUP_TMUX_SESSION" "stop" ENTER
      ;;
    start)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

control_server() {
  local command="$1"
  local method="$MC_BACKUP_CONTROL_METHOD"

  if [[ "$command" == "start" && -n "$MC_BACKUP_START_COMMAND" ]]; then
    run_custom_shell_command "$MC_BACKUP_START_COMMAND"
    return $?
  fi

  if [[ "$command" == "stop" && -n "$MC_BACKUP_STOP_COMMAND" ]]; then
    run_custom_shell_command "$MC_BACKUP_STOP_COMMAND"
    return $?
  fi

  case "$method" in
    none) return 1 ;;
    start-script) control_with_start_script "$command" ;;
    tmux) control_with_tmux "$command" ;;
    auto)
      control_with_start_script "$command" || control_with_tmux "$command"
      ;;
    *)
      err "unknown MC_BACKUP_CONTROL_METHOD=$method"
      return 1
      ;;
  esac
}

warn_and_prepare_hot_backup() {
  local start_message running_message
  start_message="$(render_message "$MC_BACKUP_MESSAGE_START")"
  running_message="$(render_message "$MC_BACKUP_MESSAGE_RUNNING")"

  say "$start_message"
  sleep "$MC_BACKUP_GRACE_SECONDS"
  say "$running_message"
  send_minecraft_command "save-all"
  sleep "$MC_BACKUP_SAVE_WAIT_SECONDS"
  send_minecraft_command "save-off"
  sleep 1
}

finish_hot_backup() {
  local elapsed="$1"
  local done_message
  done_message="$(render_message "$MC_BACKUP_MESSAGE_DONE" "$elapsed")"

  send_minecraft_command "save-on"
  say "$done_message"
}

stop_for_backup() {
  local restart_message
  restart_message="$(render_message "$MC_BACKUP_MESSAGE_RESTART")"

  say "$restart_message"
  sleep "$MC_BACKUP_GRACE_SECONDS"
  send_minecraft_command "save-all"
  sleep "$MC_BACKUP_SAVE_WAIT_SECONDS"

  log "stopping server before backup"
  if ! control_server stop; then
    log "warning: stop command failed or no control method is available; continuing anyway"
  fi

  sleep "$MC_BACKUP_STOP_WAIT_SECONDS"
}

start_after_backup() {
  bool_is_true "$MC_BACKUP_RESTART_AFTER_STOP" || return 0

  log "starting server after backup"
  if ! control_server start; then
    log "warning: start command failed or no control method is available"
  fi
}

choose_format() {
  case "$MC_BACKUP_FORMAT" in
    zip|tar.gz) printf '%s\n' "$MC_BACKUP_FORMAT" ;;
    auto)
      if command -v zip >/dev/null 2>&1; then
        printf 'zip\n'
      else
        printf 'tar.gz\n'
      fi
      ;;
    *)
      err "invalid MC_BACKUP_FORMAT: $MC_BACKUP_FORMAT"
      exit 1
      ;;
  esac
}

split_csv_to_array() {
  local raw="$1"
  local -n out_ref="$2"
  local item

  out_ref=()
  IFS=',' read -r -a raw_items <<< "$raw"
  for item in "${raw_items[@]}"; do
    item="$(trim_string "$item")"
    [[ -n "$item" ]] && out_ref+=("$item")
  done
}

make_timestamp() {
  TZ=":$MC_BACKUP_TIMEZONE" date +"%Y-%m-%d_%H-%M-%S"
}

build_archive_path() {
  local scope="$1"
  local format="$2"
  local timestamp="$3"
  local suffix extension

  case "$scope" in
    full) suffix="ALL" ;;
    worlds) suffix="WORLDS" ;;
    *) suffix="$scope" ;;
  esac

  case "$format" in
    zip) extension="zip" ;;
    tar.gz) extension="tar.gz" ;;
  esac

  printf '%s/%s_%s[%s].%s\n' "$MC_BACKUP_DIR" "$timestamp" "$MC_BACKUP_NAME" "$suffix" "$extension"
}

build_exclude_args() {
  local format="$1"
  local -n out_ref="$2"
  local excludes exclude

  out_ref=()
  split_csv_to_array "$MC_BACKUP_EXCLUDES" excludes

  for exclude in "${excludes[@]}"; do
    case "$format" in
      zip)
        out_ref+=("-x" "$exclude" "$exclude/*")
        ;;
      tar.gz)
        out_ref+=("--exclude=$exclude")
        ;;
    esac
  done
}

create_archive() {
  local scope="$1"
  local format timestamp archive
  local items=()
  local excludes=()

  mkdir -p "$MC_BACKUP_DIR"

  format="$(choose_format)"
  timestamp="$(make_timestamp)"
  archive="$(build_archive_path "$scope" "$format" "$timestamp")"

  case "$scope" in
    full)
      items=(.)
      build_exclude_args "$format" excludes
      ;;
    worlds)
      split_csv_to_array "$MC_BACKUP_WORLDS" items
      if ((${#items[@]} == 0)); then
        err "MC_BACKUP_WORLDS is empty"
        exit 1
      fi

      local item full_path
      for item in "${items[@]}"; do
        full_path="$(resolve_from_server_dir "$item")"
        if [[ ! -d "$full_path" ]]; then
          err "world directory not found: $full_path"
          exit 1
        fi
      done
      ;;
    *)
      err "unknown archive scope: $scope"
      exit 1
      ;;
  esac

  log "creating $format backup"
  log "  server dir: $MC_BACKUP_SERVER_DIR"
  log "  archive: $archive"

  (
    cd "$MC_BACKUP_SERVER_DIR" || exit 1

    case "$format" in
      zip)
        require_command zip || exit 1
        zip -r "$archive" "${items[@]}" "${excludes[@]}"
        ;;
      tar.gz)
        require_command tar || exit 1
        tar "${excludes[@]}" -czf "$archive" "${items[@]}"
        ;;
    esac
  )

  log "backup created: $archive"
}

run_backup() {
  local scope="$1"
  local stop_server="$2"
  local started_at ended_at elapsed

  started_at="$(date -u +%s)"

  if bool_is_true "$stop_server"; then
    stop_for_backup
  else
    warn_and_prepare_hot_backup
  fi

  create_archive "$scope"

  ended_at="$(date -u +%s)"
  elapsed=$((ended_at - started_at))

  if bool_is_true "$stop_server"; then
    start_after_backup
  else
    finish_hot_backup "$elapsed"
  fi

  log "backup completed in ${elapsed}s"
}

restart_only() {
  local started_at ended_at elapsed
  started_at="$(date -u +%s)"

  stop_for_backup
  start_after_backup

  ended_at="$(date -u +%s)"
  elapsed=$((ended_at - started_at))
  log "restart completed in ${elapsed}s"
}

extract_archive() {
  local archive="$1"
  local target_dir="$2"

  case "$archive" in
    *.zip)
      require_command unzip || exit 1
      unzip -q "$archive" -d "$target_dir"
      ;;
    *.tar.gz|*.tgz)
      require_command tar || exit 1
      tar -xzf "$archive" -C "$target_dir"
      ;;
    *)
      err "unsupported restore archive format: $archive"
      exit 1
      ;;
  esac
}

restore_backup() {
  local archive="${1:-}"
  if [[ -z "$archive" ]]; then
    err "missing archive path for restore"
    exit 2
  fi

  if [[ ! -f "$archive" ]]; then
    err "backup archive not found: $archive"
    exit 1
  fi

  if bool_is_true "$MC_BACKUP_CONFIRM_RESTORE"; then
    confirm_or_exit "Restore '$archive' into '$MC_BACKUP_SERVER_DIR'? This will replace matching files/directories."
  fi

  stop_for_backup

  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mc-backup-restore.XXXXXX")"

  log "extracting backup into temporary directory: $temp_dir"
  extract_archive "$archive" "$temp_dir"

  log "restoring files into: $MC_BACKUP_SERVER_DIR"
  local item base
  shopt -s dotglob nullglob
  for item in "$temp_dir"/*; do
    base="$(basename "$item")"
    rm -rf "$MC_BACKUP_SERVER_DIR/$base"
    mv "$item" "$MC_BACKUP_SERVER_DIR/"
  done
  shopt -u dotglob nullglob

  rm -rf "$temp_dir"

  log "restore completed"

  if bool_is_true "$MC_BACKUP_RESTART_AFTER_RESTORE"; then
    start_after_backup
  fi
}

main() {
  local command="${1:-full}"
  local stop_override=""

  shift || true

  while (($# > 0)); do
    case "$1" in
      --stop) stop_override="true" ;;
      --no-stop) stop_override="false" ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        # Let restore consume its archive path.
        if [[ "$command" == "restore" && -z "${restore_archive:-}" ]]; then
          restore_archive="$1"
        else
          err "unknown option: $1"
          usage
          exit 2
        fi
        ;;
    esac
    shift
  done

  case "$command" in
    full)
      run_backup full "${stop_override:-$MC_BACKUP_FULL_STOP_SERVER}"
      ;;
    worlds)
      run_backup worlds "${stop_override:-$MC_BACKUP_WORLDS_STOP_SERVER}"
      ;;
    restart)
      restart_only
      ;;
    restore)
      restore_backup "${restore_archive:-}"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      err "unknown command: $command"
      usage
      exit 2
      ;;
  esac
}

main "$@"
