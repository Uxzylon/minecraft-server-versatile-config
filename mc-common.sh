#!/usr/bin/env bash
# Shared helpers for Minecraft management scripts.
# Source this file; do not execute it directly.

if [[ -n "${MC_COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
MC_COMMON_SH_LOADED=1

trim_string() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

bool_is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  local prefix="${LOG_PREFIX:-launcher}"
  printf '[%s] %s\n' "$prefix" "$*"
}

err() {
  local prefix="${LOG_PREFIX:-launcher}"
  printf '[%s:error] %s\n' "$prefix" "$*" >&2
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    err "required command not found: $command_name"
    return 1
  fi
}

confirm_or_exit() {
  local prompt="$1"
  local confirmation

  printf '%s [y/N] ' "$prompt"
  read -r confirmation

  case "$confirmation" in
    y|Y|yes|YES) return 0 ;;
    *)
      log "operation cancelled"
      exit 1
      ;;
  esac
}

load_dotenv_file() {
  local env_file="$1"

  case "${LOAD_DOTENV:-true}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) ;;
    *) return 0 ;;
  esac

  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
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

load_dotenv_from_current_directory() {
  DOTENV_FILE="${DOTENV_FILE:-$PWD/.env}"
  LOAD_DOTENV="${LOAD_DOTENV:-true}"
  load_dotenv_file "$DOTENV_FILE"
}
