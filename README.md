# ugsm

Start the tmux dashboard with `scripts/dashboard.sh`. It opens the interactive
UGSM menu in the upper-left pane, the server console output in the upper-right,
and the scheduler output across the bottom. The server and scheduler output
panes are read-only monitors; their existing tmux sessions are left untouched.
Run the dashboard as the user that owns those tmux sessions. If an older or
incomplete dashboard exists, exit any menu action and close that dashboard
using the command reported by the script before starting it again.

Mouse scrolling is enabled in the dashboard. Click the menu or scheduler pane
first, then scroll to enter tmux scrollback. Press `q` to return to the live
view; click the menu to enter commands again. You can also use `Ctrl+b`, then
`[` to enter scrollback in the selected pane.