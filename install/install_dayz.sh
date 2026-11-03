#!/usr/bin/env bash
set -euo pipefail

# The main installer passes the server folder and SteamCMD user name.
if [[ "$#" -ne 2 || -z "$1" || -z "$2" ]]; then
	printf 'Usage: %s <server directory> <SteamCMD username>\n' "$0" >&2
	exit 2
fi

SERVER_DIRECTORY="$1"
STEAM_USER="$2"
STEAMCMD_DIRECTORY="$SERVER_DIRECTORY/steam"
SERVERDATA_DIRECTORY="$SERVER_DIRECTORY/serverdata"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
DAYZ_SERVER_APP_ID="223350"

# Make sure the SteamCMD and server folders are available to this user.
if [[ ! -d "$SERVER_DIRECTORY" || ! -w "$SERVER_DIRECTORY" || ! -d "$SERVERDATA_DIRECTORY" || ! -w "$SERVERDATA_DIRECTORY" ]]; then
	printf 'Server or serverdata directory is missing or not writable.\n' >&2
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
