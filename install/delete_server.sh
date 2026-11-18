#!/usr/bin/env bash
# Deletes a complete server folder after a double confirmation.
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
	printf 'Please run this script as root (sudo).\n' >&2
	exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Read a KEY="value" setting from a config file.
read_setting() {
	local value
	value="$(grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- || true)"
	value="${value%\"}"
	value="${value#\"}"
	printf '%s' "$value"
}

CONFIGS=()
shopt -s nullglob
for config in "$SCRIPT_DIR"/*_server.conf; do
	[[ "$(basename -- "$config")" == "default_server.conf" ]] && continue
	CONFIGS+=("$config")
done
shopt -u nullglob

if [[ "${#CONFIGS[@]}" -eq 0 ]]; then
	printf 'No server configurations found in %s.\n' "$SCRIPT_DIR" >&2
	exit 1
fi

# Build the list of servers with their folders.
NAMES=()
DIRS=()
CONF_FILES=()
USERS=()
printf 'Available servers:\n'
for config in "${CONFIGS[@]}"; do
	name="$(read_setting "$config" SERVER_NAME)"
	user="$(read_setting "$config" NEW_USER)"
	[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -n "$user" ]] || continue
	home="$(getent passwd "$user" | cut -d: -f6 || true)"
	[[ -n "$home" && -d "$home/$name" ]] || continue
	NAMES+=("$name")
	DIRS+=("$home/$name")
	CONF_FILES+=("$config")
	USERS+=("$user")
	printf '  %d) %s  (%s)\n' "${#NAMES[@]}" "$name" "$home/$name"
done

if [[ "${#NAMES[@]}" -eq 0 ]]; then
	printf 'No existing server folders found.\n' >&2
	exit 1
fi
printf '  q) Quit\n'

while true; do
	read -r -p 'Select the server folder to delete: ' choice
	[[ "${choice,,}" == "q" ]] && { printf 'Aborted.\n'; exit 0; }
	if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#NAMES[@]} )); then
		break
	fi
	printf 'Invalid selection.\n' >&2
done

idx=$((10#$choice - 1))
NAME="${NAMES[$idx]}"
DIR="${DIRS[$idx]}"
USER_NAME="${USERS[$idx]}"

# Safety: never delete anything that is not a real subfolder of a home directory.
if [[ -L "$DIR" || "$DIR" == "/" || "$(dirname -- "$DIR")" == "/" ]]; then
	printf 'Refusing to delete unsafe path: %s\n' "$DIR" >&2
	exit 1
fi

printf '\nSelected: %s\nThis will PERMANENTLY delete: %s\n' "$NAME" "$DIR"

# First confirmation.
read -r -p 'Really delete this folder? [y/N] ' answer
case "$answer" in
	[yY]|[yY][eE][sS]) ;;
	*) printf 'Aborted.\n'; exit 0 ;;
esac

# Second confirmation: type the server name.
read -r -p "Confirm again by typing the server name ($NAME): " typed
if [[ "$typed" != "$NAME" ]]; then
	printf 'Name does not match. Aborted.\n'
	exit 0
fi

UGSM_COPY="$DIR/ugsm"
SERVER_CONFIG="${CONF_FILES[$idx]}"
UFW_BIN="/usr/sbin/ufw"
GAME_PORT="$(read_setting "$SERVER_CONFIG" GAME_PORT)"
RCON_PORT="$(read_setting "$SERVER_CONFIG" RCON_PORT)"
STEAM_QUERY_PORT="$(read_setting "$SERVER_CONFIG" STEAM_QUERY_PORT)"
for port in "$GAME_PORT" "$RCON_PORT" "$STEAM_QUERY_PORT"; do
	if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
		printf 'Refusing deletion because the server has an invalid port configuration.\n' >&2
		exit 1
	fi
done

# Stop the scheduler first so it cannot restart the server during deletion.
if [[ -x "$UGSM_COPY/scripts/scheduler.sh" ]]; then
	runuser -u "$USER_NAME" -- /bin/bash "$UGSM_COPY/scripts/scheduler.sh" stop \
		|| printf 'Warning: the scheduler could not be stopped cleanly.\n' >&2
fi

AUTOSTART_ID="$(printf '%s\0%s' "$USER_NAME" "$NAME" | sha256sum | cut -c1-32)"
AUTOSTART_DIR="/etc/ugsm-scheduler-autostart/$USER_NAME/$NAME"
AUTOSTART_HELPER="$AUTOSTART_DIR/scheduler-autostart"
if [[ -x "$AUTOSTART_HELPER" ]]; then
	"$AUTOSTART_HELPER" uninstall \
		|| printf 'Warning: scheduler autostart could not be uninstalled.\n' >&2
fi

if [[ -x "$UGSM_COPY/scripts/stop.sh" ]]; then
	if ! runuser -u "$USER_NAME" -- /bin/bash "$UGSM_COPY/scripts/stop.sh"; then
		printf 'Server could not be stopped; deletion was cancelled to avoid deleting a running instance.\n' >&2
		exit 1
	fi
elif command -v tmux >/dev/null 2>&1 \
	&& runuser -u "$USER_NAME" -- tmux has-session -t "=$NAME" 2>/dev/null; then
	printf 'The stop script is missing while server tmux session "%s" is running; deletion cancelled.\n' "$NAME" >&2
	exit 1
fi

if [[ -x "$UFW_BIN" ]]; then
	for port in "$((10#$GAME_PORT))" "$((10#$RCON_PORT))" "$((10#$STEAM_QUERY_PORT))"; do
		"$UFW_BIN" delete allow "$port/udp" >/dev/null 2>&1 \
			|| printf 'Warning: could not remove UFW allow rule for UDP port %s.\n' "$port" >&2
	done
fi

rm -rf --one-file-system -- "$DIR"
printf 'Deleted: %s\n' "$DIR"

read -r -p "Also delete the config ${CONF_FILES[$idx]##*/}? [y/N] " answer
CONFIG_DELETED=0
case "$answer" in
	[yY]|[yY][eE][sS])
		rm -- "${CONF_FILES[$idx]}"
		CONFIG_DELETED=1
		printf 'Config deleted.\n'
		;;
esac

FIREWALL_ID="$(printf '%s\0%s' "$USER_NAME" "$NAME" | sha256sum | cut -c1-32)"
rm -f -- "/etc/sudoers.d/ugsm-ufw-$FIREWALL_ID" \
	"/etc/sudoers.d/ugsm-scheduler-$AUTOSTART_ID"
LEGACY_UFW_SUDOERS="/etc/sudoers.d/ugsm-${USER_NAME}-ufw"
if [[ -f "$LEGACY_UFW_SUDOERS" && ! -L "$LEGACY_UFW_SUDOERS" ]] \
	&& [[ "$(stat -c '%u:%a' "$LEGACY_UFW_SUDOERS")" == '0:440' ]]; then
	LEGACY_RULE="$USER_NAME ALL=(root) NOPASSWD: "
	for port in "$((10#$GAME_PORT))" "$((10#$RCON_PORT))" "$((10#$STEAM_QUERY_PORT))"; do
		LEGACY_RULE+=" $UFW_BIN allow $port/udp, $UFW_BIN delete allow $port/udp,"
	done
	if printf '%s\n' "${LEGACY_RULE%,}" | cmp -s - "$LEGACY_UFW_SUDOERS"; then
		rm -- "$LEGACY_UFW_SUDOERS"
	fi
fi
rm -f -- "$AUTOSTART_DIR/settings" "$AUTOSTART_DIR/scheduler-autostart"
rmdir -- "$AUTOSTART_DIR" 2>/dev/null || true
rmdir -- "/etc/ugsm-scheduler-autostart/$USER_NAME" 2>/dev/null || true
rmdir -- "/etc/ugsm-scheduler-autostart" 2>/dev/null || true

# Host reboot permission is shared by all instances of a Linux user.
USER_STILL_HAS_SERVER=0
for config in "$SCRIPT_DIR"/*_server.conf; do
	[[ -f "$config" ]] || continue
	[[ "$CONFIG_DELETED" -eq 1 && "$config" == "$SERVER_CONFIG" ]] && continue
	[[ "$(read_setting "$config" NEW_USER)" == "$USER_NAME" ]] && USER_STILL_HAS_SERVER=1
done
if (( ! USER_STILL_HAS_SERVER )); then
	rm -f -- "/etc/sudoers.d/ugsm-${USER_NAME}-reboot"
fi
