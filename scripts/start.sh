#!/usr/bin/env bash
set -euo pipefail

# Builds the DayZ server start command and runs it.
# IP and ports come from install/<server name>_server.conf, mods from config/mods.conf
# and config/servermod.conf, all other parameters from config/start.conf.
# Usage: start.sh [--print]
#   --print  only show the command instead of starting the server

PRINT_ONLY=0
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--print" ) ]]; then
	printf 'Usage: %s [--print]\n' "$0" >&2
	exit 2
fi
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVERDATA_DIRECTORY="$SERVER_DIRECTORY/serverdata"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"
START_CONFIG="$PROJECT_DIRECTORY/config/start.conf"
MODS_CONFIG="$PROJECT_DIRECTORY/config/mods.conf"
SERVERMODS_CONFIG="$PROJECT_DIRECTORY/config/servermod.conf"

for file in "$SERVER_CONFIG" "$START_CONFIG"; do
	if [[ ! -r "$file" ]]; then
		printf 'Config file is missing or unreadable: %s\n' "$file" >&2
		exit 1
	fi
done
if [[ ! -x "$SERVERDATA_DIRECTORY/DayZServer" ]]; then
	printf 'DayZServer was not found in %s\n' "$SERVERDATA_DIRECTORY" >&2
	exit 1
fi

# Read a setting from a file without executing it.
read_setting() {
	awk -v key="$2" '
	{
		separator = index($0, "=")
		if (separator == 0) next
		name = substr($0, 1, separator - 1)
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
		if (name != key) next
		value = substr($0, separator + 1)
		sub(/[[:space:]]+#.*$/, "", value)
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
		if (value ~ /^".*"$/) {
			sub(/^"/, "", value)
			sub(/"$/, "", value)
		}
		print value
		exit
	}' "$1"
}

# Read workshop IDs: one per line, "#" starts a comment.
read_ids() {
	local file="$1" line id
	[[ -r "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"
		line="${line//$'\r'/}"
		id=""
		read -r id _ <<< "$line" || true
		[[ "$id" =~ ^[0-9]+$ ]] && printf '%s\n' "$id"
	done < "$file"
}

# Build "@id;@id" and warn about mods that are not installed yet.
join_mods() {
	local result="" id
	for id in "$@"; do
		if [[ ! -e "$SERVERDATA_DIRECTORY/@$id" && ! -L "$SERVERDATA_DIRECTORY/@$id" ]]; then
			printf 'Mod %s is not installed. Run mods.sh first.\n' "$id" >&2
			exit 1
		fi
		result+="@$id;"
	done
	printf '%s' "${result%;}"
}

is_port() {
	[[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

SERVER_IP="$(read_setting "$SERVER_CONFIG" SERVER_IP)"
GAME_PORT="$(read_setting "$SERVER_CONFIG" GAME_PORT)"
STEAM_QUERY_PORT="$(read_setting "$SERVER_CONFIG" STEAM_QUERY_PORT)"
if [[ -z "$SERVER_IP" ]] || ! python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$SERVER_IP" >/dev/null 2>&1; then
	printf 'Invalid or missing SERVER_IP in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi
for name in GAME_PORT STEAM_QUERY_PORT; do
	if ! is_port "${!name}"; then
		printf 'Invalid or missing %s in %s.\n' "$name" "$SERVER_CONFIG" >&2
		exit 1
	fi
done

CONFIG_FILE="$(read_setting "$START_CONFIG" CONFIG_FILE)"
PROFILES="$(read_setting "$START_CONFIG" PROFILES)"
BEPATH="$(read_setting "$START_CONFIG" BEPATH)"
CPUCOUNT="$(read_setting "$START_CONFIG" CPUCOUNT)"
LIMITFPS="$(read_setting "$START_CONFIG" LIMITFPS)"
EXTRA_PARAMS="$(read_setting "$START_CONFIG" EXTRA_PARAMS)"

ARGS=(
	"-config=${CONFIG_FILE:-serverDZ.cfg}"
	"-ip=$SERVER_IP"
	"-port=$((10#$GAME_PORT))"
	"-steamQueryPort=$((10#$STEAM_QUERY_PORT))"
	"-profiles=${PROFILES:-profiles}"
	"-BEpath=${BEPATH:-battleye}"
)
for switch in DOLOGS:-dologs ADMINLOG:-adminlog NETLOG:-netlog FREEZECHECK:-freezecheck; do
	[[ "$(read_setting "$START_CONFIG" "${switch%%:*}")" == "1" ]] && ARGS+=("${switch#*:}")
done
if [[ -n "$CPUCOUNT" ]]; then
	[[ "$CPUCOUNT" =~ ^[0-9]+$ ]] || { printf 'Invalid CPUCOUNT in %s.\n' "$START_CONFIG" >&2; exit 1; }
	ARGS+=("-cpuCount=$CPUCOUNT")
fi
if [[ -n "$LIMITFPS" ]]; then
	[[ "$LIMITFPS" =~ ^[0-9]+$ ]] || { printf 'Invalid LIMITFPS in %s.\n' "$START_CONFIG" >&2; exit 1; }
	ARGS+=("-limitFPS=$LIMITFPS")
fi

mapfile -t MOD_IDS < <(read_ids "$MODS_CONFIG" | awk '!seen[$0]++')
mapfile -t SERVERMOD_IDS < <(read_ids "$SERVERMODS_CONFIG" | awk '!seen[$0]++')
if (( ${#MOD_IDS[@]} > 0 )); then
	ARGS+=("-mod=$(join_mods "${MOD_IDS[@]}")")
fi
if (( ${#SERVERMOD_IDS[@]} > 0 )); then
	ARGS+=("-servermod=$(join_mods "${SERVERMOD_IDS[@]}")")
fi
if [[ -n "$EXTRA_PARAMS" ]]; then
	read -r -a EXTRA_ARRAY <<< "$EXTRA_PARAMS"
	ARGS+=("${EXTRA_ARRAY[@]}")
fi

cd -- "$SERVERDATA_DIRECTORY"
printf 'cd %q && ./DayZServer' "$SERVERDATA_DIRECTORY"
printf ' %q' "${ARGS[@]}"
printf '\n'
(( PRINT_ONLY )) && exit 0

exec ./DayZServer "${ARGS[@]}"
