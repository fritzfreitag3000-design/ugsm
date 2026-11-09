#!/usr/bin/env bash
set -uo pipefail

# Find the status script in the same project.
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"
STATUS_OUTPUT=""
MESSAGE=""
REFRESH_STATUS=1

# Clear the terminal before drawing a menu.
clear_menu() {
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J\033[3J'
	fi
}

# Read one setting without executing the configuration file.
read_config_setting() {
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
		gsub(/^"|"$/, "", value)
		print value
		exit
	}' "$1"
}

# Show scheduler status, the recovery setting, and the systemd autostart state.
show_scheduler_status() {
	local scheduler_output recovery autostart service_name load_state
	if command -v tmux >/dev/null 2>&1 && scheduler_output="$(bash "$SCRIPT_DIRECTORY/scheduler.sh" status 2>/dev/null)"; then
		case "$scheduler_output" in
			*'NOT ACTIVE'*) scheduler_output="inactive" ;;
			*'ACTIVE'*) scheduler_output="active" ;;
			*) scheduler_output="unknown" ;;
		esac
	else
		scheduler_output="unknown"
	fi

	recovery=""
	if [[ -r "$PROJECT_DIRECTORY/config/scheduler.conf" ]]; then
		recovery="$(read_config_setting "$PROJECT_DIRECTORY/config/scheduler.conf" AUTO_RECOVER)"
	fi
	case "$recovery" in
		1)
			case "$scheduler_output" in
				active) recovery="active" ;;
				inactive) recovery="inactive (scheduler stopped)" ;;
				*) recovery="unknown (scheduler status unavailable)" ;;
			esac
			;;
		0) recovery="disabled" ;;
		*) recovery="unknown" ;;
	esac

	autostart="unknown"
	service_name="ugsm-scheduler-${SERVER_NAME}.service"
	if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
		autostart="$(systemctl is-enabled "$service_name" 2>/dev/null)" || true
		case "$autostart" in
			enabled|enabled-runtime) autostart="enabled" ;;
			disabled|masked|masked-runtime|not-found) autostart="disabled" ;;
			*)
				load_state="$(systemctl show "$service_name" --property=LoadState --value 2>/dev/null)" || true
				if [[ "$load_state" == "not-found" ]]; then
					autostart="disabled"
				else
					autostart="unknown"
				fi
				;;
		esac
	fi
	printf '\n  Scheduler: %s\n' "$scheduler_output"
	printf '  Auto-recovery: %s\n' "$recovery"
	printf '  Scheduler autostart: %s\n' "$autostart"
}

# Attach to an existing tmux session without starting a nested tmux session.
open_tmux_session() {
	local session_name="$1"
	if ! command -v tmux >/dev/null 2>&1; then
		printf 'tmux is not installed.\n' >&2
		return 1
	fi
	if [[ -n "${TMUX:-}" ]]; then
		printf 'Leave the current tmux session before opening another console.\n' >&2
		return 1
	fi
	if ! tmux has-session -t "=$session_name" 2>/dev/null; then
		printf 'The tmux session "%s" is not running for this user.\n' "$session_name" >&2
		return 1
	fi
	printf 'Detach with Ctrl+b, then d to return to the menu.\n'
	tmux attach-session -t "=$session_name"
}

# Let the user start or stop the server with the existing scripts.
server_control_menu() {
	local choice command message="" server_state server_user
	while true; do
		clear_menu
		printf 'Server control\n'
		printf '\n  1  Start server\n'
		printf '  2  Stop server\n'
		printf '  3  Open server console\n'
		printf '  0  Back\n'
		if [[ -n "$message" ]]; then
			printf '\n%s\n' "$message"
			message=""
		fi
		printf '\nSelect an option: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
		case "$choice" in
			1) command="start.sh" ;;
			2) command="stop.sh" ;;
			3)
				clear_menu
				server_state=""
				server_user=""
				if [[ -r "$SERVER_CONFIG" ]]; then
					server_state="$(read_config_setting "$SERVER_CONFIG" STATE)"
					server_user="$(read_config_setting "$SERVER_CONFIG" NEW_USER)"
				fi
				if [[ "$server_state" != "running" ]]; then
					printf 'The server is not marked as running.\n' >&2
				elif [[ -z "$server_user" || "$(id -un)" != "$server_user" ]]; then
					printf 'Run this menu as the configured server user to open its console.\n' >&2
				elif open_tmux_session "$SERVER_NAME"; then
					continue
				fi
				printf '\nPress Enter to return: '
				if ! IFS= read -r choice; then
					printf '\n'
					return
				fi
				continue
				;;
			0) return ;;
			*) message="Invalid option. Enter 1, 2, 3 or 0."; continue ;;
		esac

		clear_menu
		if bash "$SCRIPT_DIRECTORY/$command"; then
			printf '\nCommand completed successfully.\n'
		else
			printf '\nCommand failed.\n' >&2
		fi
		printf 'Press Enter to return: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
	done
}

# Let the user create or restore a backup.
backup_menu() {
	local choice mode confirm message=""
	while true; do
		clear_menu
		printf 'Backup management\n'
		printf '\n  1  Create backup\n'
		printf '  2  Restore latest backup\n'
		printf '  3  Choose backup to restore\n'
		printf '  0  Back\n'
		if [[ -n "$message" ]]; then
			printf '\n%s\n' "$message"
			message=""
		fi
		printf '\nSelect an option: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
		case "$choice" in
			1) mode="backup" ;;
			2) mode="auto_recover" ;;
			3) mode="recover" ;;
			0) return ;;
			*) message="Invalid option. Enter 1, 2, 3 or 0."; continue ;;
		esac

		clear_menu
		if [[ "$mode" != "backup" ]]; then
			printf 'Restore replaces server files. Stop the server before continuing.\n'
			printf 'Continue with restore? [y/N] '
			if ! IFS= read -r confirm; then
				printf '\n'
				return
			fi
			case "$confirm" in
				[yY]|[yY][eE][sS]) ;;
				*) message="Restore cancelled."; continue ;;
			esac
		fi
		if bash "$SCRIPT_DIRECTORY/backup.sh" "$mode"; then
			printf '\nBackup command finished.\n'
		else
			printf '\nBackup command failed.\n' >&2
		fi
		printf 'Press Enter to return: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
	done
}

# Open the selected configuration file in nano.
config_menu() {
	local choice config_file message=""
	while true; do
		clear_menu
		printf 'Configuration files\n'
		printf '\n  1  mods.conf\n'
		printf '  2  scheduler.conf\n'
		printf '  3  servermod.conf\n'
		printf '  4  start.conf\n'
		printf '  5  %s_server.conf\n' "$SERVER_NAME"
		printf '  0  Back\n'
		if [[ -n "$message" ]]; then
			printf '\n%s\n' "$message"
			message=""
		fi
		printf '\nSelect an option: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
		case "$choice" in
			1) config_file="$PROJECT_DIRECTORY/config/mods.conf" ;;
			2) config_file="$PROJECT_DIRECTORY/config/scheduler.conf" ;;
			3) config_file="$PROJECT_DIRECTORY/config/servermod.conf" ;;
			4) config_file="$PROJECT_DIRECTORY/config/start.conf" ;;
			5) config_file="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf" ;;
			0) return ;;
			*) message="Invalid option. Enter a number from 0 to 5."; continue ;;
		esac
		if ! command -v nano >/dev/null 2>&1; then
			message="nano is not installed."
		elif [[ ! -f "$config_file" ]]; then
			message="Config file not found: $config_file"
		else
			clear_menu
			if ! nano -- "$config_file"; then
				message="Could not open config file: $config_file"
			fi
		fi
	done
}

# Start, inspect, or stop the scheduler.
scheduler_menu() {
	local choice action command config_file message=""
	while true; do
		clear_menu
		printf 'Scheduler\n'
		printf '\n  1  Start scheduler\n'
		printf '  2  Show scheduler status\n'
		printf '  3  Stop scheduler\n'
		printf '  4  Enable scheduler autostart\n'
		printf '  5  Disable scheduler autostart\n'
		printf '  6  Open scheduler console\n'
		printf '  7  Edit scheduler.conf\n'
		printf '  0  Back\n'
		if [[ -n "$message" ]]; then
			printf '\n%s\n' "$message"
			message=""
		fi
		printf '\nSelect an option: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
		case "$choice" in
			1) command="scheduler.sh"; action="start" ;;
			2) command="scheduler.sh"; action="status" ;;
			3) command="scheduler.sh"; action="stop" ;;
			4) command="setup_scheduler_autostart.sh"; action="install" ;;
			5) command="setup_scheduler_autostart.sh"; action="uninstall" ;;
			6)
				clear_menu
				if open_tmux_session "${SERVER_NAME}_scheduler"; then
					continue
				fi
				printf '\nPress Enter to return: '
				if ! IFS= read -r choice; then
					printf '\n'
					return
				fi
				continue
				;;
			7)
				config_file="$PROJECT_DIRECTORY/config/scheduler.conf"
				if ! command -v nano >/dev/null 2>&1; then
					message="nano is not installed."
				elif [[ ! -f "$config_file" ]]; then
					message="Config file not found: $config_file"
				else
					clear_menu
					if ! nano -- "$config_file"; then
						message="Could not open config file: $config_file"
					fi
				fi
				continue
				;;
			0) return ;;
			*) message="Invalid option. Enter a number from 0 to 7."; continue ;;
		esac
		clear_menu
		if ! bash "$SCRIPT_DIRECTORY/$command" "$action"; then
			printf '\nScheduler command failed.\n' >&2
		fi
		printf '\nPress Enter to return: '
		if ! IFS= read -r choice; then
			printf '\n'
			return
		fi
	done
}

# Keep the menu open until the user chooses to exit.
while true; do
	clear_menu
	if (( REFRESH_STATUS )); then
		STATUS_OUTPUT="$(bash "$SCRIPT_DIRECTORY/status.sh" --gamedig 2>&1)" || true
		REFRESH_STATUS=0
	fi
	SERVER_STATE=""
	if [[ -r "$SERVER_CONFIG" ]]; then
		SERVER_STATE="$(read_config_setting "$SERVER_CONFIG" STATE)"
	fi
	printf '\n  Server state: %s\n' "${SERVER_STATE:-unknown}"
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "Status: online" ]] && continue
		printf '  %s\n' "$line"
	done <<< "$STATUS_OUTPUT"
	show_scheduler_status
	printf '\n----------------------------------------\n'
	printf '  1  Start or stop server\n'
	printf '  2  Backup management\n'
	printf '  3  Edit configuration\n'
	printf '  4  Scheduler\n'
	printf '  5  Refresh status\n'
	printf '  6  Full status report\n'
	printf '  0  Exit\n'
	if [[ -n "$MESSAGE" ]]; then
		printf '\n%s\n' "$MESSAGE"
		MESSAGE=""
	fi
	printf 'Select an option: '
	if ! IFS= read -r choice; then
		printf '\n'
		break
	fi
	case "$choice" in
		1) server_control_menu; REFRESH_STATUS=1 ;;
		2) backup_menu; REFRESH_STATUS=1 ;;
		3) config_menu; REFRESH_STATUS=1 ;;
		4) scheduler_menu; REFRESH_STATUS=1 ;;
		5) REFRESH_STATUS=1 ;;
		6)
			clear_menu
			if ! bash "$SCRIPT_DIRECTORY/status.sh"; then
				printf '\nStatus report failed.\n' >&2
			fi
			printf '\nPress Enter to return: '
			if ! IFS= read -r choice; then
				printf '\n'
				break
			fi
			REFRESH_STATUS=1
			;;
		0) break ;;
		*) MESSAGE="Invalid option. Enter a number from 0 to 6." ;;
	esac
done