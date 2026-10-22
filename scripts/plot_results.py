#!/usr/bin/env python3
"""Export traceable first-round result tables and exploratory static figures.

Only completed runs explicitly selected by immutable run ID enter figures.
Failed, superseded and running runs remain in the ledger. No raw observations
or posterior draws are copied to the small tracked result bundle.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import statistics
import tempfile

import report


ROOT = Path(__file__).resolve().parents[1]
SELECTED_IDS = {
    "yield_pilot": "20261022T174341747780Z-yield_pilot-d216c29e",
    "yield_diagnostic": "20261022T173918202213Z-yield_diagnostic-2dfcb415",
    "simulation_yield": "20261022T174027943774Z-simulation_yield-34654078",
    "simulation_yield_diagnostic": "20261022T173918199075Z-simulation_yield_diagnostic-928a6ac9",
    "simulation_yield_missing": "20261022T174026706024Z-simulation_yield_missing-e7825d2a",
    "air_diagnostic": "20261022T173136675021Z-air_diagnostic-e52735dd",
    "simulation_air_diagnostic": "20261022T173136683849Z-simulation_air_diagnostic-036e60dc",
    "simulation_air_mixing_check": "20261022T173620494398Z-simulation_air_mixing_check-f2011729",
    "air_mixing_check": "20261022T173619277606Z-air_mixing_check-6fd39442",
}
TARGETS = list(SELECTED_IDS)
WORKFLOW_IDS = {"20261022T174944119241Z-air_pilot-4e04475f", "20261022T174944126036Z-yield_pilot-d216c29e"}
AUDIT_ID = "20261022T175120835793Z-mixing-audit-3ba510964dac"
ORDER = ["random_walk", "dns_var", "dns_linear", "dns_macro", "linear_dynamic",
         "bart_static", "bart_two_stage", "bart_joint"]
COLORS = {"random_walk": "#777777", "dns_var": "#BBBBBB", "dns_linear": "#CC79A7",
          "dns_macro": "#882255", "linear_dynamic": "#AA4499", "bart_static": "#4477AA",
          "bart_two_stage": "#EE9944", "bart_joint": "#228866"}
LABELS = {"random_walk": "Random walk", "dns_var": "DNS VAR", "dns_linear": "Linear DNS",
          "dns_macro": "Macro DNS", "linear_dynamic": "Linear + state",
          "bart_static": "Static BART", "bart_two_stage": "Two-stage BART", "bart_joint": "Joint BART"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def config_name(path):
    match = re.fullmatch(r"\d{8}T\d+Z-(.+)-[a-f0-9]{8}", Path(path).name)
    return match.group(1) if match else Path(path).name


def discover(artifacts):
    runs = []
    for path in sorted(artifacts.iterdir()):
        if not path.is_dir() or not (path / "metadata.json").exists() or "mixing-audit" in path.name:
            continue
        run = report.load_run(path)
        run["config_name"] = config_name(path)
        runs.append(run)
    return runs


def select_runs(runs):
    selected, pending = {}, []
    for target, run_id in SELECTED_IDS.items():
        candidates = [r for r in runs if r["path"].name == run_id]
        if not candidates:
            pending.append({"config_name": target, "run_id": run_id, "reason": "Fixed canonical run not found"})
            continue
        run = candidates[-1]
        if run["metadata"].get("status") != "completed" or run["failures"] or run["issues"]:
            pending.append({"config_name": target, "run_id": run["path"].name,
                            "reason": run["metadata"].get("status", "unknown"), "issues": run["issues"]})
            continue
        selected[target] = run
    return selected, pending


def diagnostics_summary(run):
    score_status = Counter(report.score_diagnostic_status(run, score) for score in run["scores"])
    groups = defaultdict(list)
    for row in run["diagnostics"]:
        groups[(row.get("case"), row.get("model"))].append(row)
    passed = sum(all(report.diagnostic_row_passed(row) for row in rows) for rows in groups.values())
    return {"score_rows": len(run["scores"]), "score_diagnostic_pass": score_status.get("通过", 0),
            "point_estimate_rows_exempt": score_status.get("点估计：MCMC不适用", 0),
            "score_status_counts": dict(score_status), "fit_stages": len(groups),
            "fit_stages_passed": passed,
            "diagnostic_variables": len(run["diagnostics"]),
            "diagnostic_variables_passed": sum(report.diagnostic_row_passed(row) for row in run["diagnostics"])}


def write_csv(path, rows):
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as stream:
        if not fields:
            stream.write("\n")
            return
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n")


def load_audit(artifacts):
    path = artifacts / AUDIT_ID
    issues = []
    meta = report.read_json(path / "metadata.json", issues, required=True)
    config = report.read_json(path / "config.json", issues, required=True)
    simulation = report.read_json(path / "simulation_manifest.json", issues, required=True)
    rows = report.read_csv(path / "summary.csv", issues, required=True)
    if meta.get("status") != "completed":
        issues.append("Audit has not completed")
    if len(rows) != meta.get("result", {}).get("executed_cases"):
        issues.append("Audit summary count does not match metadata")
    return {"path": path, "metadata": meta, "config": config, "simulation": simulation,
            "rows": rows, "issues": issues}


def export_audit(audit, output):
    meta, path = audit["metadata"], audit["path"]
    files = ["metadata.json", "config.json", "simulation_manifest.json", "simulation_truth.rds",
             "summary.csv", "session_info.txt", "tracked_changes.diff"]
    files += [item.name for item in path.glob("*_diagnostics.csv")]
    hashes = {name: digest(path / name) for name in sorted(files) if (path / name).is_file()}
    records = [{"run_id": path.name, "role": "sampler_audit_only", "run_status": meta.get("status"),
                **row, "config_sha256": meta.get("config_sha256"), "git_commit": meta.get("git_commit"),
                "simulation_truth_sha256": audit["simulation"].get("truth_sha256"),
                "source_snapshot_sha256": canonical_digest(meta.get("source_sha256", {})),
                "summary_sha256": hashes.get("summary.csv")}
               for row in audit["rows"]]
    write_csv(output / "audit_ledger.csv", records)
    write_json(output / "audit_provenance.json", {"schema_version": 1,
               "role": "sampler_audit_only; excluded from predictive model comparison",
               "metadata": meta, "config": audit["config"], "simulation": audit["simulation"],
               "artifact_file_sha256": hashes, "issues": audit["issues"]})
    return {"audit_cases": len(records),
            "audit_execution_completed": sum(row.get("execution_status") == "completed" for row in records),
            "audit_diagnostic_passed": sum(report.boolean(row.get("passed")) is True for row in records)}


def export_tables(runs, selected, pending, output):
    ledger, provenance = [], []
    selected_ids = {run["path"].name for run in selected.values()}
    for run in runs:
        meta = run["metadata"]
        chosen = run["path"].name in selected_ids
        diag = diagnostics_summary(run)
        if chosen:
            reason = "Selected completed exploratory run; diagnostic status is reported separately"
            role = "scientific_exploratory"
        elif meta.get("status") == "failed":
            reason = "Execution failed; retained in ledger only, excluded from success tables and figures"
            role = "failed_experiment"
        elif meta.get("status") != "completed":
            reason = "Incomplete/running; retained in ledger only"
            role = "incomplete"
        elif run["path"].name in WORKFLOW_IDS:
            reason = "Prediction diagnostic wiring validation; excluded from fixed scientific result selection"
            role = "workflow_validation"
        else:
            reason = "Superseded or outside explicit final selection; retained in ledger only"
            role = "initial_smoke_or_superseded"
        hashes = {name: digest(run["path"] / name) for name in
                  ["metadata.json", "config.json", "summary.json", "scores.csv", "diagnostics.csv",
                   "prediction_rows.csv", "failures.csv", "data_manifest.json", "sources.json"]
                  if (run["path"] / name).exists()}
        record = {"run_id": run["path"].name, "config_name": run["config_name"], "task": run["task"],
                  "status": meta.get("status", "unknown"), "role": role, "selected_for_results": chosen,
                  "selection_reason": reason, "score_rows": diag["score_rows"],
                  "expected_score_rows": run["expected"], "failed_cases": len(run["failures"]),
                  "passed_stochastic_score_rows": diag["score_diagnostic_pass"],
                  "point_estimate_rows_exempt": diag["point_estimate_rows_exempt"],
                  "fit_stages_passed": diag["fit_stages_passed"], "fit_stages": diag["fit_stages"],
                  "config_sha256": meta.get("config_sha256"), "git_commit": meta.get("git_commit"),
                  "data_sha256": meta.get("data_sha256"),
                  "source_manifest_sha256": meta.get("source_manifest_sha256"),
                  "source_snapshot_sha256": canonical_digest(meta.get("source_sha256", {})),
                  "scores_csv_sha256": hashes.get("scores.csv"), "diagnostics_csv_sha256": hashes.get("diagnostics.csv"),
                  "chains": run["config"].get("control", {}).get("chains"),
                  "draws_per_chain": run["config"].get("control", {}).get("draws"),
                  "trees": run["config"].get("control", {}).get("trees"),
                  "elapsed_seconds": meta.get("elapsed_seconds")}
        ledger.append(record)
        provenance.append({**record, "source_file_sha256": meta.get("source_sha256", {}),
                           "artifact_file_sha256": hashes, "config": run["config"],
                           "summary": run["summary"], "diagnostics": diag,
                           "failures": run["failures"], "integrity_issues": run["issues"],
                           "tracked_diff_sha256": meta.get("tracked_diff_sha256"),
                           "processed_manifest_sha256": meta.get("processed_manifest_sha256")})
    write_csv(output / "run_ledger.csv", ledger)
    write_json(output / "provenance.json", {"schema_version": 1, "runs": provenance,
                                            "selection_run_ids": SELECTED_IDS, "pending": pending})
    cases, models, pairs, stage_rows = [], [], [], []
    for name, run in selected.items():
        prefix = {"run_id": run["path"].name, "config_name": name, "task": run["task"]}
        for row in run["scores"]:
            cases.append({**prefix, **row, "diagnostic_status": report.score_diagnostic_status(run, row),
                          "prediction_diagnostic_scope": report.prediction_diagnostic_scope(run, row)})
        for row in report.aggregate_scores(run):
            models.append({**prefix, **{key: value for key, value in row.items() if key != "diagnostics"},
                           "aggregation": "equal-case arithmetic means; not pooled RMSE or independent samples",
                           "diagnostics": json.dumps(row["diagnostics"], ensure_ascii=False, sort_keys=True)})
        for row in report.paired_comparisons(run):
            interval = row["interval"] or {}
            pairs.append({**prefix, **{key: value for key, value in row.items() if key not in {"interval", "reasons"}},
                          "ci95_lower": interval.get("lower"), "ci95_upper": interval.get("upper"),
                          "interval_reasons": "; ".join(row["reasons"]),
                          "aggregation": "paired observation CRPS differences, then equal physical blocks/months/replicates"})
        groups = defaultdict(list)
        for row in run["diagnostics"]:
            groups[(row["case"], row["model"])].append(row)
        for (case, model), rows in sorted(groups.items()):
            vals = {key: [report.number(row.get(key)) for row in rows] for key in ["rhat", "ess_bulk", "ess_tail"]}
            stage_rows.append({**prefix, "case": case, "model_stage": model,
                               "variables": len(rows), "variables_passed": sum(report.diagnostic_row_passed(r) for r in rows),
                               "stage_passed": all(report.diagnostic_row_passed(r) for r in rows),
                               "max_rhat": max(v for v in vals["rhat"] if v is not None) if any(v is not None for v in vals["rhat"]) else None,
                               "min_ess_bulk": min(v for v in vals["ess_bulk"] if v is not None) if any(v is not None for v in vals["ess_bulk"]) else None,
                               "min_ess_tail": min(v for v in vals["ess_tail"] if v is not None) if any(v is not None for v in vals["ess_tail"]) else None})
    for filename, rows in [("case_scores.csv", cases), ("model_summary.csv", models),
                           ("paired_crps.csv", pairs), ("diagnostic_stages.csv", stage_rows)]:
        write_csv(output / filename, rows)
    return ledger


def panel_data(run):
    groups = defaultdict(list)
    for row in run["scores"]:
        case = re.sub(r"_\d+$", "", row["case"]) if run["task"].startswith("simulation_") else row["case"]
        groups[(case, row["model"])].append(row)
    categories = list(dict.fromkeys(case for case, _ in groups))
    models = [model for model in ORDER if any(key[1] == model for key in groups)]
    return categories, models, groups


def create_figures(selected, output):
    os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "bart-matplotlib"))
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import pyplot as plt
    from matplotlib import font_manager
    cjk = any(font.name == "Noto Sans CJK JP" for font in font_manager.fontManager.ttflist)
    matplotlib.rcParams.update({"font.family": ["DejaVu Sans", "Noto Sans CJK JP"] if cjk else ["DejaVu Sans"],
                               "font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                               "svg.fonttype": "none", "svg.hashsalt": "bart-first-round-v1",
                               "savefig.facecolor": "white"})
    banner = "探索性结果：未通过诊断的拟合仅供排查，不能据此确认模型优势" if cjk else "EXPLORATORY: failed diagnostics prevent confirmatory conclusions"

    def draw_panel(axis, name):
        if name not in selected:
            axis.text(.5, .5, f"{name}\nAwaiting completed run", ha="center", va="center", transform=axis.transAxes)
            axis.set_axis_off()
            return
        run = selected[name]
        categories, models, groups = panel_data(run)
        width = .8 / max(1, len(models))
        panel_max = 0
        for j, model in enumerate(models):
            positions, heights, hatches = [], [], []
            for i, case in enumerate(categories):
                rows = groups.get((case, model), [])
                values = [report.number(row.get("crps")) for row in rows]
                if not values or any(value is None for value in values):
                    continue
                positions.append(i - .4 + width * (j + .5))
                heights.append(statistics.fmean(values))
                panel_max = max(panel_max, heights[-1])
                hatches.append("///" if any(report.score_diagnostic_status(run, row) not in
                                           {"通过", "点估计：MCMC不适用"} for row in rows) else "")
            bars = axis.bar(positions, heights, width=width, label=LABELS[model], color=COLORS[model],
                            edgecolor="white", linewidth=.6)
            for bar, hatch in zip(bars, hatches):
                bar.set_hatch(hatch)
        if panel_max > 0:
            axis.set_ylim(0, panel_max * 1.35)
        axis.set_xticks(range(len(categories)), [case.replace("conditional_persistence", "cond.persist").replace("slow_covariates", "slow covariates") for case in categories],
                        rotation=25 if len(categories) > 3 else 0, ha="right" if len(categories) > 3 else "center")
        unit = "yield percentage points" if "yield" in run["task"] else "CO mg/m³" if run["task"] == "air" else "simulation response units"
        axis.set_ylabel(f"CRPS ({unit}; lower is better)")
        control = run["config"].get("control", {})
        axis.set_title(f"{name}\n{control.get('chains')} chains × {control.get('draws')} draws; {control.get('trees')} trees", fontsize=10)
        axis.grid(axis="y", color="#dddddd", linewidth=.5)
        axis.set_axisbelow(True)
        axis.legend(fontsize=7, frameon=False, ncol=2)

    figures = []
    specs = [("observed_data_crps", ["yield_pilot", "yield_diagnostic", "air_diagnostic", "air_mixing_check"], (2, 2), (14, 10)),
             ("yield_simulation_crps", ["simulation_yield", "simulation_yield_diagnostic", "simulation_yield_missing"], (1, 3), (18, 5.5)),
             ("air_simulation_crps", ["simulation_air_diagnostic", "simulation_air_mixing_check"], (1, 2), (13, 5.5))]
    for filename, names, shape, size in specs:
        fig, axes = plt.subplots(*shape, figsize=size, squeeze=False)
        for axis, name in zip(axes.flat, names):
            draw_panel(axis, name)
        fig.suptitle(banner, fontsize=13, fontweight="bold", color="#882222")
        fig.text(.5, .012, "Hatched: failed/missing MCMC diagnostics. Descriptive means only; no inferential intervals. Run IDs: export_manifest.json.",
                 ha="center", fontsize=8, color="#555555")
        fig.tight_layout(rect=[0, .065, 1, .94], h_pad=4)
        for suffix in ["png", "svg"]:
            path = output / f"{filename}.{suffix}"
            fig.savefig(path, dpi=150, bbox_inches="tight", metadata={"Title": filename, "Date": None} if suffix == "svg" else None)
            figures.append(path.name)
        plt.close(fig)

    names = list(selected)
    fail = [diagnostics_summary(selected[name])["fit_stages"] - diagnostics_summary(selected[name])["fit_stages_passed"] for name in names]
    passed = [diagnostics_summary(selected[name])["fit_stages_passed"] for name in names]
    fig, axis = plt.subplots(figsize=(11, 6))
    axis.barh(names, passed, color="#228866", label="All variables pass in this fit stage")
    axis.barh(names, fail, left=passed, color="#BB5555", label="At least one diagnostic fails")
    for i, (good, bad) in enumerate(zip(passed, fail)):
        axis.text(good + bad + .2, i, f"{good}/{good + bad} pass", va="center", fontsize=9)
    axis.set_xlabel("Unique fit stages (stochastic first stages included; point baselines excluded)")
    axis.invert_yaxis()
    axis.legend(frameon=False, loc="lower right", fontsize=8)
    axis.grid(axis="x", linewidth=.5, color="#dddddd")
    axis.set_axisbelow(True)
    fig.suptitle(banner, fontsize=12, fontweight="bold", color="#882222")
    fig.text(.5, .015, "Pass requires every monitored variable: Rhat < 1.01 and bulk/tail ESS ≥ 400. Passing is not proof of correctness.", ha="center", fontsize=8)
    fig.tight_layout(rect=[0, .05, 1, .94])
    for suffix in ["png", "svg"]:
        path = output / f"diagnostic_stage_counts.{suffix}"
        fig.savefig(path, dpi=150, bbox_inches="tight", metadata={"Date": None} if suffix == "svg" else None)
        figures.append(path.name)
    plt.close(fig)
    runtime = {"python": platform.python_version(), "matplotlib": matplotlib.__version__,
               "numpy": importlib.metadata.version("numpy"), "backend": str(matplotlib.get_backend()),
               "noto_sans_cjk_jp_available": cjk, "font_family": list(matplotlib.rcParams["font.family"]),
               "svg_fonttype": matplotlib.rcParams["svg.fonttype"], "raster_dpi": 150}
    if cjk:
        font_path = Path(font_manager.findfont("Noto Sans CJK JP"))
        runtime["cjk_font_file"] = font_path.name
        runtime["cjk_font_sha256"] = digest(font_path)
    return figures, runtime


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "results" / "first_round")
    parser.add_argument("--allow-pending", action="store_true", help="Write an explicitly provisional bundle while long runs finish")
    args = parser.parse_args(argv)
    runs = discover(args.artifacts_dir)
    selected, pending = select_runs(runs)
    audit = load_audit(args.artifacts_dir)
    if audit["issues"]:
        pending.append({"run_id": AUDIT_ID, "role": "sampler_audit_only", "issues": audit["issues"]})
    if pending and not args.allow_pending:
        parser.error("Required runs not yet complete: " + json.dumps(pending, ensure_ascii=False))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    ledger = export_tables(runs, selected, pending, args.output_dir)
    audit_totals = export_audit(audit, args.output_dir)
    figures, plotting_runtime = create_figures(selected, args.output_dir)
    totals = {"selected_runs": len(selected), "ledger_runs": len(ledger),
              "failed_runs_in_ledger": sum(row["status"] == "failed" for row in ledger),
              "scored_case_models": sum(diagnostics_summary(run)["score_rows"] for run in selected.values()),
              "passed_stochastic_case_models": sum(diagnostics_summary(run)["score_diagnostic_pass"] for run in selected.values()),
              "point_estimate_case_models_exempt": sum(diagnostics_summary(run)["point_estimate_rows_exempt"] for run in selected.values()),
              "fit_stages": sum(diagnostics_summary(run)["fit_stages"] for run in selected.values()),
              "fit_stages_passed": sum(diagnostics_summary(run)["fit_stages_passed"] for run in selected.values()),
              **audit_totals}
    readme = f"""# 第一轮探索性结果

由 `python3 scripts/plot_results.py` 从运行目录导出。当前状态：{'尚有运行未完成' if pending else '选定运行均已完成；仍为探索性结果'}。

- 选定 {totals['selected_runs']} 个运行，{totals['scored_case_models']} 个 case/model 分数。
- 随机模型完整诊断通过 {totals['passed_stochastic_case_models']} 个；{totals['point_estimate_case_models_exempt']} 个点估计基准不适用MCMC诊断，不算通过。
- 包含随机首阶段的拟合阶段通过 {totals['fit_stages_passed']}/{totals['fit_stages']}。
- 旧失败运行 {totals['failed_runs_in_ledger']} 个，保留在运行账本，未用于成功结果表与图。
- 独立采样器审计 {totals['audit_execution_completed']}/{totals['audit_cases']} 档执行完成，诊断通过 {totals['audit_diagnostic_passed']}；只用于定位采样问题，不混入模型预测比较。

未通过诊断的误差比较只用于发现问题，不支持模型优势、机制或创新成立的结论；诊断未通过也不证明研究假设为假。

| 文件 | 内容 |
| --- | --- |
| `run_ledger.csv` | 全部运行状态、是否纳入、配置/数据/源码汇总哈希与Git提交 |
| `provenance.json` | 完整配置、逐源码文件哈希、原始结果文件哈希、失败与诊断记录 |
| `case_scores.csv` | 选定完成运行的原始case分数与诊断状态 |
| `model_summary.csv` | 每个case等权的描述性均值；RMSE不是合并观测RMSE |
| `paired_crps.csv` | 同标签配对后按整段缺口/月份/模拟重复汇总；区间不可用原因完整保留 |
| `diagnostic_stages.csv` | 主阶段与随机首阶段的Rhat/ESS及是否通过 |
| `audit_ledger.csv`、`audit_provenance.json` | 独立静态BART采样器审计及其配置/模拟真值/源码哈希 |
| `export_manifest.json` | 精确选定run IDs、导出脚本哈希和本目录输出校验值 |

四组图提供PNG与可缩放SVG：`observed_data_crps`、`yield_simulation_crps`、`air_simulation_crps`、`diagnostic_stage_counts`。
斜线柱表示相关MCMC诊断未通过或缺失；不同应用、数据版本和链长的结果不合并。
旧运行未完整记录条件均值和预测观测诊断，已在case表中标明旧门禁；不能当作完整预测诊断通过。
所有真实数据评价仅针对探索集，确认集使用情况以各运行的 `summary.json` 记录为准。
原始观测、预测逐行真值和后验链不复制到此目录。
"""
    (args.output_dir / "README.md").write_text(readme)
    files = ["run_ledger.csv", "provenance.json", "case_scores.csv", "model_summary.csv", "paired_crps.csv", "diagnostic_stages.csv",
             "audit_ledger.csv", "audit_provenance.json", *figures]
    files.append("README.md")
    manifest = {"schema_version": 1, "status": "provisional" if pending else "complete_exploratory_export",
                "limitations": ["All results exploratory; failed diagnostics cannot establish model superiority.",
                                "Failure of convergence diagnostics is not evidence that the research hypothesis is false.",
                                "Different data snapshots and sampler configurations are not pooled.",
                                "Only scores and provenance exported; no raw observations or posterior chains."],
                "summary": totals, "pending": pending,
                "exporter_sha256": digest(Path(__file__)), "report_library_sha256": digest(ROOT / "scripts" / "report.py"),
                "selected_run_ids": {name: run["path"].name for name, run in selected.items()},
                "audit_run_id": AUDIT_ID,
                "plotting_runtime": plotting_runtime,
                "output_sha256": {name: digest(args.output_dir / name) for name in files}}
    write_json(args.output_dir / "export_manifest.json", manifest)
    print(json.dumps({"output": str(args.output_dir), "status": manifest["status"], **totals, "pending": pending}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
