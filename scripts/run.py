#!/usr/bin/env python3
"""One entry point; failed runs retain their metadata and full command logs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import shutil

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_experiment(config_path, output=None):
    path = Path(config_path).resolve()
    config = json.loads(path.read_text())
    if config.get("schema_version") != 1:
        raise ValueError("Expected schema_version=1")
    if config.get("phase") != "exploratory":
        raise ValueError("This first-round runner only opens exploratory data; confirmation stays sealed")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    run_id = f"{stamp}-{path.stem}-{digest(path)[:8]}"
    out = Path(output).resolve() if output else ROOT / "artifacts" / run_id
    out.mkdir(parents=True, exist_ok=False)
    (out / "config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    manifest = ROOT / "data" / "sources.json"
    data_path = ROOT / config.get("data", {}).get("path", "__no_dataset__")
    tracked_diff = subprocess.run(["git", "diff", "HEAD", "--", "."], cwd=ROOT, capture_output=True).stdout
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for dirname in ("R", "scripts", "src")
                     for p in sorted((ROOT / dirname).glob("*")) if p.is_file()}
    for relative in source_hashes:
        destination = out / "source" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    (out / "tracked_changes.diff").write_bytes(tracked_diff)
    native_library = ROOT / "artifacts" / "native" / "bartssm.so"
    native_sha = None
    if native_library.exists():
        (out / "source" / "native").mkdir(exist_ok=True)
        shutil.copy2(native_library, out / "source" / "native" / "bartssm.so")
        native_sha = digest(native_library)
    executed_config = json.loads(json.dumps(config))
    if data_path.exists():
        shutil.copy2(data_path, out / "input.csv")
        executed_config["data"]["path"] = str(out / "input.csv")
    (out / "executed_config.json").write_text(json.dumps(executed_config, ensure_ascii=False, indent=2) + "\n")
    meta = {"run_id": run_id, "started_at": stamp, "status": "running", "config_sha256": digest(path),
            "git_commit": git("rev-parse", "HEAD"), "git_branch": git("branch", "--show-current"),
            "git_status": git("status", "--porcelain"), "tracked_diff_sha256": hashlib.sha256(tracked_diff).hexdigest(),
            "source_sha256": source_hashes, "seed": config["seed"], "phase": config["phase"],
            "native_binary_sha256": native_sha,
            "data_sha256": digest(data_path) if data_path.exists() else None,
            "source_manifest_sha256": digest(manifest) if manifest.exists() else None}
    if manifest.exists():
        (out / "sources.json").write_bytes(manifest.read_bytes())
    processed_manifest = ROOT / "data" / "processed" / "manifest.json"
    if processed_manifest.exists():
        (out / "data_manifest.json").write_bytes(processed_manifest.read_bytes())
        meta["processed_manifest_sha256"] = digest(processed_manifest)
    metadata_path = out / "metadata.json"
    metadata_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    command = [str(out / "source" / "scripts" / "Rscript"), str(out / "source" / "scripts" / "experiment.R"),
               str(out / "executed_config.json"), str(out)]
    start = time.monotonic()
    print(f"Run directory: {out}", flush=True)
    try:
        with (out / "run.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        meta["exit_code"] = result.returncode
        meta["status"] = "completed" if result.returncode == 0 else "failed"
    except (Exception, KeyboardInterrupt) as exc:
        meta["status"] = "failed"
        meta["error"] = str(exc)
        meta["exit_code"] = 1
    finally:
        meta["elapsed_seconds"] = time.monotonic() - start
        metadata_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"run_id": run_id, "status": meta["status"], "elapsed_seconds": meta["elapsed_seconds"]}))
    if meta["exit_code"]:
        if (out / "run.log").exists():
            print((out / "run.log").read_text()[-6000:], file=sys.stderr)
        elif "error" in meta:
            print(meta["error"], file=sys.stderr)
    return meta["exit_code"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    exp = sub.add_parser("experiment")
    exp.add_argument("--config", required=True)
    exp.add_argument("--output")
    prep = sub.add_parser("prepare")
    prep.add_argument("--dataset", choices=["all", "yield", "air"], default="all")
    prep.add_argument("--offline", action="store_true")
    sub.add_parser("test")
    report = sub.add_parser("report")
    report.add_argument("runs", nargs="+")
    report.add_argument("--output", default="results/generated_summary.md")
    args = parser.parse_args()
    if args.command == "experiment":
        return run_experiment(args.config, args.output)
    if args.command == "prepare":
        return subprocess.call([sys.executable, "scripts/prepare_data.py", "--dataset", args.dataset]
                               + (["--offline"] if args.offline else []), cwd=ROOT)
    if args.command == "test":
        result = subprocess.call([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"], cwd=ROOT)
        return result or subprocess.call([str(ROOT / "scripts" / "Rscript"), "tests/run_all.R"], cwd=ROOT)
    return subprocess.call([sys.executable, "scripts/report.py", *args.runs, "--output", args.output], cwd=ROOT)


if __name__ == "__main__":
    sys.exit(main())
