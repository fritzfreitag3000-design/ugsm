#!/usr/bin/env bash
set -euo pipefail

# Gracefully stops the DayZ server running in the named tmux session.
# The session name and server user are taken from the server folder and config.
# Usage: stop.sh

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"

if [[ ! -r "$SERVER_CONFIG" ]]; then
	printf 'Config file is missing or unreadable: %s\n' "$SERVER_CONFIG" >&2
	exit 1
fi

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

NEW_USER="$(read_setting "$SERVER_CONFIG" NEW_USER)"
if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$NEW_USER" >/dev/null 2>&1; then
	printf 'Invalid or missing NEW_USER (or user does not exist) in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi

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

if ! command -v tmux >/dev/null 2>&1; then
	printf 'tmux is not installed.\n' >&2
	exit 1
fi

TMUX_CMD=(tmux)
if [[ "$(id -un)" != "$NEW_USER" ]]; then
	TMUX_CMD=(sudo -u "$NEW_USER" tmux)
fi

if ! command -v flock >/dev/null 2>&1; then
	printf 'flock is not installed.\n' >&2
	exit 1
fi

# start.sh holds this lock while it runs; a stale "starting" state alone does not block stopping.
LOCK_FILE="$SERVER_DIRECTORY/.ugsm_start.lock"
if [[ ! -e "$LOCK_FILE" ]]; then
	: >> "$LOCK_FILE" || { printf 'Could not create lock file %s.\n' "$LOCK_FILE" >&2; exit 1; }
fi
exec 9< "$LOCK_FILE"
if ! flock -n 9; then
	printf 'start.sh (or another stop.sh) is still running for "%s". Try again when it has finished.\n' "$SERVER_NAME" >&2
	exit 1
fi

if ! "${TMUX_CMD[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null; then
	set_server_state stop
	printf 'Server tmux session "%s" is not running.\n' "$SERVER_NAME"
	exit 0
fi

SHUTDOWN_TIMEOUT="$(read_setting "$SERVER_CONFIG" SHUTDOWN_TIMEOUT)"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"
SIGINT_TIMEOUT="$(read_setting "$SERVER_CONFIG" SIGINT_TIMEOUT)"
SIGINT_TIMEOUT="${SIGINT_TIMEOUT:-60}"
for name in SHUTDOWN_TIMEOUT SIGINT_TIMEOUT; do
	if [[ ! "${!name}" =~ ^[0-9]+$ ]]; then
		printf 'Invalid %s in %s.\n' "$name" "$SERVER_CONFIG" >&2
		exit 1
	fi
done

# Wait up to the given seconds; succeeds as soon as the tmux session has ended.
wait_for_stop() {
	local seconds="$((10#$1))" elapsed
	for ((elapsed = 0; elapsed < seconds; elapsed++)); do
		"${TMUX_CMD[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null || return 0
		sleep 1
	done
	! "${TMUX_CMD[@]}" has-session -t "=$SERVER_NAME" 2>/dev/null
}

# Pass "backup" only when the server stopped cleanly after the RCON #shutdown.
# After Ctrl+C or a kill the data may be inconsistent, so no backup is made.
server_stopped() {
	set_server_state stop
	printf 'Server stopped.\n'

	if [[ "${1:-}" == "backup" ]]; then
		printf 'Creating backup...\n'
		BACKUP_SCRIPT="$PROJECT_DIRECTORY/scripts/backup.sh"
		if [[ -x "$BACKUP_SCRIPT" ]]; then
			if [[ "$(id -un)" == "$NEW_USER" ]]; then
				"$BACKUP_SCRIPT"
			else
				sudo -u "$NEW_USER" "$BACKUP_SCRIPT"
			fi
		else
			printf 'Warning: backup.sh not found or not executable: %s\n' "$BACKUP_SCRIPT" >&2
		fi
	else
		printf 'Server was not stopped via RCON #shutdown; skipping backup.\n'
	fi

	exit 0
}

set_server_state stopping

# Lock the server, warn the players via BattlEye RCON, then shut it down via RCON.
RCON_PORT="$(read_setting "$SERVER_CONFIG" RCON_PORT)"
RCON_PASS="$(read_setting "$SERVER_CONFIG" RCON_PASS)"
RCON_HOST="$(read_setting "$SERVER_CONFIG" SERVER_IP)"
[[ -z "$RCON_HOST" || "$RCON_HOST" == "0.0.0.0" ]] && RCON_HOST="127.0.0.1"
RCON_READY=0
if ! command -v bercon-cli >/dev/null 2>&1; then
	printf 'Warning: bercon-cli is not installed, players are not warned.\n' >&2
elif [[ ! "$RCON_PORT" =~ ^[0-9]{1,5}$ || -z "$RCON_PASS" ]]; then
	printf 'Warning: RCON_PORT or RCON_PASS is invalid in %s, players are not warned.\n' "$SERVER_CONFIG" >&2
else
	RCON_READY=1
fi

# Send raw RCON commands in one call. The password is passed via the environment
# so it does not show up in the process list.
rcon_exec() {
	BERCON_PASSWORD="$RCON_PASS" bercon-cli --no-env --ip "$RCON_HOST" --port "$((10#$RCON_PORT))" \
		exec -- "$@" >/dev/null
}

# Kick every connected player (BattlEye has no "kick all"): read the player
# numbers from "players" and send the kick commands in batches.
rcon_kick_all() {
	local output ids=() args=() id
	output="$(BERCON_PASSWORD="$RCON_PASS" bercon-cli --no-env --ip "$RCON_HOST" --port "$((10#$RCON_PORT))" 		--format raw exec -- players)" || return 1
	mapfile -t ids < <(awk '$1 ~ /^[0-9]+$/ { print $1 }' <<< "$output")
	for id in "${ids[@]}"; do
		args+=("kick $id Server restart")
		if (( ${#args[@]} >= 50 )); then
			rcon_exec "${args[@]}" || return 1
			args=()
		fi
	done
	if (( ${#args[@]} > 0 )); then
		rcon_exec "${args[@]}" || return 1
	fi
	printf 'Kicked %s player(s).\n' "${#ids[@]}"
}

rcon_say() {
	local args=() message
	for message in "$@"; do
		args+=("say -1 $message")
	done
	rcon_exec "${args[@]}"
}

if (( RCON_READY )); then
	if rcon_exec '#lock'; then
		printf 'Locked the server to prevent new players from joining.\n'
		if rcon_say 'Server restarts in 60 seconds!' 'Server restarts in 60 seconds!' 'Server restarts in 60 seconds!'; then
			printf 'Players were warned. Waiting 60 seconds...\n'
			# 60 s in total: 30 s + 15 s + 5 s + 10 s countdown.
			sleep 30
			rcon_say 'Server restarts in 30 seconds!' || true
			sleep 15
			rcon_say 'Server restarts in 15 seconds!' || true
			sleep 5
			for ((second = 10; second >= 1; second--)); do
				rcon_say "Server restarts in $second!" || true
				sleep 1
			done
		else
			printf 'Warning: could not send the RCON message, players are not warned.\n' >&2
		fi
	else
		printf 'Warning: could not lock the server; skipping player warnings.\n' >&2
	fi

	if rcon_kick_all; then
		sleep 3
	else
		printf 'Warning: could not kick all players.\n' >&2
	fi

	if rcon_exec '#shutdown'; then
		printf 'Sent #shutdown via RCON; waiting up to %s s for the server to stop...\n' "$SHUTDOWN_TIMEOUT"
		wait_for_stop "$SHUTDOWN_TIMEOUT" && server_stopped backup
		printf 'Server did not stop after #shutdown, sending Ctrl+C.\n' >&2
	else
		printf 'Could not send #shutdown via RCON, sending Ctrl+C.\n' >&2
	fi
fi

if ! "${TMUX_CMD[@]}" send-keys -t "=$SERVER_NAME:" C-c; then
	set_server_state error
	printf 'Could not send the stop signal to tmux session "%s".\n' "$SERVER_NAME" >&2
	exit 1
fi

printf 'Sent Ctrl+C to tmux session "%s"; waiting up to %s s for it to stop...\n' "$SERVER_NAME" "$SIGINT_TIMEOUT"
wait_for_stop "$SIGINT_TIMEOUT" && server_stopped

# Last resort: kill the server process hard (it is the pane process, started with exec).
printf 'Server still running, killing it.\n' >&2
PANE_PID="$("${TMUX_CMD[@]}" display-message -p -t "=$SERVER_NAME:" '#{pane_pid}' 2>/dev/null || true)"
if [[ "$PANE_PID" =~ ^[0-9]+$ ]]; then
	KILL_CMD=(kill)
	[[ "$(id -un)" == "$NEW_USER" ]] || KILL_CMD=(sudo -u "$NEW_USER" kill)
	"${KILL_CMD[@]}" -KILL "$PANE_PID" 2>/dev/null || true
fi
"${TMUX_CMD[@]}" kill-session -t "=$SERVER_NAME" 2>/dev/null || true
wait_for_stop 5 && server_stopped

set_server_state error
printf 'Could not stop the server in tmux session "%s".\n' "$SERVER_NAME" >&2
exit 1
