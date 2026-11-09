#!/usr/bin/env bash
set -euo pipefail

# Checks every minute whether one of the restart times or maintenance times
# from config/scheduler.conf has been reached. At a maintenance time the server
# is stopped, the MAINTENANCE_COMMAND lines are run one after another and the
# server is started again (if MAINTENANCE_START_SERVER=1). With AUTO_RECOVER=1 it also checks
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
LOG_DIRECTORY="$PROJECT_DIRECTORY/logs"
LOG_RETENTION_DAYS=14

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

# Print all values of a repeatable setting (one per line), in file order.
# Commented-out lines are ignored because the key must start the line.
read_setting_all() {
	awk -v key="$2" '
	{
		separator = index($0, "=")
		if (separator == 0) next
		name = substr($0, 1, separator - 1)
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
		if (name != key) next
		value = substr($0, separator + 1)
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
		if (value ~ /^".*"$/) {
			sub(/^"/, "", value)
			sub(/"$/, "", value)
		}
		if (value != "") print value
	}' "$1"
}

# Stop the server, run the configured maintenance commands, then start it again.
run_maintenance() {
	local ts="$1" command rc start_after
	local commands=()
	mapfile -t commands < <(read_setting_all "$SCHEDULER_CONFIG" MAINTENANCE_COMMAND)
	start_after="$(read_setting "$SCHEDULER_CONFIG" MAINTENANCE_START_SERVER)"

	printf '[%s] Maintenance started: stopping the server\n' "$ts"
	if ! "$SCRIPT_DIRECTORY/stop.sh"; then
		printf '[%s] ✗ stop.sh failed, maintenance cancelled\n' "$(date +%H:%M:%S)"
		return 0
	fi

	if (( ${#commands[@]} == 0 )); then
		printf '[%s] No MAINTENANCE_COMMAND configured\n' "$(date +%H:%M:%S)"
	fi
	for command in "${commands[@]}"; do
		printf '[%s] ▶ %s\n' "$(date +%H:%M:%S)" "$command"
		rc=0
		bash -c "$command" </dev/null || rc=$?
		if (( rc == 0 )); then
			printf '[%s] ✓ done (exit 0): %s\n' "$(date +%H:%M:%S)" "$command"
		else
			printf '[%s] ✗ failed (exit %s): %s\n' "$(date +%H:%M:%S)" "$rc" "$command"
		fi
	done

	if [[ "$start_after" == "0" ]]; then
		printf '[%s] Maintenance finished, server stays stopped (MAINTENANCE_START_SERVER=0)\n' "$(date +%H:%M:%S)"
	else
		printf '[%s] Maintenance finished, starting the server\n' "$(date +%H:%M:%S)"
		"$SCRIPT_DIRECTORY/start.sh" || printf '[%s] ✗ start.sh failed\n' "$(date +%H:%M:%S)"
	fi
}

restart_server() {
	if "$SCRIPT_DIRECTORY/stop.sh"; then
		"$SCRIPT_DIRECTORY/start.sh" || { printf 'start.sh failed.\n' >&2; return 1; }
	else
		printf 'stop.sh failed, skipping start.\n' >&2
		return 1
	fi
}

# Same socket check as status.sh. Returns 0 bound, 1 not bound/invalid, 2 unknown (no ss/netstat).
check_udp_port_bound() {
	local port="$1"

	if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
		return 1
	fi

	if command -v ss &>/dev/null; then
		ss -H -u -l -n "sport = :$((10#$port))" 2>/dev/null | grep -q .
	elif command -v netstat &>/dev/null; then
		netstat -uln 2>/dev/null | awk -v port="$((10#$port))" '$4 ~ (":" port "$") { found = 1 } END { exit !found }'
	else
		return 2
	fi
}

# Runs all health checks. Sets HEALTH_OK (1|0) and HEALTH_DETAILS; always returns 0.
check_server_health() {
	local state user game_port steam_port rcon_port port label
	HEALTH_OK=1
	HEALTH_DETAILS=""

	if [[ ! -r "$SERVER_CONFIG" ]]; then
		HEALTH_OK=0
		HEALTH_DETAILS="CONFIG: ✗ missing"
		return 0
	fi

	state="$(read_setting "$SERVER_CONFIG" STATE)" || state="unknown"
	if [[ "$state" != "running" ]]; then
		HEALTH_OK=0
		HEALTH_DETAILS="STATE: ✗ ${state:-unknown}"
		return 0
	fi

	user="$(read_setting "$SERVER_CONFIG" NEW_USER)" || user="unknown"
	game_port="$(read_setting "$SERVER_CONFIG" GAME_PORT)" || game_port="0"
	steam_port="$(read_setting "$SERVER_CONFIG" STEAM_QUERY_PORT)" || steam_port="0"
	rcon_port="$(read_setting "$SERVER_CONFIG" RCON_PORT)" || rcon_port="0"

	local tmux_cmd=(tmux)
	[[ "$(id -un)" != "$user" ]] && tmux_cmd=(sudo -u "$user" tmux)
	if "${tmux_cmd[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null; then
		HEALTH_DETAILS+="tmux session: ✓ ok"
	else
		HEALTH_DETAILS+="tmux session: ✗ missing"
		HEALTH_OK=0
	fi

	if pgrep -u "$user" -f DayZServer >/dev/null 2>&1; then
		HEALTH_DETAILS+=" | dayz process: ✓ ok"
	else
		HEALTH_DETAILS+=" | dayz process: ✗ missing"
		HEALTH_OK=0
	fi

	for label in "game port:$game_port" "steam query port:$steam_port" "rcon port:$rcon_port"; do
		port="${label##*:}"
		local rc=0
		check_udp_port_bound "$port" || rc=$?
		case "$rc" in
			0) HEALTH_DETAILS+=" | ${label%:*}: ✓ ok" ;;
			2) HEALTH_DETAILS+=" | ${label%:*}: ? unknown (ss/netstat missing)" ;;
			*) HEALTH_DETAILS+=" | ${label%:*}: ✗ not bound"; HEALTH_OK=0 ;;
		esac
	done
	return 0
}

# Prints the current health result; on failure also dumps status.sh for debugging.
log_health() {
	local ts="$1"
	if (( HEALTH_OK )); then
		printf '[%s] Last check: ✓ HEALTHY | %s\n' "$ts" "$HEALTH_DETAILS"
	else
		printf '[%s] Last check: ✗ UNHEALTHY | %s\n' "$ts" "$HEALTH_DETAILS"
		printf '[%s] --- status.sh output ---\n' "$ts"
		"$SCRIPT_DIRECTORY/status.sh" 2>&1 || true
		printf '[%s] --- end of status.sh ---\n' "$ts"
	fi
}

# Usage: time_due HH:MM KEY  (KEY is a time-list setting such as RESTART_TIMES)
time_due() {
	local now="$1" key="$2" time
	for time in $(read_setting "$SCHEDULER_CONFIG" "$key"); do
		if [[ ! "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
			printf 'Ignoring invalid time in %s: %s\n' "$SCHEDULER_CONFIG" "$time" >&2
			continue
		fi
		[[ "$time" == "$now" ]] && return 0
	done
	return 1
}

# Copies every line to the console and to logs/scheduler-YYYY-MM-DD.log
# (one file per day, files older than LOG_RETENTION_DAYS are deleted).
log_sink() {
	local line day last_day=""
	mkdir -p -- "$LOG_DIRECTORY" 2>/dev/null || true
	while IFS= read -r line; do
		printf '%s\n' "$line"
		day="$(date +%F)"
		if [[ "$day" != "$last_day" ]]; then
			last_day="$day"
			find "$LOG_DIRECTORY" -maxdepth 1 -name 'scheduler-*.log' -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
		fi
		printf '%s\n' "$line" >> "$LOG_DIRECTORY/scheduler-$day.log" 2>/dev/null || true
	done
}

recover_if_due() {
	local ts="$1" uptime_seconds="$2"
	if (( recovery_attempted && uptime_seconds - last_recovery < 600 )); then
		return 0
	fi
	if (( recovery_pending )); then
		((recovery_failures+=1))
		recovery_pending=0
	fi
	if (( recovery_failures >= 3 )); then
		printf '[%s] Auto-recovery failed three times in a row; stopping the scheduler.\n' "$ts" >&2
		set_scheduler_state 0 || true
		return 1
	fi
	last_recovery="$uptime_seconds"
	recovery_attempted=1
	printf '[%s] ⚠ Auto-recovery: restarting the server (attempt %s of 3)\n' "$ts" "$((recovery_failures + 1))"
	if restart_server; then
		recovery_pending=1
	else
		((recovery_failures+=1))
	fi
	if (( recovery_failures >= 3 )); then
		printf '[%s] Auto-recovery failed three times in a row; stopping the scheduler.\n' "$(date +%H:%M:%S)" >&2
		set_scheduler_state 0 || true
		return 1
	fi
}

run_loop() {
	local last_checked="" now ts auto_recover server_state uptime_seconds uptime_fraction
	local recovery_failures=0 recovery_pending=0 last_recovery=0 recovery_attempted=0
	HEALTH_OK=1
	HEALTH_DETAILS=""

	# Block all input to prevent accidental interruption or interaction
	exec 0</dev/null

	auto_recover="$(read_setting "$SCHEDULER_CONFIG" AUTO_RECOVER)"

	printf '[%s] Scheduler started | Server: %s | Auto-Recover: %s | Restart times: %s | Maintenance times: %s\n' \
		"$(date +%H:%M:%S)" "$SERVER_NAME" "$([[ "$auto_recover" == "1" ]] && echo ON || echo OFF)" "$(read_restart_times)" "$(read_setting "$SCHEDULER_CONFIG" MAINTENANCE_TIMES)"

	while true; do
		now="$(date +%H:%M)"
		if [[ "$now" != "$last_checked" ]]; then
			last_checked="$now"
			ts="$(date +%H:%M:%S)"
			auto_recover="$(read_setting "$SCHEDULER_CONFIG" AUTO_RECOVER)"
			server_state="$(read_setting "$SERVER_CONFIG" STATE)" || server_state="unknown"

			printf '[%s] Scheduler: ✓ running as planned | Server state: %s | Auto-Recover: %s\n' \
				"$ts" "${server_state:-unknown}" "$([[ "$auto_recover" == "1" ]] && echo ON || echo OFF)"

			if time_due "$now" MAINTENANCE_TIMES; then
				run_maintenance "$ts"
			elif time_due "$now" RESTART_TIMES; then
				printf '[%s] Scheduled restart at %s\n' "$ts" "$now"
				restart_server || true
			elif [[ "$server_state" == "starting" || "$server_state" == "stopping" ]]; then
				printf '[%s] Server is %s; skipping health check and auto-recovery.\n' "$ts" "$server_state"
			else
				check_server_health
				log_health "$ts"
				if (( HEALTH_OK )); then
					recovery_failures=0
					recovery_pending=0
				elif [[ "$auto_recover" == "1" ]]; then
					read -r uptime_seconds uptime_fraction < /proc/uptime
					uptime_seconds="${uptime_seconds%%.*}"
					recover_if_due "$ts" "$uptime_seconds" || return 1
				fi
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
		tmux new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIRECTORY" < /dev/null "$(printf 'exec %q run' "$SCRIPT_DIRECTORY/scheduler.sh")"
		# Scrollable output, no input: the session uses an almost empty key table, so
		# typed keys and mouse clicks are discarded. Only the wheel (scrolling) and the
		# prefix key (Ctrl+b, e.g. for detach) are bound.
		tmux set-option -t "$SESSION_NAME" history-limit 50000 2>/dev/null || true
		tmux set-option -t "$SESSION_NAME" mouse on 2>/dev/null || true
		tmux set-option -t "$SESSION_NAME" key-table scheduler_locked 2>/dev/null || true
		tmux bind-key -T scheduler_locked C-b switch-client -T prefix 2>/dev/null || true
		tmux bind-key -T scheduler_locked WheelUpPane copy-mode -e 2>/dev/null || true
		tmux bind-key -T scheduler_locked WheelDownPane copy-mode -e 2>/dev/null || true
		set_scheduler_state 1
		printf 'Scheduler started in tmux session "%s".\n' "$SESSION_NAME"
		printf 'To view logs: tmux attach -t %s\n' "$SESSION_NAME"
		printf 'Note: Input is disabled. Detach with Ctrl+b, d\n'
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
			printf 'Scheduler: ✓ ACTIVE (tmux session "%s")\n' "$SESSION_NAME"
		else
			printf 'Scheduler: ✗ NOT ACTIVE\n'
		fi
		;;
	run)
		# Internal: runs inside the tmux session.
		run_loop 2>&1 | log_sink
		;;
	*)
		printf 'Usage: %s start|stop|status\n' "$0" >&2
		exit 1
		;;
esac
