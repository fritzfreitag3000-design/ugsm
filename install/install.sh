#!/usr/bin/env bash
# Stop if a command fails, a variable is missing, or a command in a pipe fails.
set -euo pipefail

# Check that the script is running with root privileges.
if [[ "$EUID" -ne 0 ]]; then
	printf 'This script must be run as root. Try: sudo %s\n' "$0" >&2
	exit 1
fi

# Read the operating system details from the system release file.
if [[ ! -r /etc/os-release ]]; then
	printf 'Cannot identify the operating system: /etc/os-release is missing or unreadable.\n' >&2
	exit 1
fi
source /etc/os-release

# Continue only on Ubuntu 24.04.
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
	printf 'This installer requires Ubuntu 24.04. Detected: %s\n' "${PRETTY_NAME:-unknown OS}" >&2
	exit 1
fi

# Find the folder that contains this script.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The project root is the parent folder of the install folder.
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Enable i386 packages when the system does not support them yet.
APT_REFRESH_NEEDED=0
if ! dpkg --print-foreign-architectures | grep -Fxq 'i386'; then
	dpkg --add-architecture i386
	APT_REFRESH_NEEDED=1
fi

# List the packages required by the installer and the DayZ server.
REQUIRED_PACKAGES=(
	tmux
	nano
	htop
	lib32gcc-s1
	lib32stdc++6
	libc6:i386
	libstdc++6:i386
	curl
	wget
	tar
	bzip2
	gzip
	zip
	unzip
	python3
	software-properties-common
	rclone
	vsftpd
	openssl
	sudo
	ufw
)

# Collect packages that are not installed yet.
MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
	if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx 'installed'; then
		MISSING_PACKAGES+=("$package")
	fi
done

# Refresh package lists when needed and install only missing packages.
if [[ "$APT_REFRESH_NEEDED" -eq 1 || "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
	apt-get update
fi
if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
	printf 'Installing missing packages: %s\n' "${MISSING_PACKAGES[*]}"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}"
else
	printf 'All required packages are already installed.\n'
fi

# Set the paths for the source settings file and the install copy.
SOURCE_CONFIG="$PROJECT_ROOT/config/default_server.conf"
INSTALL_CONFIG="$SCRIPT_DIR/default_server.conf"

# Copy the settings file when no install copy exists yet.
if [[ ! -f "$INSTALL_CONFIG" ]]; then
	if [[ ! -f "$SOURCE_CONFIG" ]]; then
		printf 'Settings file not found: %s\n' "$SOURCE_CONFIG" >&2
		exit 1
	fi
	cp -- "$SOURCE_CONFIG" "$INSTALL_CONFIG"
	printf 'Copied settings to: %s\n' "$INSTALL_CONFIG"
else
	# Ask whether to abort and remove the existing install copy.
	read -r -p 'Settings file already exists. Abort and delete it? [y/N] ' answer
	case "$answer" in
		[yY]|[yY][eE][sS])
			rm -- "$INSTALL_CONFIG"
			printf 'Settings file deleted. Installation aborted.\n'
			exit 1
			;;
		*)
			# Open the existing settings file in nano for editing.
			if ! command -v nano >/dev/null 2>&1; then
				printf 'nano is required to edit the settings file. Install nano and try again.\n' >&2
				exit 1
			fi
			nano "$INSTALL_CONFIG"
			;;
	esac
fi

# Read the server name from the settings file without executing it.
if [[ ! -f "$INSTALL_CONFIG" ]]; then
	printf 'Settings file not found: %s\n' "$INSTALL_CONFIG" >&2
	exit 1
fi

# Read settings without executing the configuration file.
read_setting() {
	awk -F= -v key="$1" '
	$1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
		value = $2
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
		gsub(/^"|"$/, "", value)
		print value
		exit
	}' "$INSTALL_CONFIG"
}

SERVER_NAME="$(read_setting SERVER_NAME)"

# Allow only safe characters in the server name used for the file name.
if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	printf 'Invalid or missing SERVER_NAME in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
fi

# Rename the settings file and never overwrite an existing server file.
RENAMED_CONFIG="$SCRIPT_DIR/${SERVER_NAME}_server.conf"
if [[ "$INSTALL_CONFIG" != "$RENAMED_CONFIG" ]]; then
	if [[ -e "$RENAMED_CONFIG" ]]; then
		printf 'Cannot rename settings: target already exists: %s\n' "$RENAMED_CONFIG" >&2
		exit 1
	fi
	mv -- "$INSTALL_CONFIG" "$RENAMED_CONFIG"
	INSTALL_CONFIG="$RENAMED_CONFIG"
	printf 'Renamed settings file to: %s\n' "$INSTALL_CONFIG"
fi

# Read the user name and UDP ports from the renamed settings file.
NEW_USER="$(read_setting NEW_USER)"
GAME_PORT="$(read_setting GAME_PORT)"
RCON_PORT="$(read_setting RCON_PORT)"
STEAM_QUERY_PORT="$(read_setting STEAM_QUERY_PORT)"
STEAM_USER="$(read_setting STEAM_USER)"

# Check that the configured name is a valid Linux user name.
if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || [[ "${#NEW_USER}" -gt 32 ]]; then
	printf 'Invalid or missing NEW_USER in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
fi

# Ask for a SteamCMD user name when none is set in the configuration.
if [[ -z "$STEAM_USER" ]]; then
	read -r -p 'SteamCMD username [anonymous]: ' STEAM_USER
	STEAM_USER="${STEAM_USER:-anonymous}"
fi
if [[ ! "$STEAM_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ "${#STEAM_USER}" -gt 64 ]]; then
	printf 'Invalid SteamCMD username in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
fi

# Check that each configured port is a valid UDP port number.
normalize_port() {
	local port="$1"
	if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
		return 1
	fi
	printf '%d' "$((10#$port))"
}

GAME_PORT="$(normalize_port "$GAME_PORT")" || {
	printf 'Invalid or missing GAME_PORT in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
}
RCON_PORT="$(normalize_port "$RCON_PORT")" || {
	printf 'Invalid or missing RCON_PORT in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
}
STEAM_QUERY_PORT="$(normalize_port "$STEAM_QUERY_PORT")" || {
	printf 'Invalid or missing STEAM_QUERY_PORT in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
}
if [[ "$GAME_PORT" == "$RCON_PORT" || "$GAME_PORT" == "$STEAM_QUERY_PORT" || "$RCON_PORT" == "$STEAM_QUERY_PORT" ]]; then
	printf 'GAME_PORT, RCON_PORT, and STEAM_QUERY_PORT must be different.\n' >&2
	exit 1
fi

# Prepare exact sudo rules for the configured UDP ports only.
UFW_BIN="/usr/sbin/ufw"
SUDOERS_FILE="/etc/sudoers.d/ugsm-${NEW_USER}-ufw"
if [[ ! -x "$UFW_BIN" ]]; then
	printf 'UFW was not found at %s.\n' "$UFW_BIN" >&2
	exit 1
fi
if [[ -e "$SUDOERS_FILE" ]]; then
	printf 'Sudoers file already exists: %s\n' "$SUDOERS_FILE" >&2
	exit 1
fi
TEMP_SUDOERS="$(mktemp "/etc/sudoers.d/.ugsm-${NEW_USER}-ufw.XXXXXX")"
trap 'rm -f -- "$TEMP_SUDOERS"' EXIT
SUDOERS_RULE="$NEW_USER ALL=(root) NOPASSWD:"
for port in "$GAME_PORT" "$RCON_PORT" "$STEAM_QUERY_PORT"; do
	SUDOERS_RULE+=" $UFW_BIN allow $port/udp, $UFW_BIN delete allow $port/udp,"
done
SUDOERS_RULE="${SUDOERS_RULE%,}"
printf '%s\n' "$SUDOERS_RULE" > "$TEMP_SUDOERS"
chmod 0440 "$TEMP_SUDOERS"
if ! visudo -cf "$TEMP_SUDOERS"; then
	printf 'Generated sudoers rules are invalid.\n' >&2
	exit 1
fi

# Do not change the password of an account that already exists.
if getent passwd "$NEW_USER" >/dev/null; then
	printf 'User %s already exists. Refusing to change its password.\n' "$NEW_USER" >&2
	exit 1
fi

# Create the user and tell passwd to ask for the password twice.
if ! useradd --user-group --create-home --shell /bin/bash "$NEW_USER"; then
	printf 'Could not create user %s.\n' "$NEW_USER" >&2
	exit 1
fi
printf 'Set the password for %s. You will be asked to enter it twice.\n' "$NEW_USER"
if ! passwd "$NEW_USER"; then
	if userdel --remove "$NEW_USER"; then
		printf 'Password setup failed. The new user account was removed.\n' >&2
	else
		printf 'Password setup failed. The new user account could not be removed.\n' >&2
	fi
	exit 1
fi
printf 'Created Linux user: %s\n' "$NEW_USER"

# Find the new user's home directory and primary group.
USER_HOME="$(getent passwd "$NEW_USER" | awk -F: '{ print $6 }')"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
	printf 'Could not find the home directory for %s.\n' "$NEW_USER" >&2
	exit 1
fi
USER_GROUP="$(id -gn "$NEW_USER")"
SERVER_DIRECTORY="$USER_HOME/$SERVER_NAME"

# Create the server folder and its required subfolders for the new user.
install -d -o "$NEW_USER" -g "$USER_GROUP" -m 0750 \
	"$SERVER_DIRECTORY" \
	"$SERVER_DIRECTORY/steam" \
	"$SERVER_DIRECTORY/serverdata"
printf 'Created server directories under: %s\n' "$SERVER_DIRECTORY"

# Install the validated sudo rules for this user's configured ports.
if ! mv -- "$TEMP_SUDOERS" "$SUDOERS_FILE"; then
	printf 'Could not install sudoers rules for %s.\n' "$NEW_USER" >&2
	exit 1
fi
trap - EXIT
printf 'Granted %s permission to open and close only the configured UDP ports with sudo ufw.\n' "$NEW_USER"

# Copy the project folder into the server folder and assign it to the new user.
UGSM_COPY="$SERVER_DIRECTORY/ugsm"
if [[ -e "$UGSM_COPY" ]]; then
	printf 'Project copy already exists: %s\n' "$UGSM_COPY" >&2
	exit 1
fi
cp -a -- "$PROJECT_ROOT" "$UGSM_COPY"
chown -R -- "$NEW_USER:$USER_GROUP" "$UGSM_COPY"
printf 'Copied the ugsm folder to: %s\n' "$UGSM_COPY"

# Run the copied DayZ installer as the new server user.
DAYZ_INSTALL_DIR="$UGSM_COPY/install"
printf 'Running the DayZ installer as %s.\n' "$NEW_USER"
if ! runuser --user "$NEW_USER" -- /bin/bash -lc \
	'cd -- "$1" && exec /bin/bash ./install_dayz.sh "$2" "$3" "$4"' _ "$DAYZ_INSTALL_DIR" "$SERVER_DIRECTORY" "$STEAM_USER" "$UGSM_COPY/install/${SERVER_NAME}_server.conf"; then
	printf 'DayZ installation failed for user %s.\n' "$NEW_USER" >&2
	exit 1
fi

# Show the project folder so the user can confirm the detected path.
printf 'Project directory: %s\n' "$PROJECT_ROOT"
# Tell the user that no install actions have been added yet.
printf 'Install steps are not configured yet.\n'