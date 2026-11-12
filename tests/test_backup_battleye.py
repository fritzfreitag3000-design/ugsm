from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class BattlEyeBackupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.server = Path(self.temp.name) / "server"
        self.data = self.server / "serverdata"
        self.script = self.server / "ugsm/scripts/backup.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy(ROOT / "scripts/backup.sh", self.script)
        (self.data / "mpmissions/mission").mkdir(parents=True)
        (self.data / "profiles").mkdir()
        (self.data / "battleye/battleyercon").mkdir(parents=True)
        (self.data / "serverDZ.cfg").write_text('template = "mission";\n')
        (self.data / "battleye/battleyercon/beserver_x64.cfg").write_text("original")

    def run_backup(self, *args, input=None):
        return subprocess.run(
            ["bash", str(self.script), *args],
            input=input,
            text=True,
            capture_output=True,
        )

    def test_backup_and_recovery_include_rcon_directory(self):
        legacy = self.data / "battleye/legacy.cfg"
        legacy.write_text("legacy original")
        for mode in ("auto_recover", "recover"):
            with self.subTest(mode=mode):
                result = self.run_backup()
                self.assertEqual(result.returncode, 0, result.stderr)
                archive = next((self.server / "backup").glob("[0-9]*.zip"))
                with zipfile.ZipFile(archive) as backup:
                    self.assertTrue(any(
                        name.endswith("/battleye/battleyercon/beserver_x64.cfg")
                        for name in backup.namelist()
                    ))
                    self.assertTrue(any(
                        name.endswith("/battleye/legacy.cfg")
                        for name in backup.namelist()
                    ))
                config = self.data / "battleye/battleyercon/beserver_x64.cfg"
                config.write_text("changed")
                legacy.write_text("legacy changed")
                result = self.run_backup(mode, input="1\ny\n" if mode == "recover" else None)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(config.read_text(), "original")
                self.assertEqual(legacy.read_text(), "legacy original")

    def test_old_backup_preserves_current_rcon_directory(self):
        backup_dir = self.server / "backup"
        backup_dir.mkdir()
        with zipfile.ZipFile(backup_dir / "old.zip", "w") as archive:
            archive.writestr("old/battleye/legacy.cfg", "legacy")
            archive.writestr("old/mission/file", "mission")
            archive.writestr("old/profiles/file", "profiles")
            archive.writestr("old/serverDZ.cfg", 'template = "mission";\n')
        result = self.run_backup("auto_recover")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("leaving the current directory unchanged", result.stderr)
        self.assertEqual((self.data / "battleye/battleyercon/beserver_x64.cfg").read_text(), "original")
        self.assertEqual((self.data / "battleye/legacy.cfg").read_text(), "legacy")

    def test_invalid_rcon_backup_does_not_remove_current_data(self):
        backup_dir = self.server / "backup"
        backup_dir.mkdir()
        with zipfile.ZipFile(backup_dir / "old.zip", "w") as archive:
            archive.writestr("old/battleye/battleyercon", "not a directory")
            archive.writestr("old/mission/file", "mission")
            archive.writestr("old/profiles/file", "profiles")
            archive.writestr("old/serverDZ.cfg", 'template = "mission";\n')
        result = self.run_backup("auto_recover")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid BattlEye RCON directory", result.stderr)
        self.assertEqual((self.data / "battleye/battleyercon/beserver_x64.cfg").read_text(), "original")


if __name__ == "__main__":
    unittest.main()
