#!/usr/bin/env bash
set -euo pipefail

# Checks every minute whether one of the restart times from
# config/scheduler.conf has been reached. With AUTO_RECOVER=1 it also checks
# that the server is healthy and restarts it if it is not.
# Usage: scheduler.sh

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SCHEDULER_CONFIG="$PROJECT_DIRECTORY/config/scheduler.conf"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"

if [[ ! -r "$SCHEDULER_CONFIG" ]]; then
	printf 'Config file is missing or unreadable: %s\n' "$SCHEDULER_CONFIG" >&2
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

read_restart_times() {
	read_setting "$SCHEDULER_CONFIG" RESTART_TIMES
}

restart_server() {
	if "$SCRIPT_DIRECTORY/stop.sh"; then
		"$SCRIPT_DIRECTORY/start.sh" || printf 'start.sh failed.\n' >&2
	else
		printf 'stop.sh failed, skipping start.\n' >&2
	fi
}

# Prints the first failed check and returns 1 if the server is not healthy.
# Checks are skipped unless the server state is "running".
server_unhealthy() {
	local state user game_port steam_port rcon_port port listening
	state="$(read_setting "$SERVER_CONFIG" STATE)"
	[[ "$state" == "running" ]] || return 1

	user="$(read_setting "$SERVER_CONFIG" NEW_USER)"
	game_port="$(read_setting "$SERVER_CONFIG" GAME_PORT)"
	steam_port="$(read_setting "$SERVER_CONFIG" STEAM_QUERY_PORT)"
	rcon_port="$(read_setting "$SERVER_CONFIG" RCON_PORT)"

	local tmux_cmd=(tmux)
	[[ "$(id -un)" != "$user" ]] && tmux_cmd=(sudo -u "$user" tmux)
	if ! "${tmux_cmd[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null; then
		printf 'tmux session "%s" is not active.\n' "$SERVER_NAME"
		return 0
	fi

	if ! pgrep -u "$user" -x DayZServer >/dev/null 2>&1; then
		printf 'DayZServer process is not running.\n'
		return 0
	fi

	listening="$(ss -H -lnu 2>/dev/null | awk '{n = split($5, a, ":"); print a[n]}')"
	for port in "$game_port" "$steam_port" "$rcon_port"; do
		if ! grep -qx -- "$((10#$port))" <<< "$listening"; then
			printf 'Port %s is not active.\n' "$((10#$port))"
			return 0
		fi
	done
	return 1
}

restart_due() {
	local now="$1" time
	for time in $(read_restart_times); do
		if [[ ! "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
			printf 'Ignoring invalid time in %s: %s\n' "$SCHEDULER_CONFIG" "$time" >&2
			continue
		fi
		[[ "$time" == "$now" ]] && return 0
	done
	return 1
}

last_checked=""
while true; do
	now="$(date +%H:%M)"
	if [[ "$now" != "$last_checked" ]]; then
		last_checked="$now"
		if restart_due "$now"; then
			printf '[%s] Restart time reached.\n' "$now"
			restart_server
		elif [[ "$(read_setting "$SCHEDULER_CONFIG" AUTO_RECOVER)" == "1" ]] && reason="$(server_unhealthy)"; then
			printf '[%s] Auto recover: %s Restarting.\n' "$now" "$reason"
			restart_server
		fi
	fi
	# Sleep until the start of the next minute.
	sleep $((60 - 10#$(date +%S)))
done
