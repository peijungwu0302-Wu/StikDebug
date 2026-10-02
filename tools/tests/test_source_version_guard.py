import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "tools" / "ensure_source_version_absent.py"


class SourceVersionGuardTests(unittest.TestCase):
    def run_guard(self, versions: list[str], target: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_path = Path(temporary_directory) / "source.json"
            source_path.write_text(
                json.dumps(
                    {"apps": [{"versions": [{"version": version} for version in versions]}]}
                ),
                encoding="utf-8",
            )
            return subprocess.run(
                [sys.executable, str(GUARD), target, str(source_path)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_absent_target_version_allows_source_update(self) -> None:
        result = self.run_guard(["1.2.18"], "1.2.19")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("may proceed", result.stdout)

    def test_existing_target_version_rejects_duplicate_update(self) -> None:
        result = self.run_guard(["1.2.19", "1.2.18"], "1.2.19")

        self.assertEqual(result.returncode, 1)
        self.assertIn("already contains 1.2.19", result.stderr)
        self.assertIn("refusing an ambiguous duplicate release", result.stderr)


if __name__ == "__main__":
    unittest.main()
