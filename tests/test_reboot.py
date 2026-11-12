import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RebootTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "sudo.log"
        self.env = os.environ.copy()
        self.env["PATH"] = f'{self.bin}:{self.env["PATH"]}'
        self.env["SUDO_LOG"] = str(self.log)
        self.stub("sudo", 'printf "%s\\n" "$@" > "$SUDO_LOG"\nexit "${SUDO_RESULT:-0}"\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)
        return path

    def run_reboot(self, *args):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/reboot.sh"), *args],
            text=True, capture_output=True, env=self.env, timeout=10,
        )

    def test_reboot_uses_exact_noninteractive_command(self):
        result = self.run_reboot()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["-n", "/usr/bin/systemctl", "reboot"])

    def test_reboot_failure_and_arguments_are_reported(self):
        self.env["SUDO_RESULT"] = "1"
        result = self.run_reboot()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not reboot the host", result.stderr)
        self.log.unlink()
        result = self.run_reboot("--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def prepare_rule_installer(self):
        sudoers = self.root / "sudoers.d"
        sudoers.mkdir()
        systemctl = self.stub("systemctl", "exit 0\n")
        self.stub("visudo", '[[ "${VISUDO_RESULT:-0}" == 0 ]]\n')
        installer = (ROOT / "install/install.sh").read_text()
        section = installer.split("# Allow this user to reboot the host without granting other systemctl actions.\n", 1)[1].split(
            '\nUGSM_COPY=', 1
        )[0]
        section = section.replace("/etc/sudoers.d/", f"{sudoers}/")
        section = section.replace('SYSTEMCTL_BIN="/usr/bin/systemctl"', f'SYSTEMCTL_BIN="{systemctl}"')
        section = section.replace("'0:440'", f"'{os.getuid()}:440'")
        self.rule_script = self.root / "install-rule.sh"
        self.rule_script.write_text("#!/usr/bin/env bash\nset -euo pipefail\nNEW_USER=dayz\n" + section)
        return sudoers / "ugsm-dayz-reboot", systemctl

    def run_rule_installer(self):
        return subprocess.run(
            ["bash", str(self.rule_script)], text=True, capture_output=True,
            env=self.env, timeout=10,
        )

    def test_install_rule_and_repeat(self):
        rule, systemctl = self.prepare_rule_installer()
        result = self.run_rule_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rule.read_text(), f"dayz ALL=(root) NOPASSWD: {systemctl} reboot\n")
        self.assertEqual(rule.stat().st_mode & 0o777, 0o440)
        if shutil.which("visudo"):
            result = subprocess.run(
                ["visudo", "-cf", str(rule)], text=True, capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_rule_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already exist", result.stdout)

    def test_rejects_mismatched_or_symlinked_rule(self):
        rule, _ = self.prepare_rule_installer()
        other = self.root / "other"
        other.write_text("custom rules\n")
        other.chmod(0o440)
        rule.symlink_to(other)
        result = self.run_rule_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match", result.stderr)
        self.assertEqual(other.read_text(), "custom rules\n")
        rule.unlink()
        rule.write_text("custom rules\n")
        rule.chmod(0o440)
        result = self.run_rule_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(rule.read_text(), "custom rules\n")

    def test_invalid_sudoers_are_not_installed(self):
        rule, _ = self.prepare_rule_installer()
        self.env["VISUDO_RESULT"] = "1"
        result = self.run_rule_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sudoers rules are invalid", result.stderr)
        self.assertFalse(rule.exists())


if __name__ == "__main__":
    unittest.main()
