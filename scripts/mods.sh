#!/usr/bin/env bash
set -euo pipefail

# Installs, updates and removes DayZ Workshop mods and server-side mods.
# Workshop IDs are read from config/mods.conf and config/servermod.conf.
# Usage: mods.sh [--update-server] [SteamCMD username]
# Without an argument the username is read from install/<server name>_server.conf.

UPDATE_SERVER=0
if [[ "${1:-}" == "--update-server" ]]; then
	UPDATE_SERVER=1
	shift
fi
if [[ "$#" -gt 1 ]]; then
	printf 'Usage: %s [--update-server] [SteamCMD username]\n' "$0" >&2
	exit 2
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
STEAMCMD_DIRECTORY="$SERVER_DIRECTORY/steam"
SERVERDATA_DIRECTORY="$SERVER_DIRECTORY/serverdata"
KEYS_DIRECTORY="$SERVERDATA_DIRECTORY/keys"
DAYZ_WORKSHOP_APP_ID="221100"
DAYZ_SERVER_APP_ID="223350"
WORKSHOP_CONTENT_DIRECTORY="$SERVERDATA_DIRECTORY/steamapps/workshop/content/$DAYZ_WORKSHOP_APP_ID"
STATE_FILE="$SERVERDATA_DIRECTORY/.ugsm_mods.state"
MODS_CONFIG="$PROJECT_DIRECTORY/config/mods.conf"
SERVERMODS_CONFIG="$PROJECT_DIRECTORY/config/servermod.conf"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"

if [[ ! -x "$STEAMCMD_DIRECTORY/steamcmd.sh" ]]; then
	printf 'SteamCMD was not found: %s/steamcmd.sh\n' "$STEAMCMD_DIRECTORY" >&2
	exit 1
fi
if [[ ! -d "$SERVERDATA_DIRECTORY" || ! -w "$SERVERDATA_DIRECTORY" ]]; then
	printf 'Serverdata directory is missing or not writable: %s\n' "$SERVERDATA_DIRECTORY" >&2
	exit 1
fi
for file in "$MODS_CONFIG" "$SERVERMODS_CONFIG"; do
	if [[ ! -r "$file" ]]; then
		printf 'Config file is missing or unreadable: %s\n' "$file" >&2
		exit 1
	fi
done

# Read the Steam user from the argument or from the server settings file.
STEAM_USER="${1:-}"
if [[ -z "$STEAM_USER" && -r "$SERVER_CONFIG" ]]; then
	STEAM_USER="$(awk -F= '
		$1 ~ /^[[:space:]]*STEAM_USER[[:space:]]*$/ {
			value = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			gsub(/^"|"$/, "", value)
			print value
			exit
		}' "$SERVER_CONFIG")"
fi

# Read workshop IDs: one per line, "#" starts a comment, anything after the ID is ignored.
read_ids() {
	local file="$1" line id
	[[ -r "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"
		line="${line//$'\r'/}"
		read -r id _ <<< "$line" || true
		[[ -z "$id" ]] && continue
		if [[ ! "$id" =~ ^[0-9]+$ ]]; then
			printf 'Ignoring invalid workshop ID "%s" in %s.\n' "$id" "$file" >&2
			continue
		fi
		printf '%s\n' "$id"
	done < "$file"
}

mapfile -t MOD_IDS < <(read_ids "$MODS_CONFIG" | awk '!seen[$0]++')
mapfile -t SERVERMOD_IDS < <(read_ids "$SERVERMODS_CONFIG" | awk '!seen[$0]++')
ALL_IDS=("${MOD_IDS[@]}" "${SERVERMOD_IDS[@]}")
declare -A WANTED=()
for id in "${ALL_IDS[@]}"; do
	WANTED["$id"]=1
done

touch -- "$STATE_FILE"
mkdir -p -- "$KEYS_DIRECTORY"

remove_mod_link() {
	local link="$1" id="$2"
	if [[ -L "$link" && "$(readlink -- "$link")" == "$WORKSHOP_CONTENT_DIRECTORY/$id" ]]; then
		rm -- "$link"
	fi
}

# Remove mods that are no longer listed: link, keys and downloaded files.
declare -A STALE=()
while IFS='|' read -r id _; do
	if [[ ! "$id" =~ ^[0-9]+$ ]]; then
		printf 'Invalid mod ID in %s: %s\n' "$STATE_FILE" "$id" >&2
		exit 1
	fi
	[[ -z "${WANTED[$id]:-}" ]] && STALE["$id"]=1
done < "$STATE_FILE"
for link in "$SERVERDATA_DIRECTORY"/@* "$SERVERDATA_DIRECTORY"/[0-9]*; do
	[[ -L "$link" ]] || continue
	target="$(readlink -- "$link")"
	[[ "$target" == "$WORKSHOP_CONTENT_DIRECTORY"/* ]] || continue
	id="${target##*/}"
	[[ "$id" =~ ^[0-9]+$ && ( "${link##*/}" == "$id" || "${link##*/}" == "@$id" ) ]] || continue
	[[ "$target" == "$WORKSHOP_CONTENT_DIRECTORY/$id" ]] || continue
	[[ -z "${WANTED[$id]:-}" ]] && STALE["$id"]=1
done

if (( ${#STALE[@]} > 0 )); then
	NEW_STATE="$(mktemp)"
	# Keep state entries of mods that stay installed.
	while IFS='|' read -r id key; do
		[[ -n "$id" && -z "${STALE[$id]:-}" ]] && printf '%s|%s\n' "$id" "$key"
	done < "$STATE_FILE" > "$NEW_STATE"
	for id in "${!STALE[@]}"; do
		printf 'Removing mod %s.\n' "$id"
		remove_mod_link "$SERVERDATA_DIRECTORY/@$id" "$id"
		remove_mod_link "$SERVERDATA_DIRECTORY/$id" "$id"
		while IFS='|' read -r state_id key; do
			[[ "$state_id" == "$id" ]] || continue
			# Keep keys that another installed mod still provides.
			if ! grep -qxF -- "|$key" <(sed 's/^[^|]*//' "$NEW_STATE"); then
				rm -f -- "$KEYS_DIRECTORY/$key"
			fi
		done < "$STATE_FILE"
		rm -rf -- "${WORKSHOP_CONTENT_DIRECTORY:?}/$id"
	done
	mv -- "$NEW_STATE" "$STATE_FILE"
fi

if (( ${#ALL_IDS[@]} == 0 && ! UPDATE_SERVER )); then
	printf 'No mods are listed in %s or %s.\n' "$MODS_CONFIG" "$SERVERMODS_CONFIG"
	exit 0
fi

# Download all listed mods in one SteamCMD session.
STEAM_LOGIN_ARGS=(+login)
if [[ -n "$STEAM_USER" && "${STEAM_USER,,}" != "anonymous" ]]; then
	printf 'SteamCMD may ask for the account password and Steam Guard code. Enter them at the prompt.\n'
	STEAM_LOGIN_ARGS+=("$STEAM_USER")
else
	printf 'SteamCMD will prompt for the login credentials.\n'
fi
DOWNLOAD_ARGS=()
if (( UPDATE_SERVER )); then
	DOWNLOAD_ARGS+=(+app_update "$DAYZ_SERVER_APP_ID" validate)
fi
declare -A DOWNLOAD_IDS=()
for id in "${ALL_IDS[@]}"; do
	[[ -n "${DOWNLOAD_IDS[$id]:-}" ]] && continue
	DOWNLOAD_IDS["$id"]=1
	DOWNLOAD_ARGS+=(+workshop_download_item "$DAYZ_WORKSHOP_APP_ID" "$id" validate)
done
STEAM_OUTPUT="$(mktemp)"
trap 'rm -f -- "$STEAM_OUTPUT"' EXIT
(
	cd -- "$STEAMCMD_DIRECTORY"
	./steamcmd.sh \
		+force_install_dir "$SERVERDATA_DIRECTORY" \
		"${STEAM_LOGIN_ARGS[@]}" \
		"${DOWNLOAD_ARGS[@]}" \
		+quit 2>&1
) | tee "$STEAM_OUTPUT"

if (( UPDATE_SERVER )) && ! grep -Fq "Success! App '$DAYZ_SERVER_APP_ID' fully installed." "$STEAM_OUTPUT"; then
	printf 'SteamCMD did not confirm the DayZ server update; aborting.\n' >&2
	exit 1
fi
for id in "${!DOWNLOAD_IDS[@]}"; do
	if ! grep -Fq "Success. Downloaded item $id to " "$STEAM_OUTPUT"; then
		printf 'SteamCMD did not confirm the update of mod %s; aborting.\n' "$id" >&2
		exit 1
	fi
done

# Link each mod into serverdata and copy its keys (any letter case) into keys.
FAILED=0
for id in "${ALL_IDS[@]}"; do
	mod_directory="$WORKSHOP_CONTENT_DIRECTORY/$id"
	if [[ ! -d "$mod_directory" ]]; then
		printf 'Download of mod %s failed.\n' "$id" >&2
		FAILED=1
		continue
	fi
	link="$SERVERDATA_DIRECTORY/$id"
	if [[ -e "$link" && ! -L "$link" ]]; then
		printf 'Cannot link mod %s: %s exists and is not a link.\n' "$id" "$link" >&2
		FAILED=1
		continue
	fi
	if [[ -L "$link" && "$(readlink -- "$link")" != "$mod_directory" ]]; then
		printf 'Cannot link mod %s: %s points elsewhere.\n' "$id" "$link" >&2
		FAILED=1
		continue
	fi
	ln -sfn -- "$mod_directory" "$link"
	remove_mod_link "$SERVERDATA_DIRECTORY/@$id" "$id"

	# Linux DayZ servers need lowercase file and folder names; rename deepest entries first.
	while IFS= read -r -d '' entry; do
		entry_name="$(basename -- "$entry")"
		lower_name="${entry_name,,}"
		[[ "$entry_name" == "$lower_name" ]] && continue
		target="$(dirname -- "$entry")/$lower_name"
		if [[ -d "$entry" && -d "$target" ]]; then
			# SteamCMD recreated the original-case folder; merge it into the lowercase one.
			cp -a -- "$entry/." "$target/"
			rm -rf -- "$entry"
		elif [[ -e "$target" && ! -d "$target" && ! -d "$entry" ]]; then
			mv -f -- "$entry" "$target"
		elif [[ -e "$target" ]]; then
			printf 'Cannot lowercase %s: target already exists.\n' "$entry" >&2
		else
			mv -- "$entry" "$target"
		fi
	done < <(find "$mod_directory" -mindepth 1 -depth -print0)

	# Replace the recorded keys of this mod with the current ones.
	grep -v -- "^$id|" "$STATE_FILE" > "$STATE_FILE.tmp" || true
	while IFS= read -r -d '' key_file; do
		key_name="$(basename -- "$key_file")"
		cp -f -- "$key_file" "$KEYS_DIRECTORY/$key_name"
		printf '%s|%s\n' "$id" "$key_name" >> "$STATE_FILE.tmp"
	done < <(find "$mod_directory" -type f -iname '*.bikey' -print0)
	mv -- "$STATE_FILE.tmp" "$STATE_FILE"
done

join_links() {
	local result="" id
	for id in "$@"; do
		result+="$id;"
	done
	printf '%s' "${result%;}"
}

printf '\nAdd these parameters to the server start command:\n'
[[ ${#MOD_IDS[@]} -gt 0 ]] && printf -- '-mod="%s"\n' "$(join_links "${MOD_IDS[@]}")"
[[ ${#SERVERMOD_IDS[@]} -gt 0 ]] && printf -- '-servermod="%s"\n' "$(join_links "${SERVERMOD_IDS[@]}")"

exit "$FAILED"
