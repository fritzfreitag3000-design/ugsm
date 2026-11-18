import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MultiserverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env["PATH"] = f'{self.bin}:{self.env["PATH"]}'

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)
        return path

    def test_installer_rejects_ports_assigned_to_another_server(self):
        install = self.root / "install"
        install.mkdir()
        current = install / "second_server.conf"
        other = install / "first_server.conf"
        current.write_text("")
        other.write_text(
            'SERVER_NAME="first"\nGAME_PORT=2304\nRCON_PORT=2305\n'
            'STEAM_QUERY_PORT=27017\n'
        )
        installer = (ROOT / "install/install.sh").read_text()
        section = installer.split("# A UDP port may belong", 1)[1].split(
            "# Give each user/server pair", 1
        )[0]
        script = self.root / "check-ports.sh"
        script.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            f'SCRIPT_DIR="{install}"\nINSTALL_CONFIG="{current}"\n'
            'GAME_PORT=2304\nRCON_PORT=2306\nSTEAM_QUERY_PORT=27018\n'
            + "# A UDP port may belong"
            + section
        )

        result = subprocess.run(
            ["bash", str(script)], text=True, capture_output=True, timeout=10
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UDP port 2304 is already assigned to server first", result.stderr)

        other.write_text(
            'SERVER_NAME="first"\nGAME_PORT=2402\nRCON_PORT=2403\n'
            'STEAM_QUERY_PORT=27116\n'
        )
        result = subprocess.run(
            ["bash", str(script)], text=True, capture_output=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stop_closes_only_its_configured_ports(self):
        server = self.root / "server"
        project = server / "ugsm"
        scripts = project / "scripts"
        install = project / "install"
        scripts.mkdir(parents=True)
        install.mkdir()
        stop = (ROOT / "scripts/stop.sh").read_text()
        ufw = self.stub(
            "ufw",
            'printf "%s\\n" "$*" >> "$UFW_LOG"\nexit 0\n',
        )
        stop = stop.replace('UFW_BIN="/usr/sbin/ufw"', f'UFW_BIN="{ufw}"')
        (scripts / "stop.sh").write_text(stop)
        user = pwd.getpwuid(os.getuid()).pw_name
        (install / "server_server.conf").write_text(
            f'NEW_USER="{user}"\nGAME_PORT=2310\nRCON_PORT=2311\n'
            'STEAM_QUERY_PORT=27026\nSTATE="running"\n'
        )
        self.stub("tmux", "exit 1\n")
        self.stub(
            "sudo",
            '[[ "$1" == "-n" ]] && shift\nexec "$@"\n',
        )
        ufw_log = self.root / "ufw.log"
        env = dict(self.env, UFW_LOG=str(ufw_log))

        result = subprocess.run(
            ["bash", str(scripts / "stop.sh")],
            text=True,
            capture_output=True,
            env=env,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            ufw_log.read_text().splitlines(),
            [
                "delete allow 2310/udp",
                "delete allow 2311/udp",
                "delete allow 27026/udp",
            ],
        )

    def test_scheduler_does_not_use_another_server_process(self):
        server = self.root / "server"
        project = server / "ugsm"
        scripts = project / "scripts"
        install = project / "install"
        config = project / "config"
        scripts.mkdir(parents=True)
        install.mkdir()
        config.mkdir()
        (config / "scheduler.conf").write_text("")
        user = pwd.getpwuid(os.getuid())
        (install / "server_server.conf").write_text(
            f'NEW_USER="{user.pw_name}"\nSTATE="running"\n'
            'GAME_PORT=2320\nRCON_PORT=2321\nSTEAM_QUERY_PORT=27036\n'
        )
        scheduler = (ROOT / "scripts/scheduler.sh").read_text().split(
            '\ncase "${1:-}" in\n', 1
        )[0]
        (scripts / "scheduler.sh").write_text(
            scheduler
            + '\ncheck_server_health\nprintf "HEALTH_OK=%s\\n" "$HEALTH_OK"\n'
            + 'printf "%s\\n" "$HEALTH_DETAILS"\n'
        )
        self.stub(
            "tmux",
            'case "$1" in\n'
            '  has-session) exit 0 ;;\n'
            '  display-message) printf "%s\\n" "${PANE_PID:-}" ;;\n'
            'esac\n',
        )
        self.stub(
            "ps",
            f'case "$*" in\n'
            '  *"uid="*) printf "{user.pw_uid}\\n" ;;\n'
            '  *"args="*) printf "./other-process\\n" ;;\n'
            'esac\n',
        )
        self.stub("ss", "printf 'udp UNCONN 0 0 127.0.0.1:2320 0.0.0.0:*\\n'\n")
        self.stub("pgrep", "exit 0\n")

        result = subprocess.run(
            ["bash", str(scripts / "scheduler.sh")],
            text=True,
            capture_output=True,
            env=dict(self.env, PANE_PID="4242"),
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HEALTH_OK=0", result.stdout)
        self.assertIn("dayz process: ✗ missing", result.stdout)


if __name__ == "__main__":
    unittest.main()
