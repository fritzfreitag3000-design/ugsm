# ugsm

## Server configuration

The DayZ installer copies `config/default_serverDZ.cfg` to
`serverdata/serverDZ.cfg`, replacing any existing server configuration each
time it runs. Back up custom settings before rerunning the installer.

## FTPS access

Run `sudo bash install/install_vsftpd.sh` and select a server configuration.
The existing Linux account and password are used; no password is changed. The
script replaces the global vsftpd configuration after confirmation and saves
the previous file under `/etc/vsftpd.conf.ugsm-backup.*`. It restricts logins
to UGSM accounts added with this script. Existing FTP access may be affected.

Connect using explicit FTPS on TCP port 21, verify the displayed SHA-256
fingerprint of the self-signed certificate, and open the `home` folder. This
is the user's real home directory, bind-mounted inside a root-owned FTP jail.
Absolute symlinks or symlinks pointing outside this jail will not work through
FTP. The script does not change firewall or router rules: permit TCP 21 and
50000-50100, and forward those ports when behind NAT. Enter the public IPv4
address when prompted if the server is behind NAT.
On subsequent runs, Enter retains the existing passive address; enter `-` to
clear it.

## BattlEye

The installer creates `serverdata/battleye/battleyercon/beserver_x64.cfg` and the
default start configuration uses `-BEpath=battleyercon`. For existing
installations, update `BEPATH` in the server's copy of `config/start.conf` to
match. The main installer reuses an existing server project copy, so update its
`install/install_dayz.sh` before rerunning it. Existing `battleye` directories
are left in place. A previous installer could create a literal
`battleye\battleye` entry in `serverdata`; the installer removes it, but will
not delete a non-empty directory.
Backups include `battleye` and the former top-level `battleyercon` when
present. Restoring an older backup without `battleye/battleyercon` preserves
the current RCON directory.

## Workshop mods

List client-required Workshop IDs in `config/mods.conf` and server-only IDs in
`config/servermod.conf`, one ID per line without `#`. Run `scripts/mods.sh` to
download the mods and create links named after their IDs in `serverdata`.
Existing UGSM `@ID` links are migrated when the script runs. Run it again after
removing an ID from both lists to uninstall that mod.

`scripts/start.sh` uses these links in `-mod` and `-servermod`. Run
`scripts/start.sh --print` to inspect the command before starting the server.
For example, two client mods produce `-mod=1559212036;1564026768` as one
argument; shell output may escape the semicolon.

Every actual server start, including scheduler restarts, first runs SteamCMD to
update and validate the DayZ server and all listed Workshop mods. A failed
update cancels the start. The `--print` option does not run updates. SteamCMD
is run as the configured server user, uses the `STEAM_USER` in the server
configuration and may request a password or Steam Guard code. Scheduled starts
have no interactive input and therefore require a working saved SteamCMD
login; if authentication fails, the server will not start and the error
appears in the scheduler output.

## Dashboard

Start the tmux dashboard with `scripts/dashboard.sh [server-name]`. Run it as the
Linux user that owns that server's tmux sessions. It opens the interactive
UGSM menu in the upper-left pane, the server console output in the upper-right,
and the scheduler output across the bottom. The server and scheduler output
panes are read-only monitors; their existing tmux sessions are left untouched.
If an older or incomplete dashboard exists, exit any menu action and close
that dashboard using the command reported by the script before starting it
again.

To start the scheduler automatically after a reboot, open the dashboard's
Scheduler menu and choose **Enable scheduler autostart**. The systemd service
starts the tmux scheduler at boot.

Use **Enable auto-recovery** or **Disable auto-recovery** in the Scheduler menu
to change `AUTO_RECOVER` in `scheduler.conf`. A running scheduler picks up the
change on its next minute check.

Mouse scrolling is enabled in the dashboard. Click the menu or scheduler pane
first, then scroll to enter tmux scrollback. Press `q` to return to the live
view; click the menu to enter commands again. You can also use `Ctrl+b`, then
`[` to enter scrollback in the selected pane.

## Host reboot

The installer grants the configured Linux user passwordless access to
`systemctl reboot` only. Run `scripts/reboot.sh` as that user to reboot the
entire Linux host, including all other services. The script does not stop the
DayZ server first. For scheduled maintenance, the scheduler stops it before
running commands: the default `config/scheduler.conf` sets
`MAINTENANCE_START_SERVER=0` and runs `MAINTENANCE_COMMAND="./reboot.sh"` at
the configured maintenance time. Maintenance
commands run in the installation's `scripts` directory, regardless of where
the scheduler was started. Existing commands using relative paths may need
updating. Enable
scheduler autostart and auto-recovery if the DayZ server should start again
after boot. If the reboot command fails, the scheduler leaves the DayZ server
stopped when `MAINTENANCE_START_SERVER=0`.

On an existing installation, rerun the updated installer to grant the rule.
It reuses the existing project copy without updating its scripts, so also copy
the updated `scripts/reboot.sh` and `scripts/scheduler.sh` into that
installation, then restart the scheduler.