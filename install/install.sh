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
	util-linux
	nodejs
	npm
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

# bercon-cli is not available as an apt package; download the release binary (used by stop.sh).
if ! command -v bercon-cli >/dev/null 2>&1; then
	case "$(uname -m)" in
		x86_64|amd64) BERCON_ARCH="amd64" ;;
		aarch64|arm64) BERCON_ARCH="arm64" ;;
		*) printf 'Unsupported architecture for bercon-cli: %s\n' "$(uname -m)" >&2; exit 1 ;;
	esac
	BERCON_TEMP="$(mktemp)"
	printf 'Installing bercon-cli.\n'
	if ! curl -fsSL -o "$BERCON_TEMP" "https://github.com/WoozyMasta/bercon-cli/releases/latest/download/bercon-cli-linux-$BERCON_ARCH" \
		|| ! install -m 0755 -- "$BERCON_TEMP" /usr/local/bin/bercon-cli; then
		rm -f -- "$BERCON_TEMP"
		printf 'Could not install bercon-cli.\n' >&2
		exit 1
	fi
	rm -f -- "$BERCON_TEMP"
else
	printf 'bercon-cli is already installed.\n'
fi

# GameDig queries the Steam query port and prints the server status.
if ! command -v gamedig >/dev/null 2>&1; then
	printf 'Installing gamedig.\n'
	if ! npm install -g gamedig; then
		printf 'Could not install gamedig.\n' >&2
		exit 1
	fi
else
	printf 'gamedig is already installed.\n'
fi

# Set the paths for the source settings file and the install copy.
SOURCE_CONFIG="$PROJECT_ROOT/config/default_server.conf"
INSTALL_CONFIG="$SCRIPT_DIR/default_server.conf"
EXISTING_SERVER_CONFIGS=()
shopt -s nullglob
for config in "$SCRIPT_DIR"/*_server.conf; do
	if [[ -f "$config" && "$config" != "$INSTALL_CONFIG" ]]; then
		EXISTING_SERVER_CONFIGS+=("$config")
	fi
done
shopt -u nullglob

SELECTED_EXISTING_CONFIG=0
if [[ "${#EXISTING_SERVER_CONFIGS[@]}" -gt 0 ]]; then
	printf 'Existing server configurations:\n'
	for index in "${!EXISTING_SERVER_CONFIGS[@]}"; do
		printf '  %d) %s\n' "$((index + 1))" "$(basename -- "${EXISTING_SERVER_CONFIGS[$index]}")"
	done
	printf '  n) Create a new server configuration\n'
	while true; do
		read -r -p 'Select a configuration or enter n for a new one: ' CONFIG_CHOICE
		if [[ "${CONFIG_CHOICE,,}" == "n" ]]; then
			break
		fi
		if [[ "$CONFIG_CHOICE" =~ ^[0-9]+$ ]] && (( 10#$CONFIG_CHOICE >= 1 && 10#$CONFIG_CHOICE <= ${#EXISTING_SERVER_CONFIGS[@]} )); then
			INSTALL_CONFIG="${EXISTING_SERVER_CONFIGS[$((10#$CONFIG_CHOICE - 1))]}"
			SELECTED_EXISTING_CONFIG=1
			break
		fi
		printf 'Invalid selection. Choose a listed number or n.\n' >&2
	done
fi

if [[ "$SELECTED_EXISTING_CONFIG" -eq 1 ]]; then
	printf 'Using existing server configuration: %s\n' "$INSTALL_CONFIG"
else
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
				# Open the existing settings file for editing.
				if ! command -v nano >/dev/null 2>&1; then
					printf 'nano is required to edit the settings file. Install nano and try again.\n' >&2
					exit 1
				fi
				nano "$INSTALL_CONFIG"
				;;
		esac
	fi
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

# Write a quoted value for a setting into the settings file.
write_setting() {
	local tmp
	tmp="$(mktemp)"
	NEW_VALUE="$2" awk -v key="$1" '
	$0 ~ "^[[:space:]]*" key "[[:space:]]*=" && !done {
		print key "=\"" ENVIRON["NEW_VALUE"] "\""
		done = 1
		next
	}
	{ print }' "$INSTALL_CONFIG" > "$tmp"
	cat -- "$tmp" > "$INSTALL_CONFIG"
	rm -- "$tmp"
}

# Ask for one setting; Enter keeps the current value.
prompt_setting() {
	local key="$1" label="$2" secret="${3:-0}" current value confirm
	current="$(read_setting "$key")"
	while true; do
		if [[ "$secret" -eq 1 ]]; then
			read -r -s -p "$label [Enter keeps current]: " value
			printf '\n'
			if [[ -n "$value" ]]; then
				read -r -s -p "Repeat $label: " confirm
				printf '\n'
				if [[ "$value" != "$confirm" ]]; then
					printf 'Entries do not match. Try again.\n' >&2
					continue
				fi
			fi
		else
			read -r -p "$label [$current]: " value
		fi
		value="${value:-$current}"
		if [[ "$value" == *'"'* || "$value" == *'\'* ]]; then
			printf 'Quotes and backslashes are not allowed.\n' >&2
			continue
		fi
		break
	done
	write_setting "$key" "$value"
}

# Ask for the most important settings when a new configuration was just created.
if [[ "$SELECTED_EXISTING_CONFIG" -eq 0 ]]; then
	printf '\nEnter the main settings. Press Enter to keep the value in brackets.\n'
	prompt_setting NEW_USER 'Linux user name'
	prompt_setting SERVER_NAME 'Server name (folder/config name)'
	prompt_setting STEAM_USER 'Steam account user (empty or anonymous = SteamCMD prompts)'
	prompt_setting RCON_PASS 'RCON password' 1

	# Offer to edit the remaining (advanced) settings in nano.
	read -r -p 'Edit the advanced configuration (ports, IP, admin password) in nano? [y/N] ' EDIT_ANSWER
	case "$EDIT_ANSWER" in
		[yY]|[yY][eE][sS])
			if ! command -v nano >/dev/null 2>&1; then
				printf 'nano is required to edit the settings file. Install nano and try again.\n' >&2
				exit 1
			fi
			nano "$INSTALL_CONFIG"
			;;
	esac
fi

SERVER_NAME="$(read_setting SERVER_NAME)"

# Allow only safe characters in the server name used for the file name.
if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	printf 'Invalid or missing SERVER_NAME in %s.\n' "$INSTALL_CONFIG" >&2
	exit 1
fi

# Rename the settings file and never overwrite an existing server file.
RENAMED_CONFIG="$SCRIPT_DIR/${SERVER_NAME}_server.conf"
if [[ "$SELECTED_EXISTING_CONFIG" -eq 0 && "$INSTALL_CONFIG" != "$RENAMED_CONFIG" ]]; then
	if [[ -e "$RENAMED_CONFIG" ]]; then
		printf 'Cannot rename settings: target already exists: %s\n' "$RENAMED_CONFIG" >&2
		exit 1
	fi
	mv -- "$INSTALL_CONFIG" "$RENAMED_CONFIG"
	INSTALL_CONFIG="$RENAMED_CONFIG"
	printf 'Renamed settings file to: %s\n' "$INSTALL_CONFIG"
fi
if [[ "$INSTALL_CONFIG" == "$RENAMED_CONFIG" && -f "$RENAMED_CONFIG" && -f "$SCRIPT_DIR/default_server.conf" ]]; then
	rm -- "$SCRIPT_DIR/default_server.conf"
	printf 'Removed temporary settings file: %s/default_server.conf\n' "$SCRIPT_DIR"
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

# SteamCMD prompts for credentials when no account name is configured.
if [[ -n "$STEAM_USER" && "${STEAM_USER,,}" != "anonymous" && ( ! "$STEAM_USER" =~ ^[A-Za-z0-9_.-]+$ || "${#STEAM_USER}" -gt 64 ) ]]; then
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
TEMP_SUDOERS="$(mktemp "/etc/sudoers.d/.ugsm-${NEW_USER}-ufw.XXXXXX")"
trap 'rm -f -- "$TEMP_SUDOERS"' EXIT
SUDOERS_RULE="$NEW_USER ALL=(root) NOPASSWD: $UFW_BIN status verbose,"
LEGACY_SUDOERS_RULE="$NEW_USER ALL=(root) NOPASSWD:"
for port in "$GAME_PORT" "$RCON_PORT" "$STEAM_QUERY_PORT"; do
	SUDOERS_RULE+=" $UFW_BIN allow $port/udp, $UFW_BIN delete allow $port/udp,"
	LEGACY_SUDOERS_RULE+=" $UFW_BIN allow $port/udp, $UFW_BIN delete allow $port/udp,"
done
SUDOERS_RULE="${SUDOERS_RULE%,}"
LEGACY_SUDOERS_RULE="${LEGACY_SUDOERS_RULE%,}"
printf '%s\n' "$SUDOERS_RULE" > "$TEMP_SUDOERS"
chmod 0440 "$TEMP_SUDOERS"
if ! visudo -cf "$TEMP_SUDOERS"; then
	printf 'Generated sudoers rules are invalid.\n' >&2
	exit 1
fi
SUDOERS_ALREADY_INSTALLED=0
if [[ -e "$SUDOERS_FILE" || -L "$SUDOERS_FILE" ]]; then
	if [[ ! -f "$SUDOERS_FILE" || -L "$SUDOERS_FILE" ]] || [[ "$(stat -c '%u:%a' "$SUDOERS_FILE")" != '0:440' ]]; then
		printf 'Existing sudoers file does not match the configured rules: %s\n' "$SUDOERS_FILE" >&2
		exit 1
	fi
	if cmp -s -- "$TEMP_SUDOERS" "$SUDOERS_FILE"; then
		printf 'Matching sudoers rules already exist; skipping.\n'
	elif printf '%s\n' "$LEGACY_SUDOERS_RULE" | cmp -s - "$SUDOERS_FILE"; then
		install -o root -g root -m 0440 -- "$TEMP_SUDOERS" "$SUDOERS_FILE"
		printf 'Updated existing sudoers rules to allow read-only firewall status checks.\n'
	else
		printf 'Existing sudoers file does not match the configured rules: %s\n' "$SUDOERS_FILE" >&2
		exit 1
	fi
	rm -- "$TEMP_SUDOERS"
	trap - EXIT
	SUDOERS_ALREADY_INSTALLED=1
fi

# Create the user only when it does not exist yet; never reset an existing password.
if getent passwd "$NEW_USER" >/dev/null; then
	printf 'Linux user %s already exists; reusing the account.\n' "$NEW_USER"
else
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
fi

# Find the user's home directory and primary group.
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

# Install the validated sudo rules only when they were not already present.
if [[ "$SUDOERS_ALREADY_INSTALLED" -eq 0 ]]; then
	if ! mv -- "$TEMP_SUDOERS" "$SUDOERS_FILE"; then
		printf 'Could not install sudoers rules for %s.\n' "$NEW_USER" >&2
		exit 1
	fi
	trap - EXIT
	printf 'Granted %s permission to open and close only the configured UDP ports with sudo ufw.\n' "$NEW_USER"
fi

# Copy the project folder into the server folder and assign it to the new user.
UGSM_COPY="$SERVER_DIRECTORY/ugsm"
SERVER_CONFIG_NAME="$(basename -- "$INSTALL_CONFIG")"
if [[ -e "$UGSM_COPY" ]]; then
	if [[ ! -d "$UGSM_COPY" || ! -f "$UGSM_COPY/install/install_dayz.sh" || ! -r "$UGSM_COPY/install/$SERVER_CONFIG_NAME" ]]; then
		printf 'Existing project copy is incomplete or missing the selected server config: %s\n' "$UGSM_COPY" >&2
		exit 1
	fi
	if [[ "$(stat -c '%U:%G' "$UGSM_COPY")" != "$NEW_USER:$USER_GROUP" ]]; then
		chown -R -- "$NEW_USER:$USER_GROUP" "$UGSM_COPY"
	fi
	printf 'Project copy already exists; reusing it.\n'
else
	cp -a -- "$PROJECT_ROOT" "$UGSM_COPY"
	chown -R -- "$NEW_USER:$USER_GROUP" "$UGSM_COPY"
	printf 'Copied the ugsm folder to: %s\n' "$UGSM_COPY"
fi

# Run the copied DayZ installer as the new server user.
DAYZ_INSTALL_DIR="$UGSM_COPY/install"
printf 'Running the DayZ installer as %s.\n' "$NEW_USER"
if ! runuser --user "$NEW_USER" -- /bin/bash -lc \
	'cd -- "$1" && exec /bin/bash ./install_dayz.sh "$2" "$3" "$4"' _ "$DAYZ_INSTALL_DIR" "$SERVER_DIRECTORY" "$STEAM_USER" "$UGSM_COPY/install/$SERVER_CONFIG_NAME"; then
	printf 'DayZ installation failed for user %s.\n' "$NEW_USER" >&2
	exit 1
fi

# Show the project folder so the user can confirm the detected path.
printf 'Project directory: %s\n' "$PROJECT_ROOT"
# Tell the user that no install actions have been added yet.
printf 'Install steps are not configured yet.\n'