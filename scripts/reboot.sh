#!/usr/bin/env bash
set -uo pipefail

if [[ "$#" -ne 0 ]]; then
	printf 'Usage: %s\n' "$0" >&2
	exit 1
fi

if ! sudo -n /usr/bin/systemctl reboot; then
	printf 'Could not reboot the host. Check the reboot sudoers permission and systemd status.\n' >&2
	exit 1
fi
