import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class VsftpdInstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / "install"
        self.install.mkdir()
        self.home = self.root / "home/dayz"
        self.home.mkdir(parents=True)
        self.etc = self.root / "etc"
        (self.etc / "systemd/system").mkdir(parents=True)
        (self.etc / "vsftpd.conf").write_text("old configuration\n")
        (self.root / "var/lib").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "systemctl.log"

        script = (ROOT / "install/install_vsftpd.sh").read_text()
        script = script.replace('if [[ "$EUID" -ne 0 ]]; then', 'if false; then')
        script = script.replace("USER_ID < 1000", "USER_ID < 0")
        script = script.replace("^/home/", f"^{self.root}/home/")
        script = script.replace("/var/lib/ugsm-vsftpd", str(self.root / "var/lib/ugsm-vsftpd"))
        script = script.replace("/etc/", f"{self.etc}/")
        script = script.replace('!= 0 ]]', f'!= {os.getuid()} ]]')
        script = script.replace("0:600", f"{os.getuid()}:600")
        script = script.replace("0:644", f"{os.getuid()}:644")
        script = script.replace("-o root -g root ", "")
        self.script = self.install / "install_vsftpd.sh"
        self.script.write_text(script)
        (self.install / "a_server.conf").write_text('NEW_USER="dayz"\n')

        self.stub("getent", f'printf "dayz:x:{os.getuid()}:{os.getgid()}::%s:/bin/bash\\n" "{self.home}"\n')
        self.stub("systemctl", f'printf "%s\\n" "$*" >> "{self.log}"\n')
        self.stub("findmnt", "exit 1\n")
        self.env = os.environ.copy()
        self.env["PATH"] = f'{self.bin}:{self.env["PATH"]}'

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)

    def run_installer(self, answers):
        return subprocess.run(
            ["bash", str(self.script)], input=answers, text=True,
            capture_output=True, env=self.env, timeout=30,
        )

    def test_setup_and_repeat_preserve_allowlist(self):
        result = self.run_installer("y\n198.51.100.10\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        base = self.root / "var/lib/ugsm-vsftpd"
        config = (self.etc / "vsftpd.conf").read_text()
        self.assertIn("chroot_local_user=YES\n", config)
        self.assertIn("allow_writeable_chroot=NO\n", config)
        self.assertIn("force_local_logins_ssl=YES\n", config)
        self.assertIn("force_local_data_ssl=YES\n", config)
        self.assertIn("userlist_deny=NO\n", config)
        self.assertIn("pasv_address=198.51.100.10\n", config)
        self.assertEqual((base / "users").read_text(), "dayz\n")
        self.assertEqual((base / "ftps-key.pem").stat().st_mode & 0o777, 0o600)
        self.assertTrue((base / "jails/dayz/home").is_dir())
        self.assertEqual(len(list(self.etc.glob("vsftpd.conf.ugsm-backup.*"))), 1)
        mount = next((self.etc / "systemd/system").glob("*.mount"))
        self.assertIn(f"What={self.home}\n", mount.read_text())
        self.assertIn(f"Requires={mount.name}\n", (self.etc / "systemd/system/vsftpd.service.d/ugsm-dayz.conf").read_text())
        self.assertIn("restart vsftpd.service", self.log.read_text())
        result = self.run_installer("y\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((base / "users").read_text(), "dayz\n")
        self.assertIn("pasv_address=198.51.100.10\n", (self.etc / "vsftpd.conf").read_text())

    def test_selection_and_invalid_address_fail_without_changing_config(self):
        (self.install / "b_server.conf").write_text('NEW_USER="dayz"\n')
        result = self.run_installer("2\ny\ninvalid-address\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("b_server.conf", result.stdout)
        self.assertIn("Invalid IPv4", result.stderr)
        self.assertEqual((self.etc / "vsftpd.conf").read_text(), "old configuration\n")

    def test_multiple_users_keep_separate_jails(self):
        second_home = self.root / "home/other"
        second_home.mkdir()
        (self.install / "b_server.conf").write_text('NEW_USER="other"\n')
        self.stub(
            "getent",
            f'printf "%s:x:{os.getuid()}:{os.getgid()}::%s:/bin/bash\\n" "$2" "{self.root}/home/$2"\n',
        )
        first = self.run_installer("1\ny\n\n")
        second = self.run_installer("2\ny\n\n")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        base = self.root / "var/lib/ugsm-vsftpd"
        self.assertEqual((base / "users").read_text(), "dayz\nother\n")
        self.assertTrue((base / "jails/dayz/home").is_dir())
        self.assertTrue((base / "jails/other/home").is_dir())
        self.assertEqual(len(list((self.etc / "systemd/system").glob("*.mount"))), 2)

    def test_rejects_system_account(self):
        self.stub("getent", f'printf "dayz:x:0:0::%s:/bin/bash\\n" "{self.home}"\n')
        # Retain the real system-account threshold for this check.
        self.script.write_text(self.script.read_text().replace("USER_ID < 0", "USER_ID < 1000"))
        result = self.run_installer("")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing system user", result.stderr)


if __name__ == "__main__":
    unittest.main()
