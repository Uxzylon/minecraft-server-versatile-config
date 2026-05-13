#!/usr/bin/env bash
# Dynmap helper commands.
#
# Usage:
#   ./mc-dynmap.sh upload-web
#   ./mc-dynmap.sh reset-sql
#
# Environment / .env variables:
#   DYNMAP_WEB_SOURCE=dynmap/web
#   DYNMAP_REMOTE_HOST=user@example.com
#   DYNMAP_REMOTE_WEB_LOCATION=/home/user/.nginx/html/dynmap
#
#   DYNMAP_DB_HOST=example.com
#   DYNMAP_DB_PORT=3306
#   DYNMAP_DB_USER=dynmap
#   DYNMAP_DB_NAME=dynmap
#   DYNMAP_DB_PASSWORD=secret     # optional; omit to be prompted by mysql
#
#   DYNMAP_RESET_TABLES=Faces,Maps,MarkerFiles,MarkerIcons,SchemaVersion,StandaloneFiles,Tiles
#   DYNMAP_CONFIRM_RESET=true     # optional; bypass interactive confirmation

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMMON_FILE="${COMMON_FILE:-$SCRIPT_DIR/mc-common.sh}"

if [[ ! -f "$COMMON_FILE" ]]; then
	printf '[dynmap:error] common file not found: %s\n' "$COMMON_FILE" >&2
	exit 1
fi

# shellcheck source=mc-common.sh
source "$COMMON_FILE"

LOG_PREFIX="dynmap"
load_dotenv_from_current_directory

DYNMAP_WEB_SOURCE="${DYNMAP_WEB_SOURCE:-dynmap/web}"
DYNMAP_REMOTE_HOST="${DYNMAP_REMOTE_HOST:-}"
DYNMAP_REMOTE_WEB_LOCATION="${DYNMAP_REMOTE_WEB_LOCATION:-}"

DYNMAP_DB_HOST="${DYNMAP_DB_HOST:-}"
DYNMAP_DB_PORT="${DYNMAP_DB_PORT:-3306}"
DYNMAP_DB_USER="${DYNMAP_DB_USER:-dynmap}"
DYNMAP_DB_NAME="${DYNMAP_DB_NAME:-dynmap}"
DYNMAP_DB_PASSWORD="${DYNMAP_DB_PASSWORD:-}"
DYNMAP_RESET_TABLES="${DYNMAP_RESET_TABLES:-Faces,Maps,MarkerFiles,MarkerIcons,SchemaVersion,StandaloneFiles,Tiles}"
DYNMAP_CONFIRM_RESET="${DYNMAP_CONFIRM_RESET:-false}"

usage() {
	cat <<'EOF'
Dynmap helper commands:
  upload-web                  Upload dynmap web files to the configured remote web directory
  reset-sql                   Drop dynmap SQL tables from the configured database
  help                        Show this help

Environment loading:
  - Reads .env from the current working directory by default.
  - Existing environment variables override .env values.
  - Use DOTENV_FILE=/path/to/.env ./mc-dynmap.sh <command> to load another file.
  - Use LOAD_DOTENV=false ./mc-dynmap.sh <command> to disable .env loading.

Required for upload-web:
  DYNMAP_REMOTE_HOST=user@example.com
  DYNMAP_REMOTE_WEB_LOCATION=/home/user/.nginx/html/dynmap

Optional for upload-web:
  DYNMAP_WEB_SOURCE=dynmap/web

Required for reset-sql:
  DYNMAP_DB_HOST=example.com

Optional for reset-sql:
  DYNMAP_DB_PORT=3306
  DYNMAP_DB_USER=dynmap
  DYNMAP_DB_NAME=dynmap
  DYNMAP_DB_PASSWORD=secret
  DYNMAP_RESET_TABLES=Faces,Maps,MarkerFiles,MarkerIcons,SchemaVersion,StandaloneFiles,Tiles
  DYNMAP_CONFIRM_RESET=true
EOF
}

require_var() {
	local name="$1"
	local value="${!name:-}"

	if [[ -z "$value" ]]; then
		err "missing required environment variable: $name"
		return 1
	fi
}

resolve_path_from_script_dir() {
	local path="$1"
	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$SCRIPT_DIR" "$path"
	fi
}

upload_web() {
	require_command scp || exit 1
	require_var DYNMAP_REMOTE_HOST || exit 1
	require_var DYNMAP_REMOTE_WEB_LOCATION || exit 1

	local source_dir
	source_dir="$(resolve_path_from_script_dir "$DYNMAP_WEB_SOURCE")"

	if [[ ! -d "$source_dir" ]]; then
		err "dynmap web source directory not found: $source_dir"
		exit 1
	fi

	log "uploading dynmap web files"
	log "  source: $source_dir/"
	log "  target: $DYNMAP_REMOTE_HOST:$DYNMAP_REMOTE_WEB_LOCATION/"

	scp -r "$source_dir"/. "$DYNMAP_REMOTE_HOST:$DYNMAP_REMOTE_WEB_LOCATION"/

	log "dynmap web files uploaded successfully"
}

mysql_password_args() {
	if [[ -n "$DYNMAP_DB_PASSWORD" ]]; then
		MYSQL_ARGS+=("--password=$DYNMAP_DB_PASSWORD")
	else
		MYSQL_ARGS+=("-p")
	fi
}

build_drop_sql() {
	local raw_tables="$1"
	local table table_list=""

	IFS=',' read -r -a tables <<<"$raw_tables"

	for table in "${tables[@]}"; do
		table="$(trim_string "$table")"
		[[ -z "$table" ]] && continue

		if [[ ! "$table" =~ ^[A-Za-z0-9_]+$ ]]; then
			err "invalid table name in DYNMAP_RESET_TABLES: $table"
			exit 1
		fi

		if [[ -n "$table_list" ]]; then
			table_list+=", "
		fi
		table_list+="\`$table\`"
	done

	if [[ -z "$table_list" ]]; then
		err "DYNMAP_RESET_TABLES did not contain any valid table names"
		exit 1
	fi

	printf 'DROP TABLE IF EXISTS %s;\n' "$table_list"
}

reset_sql() {
	require_command mysql || exit 1
	require_var DYNMAP_DB_HOST || exit 1

	if ! bool_is_true "$DYNMAP_CONFIRM_RESET"; then
		echo "This will remove these tables from database '$DYNMAP_DB_NAME' on '$DYNMAP_DB_HOST':"
		echo "  $DYNMAP_RESET_TABLES"
		confirm_or_exit "Proceed?"
	fi

	local sql
	sql="$(build_drop_sql "$DYNMAP_RESET_TABLES")"

	MYSQL_ARGS=(
		--host="$DYNMAP_DB_HOST"
		--port="$DYNMAP_DB_PORT"
		--user="$DYNMAP_DB_USER"
		"$DYNMAP_DB_NAME"
	)
	mysql_password_args

	log "resetting dynmap SQL tables"
	mysql "${MYSQL_ARGS[@]}" <<<"$sql"

	log "dynmap SQL tables dropped successfully"
}

main() {
	local command="${1:-help}"

	case "$command" in
	upload-web) upload_web ;;
	reset-sql) reset_sql ;;
	help | -h | --help) usage ;;
	*)
		err "unknown command: $command"
		usage
		exit 2
		;;
	esac
}

main "$@"
