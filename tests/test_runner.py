import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
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
            self.assertEqual(metadata["data_sha256"], runner.digest(output / "input.csv"))
            with self.assertRaises(FileExistsError), patch.object(runner, "ROOT", root):
                runner.run_experiment(cfg, output)

    def test_metadata_hashes_copied_bytes_during_concurrent_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for directory in ("scripts", "R", "src", "data/processed", "artifacts/native"):
                (root / directory).mkdir(parents=True, exist_ok=True)
            files = {
                "scripts/Rscript": b"wrapper",
                "scripts/experiment.R": b"original driver",
                "R/model.R": b"original model",
                "data/input.csv": b"y\n1\n",
                "data/sources.json": b'{"source":"original"}\n',
                "data/processed/manifest.json": b'{"data":"original"}\n',
                "artifacts/native/bartssm.so": b"original native binary",
            }
            for relative, contents in files.items():
                (root / relative).write_bytes(contents)
            cfg = root / "config.json"
            config = {"schema_version": 1, "phase": "exploratory", "seed": 7,
                      "data": {"path": "data/input.csv"}}
            original_config = (json.dumps(config, separators=(",", ":")) + "\n\n").encode()
            cfg.write_bytes(original_config)
            original_sha = hashlib.sha256(original_config).hexdigest()
            output = root / "run"
            actual_copy = shutil.copy2

            def copy_with_concurrent_edits(source, destination, *args, **kwargs):
                source = Path(source)
                relative = str(source.relative_to(root))
                if relative == "R/model.R":
                    # The copied source changes after discovery, then changes
                    # again after the copy. Only the intermediate bytes execute.
                    source.write_bytes(b"model at snapshot time")
                result = actual_copy(source, destination, *args, **kwargs)
                if relative in files:
                    source.write_bytes(b"later concurrent edit")
                cfg.write_text(json.dumps({**config, "seed": 999}))
                return result

            def execute(command, **kwargs):
                if command[0] == "git":
                    return subprocess.CompletedProcess(command, 0, stdout=b"")
                executed = json.loads(Path(command[2]).read_text())
                self.assertEqual(executed["seed"], 7)
                self.assertEqual(Path(executed["data"]["path"]).read_bytes(), files["data/input.csv"])
                return subprocess.CompletedProcess(command, 0)

            with patch.object(runner, "ROOT", root), patch.object(runner, "git", return_value="test"), \
                    patch.object(runner.shutil, "copy2", side_effect=copy_with_concurrent_edits), \
                    patch.object(runner.subprocess, "run", side_effect=execute):
                self.assertEqual(runner.run_experiment(cfg, output), 0)
            meta = json.loads((output / "metadata.json").read_text())
            for relative, recorded_hash in meta["source_sha256"].items():
                self.assertEqual(recorded_hash, runner.digest(output / "source" / relative))
            self.assertEqual((output / "source/R/model.R").read_bytes(), b"model at snapshot time")
            snapshot_fields = {
                "data_sha256": "input.csv",
                "source_manifest_sha256": "sources.json",
                "processed_manifest_sha256": "data_manifest.json",
                "native_binary_sha256": "source/native/bartssm.so",
                "saved_config_sha256": "config.json",
                "executed_config_sha256": "executed_config.json",
            }
            for field, relative in snapshot_fields.items():
                self.assertEqual(meta[field], runner.digest(output / relative), field)
            self.assertEqual(meta["config_sha256"], original_sha)
            self.assertEqual(meta["original_config_sha256"], original_sha)
            self.assertEqual((output / "original_config.json").read_bytes(), original_config)
            self.assertNotEqual(meta["saved_config_sha256"], original_sha)
            self.assertNotEqual(meta["data_sha256"], runner.digest(root / "data/input.csv"))
            self.assertNotEqual(meta["source_manifest_sha256"], runner.digest(root / "data/sources.json"))

    def test_config_parse_and_digest_share_one_initial_read(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            (root / "scripts/Rscript").write_text("wrapper")
            (root / "scripts/experiment.R").write_text("driver")
            cfg = root / "config.json"
            first = b'{"schema_version":1,"phase":"exploratory","seed":7}'
            cfg.write_bytes(first)
            output = root / "run"
            actual_read = Path.read_bytes
            config_reads = []

            def read_then_edit(path):
                contents = actual_read(path)
                if path == cfg:
                    config_reads.append(contents)
                    cfg.write_bytes(b'{"schema_version":1,"phase":"exploratory","seed":999}')
                return contents

            def execute(command, **kwargs):
                return subprocess.CompletedProcess(command, 0, stdout=b"")

            with patch.object(runner, "ROOT", root), patch.object(runner, "git", return_value="test"), \
                    patch.object(Path, "read_bytes", read_then_edit), \
                    patch.object(runner.subprocess, "run", side_effect=execute):
                self.assertEqual(runner.run_experiment(cfg, output), 0)
            meta = json.loads((output / "metadata.json").read_text())
            self.assertEqual(config_reads, [first])
            self.assertEqual(meta["seed"], 7)
            self.assertEqual(meta["config_sha256"], hashlib.sha256(first).hexdigest())
            self.assertTrue(meta["run_id"].endswith(hashlib.sha256(first).hexdigest()[:8]))

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
