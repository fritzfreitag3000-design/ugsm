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

rm -rf --one-file-system -- "$DIR"
printf 'Deleted: %s\n' "$DIR"

read -r -p "Also delete the config ${CONF_FILES[$idx]##*/}? [y/N] " answer
case "$answer" in
	[yY]|[yY][eE][sS]) rm -- "${CONF_FILES[$idx]}"; printf 'Config deleted.\n' ;;
esac
