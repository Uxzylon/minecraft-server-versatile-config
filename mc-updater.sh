#!/usr/bin/env bash
# Unified updater for Minecraft server components.
# Supports Fabric server jars, PaperMC/Velocity jars, Modrinth, CurseForge, and direct URLs.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMMON_FILE="${COMMON_FILE:-$SCRIPT_DIR/mc-common.sh}"

if [[ ! -f "$COMMON_FILE" ]]; then
	printf '[updater:error] common file not found: %s\n' "$COMMON_FILE" >&2
	exit 1
fi

# shellcheck source=mc-common.sh
source "$COMMON_FILE"

LOG_PREFIX="updater"
load_dotenv_from_current_directory

########################################
# Configuration
########################################

MC_UPDATER_TRACKING_FILE="${MC_UPDATER_TRACKING_FILE:-mc-updater.json}"
MC_GAME_VERSION="${MC_GAME_VERSION:-1.21.6}"
MC_SERVER_LOADER="${MC_SERVER_LOADER:-fabric}"
MC_UPDATER_PLATFORMS="${MC_UPDATER_PLATFORMS:-$MC_SERVER_LOADER}"
MC_UPDATER_DEST_DIR="${MC_UPDATER_DEST_DIR:-mods}"
MC_UPDATER_DEFAULT_VERSION="${MC_UPDATER_DEFAULT_VERSION:-latest_any}"
MC_UPDATER_DRY_RUN="${MC_UPDATER_DRY_RUN:-false}"
MC_UPDATER_DISABLE_SUFFIX="${MC_UPDATER_DISABLE_SUFFIX:-.disabled}"
MC_UPDATER_REMOVE_OLD="${MC_UPDATER_REMOVE_OLD:-true}"
MC_UPDATER_ENV_FILE="${MC_UPDATER_ENV_FILE:-${DOTENV_FILE:-$PWD/.env}}"
MC_UPDATER_UPDATE_ENV="${MC_UPDATER_UPDATE_ENV:-true}"
MC_UPDATER_UPDATE_ENV_REFERENCES="${MC_UPDATER_UPDATE_ENV_REFERENCES:-true}"
MC_UPDATER_UPDATE_SERVICES_CONFIG="${MC_UPDATER_UPDATE_SERVICES_CONFIG:-true}"

FABRIC_META_BASE="${FABRIC_META_BASE:-https://meta.fabricmc.net/v2/versions}"
MODRINTH_API_BASE="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
MODRINTH_USER_AGENT="${MODRINTH_USER_AGENT:-mc-updater/1.0}"
CURSEFORGE_API_BASE="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
CURSEFORGE_API_KEY="${CURSEFORGE_API_KEY:-}"
CURSEFORGE_MODLOADER_TYPE="${CURSEFORGE_MODLOADER_TYPE:-auto}"
PAPERMC_API_BASE="${PAPERMC_API_BASE:-https://fill.papermc.io/v3}"
PAPERMC_USER_AGENT="${PAPERMC_USER_AGENT:-mc-updater/1.0}"

########################################
# Help / basics
########################################

usage() {
	cat <<'HELP'
Unified Minecraft updater:
  update [selector]                         Update all tracked entries, or one entry
  list                                      List tracked entries

Add tracked entries:
  add fabric-server [dest] [--mc version] [--env-key SERVER_JAR]
  add papermc <project> [dest] [--version latest_any|latest_stable|latest_snapshot|selector] [--filename name]
  add modrinth <project> [dest] [--version latest_any|latest_stable|latest_beta|selector] [--filename name]
  add curseforge <project-id> [dest] [--version latest_any|latest_stable|latest_beta|selector] [--filename name]
  add url <id> <url> [dest] [--filename name] [--env-key ENV_NAME]

Manage entries:
  remove <selector>
  disable <selector>
  enable <selector>
  edit <selector> [options]
  help

Examples:
  ./mc-updater.sh add fabric-server . --mc 1.21.6 --env-key SERVER_JAR
  ./mc-updater.sh add papermc velocity velocity
  ./mc-updater.sh add modrinth fabric-api mods --version latest_stable
  ./mc-updater.sh add modrinth autoserver velocity/plugins --loader velocity --ignore-game-version
  ./mc-updater.sh update

Version selectors:
  latest_any, latest_stable, latest_beta, latest_alpha, latest_snapshot
  1.2.3, 1.2.x, 1.2.*, ^1.2, ~1.2
HELP
}

require_tracking_tools() {
	require_command jq || exit 1
}

require_network_tools() {
	require_tracking_tools
	require_command curl || exit 1
}

init_tracking() {
	if [[ ! -s "$MC_UPDATER_TRACKING_FILE" ]]; then
		printf '[]\n' >"$MC_UPDATER_TRACKING_FILE"
		log "created tracking file: $MC_UPDATER_TRACKING_FILE"
	fi

	local tmp
	tmp="$(mktemp)"
	jq '
    map(
      if (.requested_version // "") == "" or .requested_version == "latest" or .requested_version == "any" then
        .requested_version = "latest_any"
      elif .requested_version == "stable" then
        .requested_version = "latest_stable"
      elif .requested_version == "beta" then
        .requested_version = "latest_beta"
      elif .requested_version == "alpha" then
        .requested_version = "latest_alpha"
      elif .requested_version == "snapshot" then
        .requested_version = "latest_snapshot"
      else
        .
      end
    )
  ' "$MC_UPDATER_TRACKING_FILE" >"$tmp" && mv "$tmp" "$MC_UPDATER_TRACKING_FILE"
}

normalize_selector() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_requested_version() {
	local requested="${1:-latest_any}"
	case "$requested" in
	"" | latest | any) printf '%s\n' 'latest_any' ;;
	stable) printf '%s\n' 'latest_stable' ;;
	beta) printf '%s\n' 'latest_beta' ;;
	alpha) printf '%s\n' 'latest_alpha' ;;
	snapshot) printf '%s\n' 'latest_snapshot' ;;
	*) printf '%s\n' "$requested" ;;
	esac
}

is_latest_selector() {
	local requested
	requested="$(normalize_requested_version "${1:-latest_any}")"
	case "$requested" in
	latest_any | latest_stable | latest_beta | latest_alpha | latest_snapshot) return 0 ;;
	*) return 1 ;;
	esac
}

version_selector_matches() {
	local version="$1"
	local selector="$2"

	case "$selector" in
	^*)
		local base="${selector#^}"
		local major="${base%%.*}"
		[[ "$version" == "$major" || "$version" == "$major".* ]]
		;;
	~*)
		local base="${selector#~}"
		local major minor
		IFS='.' read -r major minor _ <<<"$base"
		if [[ -n "$minor" ]]; then
			[[ "$version" == "$major.$minor" || "$version" == "$major.$minor".* ]]
		else
			[[ "$version" == "$major" || "$version" == "$major".* ]]
		fi
		;;
	*.x | *.*)
		local prefix="${selector%.*}"
		[[ "$version" == "$prefix" || "$version" == "$prefix".* ]]
		;;
	*)
		[[ "$version" == "$selector" || "$version" == "$selector"-* || "$version" == "$selector"+* ]]
		;;
	esac
}

modrinth_release_types_for_version() {
	local requested
	requested="$(normalize_requested_version "${1:-latest_any}")"
	case "$requested" in
	latest_stable) printf '%s\n' 'release' ;;
	latest_beta) printf '%s\n' 'release,beta' ;;
	*) printf '%s\n' 'release,beta,alpha' ;;
	esac
}

curseforge_release_types_jq() {
	local requested
	requested="$(normalize_requested_version "${1:-latest_any}")"
	case "$requested" in
	latest_stable) printf '%s\n' '[1]' ;;
	latest_beta) printf '%s\n' '[1,2]' ;;
	*) printf '%s\n' '[1,2,3]' ;;
	esac
}

papermc_requested_channel() {
	local requested
	requested="$(normalize_requested_version "${1:-latest_any}")"
	case "$requested" in
	latest_stable) printf '%s\n' 'STABLE' ;;
	*) printf '%s\n' 'ANY' ;;
	esac
}

papermc_version_allowed() {
	local version_id="$1"
	local requested
	requested="$(normalize_requested_version "${2:-latest_any}")"

	case "$requested" in
	latest_snapshot) [[ "$version_id" == *SNAPSHOT* ]] ;;
	latest_stable) [[ "$version_id" != *SNAPSHOT* ]] ;;
	latest_any | latest_beta | latest_alpha) return 0 ;;
	*) version_selector_matches "$version_id" "$requested" ;;
	esac
}

csv_to_json_array() {
	local raw="$1"
	local item json="[]"
	IFS=',' read -r -a values <<<"$raw"

	for item in "${values[@]}"; do
		item="$(trim_string "$item")"
		[[ -n "$item" ]] || continue
		json="$(jq -cn --argjson arr "$json" --arg item "$item" '$arr + [$item]')"
	done

	printf '%s\n' "$json"
}

resolve_dest() {
	local dest="$1"
	if [[ "$dest" = /* ]]; then
		printf '%s\n' "$dest"
	else
		printf '%s/%s\n' "$SCRIPT_DIR" "$dest"
	fi
}

infer_loader_for_dest() {
	local dest="${1:-}"

	if [[ "${LOADER_EXPLICIT:-false}" == "true" ]]; then
		printf '%s\n' "$LOADER"
		return 0
	fi

	local dest_lower platform raw
	dest_lower="$(normalize_selector "$dest")"

	IFS=',' read -r -a platforms <<<"$MC_UPDATER_PLATFORMS"
	for raw in "${platforms[@]}"; do
		platform="$(normalize_selector "$(trim_string "$raw")")"
		[[ -n "$platform" ]] || continue

		case "$dest_lower" in
		"$platform" | "$platform"/* | */"$platform" | */"$platform"/* | "$platform"-* | */"$platform"-*)
			printf '%s\n' "$platform"
			return 0
			;;
		esac
	done

	printf '%s\n' "$MC_SERVER_LOADER"
}

entry_key() {
	printf '%s:%s:%s\n' "$1" "$2" "$3"
}

find_entry_json() {
	local selector="$1"
	local normalized
	normalized="$(normalize_selector "$selector")"

	jq -c --arg selector "$selector" --arg normalized "$normalized" '
    map(select(
      .key == $selector or
      .id == $selector or
      .project_id == $selector or
      .slug == $selector or
      (.name | ascii_downcase) == $normalized
    )) | .[0] // empty
  ' "$MC_UPDATER_TRACKING_FILE"
}

entry_exists() {
	jq -e --arg key "$1" 'any(.[]; .key == $key)' "$MC_UPDATER_TRACKING_FILE" >/dev/null
}

upsert_entry() {
	local entry_json="$1"
	local key tmp
	key="$(jq -r '.key' <<<"$entry_json")"
	tmp="$(mktemp)"

	if entry_exists "$key"; then
		jq --arg key "$key" --argjson entry "$entry_json" 'map(if .key == $key then $entry else . end)' "$MC_UPDATER_TRACKING_FILE" >"$tmp"
	else
		jq --argjson entry "$entry_json" '. + [$entry]' "$MC_UPDATER_TRACKING_FILE" >"$tmp"
	fi

	mv "$tmp" "$MC_UPDATER_TRACKING_FILE"
}

replace_entry_by_key() {
	local key="$1"
	local entry_json="$2"
	local tmp
	tmp="$(mktemp)"
	jq --arg key "$key" --argjson entry "$entry_json" 'map(if .key == $key then $entry else . end)' "$MC_UPDATER_TRACKING_FILE" >"$tmp"
	mv "$tmp" "$MC_UPDATER_TRACKING_FILE"
}

remove_entry_from_tracking() {
	local key="$1"
	local tmp
	tmp="$(mktemp)"
	jq --arg key "$key" 'del(.[] | select(.key == $key))' "$MC_UPDATER_TRACKING_FILE" >"$tmp"
	mv "$tmp" "$MC_UPDATER_TRACKING_FILE"
}

update_env_var_file() {
	local key="$1"
	local value="$2"
	local file="$MC_UPDATER_ENV_FILE"

	[[ -n "$key" && "$key" != "null" ]] || return 0
	bool_is_true "$MC_UPDATER_UPDATE_ENV" || return 0

	if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		err "invalid env key: $key"
		return 1
	fi

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		log "would update $file: $key=$value"
		return 0
	fi

	touch "$file"

	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
		local tmp
		tmp="$(mktemp)"
		awk -v key="$key" -v replacement="$key=$value" '
			!updated && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" {
				print replacement
				updated = 1
				next
			}
			{ print }
		' "$file" >"$tmp"
		mv "$tmp" "$file"
	else
		printf '\n%s=%s\n' "$key" "$value" >>"$file"
	fi

	log "updated $file: $key=$value"
}

update_env_filename_references() {
	local old="$1"
	local new="$2"
	local file="$MC_UPDATER_ENV_FILE"

	bool_is_true "$MC_UPDATER_UPDATE_ENV" || return 0
	bool_is_true "$MC_UPDATER_UPDATE_ENV_REFERENCES" || return 0
	[[ -n "$old" && -n "$new" && "$old" != "$new" ]] || return 0
	[[ -f "$file" ]] || return 0
	grep -Fq "$old" "$file" || return 0

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		log "would replace in $file: $old -> $new"
		return 0
	fi

	local content
	content="$(cat "$file")"
	content="${content//$old/$new}"
	printf '%s\n' "$content" >"$file"
	log "updated $file references: $old -> $new"
}

read_env_var_file_value() {
	local key="$1"
	local file="$MC_UPDATER_ENV_FILE"

	[[ -f "$file" ]] || return 1

	awk -v key="$key" '
		$0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" {
			line = $0
			sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
			sub("^[^=]*=", "", line)
			print line
			exit
		}
	' "$file"
}

join_by_semicolon() {
	local IFS=';'
	printf '%s\n' "$*"
}

update_services_config_entry() {
	local service_name="$1"
	local workdir="$2"
	local jar_filename="$3"
	local java_opts="$4"
	local jar_args="$5"

	bool_is_true "$MC_UPDATER_UPDATE_ENV" || return 0
	bool_is_true "$MC_UPDATER_UPDATE_SERVICES_CONFIG" || return 0

	local service_spec current_config raw_service service name updated found
	local services=()

	service_spec="$service_name|$workdir|$jar_filename|$java_opts|$jar_args"
	current_config="$(read_env_var_file_value SERVICES_CONFIG || true)"
	found=false

	IFS=';' read -r -a raw_services <<<"$current_config"
	for raw_service in "${raw_services[@]}"; do
		service="$(trim_string "$raw_service")"
		[[ -z "$service" ]] && continue

		IFS='|' read -r name _ <<<"$service"
		if [[ "$name" == "$service_name" ]]; then
			services+=("$service_spec")
			found=true
		else
			services+=("$service")
		fi
	done

	if ! bool_is_true "$found"; then
		services+=("$service_spec")
	fi

	updated="$(join_by_semicolon "${services[@]}")"
	update_env_var_file SERVICES_CONFIG "$updated"
}

maybe_update_velocity_service_config() {
	local source="$1"
	local id="$2"
	local dest_raw="$3"
	local filename="$4"
	local service_name java_opts jar_args

	[[ "$source" == "papermc" ]] || return 0
	[[ "$(normalize_selector "$id")" == "velocity" ]] || return 0

	service_name="velocity"
	java_opts="-Xms512M -Xmx1G"
	jar_args=""

	update_services_config_entry \
		"$service_name" \
		"$dest_raw" \
		"$filename" \
		"$java_opts" \
		"$jar_args"
}

remove_old_file() {
	local dest="$1"
	local filename="$2"
	bool_is_true "$MC_UPDATER_REMOVE_OLD" || return 0
	[[ -n "$filename" && "$filename" != "null" ]] || return 0

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		[[ -f "$dest/$filename" ]] && log "would remove old file: $dest/$filename"
		[[ -f "$dest/$filename$MC_UPDATER_DISABLE_SUFFIX" ]] && log "would remove old disabled file: $dest/$filename$MC_UPDATER_DISABLE_SUFFIX"
		return 0
	fi

	rm -f "$dest/$filename" "$dest/$filename$MC_UPDATER_DISABLE_SUFFIX"
}

download_file() {
	local url="$1"
	local dest="$2"
	local filename="$3"
	local disabled="${4:-false}"
	local target="$dest/$filename"

	mkdir -p "$dest"

	if bool_is_true "$disabled"; then
		target+="$MC_UPDATER_DISABLE_SUFFIX"
	fi

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		log "would download: $url"
		log "would save as: $target"
		return 0
	fi

	log "downloading $filename"
	curl -fL --retry 3 --retry-delay 2 -o "$target" "$url"

	if [[ ! -s "$target" ]]; then
		rm -f "$target"
		err "download failed or produced an empty file: $filename"
		return 1
	fi
}

install_resolved_entry() {
	local resolved="$1"
	local dest_raw="$2"
	local disabled="${3:-false}"
	local loader="${4:-${LOADER:-}}"
	local game_version="${5:-${GAME_VERSION:-}}"
	local env_key="${6:-${ENV_KEY:-}}"
	local requested_version filename_override
	local ignore_game_version="${8:-${IGNORE_GAME_VERSION:-false}}"
	local ignore_loader="${9:-${IGNORE_LOADER:-false}}"

	requested_version="$(normalize_requested_version "${7:-${VERSION:-$MC_UPDATER_DEFAULT_VERSION}}")"
	filename_override="${10:-${FILENAME:-}}"

	if ! jq -e . >/dev/null 2>&1 <<<"$resolved"; then
		err "internal error: resolver returned invalid JSON"
		printf '%s\n' "$resolved" >&2
		return 1
	fi

	local source id key dest filename url existing old_filename entry
	source="$(jq -r '.source' <<<"$resolved")"
	id="$(jq -r '.id' <<<"$resolved")"
	filename="$(jq -r '.filename' <<<"$resolved")"
	url="$(jq -r '.url' <<<"$resolved")"
	key="$(entry_key "$source" "$id" "$dest_raw")"
	dest="$(resolve_dest "$dest_raw")"

	if [[ -n "$filename_override" ]]; then
		filename="$filename_override"
		resolved="$(jq -c --arg filename "$filename" '.filename = $filename' <<<"$resolved")"
	fi

	existing="$(jq -c --arg key "$key" '.[] | select(.key == $key) // empty' "$MC_UPDATER_TRACKING_FILE")"
	old_filename="$(jq -r '.filename // empty' <<<"${existing:-{}}" 2>/dev/null || true)"

	if [[ -n "$old_filename" && "$old_filename" != "$filename" ]]; then
		remove_old_file "$dest" "$old_filename"
	fi

	download_file "$url" "$dest" "$filename" "$disabled" || return 1

	entry="$(
		jq -cn \
			--arg key "$key" \
			--arg dest "$dest_raw" \
			--arg loader "$loader" \
			--arg game_version "$game_version" \
			--arg env_key "$env_key" \
			--arg filename_override "$filename_override" \
			--arg requested_version "$requested_version" \
			--argjson ignore_game_version "$ignore_game_version" \
			--argjson ignore_loader "$ignore_loader" \
			--argjson disabled "$disabled" \
			--argjson resolved "$resolved" \
			'$resolved + {
      key:$key,
      dest:$dest,
      loader:$loader,
      game_version:$game_version,
      env_key:$env_key,
      filename_override:$filename_override,
      requested_version:$requested_version,
      ignore_game_version:$ignore_game_version,
      ignore_loader:$ignore_loader,
      disabled:$disabled,
      updated_at:(now|todate)
    }'
	)" || {
		err "internal error: failed to build tracking entry"
		return 1
	}

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		log "would update tracking entry: $key"
	else
		upsert_entry "$entry"
	fi

	update_env_var_file "$env_key" "$filename" || return 1
	update_env_filename_references "$old_filename" "$filename" || return 1
	maybe_update_velocity_service_config "$source" "$id" "$dest_raw" "$filename" || return 1
	log "installed $(jq -r '.name' <<<"$resolved") -> $dest_raw/$filename"
}

########################################
# Resolvers
########################################

fabric_latest_stable() {
	curl -fsSL "$1" | jq -r '.[] | select(.stable == true) | .version' | head -n 1
}

fabric_header_filename() {
	curl -fsSI "$1" |
		awk 'BEGIN{IGNORECASE=1} /^content-disposition:/ {print}' |
		sed -n 's/.*filename=\([^;]*\).*/\1/p' |
		tr -d '"' |
		tr -d "'" |
		tr -d '\r' |
		head -n 1
}

resolve_fabric_server() {
	local game_version="$1"
	local installer loader url filename

	installer="$(fabric_latest_stable "$FABRIC_META_BASE/installer")"
	loader="$(fabric_latest_stable "$FABRIC_META_BASE/loader")"

	[[ -n "$installer" && "$installer" != "null" ]] || {
		err "could not resolve Fabric installer"
		return 1
	}
	[[ -n "$loader" && "$loader" != "null" ]] || {
		err "could not resolve Fabric loader"
		return 1
	}

	url="$FABRIC_META_BASE/loader/$game_version/$loader/$installer/server/jar"
	filename="$(fabric_header_filename "$url")"
	[[ -n "$filename" ]] || filename="fabric-server-mc.${game_version}-loader.${loader}-launcher.${installer}.jar"

	jq -cn \
		--arg source "fabric-server" \
		--arg id "fabric-server" \
		--arg name "Fabric Server" \
		--arg version_id "$game_version-loader.$loader-launcher.$installer" \
		--arg version_name "Minecraft $game_version / loader $loader / launcher $installer" \
		--arg filename "$filename" \
		--arg url "$url" \
		'{source:$source,id:$id,project_id:$id,slug:$id,name:$name,version_id:$version_id,version_name:$version_name,filename:$filename,url:$url}'
}

papermc_get() {
	curl -fsSL -H "User-Agent: $PAPERMC_USER_AGENT" "$PAPERMC_API_BASE$1"
}

resolve_papermc() {
	local project="$1"
	local requested_version
	requested_version="$(normalize_requested_version "${2:-$MC_UPDATER_DEFAULT_VERSION}")"

	local channel versions_json version_ids version_id build_ids build_id build_json actual_channel filename url version_name
	channel="$(papermc_requested_channel "$requested_version")"
	versions_json="$(papermc_get "/projects/$project/versions")" || return 1

	if is_latest_selector "$requested_version"; then
		mapfile -t version_ids < <(jq -r '.versions[] | select(.version.support.status == "SUPPORTED") | .version.id' <<<"$versions_json")
	else
		mapfile -t version_ids < <(jq -r --arg v "$requested_version" '.versions[] | select(.version.id == $v or (.version.id | startswith($v))) | .version.id' <<<"$versions_json")
	fi

	for version_id in "${version_ids[@]}"; do
		papermc_version_allowed "$version_id" "$requested_version" || continue
		mapfile -t build_ids < <(jq -r --arg v "$version_id" '.versions[] | select(.version.id == $v) | .builds | reverse | .[]' <<<"$versions_json")

		for build_id in "${build_ids[@]}"; do
			build_json="$(papermc_get "/projects/$project/versions/$version_id/builds/$build_id")" || continue
			actual_channel="$(jq -r '.channel // empty' <<<"$build_json")"

			case "${channel^^}" in
			ANY | LATEST | "") ;;
			*) [[ "${actual_channel^^}" == "${channel^^}" ]] || continue ;;
			esac

			filename="$(jq -r '.downloads."server:default".name // empty' <<<"$build_json")"
			url="$(jq -r '.downloads."server:default".url // empty' <<<"$build_json")"
			[[ -n "$filename" && -n "$url" ]] || continue

			version_name="$version_id build $build_id [$actual_channel]"
			jq -cn \
				--arg source "papermc" \
				--arg id "$project" \
				--arg name "$project" \
				--arg version_id "$version_id-build.$build_id-$actual_channel" \
				--arg version_name "$version_name" \
				--arg filename "$filename" \
				--arg url "$url" \
				'{source:$source,id:$id,project_id:$id,slug:$id,name:$name,version_id:$version_id,version_name:$version_name,filename:$filename,url:$url}'
			return 0
		done
	done

	err "no PaperMC build found for project=$project requested_version=$requested_version"
	return 1
}

modrinth_get() {
	local path="$1"
	shift || true
	curl -fsSL -H "User-Agent: $MODRINTH_USER_AGENT" "$@" "$MODRINTH_API_BASE$path"
}

resolve_modrinth() {
	local project_ref="$1"
	local loader="$2"
	local game_version="$3"
	local ignore_game_version="${4:-false}"
	local ignore_loader="${5:-false}"
	local requested_version
	requested_version="$(normalize_requested_version "${6:-$MC_UPDATER_DEFAULT_VERSION}")"

	local project versions version file release_types
	local args=(--get --data-urlencode "include_changelog=false")

	project="$(modrinth_get "/project/$project_ref")" || return 1

	if ! bool_is_true "$ignore_loader"; then
		args+=(--data-urlencode "loaders=[\"$loader\"]")
	fi

	if ! bool_is_true "$ignore_game_version"; then
		args+=(--data-urlencode "game_versions=[\"$game_version\"]")
	fi

	versions="$(modrinth_get "/project/$project_ref/version" "${args[@]}")" || return 1

	if is_latest_selector "$requested_version"; then
		release_types="$(csv_to_json_array "$(modrinth_release_types_for_version "$requested_version")")"
		version="$(jq -c --argjson allowed "$release_types" '
      map(select(.version_type as $t | $allowed | index($t)))
      | sort_by(.date_published)
      | reverse
      | .[0] // empty
    ' <<<"$versions")"
	else
		version="$(jq -c --arg requested "$requested_version" '
      def selector_matches($version; $selector):
        if ($selector | startswith("^")) then
          ($selector[1:] | split(".")[0]) as $major
          | ($version == $major or ($version | startswith($major + ".")))
        elif ($selector | startswith("~")) then
          ($selector[1:] | split(".")) as $parts
          | if ($parts|length) >= 2 then
              (($parts[0] + "." + $parts[1]) as $prefix | ($version == $prefix or ($version | startswith($prefix + "."))))
            else
              ($parts[0] as $prefix | ($version == $prefix or ($version | startswith($prefix + "."))))
            end
        elif ($selector | test("\\.(x|\\*)$")) then
          ($selector | sub("\\.(x|\\*)$"; "")) as $prefix
          | ($version == $prefix or ($version | startswith($prefix + ".")))
        else
          ($version == $selector or ($version | startswith($selector + "-")) or ($version | startswith($selector + "+")))
        end;
      map(select(
        .id == $requested or
        .version_number == $requested or
        .name == $requested or
        selector_matches(.version_number; $requested)
      ))
      | sort_by(.date_published)
      | reverse
      | .[0] // empty
    ' <<<"$versions")"
	fi

	[[ -n "$version" && "$version" != "null" ]] || {
		err "no matching Modrinth version found for $project_ref requested_version=$requested_version"
		err "try: --version latest_any, --version latest_beta, --ignore-game-version, or --ignore-compatibility"
		return 1
	}

	file="$(jq -c '(.files | map(select(.primary == true)) | .[0]) // .files[0] // empty' <<<"$version")"
	[[ -n "$file" && "$file" != "null" ]] || {
		err "no Modrinth download file found for $project_ref"
		return 1
	}

	jq -cn \
		--arg source "modrinth" \
		--arg id "$(jq -r '.id' <<<"$project")" \
		--arg slug "$(jq -r '.slug' <<<"$project")" \
		--arg name "$(jq -r '.title' <<<"$project")" \
		--arg version_id "$(jq -r '.id' <<<"$version")" \
		--arg version_name "$(jq -r '.name' <<<"$version")" \
		--arg filename "$(jq -r '.filename' <<<"$file")" \
		--arg url "$(jq -r '.url' <<<"$file")" \
		'{source:$source,id:$id,project_id:$id,slug:$slug,name:$name,version_id:$version_id,version_name:$version_name,filename:$filename,url:$url}'
}

curseforge_loader_type() {
	local loader="$1"
	local configured="$CURSEFORGE_MODLOADER_TYPE"

	[[ "$configured" == "none" || -z "$configured" ]] && return 0
	[[ "$configured" != "auto" ]] && {
		printf '%s\n' "$configured"
		return 0
	}

	case "${loader,,}" in
	forge) printf '%s\n' '1' ;;
	fabric) printf '%s\n' '4' ;;
	quilt) printf '%s\n' '5' ;;
	neoforge | neo-forge) printf '%s\n' '6' ;;
	*) return 0 ;;
	esac
}

curseforge_get() {
	local path="$1"
	shift || true

	[[ -n "$CURSEFORGE_API_KEY" ]] || {
		err "CURSEFORGE_API_KEY is required"
		return 1
	}
	curl -fsSL -H "Accept: application/json" -H "x-api-key: $CURSEFORGE_API_KEY" "$@" "$CURSEFORGE_API_BASE$path"
}

resolve_curseforge() {
	local project_id="$1"
	local loader="$2"
	local game_version="$3"
	local ignore_game_version="${4:-false}"
	local ignore_loader="${5:-false}"
	local requested_version
	requested_version="$(normalize_requested_version "${6:-$MC_UPDATER_DEFAULT_VERSION}")"

	local project files file loader_type file_id filename direct_url url allowed_release_types
	local args=(--get --data-urlencode "pageSize=50")

	[[ "$project_id" =~ ^[0-9]+$ ]] || {
		err "CurseForge expects a numeric project id"
		return 1
	}
	project="$(curseforge_get "/mods/$project_id")" || return 1

	if ! bool_is_true "$ignore_game_version"; then
		args+=(--data-urlencode "gameVersion=$game_version")
	fi

	if ! bool_is_true "$ignore_loader"; then
		loader_type="$(curseforge_loader_type "$loader" || true)"
		[[ -n "$loader_type" ]] && args+=(--data-urlencode "modLoaderType=$loader_type")
	fi

	files="$(curseforge_get "/mods/$project_id/files" "${args[@]}")" || return 1

	if is_latest_selector "$requested_version"; then
		allowed_release_types="$(curseforge_release_types_jq "$requested_version")"
		file="$(jq -c --argjson allowed "$allowed_release_types" '
      .data
      | map(select(.releaseType as $t | $allowed | index($t)))
      | sort_by(.fileDate)
      | reverse
      | .[0] // empty
    ' <<<"$files")"
	else
		file="$(jq -c --arg requested "$requested_version" '
      .data
      | map(select((.id|tostring) == $requested or .displayName == $requested or .fileName == $requested or (.displayName // "" | contains($requested)) or (.fileName // "" | contains($requested))))
      | sort_by(.fileDate)
      | reverse
      | .[0] // empty
    ' <<<"$files")"
	fi

	[[ -n "$file" && "$file" != "null" ]] || {
		err "no matching CurseForge file found for $project_id requested_version=$requested_version"
		err "try: --version latest_any, --version latest_beta, --ignore-game-version, or --ignore-compatibility"
		return 1
	}

	file_id="$(jq -r '.id' <<<"$file")"
	filename="$(jq -r '.fileName' <<<"$file")"
	direct_url="$(jq -r '.downloadUrl // empty' <<<"$file")"

	if [[ -n "$direct_url" && "$direct_url" != "null" ]]; then
		url="$direct_url"
	else
		url="$(curseforge_get "/mods/$project_id/files/$file_id/download-url" | jq -r '.data // empty')" || return 1
	fi

	[[ -n "$url" && "$url" != "null" ]] || {
		err "CurseForge returned no download URL for $project_id/$file_id"
		return 1
	}

	jq -cn \
		--arg source "curseforge" \
		--arg id "$project_id" \
		--arg slug "$(jq -r '.data.slug // empty' <<<"$project")" \
		--arg name "$(jq -r '.data.name' <<<"$project")" \
		--arg version_id "$file_id" \
		--arg version_name "$(jq -r '.displayName // .fileName' <<<"$file")" \
		--arg filename "$filename" \
		--arg url "$url" \
		'{source:$source,id:$id,project_id:$id,slug:$slug,name:$name,version_id:$version_id,version_name:$version_name,filename:$filename,url:$url}'
}

resolve_url() {
	local id="$1"
	local url="$2"
	local filename="$3"
	local version_id

	if [[ -z "$filename" ]]; then
		filename="${url%%\?*}"
		filename="${filename##*/}"
	fi

	[[ -n "$filename" ]] || {
		err "could not infer filename for URL entry $id; pass --filename"
		return 1
	}
	version_id="$(curl -fsSI "$url" | awk 'BEGIN{IGNORECASE=1} /^etag:|^last-modified:/ {gsub(/\r/, ""); print $0}' | sha256sum | awk '{print $1}')"
	[[ -n "$version_id" ]] || version_id="manual"

	jq -cn \
		--arg source "url" \
		--arg id "$id" \
		--arg name "$id" \
		--arg version_id "$version_id" \
		--arg version_name "$version_id" \
		--arg filename "$filename" \
		--arg url "$url" \
		'{source:$source,id:$id,project_id:$id,slug:$id,name:$name,version_id:$version_id,version_name:$version_name,filename:$filename,url:$url}'
}

########################################
# Commands
########################################

parse_flags() {
	DEST="$MC_UPDATER_DEST_DIR"
	LOADER="$MC_SERVER_LOADER"
	LOADER_EXPLICIT="false"
	GAME_VERSION="$MC_GAME_VERSION"
	IGNORE_GAME_VERSION="false"
	IGNORE_LOADER="false"
	ENV_KEY=""
	VERSION="$(normalize_requested_version "$MC_UPDATER_DEFAULT_VERSION")"
	FILENAME=""
	POSITIONALS=()

	while (($# > 0)); do
		case "$1" in
		--dest)
			shift
			DEST="${1:-}"
			;;
		--loader)
			shift
			LOADER="${1:-}"
			LOADER_EXPLICIT="true"
			;;
		--mc | --game-version)
			shift
			GAME_VERSION="${1:-}"
			;;
		--force | --ignore-game-version) IGNORE_GAME_VERSION="true" ;;
		--ignore-loader) IGNORE_LOADER="true" ;;
		--ignore-compatibility)
			IGNORE_GAME_VERSION="true"
			IGNORE_LOADER="true"
			;;
		--env-key)
			shift
			ENV_KEY="${1:-}"
			;;
		--version)
			shift
			VERSION="$(normalize_requested_version "${1:-$MC_UPDATER_DEFAULT_VERSION}")"
			;;
		--filename)
			shift
			FILENAME="${1:-}"
			;;
		*) POSITIONALS+=("$1") ;;
		esac
		shift || true
	done
}

add_entry() {
	local type="${1:-}"
	local resolved dest id url project
	shift || true

	[[ -n "$type" ]] || {
		err "usage: ./mc-updater.sh add <type> ..."
		exit 2
	}
	parse_flags "$@"

	case "$type" in
	fabric-server | fabric)
		dest="${POSITIONALS[0]:-.}"
		[[ -z "$ENV_KEY" ]] && ENV_KEY="SERVER_JAR"
		resolved="$(resolve_fabric_server "$GAME_VERSION")" || exit 1
		install_resolved_entry "$resolved" "$dest" false "$LOADER" "$GAME_VERSION" "$ENV_KEY" "$VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$FILENAME"
		;;
	papermc | paper | velocity)
		project="${POSITIONALS[0]:-}"
		[[ "$type" == "velocity" && -z "$project" ]] && project="velocity"
		dest="${POSITIONALS[1]:-.}"
		[[ -n "$project" ]] || {
			err "usage: ./mc-updater.sh add papermc <project> [dest]"
			exit 2
		}
		resolved="$(resolve_papermc "$project" "$VERSION")" || exit 1
		install_resolved_entry "$resolved" "$dest" false "$LOADER" "$GAME_VERSION" "$ENV_KEY" "$VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$FILENAME"
		;;
	modrinth | mr)
		project="${POSITIONALS[0]:-}"
		dest="${POSITIONALS[1]:-$DEST}"
		[[ -n "$project" ]] || {
			err "usage: ./mc-updater.sh add modrinth <project> [dest]"
			exit 2
		}
		LOADER="$(infer_loader_for_dest "$dest")"
		resolved="$(resolve_modrinth "$project" "$LOADER" "$GAME_VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$VERSION")" || exit 1
		install_resolved_entry "$resolved" "$dest" false "$LOADER" "$GAME_VERSION" "$ENV_KEY" "$VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$FILENAME"
		;;
	curseforge | cf)
		project="${POSITIONALS[0]:-}"
		dest="${POSITIONALS[1]:-$DEST}"
		[[ -n "$project" ]] || {
			err "usage: ./mc-updater.sh add curseforge <project-id> [dest]"
			exit 2
		}
		LOADER="$(infer_loader_for_dest "$dest")"
		resolved="$(resolve_curseforge "$project" "$LOADER" "$GAME_VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$VERSION")" || exit 1
		install_resolved_entry "$resolved" "$dest" false "$LOADER" "$GAME_VERSION" "$ENV_KEY" "$VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$FILENAME"
		;;
	url)
		id="${POSITIONALS[0]:-}"
		url="${POSITIONALS[1]:-}"
		dest="${POSITIONALS[2]:-$DEST}"
		[[ -n "$id" && -n "$url" ]] || {
			err "usage: ./mc-updater.sh add url <id> <url> [dest]"
			exit 2
		}
		resolved="$(resolve_url "$id" "$url" "$FILENAME")" || exit 1
		install_resolved_entry "$resolved" "$dest" false "$LOADER" "$GAME_VERSION" "$ENV_KEY" "$VERSION" "$IGNORE_GAME_VERSION" "$IGNORE_LOADER" "$FILENAME"
		;;
	*)
		err "unknown add type: $type"
		exit 2
		;;
	esac
}

resolve_for_existing_entry() {
	local entry="$1"
	local source id slug loader game_version requested_version url filename ignore_game_version ignore_loader

	source="$(jq -r '.source' <<<"$entry")"
	id="$(jq -r '.project_id // .id' <<<"$entry")"
	slug="$(jq -r '.slug // empty' <<<"$entry")"
	loader="$(jq -r '.loader // empty' <<<"$entry")"
	game_version="$(jq -r '.game_version // empty' <<<"$entry")"
	requested_version="$(normalize_requested_version "$(jq -r --arg default "$MC_UPDATER_DEFAULT_VERSION" '.requested_version // $default' <<<"$entry")")"
	url="$(jq -r '.url // empty' <<<"$entry")"
	filename="$(jq -r '.filename // empty' <<<"$entry")"
	ignore_game_version="$(jq -r '.ignore_game_version // false' <<<"$entry")"
	ignore_loader="$(jq -r '.ignore_loader // false' <<<"$entry")"

	[[ -n "$loader" && "$loader" != "null" ]] || loader="$MC_SERVER_LOADER"
	[[ -n "$game_version" && "$game_version" != "null" ]] || game_version="$MC_GAME_VERSION"

	case "$source" in
	fabric-server) resolve_fabric_server "$game_version" ;;
	papermc) resolve_papermc "$id" "$requested_version" ;;
	modrinth) resolve_modrinth "${slug:-$id}" "$loader" "$game_version" "$ignore_game_version" "$ignore_loader" "$requested_version" ;;
	curseforge) resolve_curseforge "$id" "$loader" "$game_version" "$ignore_game_version" "$ignore_loader" "$requested_version" ;;
	url) resolve_url "$id" "$url" "$filename" ;;
	*)
		err "unknown tracked source: $source"
		return 1
		;;
	esac
}

update_one_entry() {
	local entry="$1"
	local resolved old_version new_version old_filename new_filename name dest disabled env_key loader game_version requested_version ignore_game_version ignore_loader filename_override

	resolved="$(resolve_for_existing_entry "$entry")" || return 1

	old_version="$(jq -r '.version_id' <<<"$entry")"
	new_version="$(jq -r '.version_id' <<<"$resolved")"
	old_filename="$(jq -r '.filename // empty' <<<"$entry")"
	new_filename="$(jq -r '.filename // empty' <<<"$resolved")"
	name="$(jq -r '.name' <<<"$resolved")"
	dest="$(jq -r '.dest' <<<"$entry")"
	disabled="$(jq -r '.disabled // false' <<<"$entry")"
	env_key="$(jq -r '.env_key // empty' <<<"$entry")"
	loader="$(jq -r '.loader // empty' <<<"$entry")"
	game_version="$(jq -r '.game_version // empty' <<<"$entry")"
	requested_version="$(normalize_requested_version "$(jq -r --arg default "$MC_UPDATER_DEFAULT_VERSION" '.requested_version // $default' <<<"$entry")")"
	ignore_game_version="$(jq -r '.ignore_game_version // false' <<<"$entry")"
	ignore_loader="$(jq -r '.ignore_loader // false' <<<"$entry")"
	filename_override="$(jq -r '.filename_override // empty' <<<"$entry")"
	[[ -n "$filename_override" ]] && new_filename="$filename_override"

	[[ -n "$loader" && "$loader" != "null" ]] || loader="$MC_SERVER_LOADER"
	[[ -n "$game_version" && "$game_version" != "null" ]] || game_version="$MC_GAME_VERSION"

	if [[ "$old_version" == "$new_version" && "$old_filename" == "$new_filename" ]]; then
		maybe_update_velocity_service_config "$(jq -r '.source' <<<"$resolved")" "$(jq -r '.id' <<<"$resolved")" "$dest" "$new_filename" || return 1
		log "$name is up to date"
		return 0
	fi

	log "updating $name: $old_version/$old_filename -> $new_version/$new_filename"
	install_resolved_entry "$resolved" "$dest" "$disabled" "$loader" "$game_version" "$env_key" "$requested_version" "$ignore_game_version" "$ignore_loader" "$filename_override"
}

update_entries() {
	local selector="${1:-}"

	if [[ -n "$selector" ]]; then
		local entry
		entry="$(find_entry_json "$selector")"
		[[ -n "$entry" ]] || {
			err "no tracked entry matched: $selector"
			exit 1
		}
		update_one_entry "$entry"
		return $?
	fi

	local count i entry
	count="$(jq 'length' "$MC_UPDATER_TRACKING_FILE")"

	if [[ "$count" == "0" ]]; then
		log "no tracked entries yet"
		return 0
	fi

	for ((i = 0; i < count; i++)); do
		entry="$(jq -c ".[$i]" "$MC_UPDATER_TRACKING_FILE")"
		update_one_entry "$entry" || log "warning: failed to update $(jq -r '.name' <<<"$entry")"
	done
}

list_entries() {
	if [[ "$(jq 'length' "$MC_UPDATER_TRACKING_FILE")" == "0" ]]; then
		log "no tracked entries yet"
		return 0
	fi

	printf '%-14s %-24s %-32s %-22s %-9s %s\n' "SOURCE" "ID" "NAME" "DEST" "STATE" "FILE"

	jq -r '
    .[]
    | [
        .source,
        (.slug // .id),
        .name,
        .dest,
        (if .disabled then "disabled" else "enabled" end),
        .filename
      ]
    | @tsv
  ' "$MC_UPDATER_TRACKING_FILE" |
		while IFS=$'\t' read -r source id name dest state file; do
			printf '%-14s %-24s %-32s %-22s %-9s %s\n' "$source" "$id" "$name" "$dest" "$state" "$file"
		done
}

remove_entry() {
	local selector="${1:-}"
	local entry key dest filename name

	[[ -n "$selector" ]] || {
		err "usage: ./mc-updater.sh remove <selector>"
		exit 2
	}
	entry="$(find_entry_json "$selector")"
	[[ -n "$entry" ]] || {
		err "no tracked entry matched: $selector"
		exit 1
	}

	key="$(jq -r '.key' <<<"$entry")"
	dest="$(resolve_dest "$(jq -r '.dest' <<<"$entry")")"
	filename="$(jq -r '.filename' <<<"$entry")"
	name="$(jq -r '.name' <<<"$entry")"

	if bool_is_true "$MC_UPDATER_DRY_RUN"; then
		log "would remove $name"
	else
		rm -f "$dest/$filename" "$dest/$filename$MC_UPDATER_DISABLE_SUFFIX"
		remove_entry_from_tracking "$key"
	fi

	log "removed $name"
}

set_enabled_state() {
	local selector="${1:-}"
	local enabled="$2"
	local entry key dest filename name from to tmp disabled

	[[ -n "$selector" ]] || {
		err "usage: ./mc-updater.sh enable|disable <selector>"
		exit 2
	}
	entry="$(find_entry_json "$selector")"
	[[ -n "$entry" ]] || {
		err "no tracked entry matched: $selector"
		exit 1
	}

	key="$(jq -r '.key' <<<"$entry")"
	dest="$(resolve_dest "$(jq -r '.dest' <<<"$entry")")"
	filename="$(jq -r '.filename' <<<"$entry")"
	name="$(jq -r '.name' <<<"$entry")"

	if bool_is_true "$enabled"; then
		from="$dest/$filename$MC_UPDATER_DISABLE_SUFFIX"
		to="$dest/$filename"
		disabled=false
	else
		from="$dest/$filename"
		to="$dest/$filename$MC_UPDATER_DISABLE_SUFFIX"
		disabled=true
	fi

	if [[ -f "$from" ]]; then
		if bool_is_true "$MC_UPDATER_DRY_RUN"; then
			log "would rename: $from -> $to"
		else
			mv "$from" "$to"
		fi
	elif [[ -f "$to" ]]; then
		:
	else
		err "file not found for $name: $from"
		exit 1
	fi

	if ! bool_is_true "$MC_UPDATER_DRY_RUN"; then
		tmp="$(mktemp)"
		jq --arg key "$key" --argjson disabled "$disabled" 'map(if .key == $key then .disabled = $disabled else . end)' "$MC_UPDATER_TRACKING_FILE" >"$tmp"
		mv "$tmp" "$MC_UPDATER_TRACKING_FILE"
	fi

	if bool_is_true "$enabled"; then
		log "enabled $name"
	else
		log "disabled $name"
	fi
}

edit_entry() {
	local selector="${1:-}"

	if [[ -z "$selector" ]]; then
		err "usage: ./mc-updater.sh edit <selector> [options]"
		err "example: ./mc-updater.sh edit velocity --version latest_snapshot"
		err "example: ./mc-updater.sh edit limboapi --ignore-game-version true"
		return 2
	fi

	shift || true

	local entry key tmp value
	entry="$(find_entry_json "$selector")"
	[[ -n "$entry" ]] || {
		err "no tracked entry matched: $selector"
		return 1
	}

	key="$(jq -r '.key' <<<"$entry")"

	if (($# == 0)); then
		tmp="$(mktemp)"
		jq . <<<"$entry" >"$tmp"
		"${EDITOR:-nano}" "$tmp"

		if ! jq -e 'type == "object" and has("key")' "$tmp" >/dev/null; then
			rm -f "$tmp"
			err "edited entry is not valid JSON or is missing key"
			return 1
		fi

		if [[ "$(jq -r '.key' "$tmp")" != "$key" ]]; then
			rm -f "$tmp"
			err "editing the key field is not supported"
			return 1
		fi

		entry="$(jq -c . "$tmp")"
		rm -f "$tmp"
		replace_entry_by_key "$key" "$entry"
		log "edited $selector"
		return 0
	fi

	while (($# > 0)); do
		case "$1" in
		--version)
			shift
			value="${1:-}"
			value="$(normalize_requested_version "$value")"
			entry="$(jq -c --arg value "$value" '.requested_version = $value' <<<"$entry")"
			;;
		--loader)
			shift
			value="${1:-}"
			entry="$(jq -c --arg value "$value" '.loader = $value' <<<"$entry")"
			;;
		--mc | --game-version)
			shift
			value="${1:-}"
			entry="$(jq -c --arg value "$value" '.game_version = $value' <<<"$entry")"
			;;
		--dest)
			shift
			value="${1:-}"
			entry="$(jq -c --arg value "$value" '.dest = $value' <<<"$entry")"
			;;
		--env-key)
			shift
			value="${1:-}"
			entry="$(jq -c --arg value "$value" '.env_key = $value' <<<"$entry")"
			;;
		--filename)
			shift
			value="${1:-}"
			entry="$(jq -c --arg value "$value" '.filename_override = $value' <<<"$entry")"
			;;
		--ignore-game-version)
			shift
			value="${1:-true}"
			entry="$(jq -c --argjson value "$value" '.ignore_game_version = $value' <<<"$entry")"
			;;
		--ignore-loader)
			shift
			value="${1:-true}"
			entry="$(jq -c --argjson value "$value" '.ignore_loader = $value' <<<"$entry")"
			;;
		--disable)
			entry="$(jq -c '.disabled = true' <<<"$entry")"
			;;
		--enable)
			entry="$(jq -c '.disabled = false' <<<"$entry")"
			;;
		*)
			err "unknown edit option: $1"
			return 2
			;;
		esac
		shift || true
	done

	replace_entry_by_key "$key" "$entry"
	log "edited $selector"
}

main() {
	local command="${1:-update}"
	shift || true

	case "$command" in
	help | -h | --help)
		usage
		exit 0
		;;
	add | update)
		require_network_tools
		init_tracking
		;;
	list | remove | rm | disable | enable | edit)
		require_tracking_tools
		init_tracking
		;;
	*)
		:
		;;
	esac

	case "$command" in
	add) add_entry "$@" ;;
	update) update_entries "${1:-}" ;;
	list) list_entries ;;
	remove | rm) remove_entry "${1:-}" ;;
	disable) set_enabled_state "${1:-}" false ;;
	enable) set_enabled_state "${1:-}" true ;;
	edit) edit_entry "$@" ;;
	*)
		err "unknown command: $command"
		usage
		exit 2
		;;
	esac
}

main "$@"
