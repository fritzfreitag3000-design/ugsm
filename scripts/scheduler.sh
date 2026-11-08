#!/usr/bin/env bash
set -euo pipefail

# Checks every minute whether one of the restart times from
# config/scheduler.conf has been reached. With AUTO_RECOVER=1 it also checks
# that the server is healthy and restarts it if it is not.
# Usage: scheduler.sh start|stop|status
#   start   runs the scheduler in a background tmux session
#   stop    ends that session
#   status  shows whether the session is running
# The state is stored as SCHEDULER_STATE in the server config.

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SCHEDULER_CONFIG="$PROJECT_DIRECTORY/config/scheduler.conf"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"
SESSION_NAME="${SERVER_NAME}_scheduler"

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

# Prints the first failed check and returns 0 if the server is unhealthy.
# Returns 0 (unhealthy) if STATE != "running" or if any health check fails.
server_unhealthy() {
	local state user game_port steam_port rcon_port port listening
	state="$(read_setting "$SERVER_CONFIG" STATE)"
	if [[ "$state" != "running" ]]; then
		printf 'Server is not running (STATE=%s).\n' "$state"
		return 0
	fi

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

run_loop() {
	local last_checked="" now reason auto_recover last_check_result last_check_time
	auto_recover="$(read_setting "$SCHEDULER_CONFIG" AUTO_RECOVER)"
	
	printf '╔════════════════════════════════════════════════════════╗\n'
	printf '║ DayZ Server Scheduler Started                          ║\n'
	printf '║ Server: %s\n' "$SERVER_NAME"
	printf '║ Config: %s\n' "$SCHEDULER_CONFIG"
	printf '║ Auto-Recover: %s\n' "$([[ "$auto_recover" == "1" ]] && echo "ENABLED" || echo "DISABLED")"
	printf '║ Restart Times: %s\n' "$(read_restart_times)"
	printf '╚════════════════════════════════════════════════════════╝\n'
	
	last_check_result="Starting up..."
	last_check_time="--:--"
	
	while true; do
		now="$(date +%H:%M)"
		if [[ "$now" != "$last_checked" ]]; then
			last_checked="$now"
			last_check_time="$now"
			
			if restart_due "$now"; then
				last_check_result="✓ Scheduled restart at $now"
				printf '[%s] %-50s │ %s\n' "$now" "SCHEDULED RESTART" "Auto-Recover: $([[ "$auto_recover" == "1" ]] && echo "ON" || echo "OFF")"
				restart_server
			elif [[ "$auto_recover" == "1" ]] && reason="$(server_unhealthy)"; then
				last_check_result="⚠ Auto-Recovery: $reason"
				printf '[%s] %-50s │ %s\n' "$now" "AUTO-RECOVERY RESTART: $reason" "Auto-Recover: ON"
				restart_server
			else
				last_check_result="✓ Server healthy"
				printf '[%s] %-50s │ %s\n' "$now" "OK - Server running normally" "Auto-Recover: $([[ "$auto_recover" == "1" ]] && echo "ON" || echo "OFF")"
			fi
		fi
		# Sleep until the start of the next minute.
		sleep $((60 - 10#$(date +%S)))
	done
}

# Write SCHEDULER_STATE (1|0) to the server config.
set_scheduler_state() {
	local state="$1" temp_file
	temp_file="$(mktemp "${SERVER_CONFIG}.XXXXXX")" || return 1
	if ! STATE_VALUE="$state" awk -v key=SCHEDULER_STATE '
	BEGIN { value = ENVIRON["STATE_VALUE"] }
	{
		separator = index($0, "=")
		if (separator > 0) {
			name = substr($0, 1, separator - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			if (name == key) {
				if (!written) print key "=" value
				written = 1
				next
			}
		}
		print
	}
	END {
		if (!written) print key "=" value
	}' "$SERVER_CONFIG" > "$temp_file" \
		|| ! chmod --reference="$SERVER_CONFIG" "$temp_file" \
		|| ! mv -- "$temp_file" "$SERVER_CONFIG"; then
		rm -f -- "$temp_file"
		printf 'Could not update SCHEDULER_STATE in %s.\n' "$SERVER_CONFIG" >&2
		return 1
	fi
}

session_active() {
	tmux has-session -t "=$SESSION_NAME" 2>/dev/null
}

case "${1:-}" in
	start)
		command -v tmux >/dev/null 2>&1 || { printf 'tmux is not installed.\n' >&2; exit 1; }
		if session_active; then
			printf 'Scheduler is already running in tmux session "%s".\n' "$SESSION_NAME" >&2
			exit 1
		fi
		tmux new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIRECTORY" "$(printf 'exec %q run' "$SCRIPT_DIRECTORY/scheduler.sh")"
		set_scheduler_state 1
		printf 'Scheduler started in tmux session "%s". Attach with: tmux attach -t %s\n' "$SESSION_NAME" "$SESSION_NAME"
		;;
	stop)
		if session_active; then
			tmux kill-session -t "=$SESSION_NAME"
			printf 'Scheduler stopped.\n'
		else
			printf 'Scheduler is not running.\n'
		fi
		set_scheduler_state 0
		;;
	status)
		if session_active; then
			local auto_recover restart_times scheduler_state
			auto_recover="$(read_setting "$SCHEDULER_CONFIG" AUTO_RECOVER)"
			restart_times="$(read_restart_times)"
			scheduler_state="$(read_setting "$SERVER_CONFIG" SCHEDULER_STATE)"
			
			printf '\n┌─ Scheduler Status ────────────────────────────────────┐\n'
			printf '│ Status: ✓ RUNNING\n'
			printf '│ Session Name: %s\n' "$SESSION_NAME"
			printf '│ Server: %s\n' "$SERVER_NAME"
			printf '│\n'
			printf '│ Configuration:\n'
			printf '│   Auto-Recover: %s\n' "$([[ "$auto_recover" == "1" ]] && echo "ENABLED" || echo "DISABLED")"
			printf '│   Restart Times: %s\n' "$restart_times"
			printf '│   Scheduler State: %s\n' "$scheduler_state"
			printf '│\n'
			printf '│ To view logs: tmux attach -t %s\n' "$SESSION_NAME"
			printf '│ To stop: %s stop\n' "$0"
			printf '└────────────────────────────────────────────────────────┘\n\n'
		else
			printf '\n┌─ Scheduler Status ────────────────────────────────────┐\n'
			printf '│ Status: ✗ NOT RUNNING\n'
			printf '│ Session Name: %s\n' "$SESSION_NAME"
			printf '│\n'
			printf '│ To start: %s start\n' "$0"
			printf '└────────────────────────────────────────────────────────┘\n\n'
		fi
		;;
	run)
		# Internal: runs inside the tmux session.
		run_loop
		;;
	*)
		printf 'Usage: %s start|stop|status\n' "$0" >&2
		exit 1
		;;
esac
