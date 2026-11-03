#!/usr/bin/env bash
set -euo pipefail

# The main installer passes the server folder, SteamCMD user, and settings file.
if [[ "$#" -ne 3 || -z "$1" || -z "$3" ]]; then
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
GAME_PORT="$(read_setting GAME_PORT)"
SERVER_IP="$(read_setting SERVER_IP)"
if [[ ! "$RCON_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$RCON_PORT < 1 || 10#$RCON_PORT > 65535 )); then
	printf 'Invalid or missing RCON_PORT in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi
RCON_PORT="$((10#$RCON_PORT))"
if [[ ! "$GAME_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$GAME_PORT < 1 || 10#$GAME_PORT > 65535 )); then
	printf 'Invalid or missing GAME_PORT in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi
GAME_PORT="$((10#$GAME_PORT))"
if [[ -z "$SERVER_IP" ]] || ! python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$SERVER_IP" >/dev/null 2>&1; then
	printf 'Invalid or missing SERVER_IP in %s.\n' "$SERVER_CONFIG" >&2
	exit 1
fi
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
STEAM_LOGIN_ARGS=(+login)
if [[ -n "$STEAM_USER" && "${STEAM_USER,,}" != "anonymous" ]]; then
	printf 'SteamCMD may ask for the account password and Steam Guard code. Enter them at the prompt.\n'
	STEAM_LOGIN_ARGS+=("$STEAM_USER")
else
	printf 'SteamCMD will prompt for the login credentials.\n'
fi
printf 'Installing DayZ server files into %s.\n' "$SERVERDATA_DIRECTORY"
(
	cd -- "$STEAMCMD_DIRECTORY"
	./steamcmd.sh \
		+force_install_dir "$SERVERDATA_DIRECTORY" \
		"${STEAM_LOGIN_ARGS[@]}" \
		+app_update "$DAYZ_SERVER_APP_ID" validate \
		+quit
)
printf 'DayZ server files are ready in %s.\n' "$SERVERDATA_DIRECTORY"

# Find the default server configuration in the copied project folder.
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
DEFAULT_SERVER_CONFIG="$PROJECT_DIRECTORY/config/default_serverDZ.cfg"

# Replace serverDZ.cfg with the project template.
if [[ ! -f "$DEFAULT_SERVER_CONFIG" ]]; then
	printf 'Default server config was not found: %s\n' "$DEFAULT_SERVER_CONFIG" >&2
	exit 1
fi
cp -- "$DEFAULT_SERVER_CONFIG" "$SERVERDATA_DIRECTORY/serverDZ.cfg"
printf 'Installed server config at %s/serverDZ.cfg.\n' "$SERVERDATA_DIRECTORY"

# Create the BattlEye RCON settings using the configured port and password.
mkdir -p -- "$BATTLEYE_DIRECTORY"
umask 077
printf 'RConPassword %s\nRConPort %s\n' "$RCON_PASS" "$RCON_PORT" > "$BATTLEYE_CONFIG"
chmod 0600 "$BATTLEYE_CONFIG"
printf 'Created BattlEye config at %s.\n' "$BATTLEYE_CONFIG"

# Prepare the profile folder used by the example start command.
mkdir -p -- "$SERVERDATA_DIRECTORY/profiles"

# Show a clear completion message and a command for a manual test start.
printf '\n'
printf '==================================================\n'
printf '       DAYZ SERVER INSTALLATION COMPLETE\n'
printf '==================================================\n'
printf 'Example test command (run as the server user):\n'
printf 'cd %q && ./DayZServer -config=serverDZ.cfg -ip=%s -port=%s -profiles=profiles -BEpath=battleye -dologs -adminlog -netlog\n' \
	"$SERVERDATA_DIRECTORY" "$SERVER_IP" "$GAME_PORT"
