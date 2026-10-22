import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("report", Path(__file__).resolve().parents[1] / "scripts" / "report.py")
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def score(case, model, rmse=1, n=2, passed="TRUE"):
    return {"case": case, "model": model, "n": n, "rmse": rmse, "mae": rmse,
            "crps": rmse, "coverage80": .8, "width80": 1,
            "coverage95": .95, "width95": 2, "diagnostic_pass": passed}


def diagnostic(case, model, passed="TRUE"):
    return {"case": case, "model": model, "variable": "q", "rhat": 1.001,
            "ess_bulk": 800, "ess_tail": 800, "passed": passed, "reason": ""}


class ReportTests(unittest.TestCase):
    def make_run(self, path, scores, diagnostics=None, predictions=None, task="yield", status="completed", models=None):
        path.mkdir(exist_ok=True)
        cases = sorted({s["case"] for s in scores})
        models = models or sorted({s["model"] for s in scores})
        config = {"task": task, "phase": "exploratory", "models": models,
                  "evaluation": {"target_months": cases, "gaps_hours": [24]},
                  "control": {"chains": 2, "draws": 1000, "burn": 1000}}
        (path / "config.json").write_text(json.dumps(config))
        (path / "metadata.json").write_text(json.dumps({"status": status, "config_sha256": "abc", "git_commit": "def"}))
        (path / "summary.json").write_text(json.dumps({"confirmation_opened": False}))
        write_csv(path / "scores.csv", scores)
        if diagnostics:
            write_csv(path / "diagnostics.csv", diagnostics)
        if predictions:
            write_csv(path / "prediction_rows.csv", predictions)
        return report.load_run(path)

    def test_case_means_are_equal_weight_not_pooled_or_sample_weighted(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.make_run(Path(directory), [score("a", "random_walk", 1, 1, "NA"), score("b", "random_walk", 3, 9, "NA")])
            result = report.aggregate_scores(run)[0]
            self.assertEqual(result["rmse"], 2)
            self.assertEqual(result["n"], 10)
            self.assertEqual(result["diagnostics"], {"点估计：MCMC不适用": 2})

    def test_first_stage_failure_overrides_score_true(self):
        with tempfile.TemporaryDirectory() as directory:
            item = score("gap24", "bart_two_stage")
            run = self.make_run(Path(directory), [item], [diagnostic("air_validation", "bart_two_stage"), diagnostic("air_validation", "bart_two_stage:first_stage", "FALSE")], task="air")
            self.assertEqual(report.score_diagnostic_status(run, item), "未通过：仅pilot")
            text = report.render_report([run])
            self.assertIn("bart_two_stage:first_stage", text)
            self.assertIn("未通过：仅pilot", text)

    def test_missing_stochastic_diagnostics_are_not_exempt(self):
        with tempfile.TemporaryDirectory() as directory:
            item = score("a", "bart_joint", passed="NA")
            run = self.make_run(Path(directory), [item])
            self.assertEqual(report.score_diagnostic_status(run, item), "诊断缺失")

    def test_many_hours_in_three_blocks_do_not_create_confidence_interval(self):
        with tempfile.TemporaryDirectory() as directory:
            scores = [score("gap24", model) for model in ["bart_joint", "bart_static"]]
            diagnostics = [diagnostic("air_validation", model) for model in ["bart_joint", "bart_static"]]
            predictions = [{"case": "gap24", "model": model, "label": f"hour{h};block={block}", "y": 1, "crps": loss}
                          for model, loss in [("bart_joint", .5), ("bart_static", 1)]
                          for block in range(1, 4) for h in range(24)]
            run = self.make_run(Path(directory), scores, diagnostics, predictions, task="air")
            result = next(r for r in report.paired_comparisons(run) if r["baseline"] == "bart_static")
            self.assertEqual(result["blocks"], 3)
            self.assertEqual(result["observations"], 72)
            self.assertEqual(result["delta_crps"], -.5)
            self.assertIsNone(result["interval"])
            self.assertTrue(any("不足8" in reason for reason in result["reasons"]))

    def test_diagnostics_gate_interval_even_with_enough_months(self):
        with tempfile.TemporaryDirectory() as directory:
            cases = [f"2006-{m:02d}" for m in range(1, 10)]
            scores = [score(case, model) for case in cases for model in ["bart_joint", "dns_macro"]]
            diagnostics = [diagnostic(case, model, "FALSE" if model == "bart_joint" else "TRUE") for case in cases for model in ["bart_joint", "dns_macro"]]
            predictions = [{"case": case, "model": model, "label": f"maturity{m}", "y": 3, "crps": loss}
                          for case in cases for model, loss in [("bart_joint", .1), ("dns_macro", .2)] for m in range(6)]
            run = self.make_run(Path(directory), scores, diagnostics, predictions)
            result = next(r for r in report.paired_comparisons(run) if r["baseline"] == "dns_macro")
            self.assertEqual(result["blocks"], 9)
            self.assertIsNone(result["interval"])
            self.assertTrue(any("诊断" in reason for reason in result["reasons"]))

    def test_failed_and_missing_runs_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "failed_run"
            run = self.make_run(path, [score("a", "bart_joint")], status="failed")
            write_csv(path / "failures.csv", [{"case": "a", "model": "bart_joint", "error": "Cholesky failed"}])
            text = report.render_report([report.load_run(path), report.load_run(Path(directory) / "absent")])
            self.assertIn("执行失败", text)
            self.assertIn("Cholesky failed", text)
            self.assertIn("运行目录不存在", text)
            self.assertIn("没有可评分结果", text)

    def test_cluster_bootstrap_is_deterministic(self):
        first = report.bootstrap_interval([-.2, -.1, .1, 0, -.3, .2, -.1, .05], simulation=False)
        self.assertEqual(first, report.bootstrap_interval([-.2, -.1, .1, 0, -.3, .2, -.1, .05], simulation=False))
        self.assertEqual(first["cluster_block_length"], 2)
        self.assertIsNone(report.bootstrap_interval([0] * 7, simulation=True))

    def test_complete_passing_months_get_cluster_interval(self):
        with tempfile.TemporaryDirectory() as directory:
            cases = [f"2006-{m:02d}" for m in range(1, 10)]
            scores = [score(case, model) for case in cases for model in ["bart_joint", "dns_macro"]]
            diagnostics = [diagnostic(case, model) for case in cases for model in ["bart_joint", "dns_macro"]]
            predictions = [{"case": case, "model": model, "label": f"maturity{m}", "y": 3, "crps": loss}
                          for case in cases for model, loss in [("bart_joint", .1), ("dns_macro", .2)] for m in range(6)]
            run = self.make_run(Path(directory), scores, diagnostics, predictions)
            result = next(r for r in report.paired_comparisons(run) if r["baseline"] == "dns_macro")
            self.assertEqual(result["blocks"], 9)
            self.assertEqual(result["observations"], 54)
            self.assertIsNotNone(result["interval"])
            self.assertAlmostEqual(result["interval"]["lower"], -.1)

    def test_partial_csv_row_is_recorded_without_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            run = self.make_run(path, [score("a", "bart_joint")], status="running")
            with (path / "scores.csv").open("a") as stream:
                stream.write("b,bart_joint,2\n")
            run = report.load_run(path)
            self.assertEqual(len(run["scores"]), 1)
            self.assertTrue(any("未写完" in issue for issue in run["issues"]))
            self.assertIn("仍在运行/未完成", report.render_report([run]))


if __name__ == "__main__":
    unittest.main()
