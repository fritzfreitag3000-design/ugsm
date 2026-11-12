import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StartFirewallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.server = Path(self.temp.name) / "testserver"
        self.project = self.server / "ugsm"
        self.scripts = self.project / "scripts"
        self.data = self.server / "serverdata"
        self.bin = Path(self.temp.name) / "bin"
        self.scripts.mkdir(parents=True)
        self.data.mkdir()
        self.bin.mkdir()
        (self.data / "profiles").mkdir()

        start_script = (ROOT / "scripts/start.sh").read_text()
        self.ufw = self.bin / "ufw"
        self.ufw_log = Path(self.temp.name) / "ufw.log"
        self.ufw.write_text(
            '#!/usr/bin/env bash\n'
            'printf "%s\\n" "$*" >> "$UFW_LOG"\n'
            'printf "simulated firewall failure\\n" >&2\n'
            'exit 1\n'
        )
        self.ufw.chmod(0o755)
        start_script = start_script.replace(
            'UFW_BIN="/usr/sbin/ufw"', f'UFW_BIN="{self.ufw}"'
        )
        (self.scripts / "start.sh").write_text(start_script)
        (self.scripts / "mods.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        (self.data / "DayZServer").write_text("")
        (self.data / "DayZServer").chmod(0o755)

        config = self.project / "config"
        config.mkdir()
        (config / "start.conf").write_text(
            'CONFIG_FILE="serverDZ.cfg"\nPROFILES="profiles"\n'
            'BEPATH="battleye/battleye"\nCPUCOUNT=""\nLIMITFPS=""\n'
            'EXTRA_PARAMS=""\nHIVE_PATTERN="HiveReady"\n'
        )
        (config / "mods.conf").write_text("")
        (config / "servermod.conf").write_text("")
        install = self.project / "install"
        install.mkdir()
        (install / "testserver_server.conf").write_text(
            'SERVER_IP="127.0.0.1"\n'
            f'NEW_USER="{pwd.getpwuid(os.getuid()).pw_name}"\n'
            'GAME_PORT=2302\nRCON_PORT=2303\nSTEAM_QUERY_PORT=27016\n'
            'STARTUP_TIMEOUT=10\nPORT_OPEN_DELAY=0\nSTATE="stop"\n'
        )

        tmux = self.bin / "tmux"
        tmux.write_text(
            '#!/usr/bin/env bash\n'
            'case "$1" in\n'
            '  has-session) [[ -e "$TMUX_STATE" ]] ;;\n'
            '  new-session) touch "$TMUX_STATE" ;;\n'
            '  capture-pane) printf "HiveReady\\n" ;;\n'
            '  *) exit 0 ;;\n'
            'esac\n'
        )
        tmux.chmod(0o755)
        ss = self.bin / "ss"
        ss.write_text("#!/usr/bin/env bash\nexit 0\n")
        ss.chmod(0o755)
        sudo = self.bin / "sudo"
        sudo.write_text(
            '#!/usr/bin/env bash\n'
            '[[ "$1" == "-n" ]] && shift\n'
            'exec "$@"\n'
        )
        sudo.chmod(0o755)

    def test_firewall_failures_warn_but_server_reaches_running_state(self):
        env = os.environ.copy()
        env["PATH"] = f'{self.bin}:{env["PATH"]}'
        env["TMUX_STATE"] = str(Path(self.temp.name) / "tmux.state")
        env["UFW_LOG"] = str(self.ufw_log)

        result = subprocess.run(
            ["bash", str(self.scripts / "start.sh")],
            text=True,
            capture_output=True,
            env=env,
            timeout=15,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not remove the UFW allow rule", result.stderr)
        self.assertIn("Could not add the UFW allow rule", result.stderr)
        self.assertIn("Server is running", result.stderr)
        server_config = self.project / "install/testserver_server.conf"
        self.assertIn('STATE="running"', server_config.read_text())
        firewall_calls = self.ufw_log.read_text().splitlines()
        self.assertEqual(firewall_calls.count("status verbose"), 1)
        self.assertEqual(sum(call.startswith("delete allow ") for call in firewall_calls), 3)
        self.assertEqual(sum(call.startswith("allow ") for call in firewall_calls), 3)


if __name__ == "__main__":
    unittest.main()
