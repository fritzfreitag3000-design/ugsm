#!/usr/bin/env bash
set -euo pipefail

# The main installer passes the server folder, SteamCMD user, and settings file.
if [[ "$#" -ne 3 || -z "$1" || -z "$2" || -z "$3" ]]; then
	printf 'Usage: %s <server directory> <SteamCMD username> <server config>\n' "$0" >&2
	exit 2
fi

SERVER_DIRECTORY="$1"
STEAM_USER="$2"
SERVER_CONFIG="$3"
STEAMCMD_DIRECTORY="$SERVER_DIRECTORY/steam"
SERVERDATA_DIRECTORY="$SERVER_DIRECTORY/serverdata"
 BATTLEYE_DIRECTORY="$SERVERDATA_DIRECTORY/battleye"
 BATTLEYE_CONFIG="$BATTLEYE_DIRECTORY/beserver_x64.cfg"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
DAYZ_SERVER_APP_ID="223350"

# Make sure the SteamCMD and server folders are available to this user.
if [[ ! -d "$SERVER_DIRECTORY" || ! -w "$SERVER_DIRECTORY" || ! -d "$SERVERDATA_DIRECTORY" || ! -w "$SERVERDATA_DIRECTORY" ]]; then
	printf 'Server or serverdata directory is missing or not writable.\n' >&2
	exit 1
fi
if [[ ! -r "$SERVER_CONFIG" ]]; then
	printf 'Server config is missing or unreadable: %s\n' "$SERVER_CONFIG" >&2
	exit 1
fi

# Read settings without executing the server configuration file.
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

RCON_PORT="$(read_setting RCON_PORT)"
RCON_PASS="$(read_setting RCON_PASS)"
if [[ ! "$RCON_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$RCON_PORT < 1 || 10#$RCON_PORT > 65535 )); then
	printf 'Invalid or missing RCON_PORT in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi
RCON_PORT="$((10#$RCON_PORT))"
if [[ -z "$RCON_PASS" || "$RCON_PASS" =~ [[:space:]] ]]; then
	printf 'RCON_PASS must be set and must not contain whitespace in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi

mkdir -p -- "$STEAMCMD_DIRECTORY"

# Download and extract SteamCMD when it is not installed yet.
if [[ ! -x "$STEAMCMD_DIRECTORY/steamcmd.sh" ]]; then
	TEMP_ARCHIVE="$(mktemp)"
	trap 'rm -f -- "$TEMP_ARCHIVE"' EXIT
	printf 'Downloading SteamCMD to %s.\n' "$STEAMCMD_DIRECTORY"
	curl --fail --location --silent --show-error --retry 3 \
		--output "$TEMP_ARCHIVE" "$STEAMCMD_URL"
	tar -xzf "$TEMP_ARCHIVE" -C "$STEAMCMD_DIRECTORY"
	rm -- "$TEMP_ARCHIVE"
	trap - EXIT
fi

# Run SteamCMD once so it can download and install its updates.
if [[ ! -x "$STEAMCMD_DIRECTORY/steamcmd.sh" ]]; then
	printf 'SteamCMD was not found after extraction.\n' >&2
	exit 1
fi
printf 'Initializing SteamCMD.\n'
(cd -- "$STEAMCMD_DIRECTORY" && ./steamcmd.sh +quit)
printf 'SteamCMD is ready in %s.\n' "$STEAMCMD_DIRECTORY"

# Download and validate the DayZ server files into serverdata.
if [[ "$STEAM_USER" != "anonymous" ]]; then
	printf 'SteamCMD may ask for the account password and Steam Guard code. Enter them at the prompt.\n'
fi
printf 'Installing DayZ server files into %s.\n' "$SERVERDATA_DIRECTORY"
(
	cd -- "$STEAMCMD_DIRECTORY"
	./steamcmd.sh \
		+force_install_dir "$SERVERDATA_DIRECTORY" \
		+login "$STEAM_USER" \
		+app_update "$DAYZ_SERVER_APP_ID" validate \
		+quit
)
printf 'DayZ server files are ready in %s.\n' "$SERVERDATA_DIRECTORY"

# Create the BattlEye RCON settings using the configured port and password.
mkdir -p -- "$BATTLEYE_DIRECTORY"
umask 077
printf 'RConPassword %s\nRConPort %s\n' "$RCON_PASS" "$RCON_PORT" > "$BATTLEYE_CONFIG"
chmod 0600 "$BATTLEYE_CONFIG"
printf 'Created BattlEye config at %s.\n' "$BATTLEYE_CONFIG"

#dayzcfg  ersetzen
