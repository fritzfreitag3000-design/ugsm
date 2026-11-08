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

# Check whether a local UDP socket is bound to the exact port.
check_udp_socket() {
	local port="$1"
	if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
		echo "⚠ INVALID PORT"
		return 1
	fi

	if command -v ss &>/dev/null; then
		if ss -H -u -l -n "sport = :$((10#$port))" 2>/dev/null | grep -q .; then
			echo "✓ BOUND"
		else
			echo "✗ NOT BOUND"
		fi
	elif command -v netstat &>/dev/null; then
		if netstat -uln 2>/dev/null | awk -v port="$((10#$port))" '$4 ~ (":" port "$") { found = 1 } END { exit !found }'; then
			echo "✓ BOUND"
		else
			echo "✗ NOT BOUND"
		fi
	else
		echo "? UNKNOWN (ss/netstat not available)"
	fi
}

# Read UFW's status once so each configured port can be checked against the
# same firewall snapshot.
load_ufw_status() {
	local output
	UFW_BIN="/usr/sbin/ufw"
	UFW_STATUS=""
	UFW_STATE="unknown"
	UFW_STATUS_ERROR=""

	if [[ ! -x "$UFW_BIN" ]]; then
		UFW_STATUS_ERROR="ufw not found at $UFW_BIN"
		return
	fi

	if (( EUID == 0 )); then
		if ! output="$("$UFW_BIN" status verbose 2>&1)"; then
			UFW_STATUS_ERROR="$output"
			return
		fi
	elif command -v sudo &>/dev/null; then
		if ! output="$(sudo -n "$UFW_BIN" status verbose 2>&1)"; then
			UFW_STATUS_ERROR="$output"
			return
		fi
	else
		UFW_STATUS_ERROR="root privileges or sudo are required"
		return
	fi

	UFW_STATUS="$output"
	if grep -Fqx "Status: active" <<< "$UFW_STATUS"; then
		UFW_STATE="active"
	elif grep -Fqx "Status: inactive" <<< "$UFW_STATUS"; then
		UFW_STATE="inactive"
	else
		UFW_STATUS_ERROR="could not determine UFW status"
	fi
}

# Report whether UFW has a rule for a configured UDP port.
check_ufw_port() {
	local port="$1" actions incoming_policy
	case "$UFW_STATE" in
		inactive)
			echo "⚠ UFW INACTIVE"
			return
			;;
		unknown)
			printf '? UNKNOWN (%s)\n' "$UFW_STATUS_ERROR"
			return
			;;
	esac

	actions="$(awk -v rule="${port}/udp" '
		$1 == rule {
			action = $2
			if (action == "(v6)") action = $3
			if (action == "ALLOW" || action == "DENY" || action == "REJECT" || action == "LIMIT") {
				print action
			}
		}' <<< "$UFW_STATUS" | sort -u)"

	if grep -Fxq "ALLOW" <<< "$actions"; then
		if grep -Fxq "DENY" <<< "$actions" || grep -Fxq "REJECT" <<< "$actions"; then
			echo "⚠ MIXED ALLOW/DENY RULES"
		else
			echo "✓ ALLOW RULE"
		fi
	elif grep -Fxq "DENY" <<< "$actions" || grep -Fxq "REJECT" <<< "$actions"; then
		echo "✗ BLOCKED (DENY RULE)"
	elif grep -Fxq "LIMIT" <<< "$actions"; then
		echo "⚠ LIMITED"
	else
		incoming_policy="$(awk '
			/^Default:/ {
				line = tolower($0)
				if (index(line, "deny (incoming)")) print "deny"
				else if (index(line, "allow (incoming)")) print "allow"
			}' <<< "$UFW_STATUS")"
		case "$incoming_policy" in
			deny) echo "✗ BLOCKED (DEFAULT DENY)" ;;
			allow) echo "⚠ NO EXPLICIT RULE (DEFAULT ALLOW)" ;;
			*) echo "⚠ NO EXPLICIT RULE" ;;
		esac
	fi
}

# Check whether the BattlEye RCON endpoint responds to an authenticated command.
check_rcon_response() {
	local server_ip="$1"
	local port="$2"
	local rcon_password="$3"
	local rcon_host="$server_ip"

	if ! command -v bercon-cli &>/dev/null; then
		echo "? UNKNOWN (bercon-cli not available)"
	elif [[ -z "$rcon_password" ]] || [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
		echo "? UNKNOWN (RCON configuration missing or invalid)"
	else
		[[ -z "$rcon_host" || "$rcon_host" == "0.0.0.0" ]] && rcon_host="127.0.0.1"
		if BERCON_PASSWORD="$rcon_password" bercon-cli --no-env --ip "$rcon_host" \
			--port "$((10#$port))" --timeout 3s --attempts 1 --format raw exec -- players \
			>/dev/null 2>&1; then
			echo "✓ RESPONDING"
		else
			echo "✗ NO RESPONSE"
		fi
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
	printf "  Server IP: %s\n" "$(echo "$json" | jq -r '.connect // "N/A"')"
	
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
RCON_PASS="$(read_setting "$SERVER_CONFIG" RCON_PASS)"
NEW_USER="$(read_setting "$SERVER_CONFIG" NEW_USER)"
load_ufw_status

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

printf "│ Game Port (UDP %s)\n" "$GAME_PORT"
printf "│   Local socket: " && check_udp_socket "$GAME_PORT"
printf "│   UFW firewall: " && check_ufw_port "$GAME_PORT"
printf "│\n"

printf "│ RCON Port (UDP %s)\n" "$RCON_PORT"
printf "│   Local socket: " && check_udp_socket "$RCON_PORT"
printf "│   UFW firewall: " && check_ufw_port "$RCON_PORT"
printf "│   RCON check: " && check_rcon_response "$SERVER_IP" "$RCON_PORT" "$RCON_PASS"
printf "│\n"

printf "│ Steam Query Port (UDP %s)\n" "$STEAM_QUERY_PORT"
printf "│   Local socket: " && check_udp_socket "$STEAM_QUERY_PORT"
printf "│   UFW firewall: " && check_ufw_port "$STEAM_QUERY_PORT"
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
	QUERY_HOST="$SERVER_IP"
	[[ -z "$QUERY_HOST" || "$QUERY_HOST" == "0.0.0.0" ]] && QUERY_HOST="127.0.0.1"
	printf "│ Querying server at %s:%s...\n" "$QUERY_HOST" "$GAME_PORT"
	printf "│\n"
	
	gamedig_output=$(query_gamedig "$QUERY_HOST" "$GAME_PORT" 2>&1 || echo "")
	
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
	mapfile -t server_pids < <(pgrep -u "$NEW_USER" -f DayZServer 2>/dev/null || true)
	if (( ${#server_pids[@]} > 0 )); then
		for server_pid in "${server_pids[@]}"; do
			printf "│ Process ID: %s\n" "$server_pid"
		done
	fi
fi

printf "│\n"
printf "└────────────────────────────────────────────────────────────────────┘\n"

printf "\nStatus check completed at $(date '+%Y-%m-%d %H:%M:%S')\n"
