#!/usr/bin/env bash
set -euo pipefail

# Opens a tmux dashboard with the UGSM menu and read-only server/scheduler output.
# Usage: dashboard.sh [server-name]

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
SERVER_DIRECTORY="$(dirname -- "$PROJECT_DIRECTORY")"
SERVER_NAME=""
DASHBOARD_SESSION="${SERVER_NAME}_dashboard"

monitor_pane() {
	local source_session="$1" output previous="" state=""
	while true; do
		if output="$(tmux capture-pane -p -t "=$source_session:" -S -50000 2>/dev/null)"; then
			output="$(printf '%s\n' "$output" | awk '
				{ lines[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
				END { for (i = 1; i <= last; i++) print lines[i] }
			')"
			if [[ -n "${output//[[:space:]]/}" ]]; then
				if [[ "$state" == output && "$output" == "$previous" ]]; then
					:
				elif [[ "$state" == output && "$output" == "$previous"$'\n'* ]]; then
					printf '%s\n' "${output#"$previous"$'\n'}"
				else
					printf '\033[H\033[2J%s\n' "$output"
				fi
				previous="$output"
				state=output
			elif [[ "$state" != empty ]]; then
				printf '\033[H\033[2JSession "%s" is running; no output yet.\n' "$source_session"
				previous=""
				state=empty
			fi
		elif [[ "$state" != waiting ]]; then
			printf '\033[H\033[2JWaiting for tmux session "%s"...\n' "$source_session"
			previous=""
			state=waiting
		fi
		sleep 1
	done
}

if [[ "${1:-}" == "--monitor" && "$#" -eq 2 ]]; then
	monitor_pane "$2"
fi
if (( $# > 1 )) || { (( $# == 1 )) && [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }; then
	printf 'Usage: %s [server-name]\n' "$0" >&2
	exit 2
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

if (( $# == 1 )); then
	SERVER_NAME="$1"
	SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"
	if [[ ! -r "$SERVER_CONFIG" ]] || [[ "$(read_setting "$SERVER_CONFIG" SERVER_NAME)" != "$SERVER_NAME" ]]; then
		printf 'Matching server config not found: %s\n' "$SERVER_CONFIG" >&2
		exit 1
	fi
else
	shopt -s nullglob
	SERVER_CONFIGS=("$PROJECT_DIRECTORY"/install/*_server.conf)
	shopt -u nullglob
	for config in "${SERVER_CONFIGS[@]}"; do
		config_name="$(read_setting "$config" SERVER_NAME)"
		if [[ ! "$config_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
			|| [[ "$(basename -- "$config")" != "${config_name}_server.conf" ]]; then
			continue
		fi
		if [[ "$(basename -- "$SERVER_DIRECTORY")" == "$config_name" ]]; then
			SERVER_NAME="$config_name"
			SERVER_CONFIG="$config"
			break
		fi
		if [[ -n "$SERVER_NAME" ]]; then
			printf 'Multiple server configs found. Specify one: %s <server-name>\n' "$0" >&2
			exit 2
		fi
		SERVER_NAME="$config_name"
		SERVER_CONFIG="$config"
	done
	if [[ -z "$SERVER_NAME" ]]; then
		printf 'No matching install/<server-name>_server.conf found in %s/install.\n' "$PROJECT_DIRECTORY" >&2
		exit 1
	fi
fi

DASHBOARD_SESSION="${SERVER_NAME}_dashboard"

if ! command -v tmux >/dev/null 2>&1; then
	printf 'tmux is not installed.\n' >&2
	exit 1
fi

monitor_command() {
	printf 'exec %q --monitor %q' "$SCRIPT_DIRECTORY/dashboard.sh" "$1"
}

if tmux has-session -t "=$DASHBOARD_SESSION" 2>/dev/null; then
	if [[ "$(tmux show-options -qv -t "$DASHBOARD_SESSION" @ugsm_dashboard_version)" != "2" ]]; then
		printf 'An older or incomplete dashboard session exists: %s\n' "$DASHBOARD_SESSION" >&2
		printf 'After exiting any menu action, close only that dashboard with: tmux kill-session -t "=%s"\n' "$DASHBOARD_SESSION" >&2
		printf 'Then run this script again. The server and scheduler sessions are not affected.\n' >&2
		exit 1
	fi
else
	printf -v menu_command 'exec bash %q' "$SCRIPT_DIRECTORY/menu.sh"
	tmux new-session -d -s "$DASHBOARD_SESSION" -n dashboard \
		-c "$SCRIPT_DIRECTORY" "$menu_command"
	# Remove an incomplete dashboard if layout creation fails.
	trap 'tmux kill-session -t "=$DASHBOARD_SESSION" 2>/dev/null || true' EXIT
	tmux set-option -w -t "$DASHBOARD_SESSION:0" pane-border-status top
	tmux set-option -w -t "$DASHBOARD_SESSION:0" \
		pane-border-format ' #{pane_index}: #{pane_title} '
	tmux select-pane -t "$DASHBOARD_SESSION:0.0" -T menu

	tmux split-window -v -l 35% -t "$DASHBOARD_SESSION:0.0" \
		-c "$SCRIPT_DIRECTORY" "$(monitor_command "${SERVER_NAME}_scheduler")"
	tmux select-pane -t "$DASHBOARD_SESSION:0.0" -T menu
	tmux select-pane -t "$DASHBOARD_SESSION:0.1" -T scheduler

	tmux split-window -h -l 50% -t "$DASHBOARD_SESSION:0.0" \
		-c "$SCRIPT_DIRECTORY" "$(monitor_command "$SERVER_NAME")"
	tmux select-pane -t "$DASHBOARD_SESSION:0.0" -T menu
	tmux select-pane -t "$DASHBOARD_SESSION:0.1" -T server
	tmux select-pane -t "$DASHBOARD_SESSION:0.2" -T scheduler
	tmux set-option -t "$DASHBOARD_SESSION" @ugsm_dashboard_version 2
	tmux select-pane -t "$DASHBOARD_SESSION:0.0"
	trap - EXIT
fi

tmux set-option -t "$DASHBOARD_SESSION" mouse on

if [[ -n "${TMUX:-}" ]]; then
	tmux switch-client -t "=$DASHBOARD_SESSION"
else
	tmux attach-session -t "=$DASHBOARD_SESSION"
fi
