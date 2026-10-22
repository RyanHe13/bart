import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "run.py"
spec = importlib.util.spec_from_file_location("bart_runner", MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_running_experiment_reads_frozen_driver_and_data(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for directory in ("scripts", "R", "src", "data"):
                (root / directory).mkdir()
            (root / "scripts/Rscript").write_text("wrapper")
            (root / "scripts/experiment.R").write_text("original driver")
            (root / "R/model.R").write_text("original model")
            (root / "data/input.csv").write_text("y\n1\n")
            cfg = root / "config.json"
            cfg.write_text(json.dumps({"schema_version": 1, "phase": "exploratory", "seed": 7,
                                       "data": {"path": "data/input.csv"}}))
            output = root / "run"

            def execute(command, **kwargs):
                if command[0] == "git":
                    return subprocess.CompletedProcess(command, 0, stdout=b"")
                (root / "scripts/experiment.R").write_text("concurrent edit")
                (root / "data/input.csv").write_text("y\n999\n")
                self.assertEqual(Path(command[1]).read_text(), "original driver")
                executed = json.loads(Path(command[2]).read_text())
                self.assertEqual(Path(executed["data"]["path"]).read_text(), "y\n1\n")
                self.assertEqual((output / "source/R/model.R").read_text(), "original model")
                return subprocess.CompletedProcess(command, 0)

            with patch.object(runner, "ROOT", root), patch.object(runner, "git", return_value="test"), \
                    patch.object(runner.subprocess, "run", side_effect=execute):
                self.assertEqual(runner.run_experiment(cfg, output), 0)
            metadata = json.loads((output / "metadata.json").read_text())
            self.assertEqual(metadata["status"], "completed")
            self.assertTrue(metadata["data_sha256"])
            with self.assertRaises(FileExistsError), patch.object(runner, "ROOT", root):
                runner.run_experiment(cfg, output)

    def test_confirmation_rejected_before_output_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            cfg = Path(temp) / "config.json"
            cfg.write_text(json.dumps({"schema_version": 1, "phase": "confirmation", "seed": 7}))
            output = Path(temp) / "run"
            with self.assertRaisesRegex(ValueError, "confirmation"):
                runner.run_experiment(cfg, output)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
