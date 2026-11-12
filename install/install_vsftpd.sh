#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
	printf 'Run this script as root: sudo %s\n' "$0" >&2
	exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS=()
shopt -s nullglob
for config in "$SCRIPT_DIR"/*_server.conf; do
	[[ -f "$config" ]] && CONFIGS+=("$config")
done
shopt -u nullglob
if (( ${#CONFIGS[@]} == 0 )); then
	printf 'No *_server.conf files found in %s.\n' "$SCRIPT_DIR" >&2
	exit 1
fi
if (( ${#CONFIGS[@]} == 1 )); then
	SELECTED_CONFIG="${CONFIGS[0]}"
else
	printf 'Select a server configuration:\n'
	for index in "${!CONFIGS[@]}"; do
		printf '  %d) %s\n' "$((index + 1))" "${CONFIGS[$index]##*/}"
	done
	while true; do
		read -r -p 'Number (or q to cancel): ' choice
		[[ "${choice,,}" == q ]] && exit 0
		if [[ "$choice" =~ ^[0-9]{1,6}$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#CONFIGS[@]} )); then
			SELECTED_CONFIG="${CONFIGS[$((10#$choice - 1))]}"
			break
		fi
		printf 'Invalid selection.\n' >&2
	done
fi

USER_NAME="$(awk -F= '
	$1 ~ /^[[:space:]]*NEW_USER[[:space:]]*$/ {
		value = $2
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
		gsub(/^"|"$/, "", value)
		print value
		exit
	}' "$SELECTED_CONFIG")"
if [[ ! "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || (( ${#USER_NAME} > 32 )); then
	printf 'Invalid NEW_USER in %s.\n' "$SELECTED_CONFIG" >&2
	exit 1
fi
if ! USER_ENTRY="$(getent passwd "$USER_NAME")"; then
	printf 'Linux user %s does not exist. Run the server installer first.\n' "$USER_NAME" >&2
	exit 1
fi
IFS=: read -r _ _ USER_ID _ _ USER_HOME _ <<< "$USER_ENTRY"
if [[ ! "$USER_ID" =~ ^[0-9]+$ ]] || (( USER_ID < 1000 )) || [[ ! -d "$USER_HOME" || -L "$USER_HOME" ]]; then
	printf 'Refusing system user or invalid home directory for %s.\n' "$USER_NAME" >&2
	exit 1
fi
USER_HOME="$(realpath -e -- "$USER_HOME")"
if [[ ! "$USER_HOME" =~ ^/home/[a-zA-Z0-9._/-]+$ || "$USER_HOME" == /home || "$(stat -c %u -- "$USER_HOME")" != "$USER_ID" ]]; then
	printf 'Home must be a user-owned directory below /home: %s\n' "$USER_HOME" >&2
	exit 1
fi

printf 'FTP user: %s\nHome: %s\n' "$USER_NAME" "$USER_HOME"
printf 'FTPS uses the existing Linux password and exposes the home directory as /home.\n'
printf 'The global vsftpd configuration will be replaced; existing FTP users may lose access.\n'
read -r -p 'Continue? [y/N] ' answer
case "$answer" in
	[yY]|[yY][eE][sS]) ;;
	*) printf 'Cancelled.\n'; exit 0 ;;
esac

CURRENT_PASV_ADDRESS=""
if [[ -f /etc/vsftpd.conf && ! -L /etc/vsftpd.conf ]] \
	&& grep -Fxq '# Managed by UGSM install_vsftpd.sh' /etc/vsftpd.conf; then
	CURRENT_PASV_ADDRESS="$(awk -F= '$1 == "pasv_address" { print $2; exit }' /etc/vsftpd.conf)"
fi
read -r -p "Public IPv4 for passive FTP [${CURRENT_PASV_ADDRESS:-none}; - clears]: " PASV_ADDRESS
if [[ "$PASV_ADDRESS" == "-" ]]; then
	PASV_ADDRESS=""
else
	PASV_ADDRESS="${PASV_ADDRESS:-$CURRENT_PASV_ADDRESS}"
fi
if ! command -v vsftpd >/dev/null 2>&1; then
	printf 'Installing vsftpd.\n'
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vsftpd
fi
for command in openssl systemctl systemd-escape findmnt realpath python3; do
	if ! command -v "$command" >/dev/null 2>&1; then
		printf 'Required command is missing: %s\n' "$command" >&2
		exit 1
	fi
done
if [[ -n "$PASV_ADDRESS" ]] && ! python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$PASV_ADDRESS" >/dev/null 2>&1; then
	printf 'Invalid IPv4 address: %s\n' "$PASV_ADDRESS" >&2
	exit 1
fi

BASE="/var/lib/ugsm-vsftpd"
JAIL="$BASE/jails/$USER_NAME"
MOUNT_POINT="$JAIL/home"
ALLOWLIST="$BASE/users"
CERTIFICATE="$BASE/ftps-cert.pem"
KEY="$BASE/ftps-key.pem"
SERVICE_DROPIN="/etc/systemd/system/vsftpd.service.d"
MOUNT_UNIT="$(systemd-escape --path --suffix=mount "$MOUNT_POINT")"
MOUNT_FILE="/etc/systemd/system/$MOUNT_UNIT"
DROPIN_FILE="$SERVICE_DROPIN/ugsm-$USER_NAME.conf"

secure_directory() {
	local directory="$1" permissions
	if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
		printf 'Unsafe directory: %s\n' "$directory" >&2
		exit 1
	fi
	if [[ ! -d "$directory" ]]; then
		mkdir -m 0755 -- "$directory"
	fi
	permissions="$(stat -c %a -- "$directory")"
	if [[ "$(stat -c %u -- "$directory")" != 0 ]] || (( (8#$permissions & 8#022) != 0 )); then
		printf 'Directory must be root-owned and not group/world writable: %s\n' "$directory" >&2
		exit 1
	fi
}

for directory in "$BASE" "$BASE/jails" "$JAIL" "$SERVICE_DROPIN"; do
	secure_directory "$directory"
done
if findmnt -rn -M "$MOUNT_POINT" >/dev/null; then
	if [[ "$(stat -Lc '%d:%i' -- "$USER_HOME")" != "$(stat -Lc '%d:%i' -- "$MOUNT_POINT")" ]]; then
		printf 'Mount point already contains a different filesystem: %s\n' "$MOUNT_POINT" >&2
		exit 1
	fi
else
	secure_directory "$MOUNT_POINT"
	if [[ -n "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
		printf 'Mount point is not empty: %s\n' "$MOUNT_POINT" >&2
		exit 1
	fi
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
cat > "$TEMP_DIR/mount" <<EOF
[Unit]
Description=UGSM FTP home for $USER_NAME
Before=vsftpd.service

[Mount]
What=$USER_HOME
Where=$MOUNT_POINT
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
printf '[Unit]\nRequires=%s\nAfter=%s\n' "$MOUNT_UNIT" "$MOUNT_UNIT" > "$TEMP_DIR/dropin"
for pair in "$TEMP_DIR/mount:$MOUNT_FILE" "$TEMP_DIR/dropin:$DROPIN_FILE"; do
	source_file="${pair%%:*}"
	target_file="${pair#*:}"
	if [[ -e "$target_file" || -L "$target_file" ]]; then
		if [[ ! -f "$target_file" || -L "$target_file" ]] || ! cmp -s -- "$source_file" "$target_file"; then
			printf 'Existing systemd configuration does not match: %s\n' "$target_file" >&2
			exit 1
		fi
	else
		install -o root -g root -m 0644 -- "$source_file" "$target_file"
	fi
done

if [[ -e "$ALLOWLIST" || -L "$ALLOWLIST" ]]; then
	if [[ ! -f "$ALLOWLIST" || -L "$ALLOWLIST" || "$(stat -c %u:%a -- "$ALLOWLIST")" != 0:600 ]]; then
		printf 'Unsafe FTP user list: %s\n' "$ALLOWLIST" >&2
		exit 1
	fi
else
	install -o root -g root -m 0600 /dev/null "$ALLOWLIST"
fi
if ! grep -Fxq -- "$USER_NAME" "$ALLOWLIST"; then
	printf '%s\n' "$USER_NAME" >> "$ALLOWLIST"
fi

if [[ ! -e "$CERTIFICATE" && ! -e "$KEY" && ! -L "$CERTIFICATE" && ! -L "$KEY" ]]; then
	openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
		-keyout "$TEMP_DIR/key" -out "$TEMP_DIR/cert" -subj '/CN=UGSM FTPS server'
	install -o root -g root -m 0600 -- "$TEMP_DIR/key" "$KEY"
	install -o root -g root -m 0644 -- "$TEMP_DIR/cert" "$CERTIFICATE"
fi
if [[ ! -f "$CERTIFICATE" || -L "$CERTIFICATE" || ! -f "$KEY" || -L "$KEY" ]] \
	|| [[ "$(stat -c %u:%a -- "$KEY")" != 0:600 || "$(stat -c %u:%a -- "$CERTIFICATE")" != 0:644 ]] \
	|| ! openssl x509 -in "$CERTIFICATE" -noout >/dev/null \
	|| ! openssl pkey -in "$KEY" -noout >/dev/null; then
	printf 'Invalid or unsafe FTPS certificate or key in %s.\n' "$BASE" >&2
	exit 1
fi

cat > "$TEMP_DIR/vsftpd.conf" <<'EOF'
# Managed by UGSM install_vsftpd.sh
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=$USER
local_root=/var/lib/ugsm-vsftpd/jails/$USER
userlist_enable=YES
userlist_deny=NO
userlist_file=/var/lib/ugsm-vsftpd/users
pam_service_name=vsftpd
ssl_enable=YES
force_local_logins_ssl=YES
force_local_data_ssl=YES
rsa_cert_file=/var/lib/ugsm-vsftpd/ftps-cert.pem
rsa_private_key_file=/var/lib/ugsm-vsftpd/ftps-key.pem
require_ssl_reuse=NO
port_enable=NO
pasv_enable=YES
pasv_min_port=50000
pasv_max_port=50100
EOF
if [[ -n "$PASV_ADDRESS" ]]; then
	printf 'pasv_address=%s\n' "$PASV_ADDRESS" >> "$TEMP_DIR/vsftpd.conf"
fi
if [[ -e /etc/vsftpd.conf || -L /etc/vsftpd.conf ]]; then
	if [[ ! -f /etc/vsftpd.conf || -L /etc/vsftpd.conf ]]; then
		printf 'Refusing to replace unsafe /etc/vsftpd.conf.\n' >&2
		exit 1
	fi
	BACKUP="$(mktemp /etc/vsftpd.conf.ugsm-backup.XXXXXX)"
	cp -p -- /etc/vsftpd.conf "$BACKUP"
	printf 'Saved previous configuration: %s\n' "$BACKUP"
fi
install -o root -g root -m 0644 -- "$TEMP_DIR/vsftpd.conf" /etc/vsftpd.conf
systemctl daemon-reload
systemctl enable --now "$MOUNT_UNIT"
systemctl enable vsftpd.service
systemctl restart vsftpd.service
systemctl is-active --quiet vsftpd.service
printf '\nFTPS is ready. Log in as %s using its Linux password and open /home.\n' "$USER_NAME"
printf 'Use explicit FTPS on TCP port 21 and allow TCP ports 50000-50100 for passive transfers.\n'
printf 'Verify the self-signed certificate fingerprint in your FTP client:\n'
openssl x509 -in "$CERTIFICATE" -noout -fingerprint -sha256
