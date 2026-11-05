#!/usr/bin/env bash
set -euo pipefail

# Creates and manages backups of the active DayZ server mission and profiles
# Reads the active mission from serverdata/serverDZ.cfg, backs up the mission folder
# and profiles directory, compresses them, and maintains a maximum of 8 backups.
# This script is meant to run from <server_directory>/ugsm/scripts/backup.sh
# Usage: backup.sh

if [[ "$#" -gt 0 ]]; then
	printf 'Usage: %s\n' "$0" >&2
	exit 2
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UGSM_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$UGSM_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVERDATA_DIRECTORY="$SERVER_DIRECTORY/serverdata"
SERVER_CONFIG_FILE="$SERVERDATA_DIRECTORY/serverDZ.cfg"
BACKUP_BASE_DIRECTORY="$SERVER_DIRECTORY/backup"
MPMISSION_DIRECTORY="$SERVERDATA_DIRECTORY/mpmissions"
PROFILES_DIRECTORY="$SERVERDATA_DIRECTORY/profiles"
BATTLEYE_DIRECTORY="$SERVERDATA_DIRECTORY/battleye"

# Validate required directories and files exist
if [[ ! -d "$SERVER_DIRECTORY" ]]; then
	printf 'Server directory not found: %s\n' "$SERVER_DIRECTORY" >&2
	printf 'This script must be located at: <server_directory>/ugsm/scripts/backup.sh\n' >&2
	exit 1
fi
if [[ ! -f "$SERVER_CONFIG_FILE" ]]; then
	printf 'Server config file is missing: %s\n' "$SERVER_CONFIG_FILE" >&2
	exit 1
fi
if [[ ! -d "$MPMISSION_DIRECTORY" ]]; then
	printf 'mpmissions directory is missing: %s\n' "$MPMISSION_DIRECTORY" >&2
	exit 1
fi
if [[ ! -d "$PROFILES_DIRECTORY" ]]; then
	printf 'profiles directory is missing: %s\n' "$PROFILES_DIRECTORY" >&2
	exit 1
fi
if [[ ! -d "$BATTLEYE_DIRECTORY" ]]; then
	printf 'battleye directory is missing: %s\n' "$BATTLEYE_DIRECTORY" >&2
	exit 1
fi

# Read the active mission template from serverDZ.cfg
read_active_mission() {
	awk '
	/template[[:space:]]*=/ {
		# Extract the value between quotes
		if (match($0, /"[^"]+"/)) {
			value = substr($0, RSTART + 1, RLENGTH - 2)
			print value
			exit
		}
	}' "$SERVER_CONFIG_FILE"
}

ACTIVE_MISSION="$(read_active_mission)"
if [[ -z "$ACTIVE_MISSION" ]]; then
	printf 'Could not determine active mission from %s\n' "$SERVER_CONFIG_FILE" >&2
	exit 1
fi

MISSION_FOLDER="$MPMISSION_DIRECTORY/$ACTIVE_MISSION"
if [[ ! -d "$MISSION_FOLDER" ]]; then
	printf 'Active mission folder not found: %s\n' "$MISSION_FOLDER" >&2
	exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p -- "$BACKUP_BASE_DIRECTORY"

# Clean up profiles and serverdata directory: archive logs and error scripts
CLEANUP_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
PROFILES_CLEANUP_DIR="$PROFILES_DIRECTORY/logs_archiv"
mkdir -p -- "$PROFILES_CLEANUP_DIR"

CLEANUP_FOLDER="$PROFILES_CLEANUP_DIR/$CLEANUP_TIMESTAMP"
mkdir -p -- "$CLEANUP_FOLDER"

# Find and move log files and error scripts from profiles
find "$PROFILES_DIRECTORY" -maxdepth 2 \( -iname "*.log" -o -iname "*.rpt" -o -iname "*.adm" -o -iname "*error*" \) -type f -exec mv -- {} "$CLEANUP_FOLDER/" \; 2>/dev/null || true

# Find and move log files and error scripts from serverdata
find "$SERVERDATA_DIRECTORY" -maxdepth 1 \( -iname "*.log" -o -iname "*.rpt" -o -iname "*.adm" -o -iname "*error*" \) -type f -exec mv -- {} "$CLEANUP_FOLDER/" \; 2>/dev/null || true

# Clean up old cleanup folders in profiles, keep only the 8 most recent
CLEANUP_COUNT=$(find "$PROFILES_CLEANUP_DIR" -maxdepth 1 -type d | grep -v "^$PROFILES_CLEANUP_DIR$" | wc -l)
if (( CLEANUP_COUNT > 8 )); then
	find "$PROFILES_CLEANUP_DIR" -maxdepth 1 -type d ! -name "logs_archiv" -printf '%T@ %p\n' | \
		sort -n | head -n "$((CLEANUP_COUNT - 8))" | cut -d' ' -f2- | while read -r old_cleanup; do
			rm -rf -- "$old_cleanup"
			printf 'Deleted old cleanup folder: %s\n' "$old_cleanup"
		done
fi

printf 'Cleaned up profiles and serverdata directories, archived logs to: %s\n' "$CLEANUP_FOLDER"

# Create timestamped backup folder
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_FOLDER="$BACKUP_BASE_DIRECTORY/$TIMESTAMP"
mkdir -p -- "$BACKUP_FOLDER"

# Copy the active mission folder, profiles directory, server config, and battleye config
cp -a -- "$MISSION_FOLDER" "$BACKUP_FOLDER/"
cp -a -- "$PROFILES_DIRECTORY" "$BACKUP_FOLDER/"
cp -a -- "$BATTLEYE_DIRECTORY" "$BACKUP_FOLDER/"
cp -- "$SERVER_CONFIG_FILE" "$BACKUP_FOLDER/"

# Compress the backup
BACKUP_FILE="$BACKUP_BASE_DIRECTORY/$TIMESTAMP.tar.gz"
cd -- "$BACKUP_FOLDER/.." || exit 1
tar -czf "$TIMESTAMP.tar.gz" "$TIMESTAMP" 2>/dev/null
if [[ -f "$BACKUP_FILE" ]]; then
	rm -rf -- "$BACKUP_FOLDER"
	printf 'Created backup: %s\n' "$BACKUP_FILE"
else
	printf 'Failed to create backup archive: %s\n' "$BACKUP_FILE" >&2
	rm -rf -- "$BACKUP_FOLDER"
	exit 1
fi

# Clean up old backups, keep only the 8 most recent
BACKUP_COUNT=$(find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.tar.gz" -type f | wc -l)
if (( BACKUP_COUNT > 8 )); then
	# Sort by modification time, keep the 8 newest, delete the rest
	find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.tar.gz" -type f -printf '%T@ %p\n' | \
		sort -rn | tail -n "+9" | cut -d' ' -f2- | while read -r old_backup; do
			rm -f -- "$old_backup"
			printf 'Deleted old backup: %s\n' "$old_backup"
		done
fi

printf 'Backup completed successfully for server %s (mission: %s)\n' "$SERVER_NAME" "$ACTIVE_MISSION"
