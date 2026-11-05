#!/usr/bin/env bash
set -euo pipefail

# Creates and manages backups of the active DayZ server mission and profiles
# Reads the active mission from serverdata/serverDZ.cfg, backs up the mission folder
# and profiles directory, compresses them, and maintains a maximum of 8 backups.
# This script is meant to run from <server_directory>/ugsm/scripts/backup.sh
# Usage: 
#   backup.sh              - Create a new backup
#   backup.sh auto_recover - Restore from the latest backup (creates error backup first)
#   backup.sh recover      - Choose a backup from list and restore it

if [[ "$#" -gt 1 ]]; then
	printf 'Usage: %s [auto_recover|recover]\n' "$0" >&2
	exit 2
fi

MODE="${1:-backup}"
if [[ "$MODE" != "backup" && "$MODE" != "auto_recover" && "$MODE" != "recover" ]]; then
	printf 'Invalid mode: %s\n' "$MODE" >&2
	printf 'Usage: %s [auto_recover|recover]\n' "$0" >&2
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

# Function to create a backup
create_backup() {
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
	BACKUP_FILE="$BACKUP_BASE_DIRECTORY/$TIMESTAMP.zip"
	cd -- "$BACKUP_FOLDER/.." || exit 1
	zip -r "$TIMESTAMP.zip" "$TIMESTAMP" >/dev/null 2>&1
	if [[ -f "$BACKUP_FILE" ]]; then
		rm -rf -- "$BACKUP_FOLDER"
		printf 'Created backup: %s\n' "$BACKUP_FILE"
	else
		printf 'Failed to create backup archive: %s\n' "$BACKUP_FILE" >&2
		rm -rf -- "$BACKUP_FOLDER"
		exit 1
	fi

	# Clean up old backups, keep only the 8 most recent
	BACKUP_COUNT=$(find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.zip" -type f | wc -l)
	if (( BACKUP_COUNT > 8 )); then
		# Sort by modification time, keep the 8 newest, delete the rest
		find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.zip" -type f -printf '%T@ %p\n' | \
			sort -rn | tail -n "+9" | cut -d' ' -f2- | while read -r old_backup; do
				rm -f -- "$old_backup"
				printf 'Deleted old backup: %s\n' "$old_backup"
			done
	fi

	printf 'Backup completed successfully for server %s (mission: %s)\n' "$SERVER_NAME" "$ACTIVE_MISSION"
}

# Function to restore from latest backup
auto_recover() {
	printf 'Starting auto_recover: Creating error backup first...\n'

	# Create error backup (same as normal backup but with ERROR_ prefix)
	printf '[DEBUG] Creating ERROR_BACKUP_FOLDER...\n'
	ERROR_BACKUP_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
	ERROR_BACKUP_FOLDER="$BACKUP_BASE_DIRECTORY/ERROR_$ERROR_BACKUP_TIMESTAMP"
	printf '[DEBUG] ERROR_BACKUP_FOLDER=%s\n' "$ERROR_BACKUP_FOLDER"
	mkdir -p -- "$ERROR_BACKUP_FOLDER"

	printf '[DEBUG] Copying mission folder to error backup...\n'
	cp -a -- "$MISSION_FOLDER" "$ERROR_BACKUP_FOLDER/"
	printf '[DEBUG] Copying profiles to error backup...\n'
	cp -a -- "$PROFILES_DIRECTORY" "$ERROR_BACKUP_FOLDER/"
	printf '[DEBUG] Copying battleye to error backup...\n'
	cp -a -- "$BATTLEYE_DIRECTORY" "$ERROR_BACKUP_FOLDER/"
	printf '[DEBUG] Copying serverDZ.cfg to error backup...\n'
	cp -- "$SERVER_CONFIG_FILE" "$ERROR_BACKUP_FOLDER/"

	printf '[DEBUG] Creating ZIP file of error backup...\n'
	ERROR_BACKUP_FILE="$BACKUP_BASE_DIRECTORY/ERROR_$ERROR_BACKUP_TIMESTAMP.zip"
	cd -- "$BACKUP_BASE_DIRECTORY" || exit 1
	printf '[DEBUG] Compressing: zip -r %s %s\n' "$(basename "$ERROR_BACKUP_FILE")" "$(basename "$ERROR_BACKUP_FOLDER")"
	zip -r "$(basename "$ERROR_BACKUP_FILE")" "$(basename "$ERROR_BACKUP_FOLDER")" >/dev/null 2>&1
	printf '[DEBUG] Zip completed, exit code: %d\n' $?
	printf '[DEBUG] Removing error backup folder...\n'
	rm -rf -- "$ERROR_BACKUP_FOLDER"
	printf 'Created error backup: %s\n' "$ERROR_BACKUP_FILE"

	# Find the latest backup (most recent .zip file, excluding ERROR_*)
	printf 'Finding latest backup...\n'
	printf '[DEBUG] Searching in: %s\n' "$BACKUP_BASE_DIRECTORY"
	LATEST_BACKUP=$(find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.zip" -type f ! -name "ERROR_*" -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
	printf '[DEBUG] LATEST_BACKUP=%s\n' "$LATEST_BACKUP"
	
	if [[ -z "$LATEST_BACKUP" ]]; then
		printf 'No backup found to restore from!\n' >&2
		exit 1
	fi

	printf 'Restoring from: %s\n' "$LATEST_BACKUP"

	# Extract backup to temporary location
	printf '[DEBUG] Creating restore temp directory...\n'
	RESTORE_TEMP="$BACKUP_BASE_DIRECTORY/restore_temp_$$"
	mkdir -p -- "$RESTORE_TEMP"
	printf '[DEBUG] Extracting backup...\n'
	unzip -q "$LATEST_BACKUP" -d "$RESTORE_TEMP"

	# Find the backup folder name inside the zip
	printf '[DEBUG] Finding backup folder inside zip...\n'
	BACKUP_FOLDER_NAME=$(find "$RESTORE_TEMP" -maxdepth 1 -type d ! -name "restore_temp_$$" | head -1)
	printf '[DEBUG] BACKUP_FOLDER_NAME=%s\n' "$BACKUP_FOLDER_NAME"
	if [[ -z "$BACKUP_FOLDER_NAME" ]]; then
		printf 'Error: Invalid backup archive structure\n' >&2
		rm -rf -- "$RESTORE_TEMP"
		exit 1
	fi

	# Restore the data
	printf 'Restoring mission folder...\n'
	printf '[DEBUG] Removing old mission folder: %s\n' "$MISSION_FOLDER"
	rm -rf -- "$MISSION_FOLDER"
	printf '[DEBUG] Copying mission from backup: %s/%s to %s\n' "$BACKUP_FOLDER_NAME" "$(basename "$ACTIVE_MISSION")" "$MPMISSION_DIRECTORY"
	cp -a -- "$BACKUP_FOLDER_NAME/$(basename "$ACTIVE_MISSION")" "$MPMISSION_DIRECTORY/"

	printf 'Restoring profiles folder...\n'
	printf '[DEBUG] Removing old profiles: %s\n' "$PROFILES_DIRECTORY"
	rm -rf -- "$PROFILES_DIRECTORY"
	printf '[DEBUG] Copying profiles from backup\n'
	cp -a -- "$BACKUP_FOLDER_NAME/profiles" "$SERVERDATA_DIRECTORY/"

	printf 'Restoring battleye config...\n'
	printf '[DEBUG] Removing old battleye: %s\n' "$BATTLEYE_DIRECTORY"
	rm -rf -- "$BATTLEYE_DIRECTORY"
	printf '[DEBUG] Copying battleye from backup\n'
	cp -a -- "$BACKUP_FOLDER_NAME/battleye" "$SERVERDATA_DIRECTORY/"

	printf 'Restoring serverDZ.cfg...\n'
	printf '[DEBUG] Copying serverDZ.cfg from backup\n'
	cp -- "$BACKUP_FOLDER_NAME/serverDZ.cfg" "$SERVER_CONFIG_FILE"

	# Clean up
	printf '[DEBUG] Cleaning up temporary restore folder\n'
	rm -rf -- "$RESTORE_TEMP"

	printf 'Auto recover completed successfully!\n'
}

# Function to restore from selected backup
recover() {
	printf '[DEBUG] Starting recover function\n'
	printf 'Available backups:\n'
	printf '==================\n'

	# List all backups and store them in an array
	printf '[DEBUG] Searching for backups in: %s\n' "$BACKUP_BASE_DIRECTORY"
	BACKUPS=()
	INDEX=1
	while IFS= read -r backup_file; do
		printf '[DEBUG] Found backup: %s\n' "$backup_file"
		BACKUP_SIZE=$(du -h "$backup_file" | cut -f1)
		BACKUP_DATE=$(stat -c '%y' "$backup_file" 2>/dev/null | cut -d' ' -f1,2 || stat -f '%Sm' "$backup_file" 2>/dev/null)
		printf '%d) %s (%s) - %s\n' "$INDEX" "$(basename "$backup_file")" "$BACKUP_SIZE" "$BACKUP_DATE"
		BACKUPS+=("$backup_file")
		((INDEX++))
	done < <(find "$BACKUP_BASE_DIRECTORY" -maxdepth 1 -name "*.zip" -type f ! -name "ERROR_*" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)

	printf '[DEBUG] Total backups found: %d\n' "${#BACKUPS[@]}"
	if [[ ${#BACKUPS[@]} -eq 0 ]]; then
		printf 'No backups found!\n' >&2
		exit 1
	fi

	printf '\n'
	printf 'Select a backup to restore (enter number): '
	read -r CHOICE
	printf '[DEBUG] User selected: %s\n' "$CHOICE"

	# Validate input
	if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#BACKUPS[@]} )); then
		printf 'Invalid selection!\n' >&2
		exit 1
	fi

	SELECTED_BACKUP="${BACKUPS[$((CHOICE - 1))]}"
	printf 'Selected: %s\n' "$(basename "$SELECTED_BACKUP")"

	# Confirm restore
	printf 'Create error backup and restore from selected backup? (yes/no): '
	read -r CONFIRM
	printf '[DEBUG] Confirmation: %s\n' "$CONFIRM"
	if [[ "$CONFIRM" != "yes" ]]; then
		printf 'Recovery cancelled.\n'
		exit 0
	fi

	printf 'Starting recovery: Creating error backup first...\n'

	# Create error backup (same as normal backup but with ERROR_ prefix)
	printf '[DEBUG] Creating ERROR_BACKUP_FOLDER...\n'
	ERROR_BACKUP_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
	ERROR_BACKUP_FOLDER="$BACKUP_BASE_DIRECTORY/ERROR_$ERROR_BACKUP_TIMESTAMP"
	mkdir -p -- "$ERROR_BACKUP_FOLDER"

	printf '[DEBUG] Copying data to error backup...\n'
	cp -a -- "$MISSION_FOLDER" "$ERROR_BACKUP_FOLDER/"
	cp -a -- "$PROFILES_DIRECTORY" "$ERROR_BACKUP_FOLDER/"
	cp -a -- "$BATTLEYE_DIRECTORY" "$ERROR_BACKUP_FOLDER/"
	cp -- "$SERVER_CONFIG_FILE" "$ERROR_BACKUP_FOLDER/"

	printf '[DEBUG] Creating ZIP of error backup...\n'
	ERROR_BACKUP_FILE="$BACKUP_BASE_DIRECTORY/ERROR_$ERROR_BACKUP_TIMESTAMP.zip"
	cd -- "$BACKUP_BASE_DIRECTORY" || exit 1
	zip -r "$(basename "$ERROR_BACKUP_FILE")" "$(basename "$ERROR_BACKUP_FOLDER")" >/dev/null 2>&1
	printf '[DEBUG] Zip completed, exit code: %d\n' $?
	rm -rf -- "$ERROR_BACKUP_FOLDER"
	printf 'Created error backup: %s\n' "$ERROR_BACKUP_FILE"

	printf 'Restoring from: %s\n' "$(basename "$SELECTED_BACKUP")"

	# Extract backup to temporary location
	printf '[DEBUG] Creating temp restore directory...\n'
	RESTORE_TEMP="$BACKUP_BASE_DIRECTORY/restore_temp_$$"
	mkdir -p -- "$RESTORE_TEMP"
	printf '[DEBUG] Extracting selected backup...\n'
	unzip -q "$SELECTED_BACKUP" -d "$RESTORE_TEMP"

	# Find the backup folder name inside the zip
	printf '[DEBUG] Finding backup folder in zip...\n'
	BACKUP_FOLDER_NAME=$(find "$RESTORE_TEMP" -maxdepth 1 -type d ! -name "restore_temp_$$" | head -1)
	printf '[DEBUG] BACKUP_FOLDER_NAME=%s\n' "$BACKUP_FOLDER_NAME"
	if [[ -z "$BACKUP_FOLDER_NAME" ]]; then
		printf 'Error: Invalid backup archive structure\n' >&2
		rm -rf -- "$RESTORE_TEMP"
		exit 1
	fi

	# Restore the data
	printf 'Restoring mission folder...\n'
	printf '[DEBUG] Removing old mission and restoring...\n'
	rm -rf -- "$MISSION_FOLDER"
	cp -a -- "$BACKUP_FOLDER_NAME/$(basename "$ACTIVE_MISSION")" "$MPMISSION_DIRECTORY/"

	printf 'Restoring profiles folder...\n'
	printf '[DEBUG] Removing old profiles and restoring...\n'
	rm -rf -- "$PROFILES_DIRECTORY"
	cp -a -- "$BACKUP_FOLDER_NAME/profiles" "$SERVERDATA_DIRECTORY/"

	printf 'Restoring battleye config...\n'
	printf '[DEBUG] Removing old battleye and restoring...\n'
	rm -rf -- "$BATTLEYE_DIRECTORY"
	cp -a -- "$BACKUP_FOLDER_NAME/battleye" "$SERVERDATA_DIRECTORY/"

	printf 'Restoring serverDZ.cfg...\n'
	printf '[DEBUG] Restoring serverDZ.cfg...\n'
	cp -- "$BACKUP_FOLDER_NAME/serverDZ.cfg" "$SERVER_CONFIG_FILE"

	# Clean up
	printf '[DEBUG] Cleaning up temp folder\n'
	rm -rf -- "$RESTORE_TEMP"

	printf 'Recovery from %s completed successfully!\n' "$(basename "$SELECTED_BACKUP")"
}

# Execute based on mode
if [[ "$MODE" == "auto_recover" ]]; then
	auto_recover
elif [[ "$MODE" == "recover" ]]; then
	recover
else
	create_backup
fi
