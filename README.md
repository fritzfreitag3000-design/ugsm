# ugsm

Start a registered server's tmux dashboard from any directory with
`ugsm <server-name>` (for example, `ugsm my-server`). The server is registered
by `install/install.sh`; after updating the UGSM copy on an existing server, run
`sudo /path/to/server/ugsm/scripts/install_command.sh` once. Run `ugsm` as the
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