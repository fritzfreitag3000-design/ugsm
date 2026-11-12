# ugsm

## Server configuration

The DayZ installer copies `config/default_serverDZ.cfg` to
`serverdata/serverDZ.cfg`, replacing any existing server configuration each
time it runs. Back up custom settings before rerunning the installer.

## BattlEye

The installer creates `serverdata/battleyercon/beserver_x64.cfg` and the
default start configuration uses `-BEpath=battleyercon`. For existing
installations, update `BEPATH` in the server's copy of `config/start.conf` to
match. The main installer reuses an existing server project copy, so update its
`install/install_dayz.sh` before rerunning it. Existing `battleye` directories
are left in place. A previous installer could create a literal
`battleye\battleye` entry in `serverdata`; the installer removes it, but will
not delete a non-empty directory.
Backups include both `battleyercon` and `battleye` when present. Restoring an
older backup without `battleyercon` leaves the current directory unchanged.

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

Mouse scrolling is enabled in the dashboard. Click the menu or scheduler pane
first, then scroll to enter tmux scrollback. Press `q` to return to the live
view; click the menu to enter commands again. You can also use `Ctrl+b`, then
`[` to enter scrollback in the selected pane.