#!/usr/bin/env bash
set -euo pipefail

# Install or remove the scheduler autostart for this server.
ACTION="${1:-install}"
if [[ "$#" -gt 1 || ( "$ACTION" != "install" && "$ACTION" != "uninstall" ) ]]; then
	printf 'Usage: %s [install|uninstall]\n' "$0" >&2
	exit 1
fi

# Find the root-owned helper for the current user and server folder.
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
SERVER_DIRECTORY="$(cd -- "$PROJECT_DIRECTORY/.." && pwd)"
SERVER_NAME="$(basename -- "$SERVER_DIRECTORY")"
SERVER_USER="$(id -un)"
if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ ! "$SERVER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
	printf 'Invalid server folder or user name.\n' >&2
	exit 1
fi
HELPER="/etc/ugsm-scheduler-autostart/$SERVER_USER/$SERVER_NAME/scheduler-autostart"

# Run only the matching helper without asking for a password.
exec sudo -n -- "$HELPER" "$ACTION"