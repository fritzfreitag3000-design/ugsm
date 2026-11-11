import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class BattlEyeInstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.server = Path(self.temp.name) / "testserver"
        self.data = self.server / "serverdata"
        self.data.mkdir(parents=True)
        steamcmd = self.server / "steam" / "steamcmd.sh"
        steamcmd.parent.mkdir()
        steamcmd.write_text("#!/usr/bin/env bash\nexit 0\n")
        steamcmd.chmod(0o755)
        self.config = self.server / "server.conf"
        self.config.write_text(
            'RCON_PORT="2305"\nRCON_PASS="example"\n'
            'GAME_PORT="2302"\nSERVER_IP="127.0.0.1"\n'
        )
        self.legacy = self.data / "battleye\\battleye"

    def install(self):
        return subprocess.run(
            ["bash", str(ROOT / "install/install_dayz.sh"), str(self.server), "", str(self.config)],
            text=True,
            capture_output=True,
        )

    def test_installs_nested_config_and_removes_legacy_entry(self):
        for legacy_type in ("absent", "directory", "file"):
            with self.subTest(legacy_type=legacy_type):
                if legacy_type == "directory":
                    self.legacy.mkdir()
                elif legacy_type == "file":
                    self.legacy.touch()
                result = self.install()
                self.assertEqual(result.returncode, 0, result.stderr)
                config = self.data / "battleye/battleye/beserver_x64.cfg"
                self.assertEqual(config.read_text(), "RConPassword example\nRConPort 2305\n")
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
                self.assertFalse(self.legacy.exists())
                self.assertIn("-BEpath=battleye/battleye", result.stdout)

    def test_nonempty_legacy_directory_is_preserved(self):
        self.legacy.mkdir()
        contents = self.legacy / "keep"
        contents.write_text("data")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("check its contents", result.stderr)
        self.assertEqual(contents.read_text(), "data")

    def test_default_start_command_uses_installed_config_directory(self):
        project = self.server / "ugsm"
        (project / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/start.sh", project / "scripts/start.sh")
        shutil.copytree(ROOT / "config", project / "config")
        (project / "install").mkdir()
        (project / "install/testserver_server.conf").write_text(
            self.config.read_text()
            + f'STEAM_QUERY_PORT="27016"\nNEW_USER="{pwd.getpwuid(os.getuid()).pw_name}"\n'
        )
        dayz = self.data / "DayZServer"
        dayz.touch(mode=0o755)
        bin_dir = self.server / "bin"
        bin_dir.mkdir()
        tmux = bin_dir / "tmux"
        tmux.write_text("#!/usr/bin/env bash\nexit 1\n")
        tmux.chmod(0o755)
        ss = bin_dir / "ss"
        ss.write_text("#!/usr/bin/env bash\nexit 0\n")
        ss.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f'{bin_dir}:{env["PATH"]}'
        result = subprocess.run(
            ["bash", str(project / "scripts/start.sh"), "--print"],
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-BEpath=battleye/battleye", result.stdout)


if __name__ == "__main__":
    unittest.main()
