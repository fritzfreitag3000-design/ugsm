from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SchedulerMaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "server name" / "ugsm"
        self.scripts = self.project / "scripts"
        self.scripts.mkdir(parents=True)
        config = self.project / "config"
        config.mkdir()
        (config / "scheduler.conf").write_text(
            'MAINTENANCE_START_SERVER=0\n'
            'MAINTENANCE_COMMAND="./maintenance.sh"\n'
            'MAINTENANCE_COMMAND="pwd > second-command-directory"\n'
        )
        scheduler = (ROOT / "scripts/scheduler.sh").read_text()
        scheduler = scheduler.split('\ncase "${1:-}" in\n', 1)[0]
        (self.scripts / "scheduler.sh").write_text(scheduler + '\nrun_maintenance "test"\n')
        self.stub("stop.sh", "exit 0\n")
        self.stub("maintenance.sh", 'pwd > first-command-directory\ncd /\n')
        self.stub("start.sh", 'echo unexpected-start\n')

    def stub(self, name, body):
        script = self.scripts / name
        script.write_text("#!/usr/bin/env bash\n" + body)
        script.chmod(0o755)

    def test_commands_run_in_scripts_directory_independently(self):
        result = subprocess.run(
            ["bash", str(self.scripts / "scheduler.sh")],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.scripts / "first-command-directory").read_text().strip(), str(self.scripts))
        self.assertEqual((self.scripts / "second-command-directory").read_text().strip(), str(self.scripts))
        self.assertNotIn("unexpected-start", result.stdout)

    def test_stop_failure_does_not_run_maintenance(self):
        self.stub("stop.sh", "exit 1\n")
        result = subprocess.run(
            ["bash", str(self.scripts / "scheduler.sh")],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )
        self.assertIn("maintenance cancelled", result.stdout)
        self.assertFalse((self.scripts / "first-command-directory").exists())


if __name__ == "__main__":
    unittest.main()
