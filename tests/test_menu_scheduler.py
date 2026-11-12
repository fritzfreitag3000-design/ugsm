from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SchedulerMenuTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        project = Path(self.temp.name) / "testserver" / "ugsm"
        self.scripts = project / "scripts"
        self.scripts.mkdir(parents=True)
        self.config = project / "config"
        self.config.mkdir()
        self.scheduler_config = self.config / "scheduler.conf"
        (self.scripts / "menu.sh").write_text((ROOT / "scripts/menu.sh").read_text())
        (self.scripts / "status.sh").write_text("#!/bin/bash\nexit 0\n")

    def run_menu(self, choices):
        return subprocess.run(
            ["bash", str(self.scripts / "menu.sh")],
            input=choices,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_enable_and_disable_preserve_other_settings_and_comment(self):
        self.scheduler_config.write_text(
            '# AUTO_RECOVER=0\nRESTART_TIMES="12:00"\n'
            '  AUTO_RECOVER = "0"  # recovery\nOTHER=1\n'
        )
        self.scheduler_config.chmod(0o640)
        result = self.run_menu("4\n8\n0\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Auto-recovery enabled.", result.stdout)
        self.assertIn('  AUTO_RECOVER =1  # recovery\n', self.scheduler_config.read_text())
        result = self.run_menu("4\n9\n0\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Auto-recovery disabled.", result.stdout)
        self.assertEqual(
            self.scheduler_config.read_text(),
            '# AUTO_RECOVER=0\nRESTART_TIMES="12:00"\n'
            '  AUTO_RECOVER =0  # recovery\nOTHER=1\n',
        )
        self.assertEqual(self.scheduler_config.stat().st_mode & 0o777, 0o640)

    def test_missing_setting_is_added(self):
        self.scheduler_config.write_text('RESTART_TIMES="12:00"\n')
        result = self.run_menu("4\n8\n0\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Auto-recovery enabled.", result.stdout)
        self.assertEqual(
            self.scheduler_config.read_text(),
            'RESTART_TIMES="12:00"\nAUTO_RECOVER=1\n',
        )

    def test_missing_config_reports_error_without_creating_file(self):
        result = self.run_menu("4\n8\n0\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Config file is missing or unreadable:", result.stdout)
        self.assertNotIn("Auto-recovery enabled.", result.stdout)
        self.assertFalse(self.scheduler_config.exists())


if __name__ == "__main__":
    unittest.main()
