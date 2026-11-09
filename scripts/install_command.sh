#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
	printf 'This script must be run as root. Try: sudo %s\n' "$0" >&2
	exit 1
fi

if (( $# > 1 )); then
	printf 'Usage: %s [project-directory]\n' "$0" >&2
	exit 2
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIRECTORY_INPUT="${1:-$SCRIPT_DIRECTORY/..}"
if ! PROJECT_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY_INPUT" && pwd -P)"; then
	printf 'UGSM project directory does not exist: %s\n' "$PROJECT_DIRECTORY_INPUT" >&2
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

SERVER_NAME=""
SERVER_CONFIG=""
shopt -s nullglob
SERVER_CONFIGS=("$PROJECT_DIRECTORY"/install/*_server.conf)
shopt -u nullglob
for config in "${SERVER_CONFIGS[@]}"; do
	config_name="$(read_setting "$config" SERVER_NAME)"
	if [[ ! "$config_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		continue
	fi
	if [[ "$(basename -- "$config")" != "${config_name}_server.conf" ]]; then
		continue
	fi
	if [[ -n "$SERVER_CONFIG" ]]; then
		printf 'Multiple matching server configs found in %s/install.\n' "$PROJECT_DIRECTORY" >&2
		exit 1
	fi
	SERVER_NAME="$config_name"
	SERVER_CONFIG="$config"
done

if [[ -z "$SERVER_CONFIG" ]]; then
	printf 'Could not find a matching install/<SERVER_NAME>_server.conf in %s.\n' "$PROJECT_DIRECTORY" >&2
	exit 1
fi
if [[ ! -x "$PROJECT_DIRECTORY/scripts/dashboard.sh" ]]; then
	printf 'Dashboard script is missing or not executable: %s\n' "$PROJECT_DIRECTORY/scripts/dashboard.sh" >&2
	exit 1
fi
if [[ ! -x "$SCRIPT_DIRECTORY/ugsm" ]]; then
	printf 'UGSM command script is missing or not executable: %s\n' "$SCRIPT_DIRECTORY/ugsm" >&2
	exit 1
fi

REGISTRY_ROOT="/etc/ugsm"
REGISTRY_DIRECTORY="$REGISTRY_ROOT/servers"
REGISTRY_FILE="$REGISTRY_DIRECTORY/$SERVER_NAME"
for directory in "$REGISTRY_ROOT" "$REGISTRY_DIRECTORY"; do
	if [[ ! -e "$directory" && ! -L "$directory" ]]; then
		mkdir -m 0755 -- "$directory"
	fi
	if [[ ! -d "$directory" || -L "$directory" ]] \
		|| [[ "$(stat -c '%u' "$directory")" != 0 ]] \
		|| (( (8#$(stat -c '%a' "$directory") & 8#022) != 0 )); then
		printf 'Unsafe UGSM registry directory: %s\n' "$directory" >&2
		exit 1
	fi
done

if [[ -e /usr/local/bin/ugsm || -L /usr/local/bin/ugsm ]]; then
	if [[ ! -f /usr/local/bin/ugsm || -L /usr/local/bin/ugsm ]] \
		|| ! grep -Fxq '# Managed by UGSM: dispatch to a registered server dashboard.' /usr/local/bin/ugsm; then
		printf 'Refusing to replace an unrelated command: /usr/local/bin/ugsm\n' >&2
		exit 1
	fi
fi

if [[ -e "$REGISTRY_FILE" || -L "$REGISTRY_FILE" ]]; then
	if [[ ! -f "$REGISTRY_FILE" || -L "$REGISTRY_FILE" ]] \
		|| [[ "$(stat -c '%u:%a' "$REGISTRY_FILE")" != '0:644' ]] \
		|| [[ "$(cat -- "$REGISTRY_FILE")" != "$PROJECT_DIRECTORY" ]]; then
		printf 'Server name is already registered to another UGSM installation: %s\n' "$SERVER_NAME" >&2
		exit 1
	fi
else
	TEMP_REGISTRY_FILE="$(mktemp "$REGISTRY_DIRECTORY/.${SERVER_NAME}.XXXXXX")"
	trap 'rm -f -- "$TEMP_REGISTRY_FILE"' EXIT
	printf '%s\n' "$PROJECT_DIRECTORY" > "$TEMP_REGISTRY_FILE"
	chmod 0644 "$TEMP_REGISTRY_FILE"
	if ! ln -- "$TEMP_REGISTRY_FILE" "$REGISTRY_FILE"; then
		printf 'Could not register UGSM server: %s\n' "$SERVER_NAME" >&2
		exit 1
	fi
	rm -- "$TEMP_REGISTRY_FILE"
	trap - EXIT
fi

install -o root -g root -m 0755 -- "$SCRIPT_DIRECTORY/ugsm" /usr/local/bin/ugsm
printf 'Run the dashboard from anywhere with: ugsm %s\n' "$SERVER_NAME"
