#!/usr/bin/env bash
set -euo pipefail

# Copies the current ugsm project folder into the server user's server folder
# (<home>/<server name>/ugsm) to test changes. Run as root, e.g. with sudo.
# Usage: sync.sh [server name]
# Without an argument the single install/*_server.conf file is used.

if [[ "$#" -gt 1 ]]; then
	printf 'Usage: %s [server name]\n' "$0" >&2
	exit 2
fi
if [[ "$EUID" -ne 0 ]]; then
	printf 'Run this script as root (sudo).\n' >&2
	exit 1
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
INSTALL_DIRECTORY="$PROJECT_ROOT/install"

# Pick the server settings file.
if [[ "$#" -eq 1 ]]; then
	SERVER_CONFIG="$INSTALL_DIRECTORY/$1_server.conf"
else
	CONFIGS=()
	for config in "$INSTALL_DIRECTORY"/*_server.conf; do
		[[ -f "$config" && "$(basename -- "$config")" != "default_server.conf" ]] && CONFIGS+=("$config")
	done
	if (( ${#CONFIGS[@]} != 1 )); then
		printf 'Found %s server configs in %s. Pass the server name as argument.\n' "${#CONFIGS[@]}" "$INSTALL_DIRECTORY" >&2
		exit 1
	fi
	SERVER_CONFIG="${CONFIGS[0]}"
fi
if [[ ! -r "$SERVER_CONFIG" ]]; then
	printf 'Server config is missing or unreadable: %s\n' "$SERVER_CONFIG" >&2
	exit 1
fi

# Read settings without executing the configuration file.
read_setting() {
	awk -v key="$1" '
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
		print value
		exit
	}' "$SERVER_CONFIG"
}

NEW_USER="$(read_setting NEW_USER)"
SERVER_NAME="$(read_setting SERVER_NAME)"
if [[ -z "$NEW_USER" || ! "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	printf 'Invalid or missing NEW_USER or SERVER_NAME in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi

USER_HOME="$(getent passwd "$NEW_USER" | awk -F: '{ print $6 }')"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
	printf 'Could not find the home directory for %s.\n' "$NEW_USER" >&2
	exit 1
fi
USER_GROUP="$(id -gn "$NEW_USER")"
SERVER_DIRECTORY="$USER_HOME/$SERVER_NAME"
UGSM_COPY="$SERVER_DIRECTORY/ugsm"
if [[ ! -d "$SERVER_DIRECTORY" ]]; then
	printf 'Server folder does not exist yet: %s (run the installer first).\n' "$SERVER_DIRECTORY" >&2
	exit 1
fi

# Overwrite the copy; files that only exist in the copy are kept.
mkdir -p -- "$UGSM_COPY"
cp -a -- "$PROJECT_ROOT/." "$UGSM_COPY/"
chown -R -- "$NEW_USER:$USER_GROUP" "$UGSM_COPY"
printf 'Copied %s to %s for user %s.\n' "$PROJECT_ROOT" "$UGSM_COPY" "$NEW_USER"
