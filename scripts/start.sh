#!/usr/bin/env bash
set -euo pipefail

# Builds the DayZ server start command and runs it.
# IP and ports come from install/<server name>_server.conf, mods from config/mods.conf
# and config/servermod.conf, all other parameters from config/start.conf.
# After the start the console and RPT log are watched until the Hive is initialized,
# then the ports are opened again in ufw (limited by STARTUP_TIMEOUT in the server conf).
# Usage: start.sh [--print]
#   --print  only show the command; otherwise show it and start the server

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

set_server_state() {
	local state="$1" temp_file
	case "$state" in
		stop|starting|running|stopping|error) ;;
		*) printf 'Invalid server state: %s\n' "$state" >&2; return 1 ;;
	esac

	if ! temp_file="$(mktemp "${SERVER_CONFIG}.XXXXXX")"; then
		printf 'Could not create a temporary file for %s.\n' "$SERVER_CONFIG" >&2
		return 1
	fi
	if ! STATE_VALUE="$state" awk -v key=STATE '
	BEGIN { value = ENVIRON["STATE_VALUE"] }
	{
		separator = index($0, "=")
		if (separator > 0) {
			name = substr($0, 1, separator - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			if (name == key) {
				if (!written) print key "=\"" value "\""
				written = 1
				next
			}
		}
		print
	}
	END {
		if (!written) print key "=\"" value "\""
	}' "$SERVER_CONFIG" > "$temp_file"; then
		rm -f -- "$temp_file"
		printf 'Could not update server state in %s.\n' "$SERVER_CONFIG" >&2
		return 1
	fi
	if ! chmod --reference="$SERVER_CONFIG" "$temp_file" || ! mv -- "$temp_file" "$SERVER_CONFIG"; then
		rm -f -- "$temp_file"
		printf 'Could not update server state in %s.\n' "$SERVER_CONFIG" >&2
		return 1
	fi
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

NEW_USER="$(read_setting "$SERVER_CONFIG" NEW_USER)"
if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$NEW_USER" >/dev/null 2>&1; then
	printf 'Invalid or missing NEW_USER (or user does not exist) in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi

CONFIG_FILE="$(read_setting "$START_CONFIG" CONFIG_FILE)"
PROFILES="$(read_setting "$START_CONFIG" PROFILES)"
BEPATH="$(read_setting "$START_CONFIG" BEPATH)"
CPUCOUNT="$(read_setting "$START_CONFIG" CPUCOUNT)"
LIMITFPS="$(read_setting "$START_CONFIG" LIMITFPS)"
EXTRA_PARAMS="$(read_setting "$START_CONFIG" EXTRA_PARAMS)"
STARTUP_TIMEOUT="$(read_setting "$SERVER_CONFIG" STARTUP_TIMEOUT)"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"
PORT_OPEN_DELAY="$(read_setting "$SERVER_CONFIG" PORT_OPEN_DELAY)"
PORT_OPEN_DELAY="${PORT_OPEN_DELAY:-0}"
HIVE_PATTERN="$(read_setting "$START_CONFIG" HIVE_PATTERN)"
HIVE_PATTERN="${HIVE_PATTERN:-\[CE\]\[Hive\] :: Init sequence finished}"
for name in STARTUP_TIMEOUT PORT_OPEN_DELAY; do
	if [[ ! "${!name}" =~ ^[0-9]+$ ]]; then
		printf 'Invalid %s in %s.\n' "$name" "$SERVER_CONFIG" >&2
		exit 1
	fi
done

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

if ! command -v tmux >/dev/null 2>&1; then
	printf 'tmux is not installed.\n' >&2
	exit 1
fi

TMUX_CMD=(tmux)
if [[ "$(id -un)" != "$NEW_USER" ]]; then
	TMUX_CMD=(sudo -u "$NEW_USER" tmux)
fi

# Hold a lock while this script runs so stop.sh can refuse to run in the meantime.
# The kernel releases it when the script ends, even after an abort.
if (( ! PRINT_ONLY )); then
	if ! command -v flock >/dev/null 2>&1; then
		printf 'flock is not installed.\n' >&2
		exit 1
	fi
	LOCK_FILE="$SERVER_DIRECTORY/.ugsm_start.lock"
	touch -- "$LOCK_FILE"
	exec 9< "$LOCK_FILE"
	if ! flock -n 9; then
		printf 'Another start.sh or stop.sh is already running for "%s".\n' "$SERVER_NAME" >&2
		exit 1
	fi
fi

if "${TMUX_CMD[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null; then
	printf 'tmux session "%s" is already running.\n' "$SERVER_NAME" >&2
	exit 1
fi

if command -v ss >/dev/null 2>&1; then
	for port in "$((10#$GAME_PORT))" "$((10#$STEAM_QUERY_PORT))"; do
		if ss -H -lntu 2>/dev/null | awk -v p="$port" '{n = split($5, a, ":"); if (a[n] == p) found = 1} END {exit !found}'; then
			printf 'Port %s is already in use.\n' "$port" >&2
			exit 1
		fi
	done
else
	printf 'Warning: ss not found, port check skipped.\n' >&2
fi

cd -- "$SERVERDATA_DIRECTORY"
printf 'cd %q && ./DayZServer' "$SERVERDATA_DIRECTORY"
printf ' %q' "${ARGS[@]}"
printf '\n'
(( PRINT_ONLY )) && exit 0

# The installer only allows exactly these sudo commands: ufw allow|delete allow <port>/udp.
UFW_BIN="/usr/sbin/ufw"
if [[ ! -x "$UFW_BIN" ]]; then
	printf 'ufw was not found at %s.\n' "$UFW_BIN" >&2
	exit 1
fi
UFW_CMD=("$UFW_BIN")
(( EUID == 0 )) || UFW_CMD=(sudo -n "$UFW_BIN")

# Block the ports by removing their allow rules (incoming traffic is denied by default).
for port in "$((10#$GAME_PORT))" "$((10#$STEAM_QUERY_PORT))"; do
	if ! UFW_OUTPUT="$("${UFW_CMD[@]}" delete allow "$port/udp" 2>&1)"; then
		printf '%s\nCould not block port %s with ufw.\n' "$UFW_OUTPUT" "$port" >&2
		exit 1
	fi
done

SERVER_COMMAND="$(printf 'exec ./DayZServer'; printf ' %q' "${ARGS[@]}")"
"${TMUX_CMD[@]}" new-session -d -s "$SERVER_NAME" -c "$SERVERDATA_DIRECTORY" "$SERVER_COMMAND" 9<&-
set_server_state starting
printf 'Server started in tmux session "%s" as user %s. Attach with: %s attach -t %s\n' \
	"$SERVER_NAME" "$NEW_USER" "${TMUX_CMD[*]}" "$SERVER_NAME"
printf 'Leave the session without stopping the server: press Ctrl+B, then D (detach).\n'

# Watch the console and the newest RPT log until the Hive is initialized.
PROFILES_DIRECTORY="$SERVERDATA_DIRECTORY/${PROFILES:-profiles}"
[[ "$PROFILES_DIRECTORY" == /* ]] || PROFILES_DIRECTORY="$SERVERDATA_DIRECTORY/$PROFILES_DIRECTORY"
START_TIME="$(date +%s)"
printf 'Waiting up to %s s for the Hive to initialize...\n' "$STARTUP_TIMEOUT"
HIVE_READY=0
while (( $(date +%s) - START_TIME < STARTUP_TIMEOUT )); do
	if ! "${TMUX_CMD[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null; then
		set_server_state error
		printf 'The server stopped before the Hive was initialized. Ports stay blocked.\n' >&2
		exit 1
	fi
	if "${TMUX_CMD[@]}" capture-pane -p -t "=$SERVER_NAME:" 2>/dev/null | grep -Eiq -- "$HIVE_PATTERN"; then
		HIVE_READY=1
		break
	fi
	RPT_FILE="$(find "$PROFILES_DIRECTORY" -maxdepth 1 -name '*.RPT' -newermt "@$START_TIME" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"
	if [[ -n "$RPT_FILE" ]] && grep -Eiq -- "$HIVE_PATTERN" "$RPT_FILE" 2>/dev/null; then
		HIVE_READY=1
		break
	fi
	sleep 2
done

if (( ! HIVE_READY )); then
	set_server_state error
	printf 'Hive was not initialized within %s s. Ports stay blocked.\n' "$STARTUP_TIMEOUT" >&2
	exit 1
fi

set_server_state running

if (( 10#$PORT_OPEN_DELAY > 0 )); then
	printf 'Hive initialized. Opening the ports in %s s...\n' "$PORT_OPEN_DELAY"
	sleep "$((10#$PORT_OPEN_DELAY))"
fi
for port in "$((10#$GAME_PORT))" "$((10#$STEAM_QUERY_PORT))"; do
	"${UFW_CMD[@]}" allow "$port/udp" || { printf 'Could not open port %s with ufw.\n' "$port" >&2; exit 1; }
done
printf 'Ports %s and %s are open.\n' "$GAME_PORT" "$STEAM_QUERY_PORT"
