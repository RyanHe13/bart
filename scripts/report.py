#!/usr/bin/env python3
"""Render Chinese pilot reports without treating failed diagnostics as evidence."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import json
import math
from pathlib import Path
import random
import re
import statistics


BOOTSTRAP_SEED = 20261023
MIN_BLOCKS = 8
POINT_MODELS = {"random_walk", "dns_var"}
METRICS = ["rmse", "mae", "crps", "coverage80", "width80", "coverage95", "width95"]


def number(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def boolean(value):
    if value is True or str(value).upper() == "TRUE":
        return True
    if value is False or str(value).upper() == "FALSE":
        return False
    return None


def mean(values):
    values = [value for value in values if value is not None]
    return statistics.fmean(values) if values else None


def fmt(value):
    value = number(value)
    return "—" if value is None else f"{value:.5g}"


def escaped(value):
    return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def table(headers, rows):
    return ["| " + " | ".join(map(escaped, headers)) + " |",
            "| " + " | ".join("---" for _ in headers) + " |"] + [
        "| " + " | ".join(map(escaped, row)) + " |" for row in rows]


def read_json(path, issues, required=False):
    if not path.exists():
        if required:
            issues.append(f"缺少 {path.name}")
        return {}
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("expected a JSON object")
        return value
    except (OSError, ValueError) as error:
        issues.append(f"{path.name} 尚不可读取：{error}")
        return {}


def read_csv(path, issues, required=False):
    if not path.exists():
        if required:
            issues.append(f"缺少 {path.name}")
        return []
    try:
        with path.open(newline="") as stream:
            reader = csv.DictReader(stream)
            if reader.fieldnames is None:
                issues.append(f"{path.name} 尚无CSV表头")
                return []
            records = list(reader)
            complete = [row for row in records if None not in row and all(value is not None for value in row.values())]
            if len(complete) != len(records):
                issues.append(f"{path.name} 有 {len(records) - len(complete)} 条未写完/列数异常记录，暂不纳入数值汇总")
            return complete
    except (OSError, csv.Error, UnicodeError) as error:
        issues.append(f"{path.name} 尚不可读取：{error}")
        return []


def expected_count(config):
    models = len(config.get("models", []))
    task = config.get("task")
    evaluation = config.get("evaluation", {})
    simulation = config.get("simulation", {})
    if task == "yield":
        return models * len(evaluation.get("target_months", []))
    if task == "air":
        return models * len(evaluation.get("gaps_hours", []))
    if task in {"simulation_yield", "simulation_air"}:
        result = models * len(simulation.get("scenarios", [])) * int(simulation.get("replicates", 0))
        if task == "simulation_yield":
            return result * len(simulation.get("noise", [])) * len(simulation.get("missing_modes", ["none"]))
        return result
    return None


def load_run(path):
    path = Path(path)
    issues = []
    run = {"path": path, "issues": issues}
    if not path.is_dir():
        issues.append("运行目录不存在")
    run["metadata"] = read_json(path / "metadata.json", issues, required=True)
    run["config"] = read_json(path / "config.json", issues, required=True)
    run["summary"] = read_json(path / "summary.json", issues)
    for filename in ["scores", "diagnostics", "prediction_rows", "failures"]:
        run[filename] = read_csv(path / f"{filename}.csv", issues, required=filename == "scores")
    run["task"] = run["config"].get("task", run["summary"].get("task", "unknown"))
    run["expected"] = expected_count(run["config"])
    counts = Counter((r.get("case"), r.get("model")) for r in run["scores"])
    run["duplicates"] = {key for key, count in counts.items() if count > 1}
    if run["duplicates"]:
        issues.append("重复 case/model 分数：保留原始表，但排除重复项汇总和区间推断")
    if run["expected"] is not None and len(counts) != run["expected"]:
        issues.append(f"已记录 {len(counts)} / 预期 {run['expected']} 个 case/model")
    if run["metadata"].get("status") == "completed" and not (path / "summary.json").exists():
        issues.append("状态为 completed，但缺少 summary.json；完整性未证实")
    return run


def relevant_diagnostics(run, score):
    cases = {score.get("case")}
    if run["task"] == "air":
        cases.add("air_validation")
    model = score.get("model", "")
    return [r for r in run["diagnostics"] if r.get("case") in cases and
            (r.get("model") == model or r.get("model", "").startswith(model + ":"))]


def prediction_diagnostic_scope(run, score):
    if score.get("model") in POINT_MODELS:
        return "点估计：MCMC不适用"
    variables = [row.get("variable", "") for row in run["diagnostics"]
                 if row.get("case") == score.get("case") and row.get("model") == score.get("model")]
    return ("包含条件均值与预测观测诊断" if all(any(v.startswith(prefix) for v in variables)
            for prefix in ["predictive_mean_", "predictive_observation_"])
            else "旧门禁/预测量诊断不完整")


def diagnostic_row_passed(row):
    values = [number(row.get(key)) for key in ["rhat", "ess_bulk", "ess_tail"]]
    return (boolean(row.get("passed")) is True and all(v is not None for v in values)
            and values[0] < 1.01 and values[1] >= 400 and values[2] >= 400)


def score_diagnostic_status(run, score):
    rows = relevant_diagnostics(run, score)
    declared = boolean(score.get("diagnostic_pass"))
    model = score.get("model", "")
    if model in POINT_MODELS and declared is None and not rows:
        return "点估计：MCMC不适用"
    if not rows:
        return "诊断缺失"
    if not any(r.get("model") == model for r in rows):
        return "主阶段诊断缺失"
    if "air" in run["task"] and model == "bart_two_stage" and not any(
            r.get("model") == model + ":first_stage" for r in rows):
        return "首阶段诊断缺失"
    if declared is False or not all(diagnostic_row_passed(r) for r in rows):
        return "未通过：仅pilot"
    if declared is not True:
        return "汇总诊断未确认"
    if prediction_diagnostic_scope(run, score) == "旧门禁/预测量诊断不完整":
        return "预测量诊断缺失：旧门禁"
    return "通过"


def aggregate_scores(run):
    """Equal weight to each unique case, not pooled observation-level RMSE."""
    models = defaultdict(list)
    for score in run["scores"]:
        if (score.get("case"), score.get("model")) not in run["duplicates"]:
            models[score.get("model", "unknown")].append(score)
    results = []
    for model, scores in sorted(models.items()):
        record = {"model": model, "cases": len(scores),
                  "n": sum(number(s.get("n")) or 0 for s in scores),
                  "diagnostics": dict(Counter(score_diagnostic_status(run, s) for s in scores))}
        for metric in METRICS + ["state_rmse", "function_rmse"]:
            values = [number(s.get(metric)) for s in scores]
            # Missing metrics must not be silently omitted from a model mean.
            record[metric] = mean(values) if all(v is not None for v in values) else None
        results.append(record)
    return results


def quantile(values, probability):
    values = sorted(values)
    position = (len(values) - 1) * probability
    lower = math.floor(position)
    fraction = position - lower
    return values[lower] * (1 - fraction) + values[min(lower + 1, len(values) - 1)] * fraction


def bootstrap_interval(values, simulation, draws=2000):
    """Resample whole clusters; real-data circular blocks retain nearby clusters."""
    if len(values) < MIN_BLOCKS:
        return None
    rng = random.Random(BOOTSTRAP_SEED)
    n = len(values)
    length = 1 if simulation else max(2, math.ceil(n ** (1 / 3)))
    averages = []
    for _ in range(draws):
        sample = []
        while len(sample) < n:
            start = rng.randrange(n)
            sample.extend(values[(start + step) % n] for step in range(length))
        averages.append(statistics.fmean(sample[:n]))
    return {"lower": quantile(averages, .025), "upper": quantile(averages, .975),
            "cluster_block_length": length, "draws": draws}


def pair_block(task, case, label):
    if task.startswith("simulation_"):
        return re.sub(r"_\d+$", "", case), case
    if task == "air":
        match = re.search(r"(?:^|;)block=(\d+)(?:;|$)", label)
        return (case, match.group(1)) if match else (case, None)
    if task == "yield":
        return "目标月份", case
    return "未知任务", None


def paired_comparisons(run):
    baselines = ["bart_two_stage", "bart_static"] if "air" in run["task"] else ["bart_two_stage", "dns_macro"]
    by_model = defaultdict(dict)
    duplicate_keys = set()
    for row in run["prediction_rows"]:
        key = (row.get("case", ""), row.get("label", ""))
        model = row.get("model", "")
        if key in by_model[model]:
            duplicate_keys.add((model, key))
        by_model[model][key] = row
    score_map = {(s.get("case"), s.get("model")): s for s in run["scores"]}
    results = []
    for baseline in baselines:
        joint, other = by_model["bart_joint"], by_model[baseline]
        groups = defaultdict(lambda: {"blocks": defaultdict(list), "cases": set(), "issues": set(), "unmatched": 0})
        for key in sorted(set(joint) | set(other)):
            case, label = key
            stratum, block = pair_block(run["task"], case, label)
            group = groups[stratum]
            if key not in joint or key not in other:
                group["unmatched"] += 1
                continue
            group["cases"].add(case)
            if ("bart_joint", key) in duplicate_keys or (baseline, key) in duplicate_keys:
                group["issues"].add("重复预测标签")
                continue
            if block is None or not label:
                group["issues"].add("缺少可核验分组标签")
                continue
            left, right = joint[key], other[key]
            yl, yr = number(left.get("y", left.get("truth"))), number(right.get("y", right.get("truth")))
            cl, cr = number(left.get("crps")), number(right.get("crps"))
            if yl is None or yr is None or cl is None or cr is None:
                group["issues"].add("配对预测含缺失真值或CRPS")
                continue
            if not math.isclose(yl, yr, abs_tol=1e-9, rel_tol=1e-9):
                group["issues"].add("配对真值不一致")
                continue
            group["blocks"][block].append(cl - cr)
        if not groups:
            results.append({"baseline": baseline, "stratum": "无配对记录", "blocks": 0,
                            "observations": 0, "delta_crps": None, "interval": None,
                            "reasons": ["缺少联合模型或基准的逐观测记录"]})
        for stratum, group in sorted(groups.items()):
            # Simulation identifiers need natural ordering (replicate 2 before 10).
            def sort_key(key):
                return tuple(int(part) if part.isdigit() else part for part in re.split(r"(\d+)", key))
            values = [statistics.fmean(group["blocks"][block]) for block in sorted(group["blocks"], key=sort_key)]
            reasons = set(group["issues"])
            if group["unmatched"]:
                reasons.add(f"{group['unmatched']} 个标签未配对")
            if len(values) < MIN_BLOCKS:
                reasons.add(f"有效块不足{MIN_BLOCKS}：不计算区间")
            if run["metadata"].get("status") != "completed" or run["failures"] or run["issues"]:
                reasons.add("运行失败、未完成或完整性不足")
            for case in group["cases"]:
                for model in ["bart_joint", baseline]:
                    score = score_map.get((case, model))
                    if score is None or score_diagnostic_status(run, score) not in {"通过", "点估计：MCMC不适用"}:
                        reasons.add("至少一个模型或首阶段诊断未通过/缺失")
            interval = bootstrap_interval(values, run["task"].startswith("simulation_")) if not reasons else None
            results.append({"baseline": baseline, "stratum": stratum, "blocks": len(values),
                            "observations": sum(map(len, group["blocks"].values())),
                            "delta_crps": mean(values), "interval": interval, "reasons": sorted(reasons)})
    return results


def diagnostic_tables(run):
    groups = defaultdict(list)
    for row in run["diagnostics"]:
        groups[(row.get("case", ""), row.get("model", ""))].append(row)
    rows = []
    for (case, model), records in sorted(groups.items()):
        rhats = [number(r.get("rhat")) for r in records]
        bulk = [number(r.get("ess_bulk")) for r in records]
        tail = [number(r.get("ess_tail")) for r in records]
        def extreme(values, function):
            return function(values) if values and all(v is not None for v in values) else None
        rows.append([case, model, f"{sum(diagnostic_row_passed(r) for r in records)}/{len(records)}",
                     fmt(extreme(rhats, max)), fmt(extreme(bulk, min)), fmt(extreme(tail, min)),
                     "；".join(sorted({r.get("reason", "") for r in records if r.get("reason")})) or "—"])
    return table(["拟合case", "模型/阶段", "通过变量/全部", "最大Rhat", "最小bulk ESS", "最小tail ESS", "原始原因"], rows) if rows else ["未记录 MCMC 诊断；这不代表通过。"]


def render_run(run):
    meta, config, summary = run["metadata"], run["config"], run["summary"]
    status = meta.get("status", "unknown")
    status_text = {"completed": "执行结束", "failed": "执行失败", "running": "仍在运行/未完成"}.get(status, "状态未知")
    control = config.get("control", {})
    lines = [f"## {escaped(run['path'].name)}", "",
             f"任务：`{escaped(run['task'])}`；阶段：`{escaped(config.get('phase', 'unknown'))}`；**{status_text}**。",
             f"运行目录：`{escaped(str(run['path']))}`。配置 SHA-256：`{escaped(meta.get('config_sha256', '未记录'))}`；Git：`{escaped(meta.get('git_commit', '未记录'))}`。",
             f"链数 {control.get('chains', '未记录')}；每链保留抽样 {control.get('draws', '未记录')}；burn-in {control.get('burn', '未记录')}；运行耗时 {fmt(meta.get('elapsed_seconds'))} 秒。",
             f"已记录 {len(run['scores'])} 个 case/model 分数，预期 {run['expected'] if run['expected'] is not None else '未知'}；失败记录 {len(run['failures'])}。"]
    if meta.get("git_status"):
        lines.append("执行时工作树有改动；复现还需运行目录内的 source 快照与 tracked_changes.diff，不能只依赖 Git SHA。")
    if summary.get("confirmation_opened") is False:
        lines.append("运行记录声明未使用封存确认集。")
    elif summary.get("confirmation_opened") is True:
        lines.append("**运行记录声明已打开确认集。**")
    else:
        lines.append("是否打开确认集：记录缺失，不能据此宣称未使用。")
    if run["issues"]:
        lines += ["", "完整性记录："] + [f"- {escaped(issue)}" for issue in run["issues"]]
    if meta.get("error"):
        lines += ["", f"执行异常：{escaped(meta['error'])}"]
    if run["failures"]:
        lines += ["", "失败明细（保留，未作为成功或跳过处理）：", ""]
        lines += table(["case", "模型", "异常"], [[r.get("case", ""), r.get("model", ""), r.get("error", "未记录")] for r in run["failures"]])
    if not run["scores"]:
        return lines + ["", "没有可评分结果；本次运行不构成模型验证。", ""]

    if any(prediction_diagnostic_scope(run, score) == "旧门禁/预测量诊断不完整" for score in run["scores"]):
        lines.append("部分拟合使用旧诊断门禁，未完整记录条件预测均值及预测观测的诊断，不能视为完整预测诊断通过。")

    aggregates = aggregate_scores(run)
    lines += ["", "### 各case等权的描述性均值", "",
              "每个case权重相同；RMSE列是各case RMSE的算术平均，**不是**合并观测后的RMSE。Σn只表示评分行数，小时、期限和复用的缺口并非独立样本。不同运行及不同应用不合并排名；未通过诊断的数值仅供pilot排查。", ""]
    lines += table(["模型", "case数", "Σn", "RMSE均值", "MAE均值", "CRPS均值", "覆盖80", "宽度80", "覆盖95", "宽度95", "case诊断"], [
        [r["model"], r["cases"], int(r["n"]), *[fmt(r[m]) for m in METRICS],
         "；".join(f"{k} {v}" for k, v in sorted(r["diagnostics"].items()))] for r in aggregates])
    lines += ["", "### 原始case分数", ""]
    lines += table(["case", "模型", "n", "RMSE", "MAE", "CRPS", "覆盖80", "宽度80", "覆盖95", "宽度95", "诊断"], [
        [r.get("case", ""), r.get("model", ""), r.get("n", "—"), *[fmt(r.get(m)) for m in METRICS], score_diagnostic_status(run, r)] for r in run["scores"]])
    recovery = [r for r in run["scores"] if number(r.get("state_rmse")) is not None or number(r.get("function_rmse")) is not None]
    if recovery:
        lines += ["", "模拟真值恢复（沿用运行定义；不存在的状态不应解读为准确恢复）：", ""]
        lines += table(["case", "模型", "状态RMSE", "函数RMSE"], [[r.get("case", ""), r.get("model", ""), fmt(r.get("state_rmse")), fmt(r.get("function_rmse"))] for r in recovery])

    lines += ["", "### 联合模型与基准的配对CRPS", "",
              "ΔCRPS = bart_joint − 基准；负值表示本次记录的联合模型误差较小。先对同一标签配对，再在整段缺口/目标月份/模拟重复内平均，最后对块等权；不把小时或期限单独重采样。模拟按DGP与噪声分层，不把不同DGP凑成重复样本。", "",
              f"至少 {MIN_BLOCKS} 个匹配块、运行完整且所有相关阶段通过诊断才给出探索性95%区间。模拟按重复重采样；真实数据使用按时间排序的循环移动块（块长 ceil(n^(1/3))、至少2），保留相邻组的相关性。这不证明块相互独立，也不替代更大样本验证。固定种子 {BOOTSTRAP_SEED}，2000次重采样。", ""]
    comparisons = paired_comparisons(run)
    lines += table(["分层", "基准", "匹配块", "匹配评分行", "ΔCRPS块均值", "探索性95%区间", "限制"], [
        [r["stratum"], r["baseline"], r["blocks"], r["observations"], fmt(r["delta_crps"]),
         f"[{fmt(r['interval']['lower'])}, {fmt(r['interval']['upper'])}]" if r["interval"] else "不计算",
         "；".join(r["reasons"]) or f"移动块长 {r['interval']['cluster_block_length']}"] for r in comparisons])
    lines += ["", "### 诊断明细", "",
              "通过要求每个记录的随机量均满足 Rhat < 1.01、bulk ESS ≥ 400、tail ESS ≥ 400，并且原始 passed 为真。两阶段方法的随机首阶段也纳入判定；点估计基准的NA只表示MCMC不适用，绝不算作收敛通过。", ""]
    lines += diagnostic_tables(run)
    return lines + [""]


def render_report(runs):
    lines = ["# BART＋状态空间模型：实验记录汇总", "",
             "本文件自动整理执行状态、原始分数和诊断。跑通、取得更低的pilot误差、后验诊断通过是三个不同结论；失败和未完成运行保留。数值比较不构成创新性、因果机制或可发表性的证明。", ""]
    for run in runs:
        lines += render_run(run)
    return "\n".join(lines).rstrip() + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, default=Path("results/generated_summary.md"))
    args = parser.parse_args(argv)
    report = render_report([load_run(path) for path in args.runs])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report)
    print(f"Report: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
