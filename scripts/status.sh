#!/usr/bin/env bash
set -uo pipefail

# Displays detailed status information for the DayZ server.
# Shows server state, port status, tmux session status, and GameDig server info.
# Configuration is read from install/<server name>_server.conf
# Usage: status.sh

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVER_CONFIG="$PROJECT_DIRECTORY/install/${SERVER_NAME}_server.conf"

if [[ ! -r "$SERVER_CONFIG" ]]; then
	printf 'Config file is missing or unreadable: %s\n' "$SERVER_CONFIG" >&2
	exit 1
fi

# Read a setting from a file without executing it.
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

# Check if a port is listening and responding.
check_port() {
	local port="$1"
	if nc -zu localhost "$port" >/dev/null 2>&1; then
		echo "✓ OPEN"
		return 0
	else
		echo "✗ CLOSED"
		return 1
	fi
}

# Check if a process is listening on a specific port using netstat/ss.
check_port_listening() {
	local port="$1"
	if command -v ss &>/dev/null; then
		ss -uln 2>/dev/null | grep -q ":$port " && echo "✓ LISTENING" || echo "✗ NOT LISTENING"
	elif command -v netstat &>/dev/null; then
		netstat -uln 2>/dev/null | grep -q ":$port " && echo "✓ LISTENING" || echo "✗ NOT LISTENING"
	else
		echo "? UNKNOWN (ss/netstat not available)"
	fi
}

# Check if tmux session exists and is active.
check_tmux_session() {
	local session_name="$1"
	if tmux has-session -t "$session_name" 2>/dev/null; then
		if tmux list-sessions -F "#{session_name}:#{?session_attached,attached,detached}" 2>/dev/null | grep -q "^${session_name}:"; then
			echo "✓ ACTIVE (attached)"
		else
			echo "✓ RUNNING (detached)"
		fi
		return 0
	else
		echo "✗ NOT RUNNING"
		return 1
	fi
}

# Query GameDig for server info using gamedig if available.
query_gamedig() {
	local server_ip="$1"
	local game_port="$2"
	
	if ! command -v gamedig &>/dev/null; then
		echo "GameDig not installed. Install with: npm install -g gamedig"
		return 1
	fi
	
	gamedig --type dayz --host "$server_ip" --port "$game_port" 2>/dev/null || return 1
}

# Parse gamedig JSON output.
parse_gamedig_output() {
	local json="$1"
	
	if ! command -v jq &>/dev/null; then
		echo "jq not installed. Cannot parse GameDig output."
		return 1
	fi
	
	printf "  Server Name: %s\n" "$(echo "$json" | jq -r '.name // "N/A"')"
	printf "  Map: %s\n" "$(echo "$json" | jq -r '.map // "N/A"')"
	printf "  Players: %s/%s\n" "$(echo "$json" | jq -r '.players | length // 0')" "$(echo "$json" | jq -r '.maxplayers // "N/A"')"
	printf "  Game: %s\n" "$(echo "$json" | jq -r '.game // "N/A"')"
	printf "  Server IP: %s:%s\n" "$(echo "$json" | jq -r '.connect // "N/A"')" "$(echo "$json" | jq -r '.port // "N/A"')"
	
	local player_count=$(echo "$json" | jq -r '.players | length // 0')
	if [[ "$player_count" -gt 0 ]]; then
		printf "\n  Connected Players:\n"
		echo "$json" | jq -r '.players[] | "    - \(.name) (Score: \(.score // 0), Time: \(.time // 0)s)"' 2>/dev/null || true
	fi
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

printf "╔════════════════════════════════════════════════════════════════════╗\n"
printf "║ DayZ Server Status Report: %s\n" "$SERVER_NAME"
printf "╚════════════════════════════════════════════════════════════════════╝\n"

# Load configuration values.
STATE="$(read_setting "$SERVER_CONFIG" STATE)"
SERVER_IP="$(read_setting "$SERVER_CONFIG" SERVER_IP)"
GAME_PORT="$(read_setting "$SERVER_CONFIG" GAME_PORT)"
RCON_PORT="$(read_setting "$SERVER_CONFIG" RCON_PORT)"
STEAM_QUERY_PORT="$(read_setting "$SERVER_CONFIG" STEAM_QUERY_PORT)"
NEW_USER="$(read_setting "$SERVER_CONFIG" NEW_USER)"

# ============================================================================
# 1. SERVER STATE
# ============================================================================

printf "\n┌─ Server State ─────────────────────────────────────────────────────┐\n"
case "$STATE" in
	stop)
		printf "│ Status: ✗ STOPPED\n"
		;;
	starting)
		printf "│ Status: ⟳ STARTING\n"
		;;
	running)
		printf "│ Status: ✓ RUNNING\n"
		;;
	stopping)
		printf "│ Status: ⟳ STOPPING\n"
		;;
	error)
		printf "│ Status: ✗ ERROR\n"
		;;
	*)
		printf "│ Status: ? UNKNOWN (%s)\n" "$STATE"
		;;
esac
printf "└────────────────────────────────────────────────────────────────────┘\n"

# ============================================================================
# 2. PORT STATUS
# ============================================================================

printf "\n┌─ Port Configuration & Status ──────────────────────────────────────┐\n"

printf "│ Game Port (UDP %s:%s)\n" "$SERVER_IP" "$GAME_PORT"
printf "│   Listening: " && check_port_listening "$GAME_PORT"
printf "│   Reachable: " && check_port "$GAME_PORT" || true
printf "│\n"

printf "│ RCON Port (UDP %s:%s)\n" "$SERVER_IP" "$RCON_PORT"
printf "│   Listening: " && check_port_listening "$RCON_PORT"
printf "│   Reachable: " && check_port "$RCON_PORT" || true
printf "│\n"

printf "│ Steam Query Port (UDP %s:%s)\n" "$SERVER_IP" "$STEAM_QUERY_PORT"
printf "│   Listening: " && check_port_listening "$STEAM_QUERY_PORT"
printf "│   Reachable: " && check_port "$STEAM_QUERY_PORT" || true
printf "│\n"

printf "└────────────────────────────────────────────────────────────────────┘\n"

# ============================================================================
# 3. TMUX SESSION STATUS
# ============================================================================

printf "\n┌─ Tmux Session Status ──────────────────────────────────────────────┐\n"
printf "│ Session Name: %s\n" "$SERVER_NAME"
printf "│ Status: " && check_tmux_session "$SERVER_NAME"
printf "│\n"

if tmux has-session -t "$SERVER_NAME" 2>/dev/null; then
	printf "│ Active Windows/Panes:\n"
	tmux list-windows -t "$SERVER_NAME" -F "│   #{window_index}: #{window_name} (#{window_panes} panes)" || true
	printf "│\n"
fi

printf "└────────────────────────────────────────────────────────────────────┘\n"

# ============================================================================
# 4. GAMEDIG / STEAM QUERY STATUS
# ============================================================================

printf "\n┌─ GameDig Server Query ──────────────────────────────────────────────┐\n"

if command -v gamedig &>/dev/null; then
	printf "│ Querying server at %s:%s...\n" "$SERVER_IP" "$GAME_PORT"
	printf "│\n"
	
	gamedig_output=$(query_gamedig "$SERVER_IP" "$GAME_PORT" 2>&1 || echo "")
	
	if [[ -n "$gamedig_output" ]]; then
		parse_gamedig_output "$gamedig_output"
	else
		printf "│ GameDig query failed. Server may not be responding.\n"
	fi
else
	printf "│ ⚠ GameDig not installed.\n"
	printf "│ Install GameDig to query server information:\n"
	printf "│   npm install -g gamedig\n"
fi

printf "│\n"
printf "└────────────────────────────────────────────────────────────────────┘\n"

# ============================================================================
# 5. ADDITIONAL INFORMATION
# ============================================================================

printf "\n┌─ Additional Information ───────────────────────────────────────────┐\n"
printf "│ Server Directory: %s\n" "$SERVER_DIRECTORY"
printf "│ Server User: %s\n" "$NEW_USER"
printf "│ Config File: %s\n" "$SERVER_CONFIG"

# Show server process info if running.
if [[ "$STATE" == "running" ]]; then
	server_pid=$(pgrep -u "$NEW_USER" -f DayZServer 2>/dev/null || echo "")
	if [[ -n "$server_pid" ]]; then
		printf "│ Process ID: %s\n" "$server_pid"
		printf "│ Memory Usage: %s\n" "$(ps -p "$server_pid" -o rss= 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')"
		printf "│ CPU Usage: %s\n" "$(ps -p "$server_pid" -o %%cpu= 2>/dev/null | xargs)"
	fi
fi

printf "│\n"
printf "└────────────────────────────────────────────────────────────────────┘\n"

printf "\nStatus check completed at $(date '+%Y-%m-%d %H:%M:%S')\n"
