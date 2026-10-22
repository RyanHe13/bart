#!/usr/bin/env python3
"""Prepare checksum-locked exploratory data without imputing target values.

Python's standard library is sufficient. Official source payloads are accepted
only if they match the locked snapshot; otherwise the pinned mirror is used and
the reason is recorded. This never silently refreshes the research vintage.
"""
from __future__ import annotations

import argparse
import calendar
import csv
from datetime import date, datetime, timedelta, timezone
import hashlib
import io
import json
import math
from pathlib import Path
import sys
import urllib.error
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
YIELD_COLUMNS = ["SVENY01", "SVENY02", "SVENY03", "SVENY05", "SVENY07", "SVENY10"]
AIR_COLUMNS = {
    "CO(GT)": "CO", "PT08.S1(CO)": "PT08_1", "PT08.S2(NMHC)": "PT08_2",
    "PT08.S3(NOx)": "PT08_3", "PT08.S4(NO2)": "PT08_4",
    "PT08.S5(O3)": "PT08_5", "T": "T", "RH": "RH", "AH": "AH",
}


def numeric(value: str | None) -> float | None:
    """Parse supplied measurements. Missing is not zero and is not imputed."""
    if value is None or value.strip() in {"", "NA", "N/A", "NaN", "nan", "."}:
        return None
    number = float(value.strip().replace(",", "."))
    if number == -200 or not math.isfinite(number):
        return None
    return number


def add_months(month: date, offset: int) -> date:
    index = month.year * 12 + month.month - 1 + offset
    return date(index // 12, index % 12 + 1, 1)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    temporary.write_bytes(payload)
    temporary.replace(path)


def write_json(path: Path, value: object) -> None:
    atomic_write(path, (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode())


def fetch_source(source: dict, raw_dir: Path, offline: bool = False,
                 prefer_official: bool = True) -> tuple[bytes, dict]:
    path = raw_dir / source["filename"]
    metadata_path = path.with_suffix(path.suffix + ".download.json")
    if path.exists():
        payload = path.read_bytes()
        if sha256(payload) != source["sha256"]:
            raise ValueError(f"Checksum mismatch in {path}; refusing to use or overwrite it")
        metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {
            "source_id": source["id"], "retrieval": "verified_existing_cache",
            "downloaded_from": None, "sha256": source["sha256"],
        }
        metadata["cache_verified"] = True
        return payload, metadata
    if offline:
        raise FileNotFoundError(f"Offline snapshot unavailable: {path}")

    candidates = []
    if prefer_official:
        candidates.append((source["official_url"], True))
    candidates.append((source["download_url"], False))
    failures = []
    for url, official in candidates:
        try:
            # urllib's default SSL context verifies certificates and hostnames.
            with urllib.request.urlopen(url, timeout=60) as response:
                payload = response.read()
            if official and source.get("official_format") == "zip":
                with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                    matches = [n for n in archive.namelist()
                               if Path(n).name == source["archive_member"]]
                    if len(matches) != 1:
                        raise ValueError("Expected exactly one data member in official archive")
                    payload = archive.read(matches[0])
            if sha256(payload) != source["sha256"]:
                raise ValueError("Payload differs from locked snapshot; no automatic vintage change")
            metadata = {
                "source_id": source["id"], "downloaded_from": url,
                "retrieval": "official_locked_snapshot" if official else "pinned_mirror",
                "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
                "sha256": source["sha256"], "bytes": len(payload),
                "earlier_attempts": failures,
                "official_checksum_verified": official,
            }
            atomic_write(path, payload)
            write_json(metadata_path, metadata)
            print(f"{source['id']}: {metadata['retrieval']}, SHA-256 verified", file=sys.stderr)
            return payload, metadata
        except (OSError, ValueError, zipfile.BadZipFile) as error:
            failures.append({"url": url, "error": str(error)})
            print(f"{source['id']}: {error}", file=sys.stderr)
    raise RuntimeError(f"All verified download candidates failed for {source['id']}: {failures}")


def parse_gsw(payload: bytes) -> dict[date, dict]:
    lines = payload.decode("utf-8-sig").splitlines()
    header = next((i for i, line in enumerate(lines) if line.startswith("Date,")), None)
    if header is None:
        raise ValueError("GSW Date header missing")
    reader = csv.DictReader(lines[header:])
    if not set(YIELD_COLUMNS).issubset(reader.fieldnames or []):
        raise ValueError("GSW zero-coupon yield columns missing")
    monthly = {}
    seen = set()
    for row in reader:
        observed = date.fromisoformat(row["Date"])
        if observed in seen:
            raise ValueError(f"Duplicate GSW observation: {observed}")
        seen.add(observed)
        values = {column: numeric(row[column]) for column in YIELD_COLUMNS}
        if any(v is None for v in values.values()):
            continue
        month = observed.replace(day=1)
        # Select the last COMPLETE same-day curve; never combine different dates.
        if month not in monthly or observed > monthly[month]["observed_at"]:
            monthly[month] = {"observed_at": observed, **values}
    return monthly


def parse_macro(payload: bytes) -> dict[date, dict]:
    reader = csv.DictReader(io.StringIO(payload.decode("utf-8-sig")))
    required = {"sasdate", "FEDFUNDS", "CUMFNS", "CPIAUCSL"}
    if not required.issubset(reader.fieldnames or []):
        raise ValueError("FRED-MD must contain raw FEDFUNDS, CUMFNS and CPIAUCSL")
    observations = {}
    for row in reader:
        if not row["sasdate"] or row["sasdate"].strip().lower().startswith("transform"):
            continue
        month = datetime.strptime(row["sasdate"], "%m/%d/%Y").date().replace(day=1)
        if month in observations:
            raise ValueError(f"Duplicate macro month: {month}")
        observations[month] = {column: numeric(row[column])
                               for column in ["FEDFUNDS", "CUMFNS", "CPIAUCSL"]}
    return observations


def build_yield_rows(gsw: dict[date, dict], macro: dict[date, dict],
                     start: date = date(1985, 1, 1),
                     end: date = date(2024, 12, 1)) -> list[dict]:
    rows = []
    month = start.replace(day=1)
    while month <= end:
        macro_month = add_months(month, -2)
        annual_base = add_months(macro_month, -12)
        if month not in gsw or macro_month not in macro or annual_base not in macro:
            raise ValueError(f"Missing required calendar observation for target {month}")
        current, past = macro[macro_month], macro[annual_base]
        if any(current.get(c) is None for c in ["FEDFUNDS", "CUMFNS", "CPIAUCSL"]) or past.get("CPIAUCSL") is None:
            raise ValueError(f"Missing macro input for target {month}; no forward fill is permitted")
        if current["CPIAUCSL"] <= 0 or past["CPIAUCSL"] <= 0:
            raise ValueError("CPI must be positive for log inflation")
        row = {
            "date": month.replace(day=calendar.monthrange(month.year, month.month)[1]).isoformat(),
            "observed_at": gsw[month]["observed_at"].isoformat(),
            **{column: gsw[month][column] for column in YIELD_COLUMNS},
            "macro_observed_month": macro_month.isoformat(),
            "macro_fedfunds": current["FEDFUNDS"],
            "macro_cumfns": current["CUMFNS"],
            "macro_capacity": current["CUMFNS"],
            "macro_inflation": 100 * math.log(current["CPIAUCSL"] / past["CPIAUCSL"]),
            "capacity_series": "CUMFNS",
            "split": "train" if month.year < 2005 else "validation" if month.year < 2020 else "confirmation",
        }
        rows.append(row)
        month = add_months(month, 1)
    return rows


def parse_air(payload: bytes) -> list[dict]:
    reader = csv.DictReader(io.StringIO(payload.decode("utf-8-sig")), delimiter=";")
    if not ({"Date", "Time"} | set(AIR_COLUMNS)).issubset(reader.fieldnames or []):
        raise ValueError("Expected original UCI semicolon-separated schema")
    observations = []
    previous = None
    for row in reader:
        if not row["Date"]:
            if any((value or "").strip() for key, value in row.items() if key):
                raise ValueError("Nonempty air observation has no date")
            continue
        timestamp = datetime.strptime(row["Date"] + " " + row["Time"], "%d/%m/%Y %H.%M.%S")
        if previous is not None and timestamp - previous != timedelta(hours=1):
            raise ValueError("Air snapshot must be a unique, ordered hourly grid")
        previous = timestamp
        observations.append({
            "timestamp": timestamp.isoformat(),
            **{output: numeric(row[column]) for column, output in AIR_COLUMNS.items()},
            "split": "train" if timestamp < datetime(2004, 11, 1)
                     else "validation" if timestamp < datetime(2005, 1, 1)
                     else "confirmation",
        })
    return observations


def write_csv(path: Path, rows: list[dict]) -> dict:
    if not rows:
        raise ValueError("Refusing to write an empty dataset")
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    payload = buffer.getvalue().encode()
    atomic_write(path, payload)
    return {"path": str(path.relative_to(path.parents[1])), "rows": len(rows),
            "sha256": sha256(payload), "columns": list(rows[0])}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", choices=["all", "yield", "air"], default="all")
    parser.add_argument("--offline", action="store_true", help="Use only checksum-verified local raw snapshots")
    parser.add_argument("--prefer-official", action=argparse.BooleanOptionalAction, default=True,
                        help="Try official sources before locked mirrors; never change checksums automatically")
    parser.add_argument("--data-root", type=Path, default=ROOT / "data")
    args = parser.parse_args(argv)
    registry = json.loads((ROOT / "data" / "sources.json").read_text())
    sources = {s["id"]: s for s in registry["sources"]}
    raw_dir, processed_dir = args.data_root / "raw", args.data_root / "processed"
    manifest_path = processed_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {
        "schema_version": 1, "sources": {}, "datasets": {},
    }
    manifest["source_registry_sha256"] = sha256((ROOT / "data" / "sources.json").read_bytes())
    manifest["canonical_yield_design"] = registry["canonical_yield_design"]

    def obtain(source_id: str) -> bytes:
        payload, retrieval = fetch_source(sources[source_id], raw_dir, args.offline, args.prefer_official)
        manifest["sources"][source_id] = {**sources[source_id], "retrieval": retrieval}
        return payload

    if args.dataset in {"all", "yield"}:
        rows = build_yield_rows(parse_gsw(obtain("gsw")), parse_macro(obtain("fred_md")))
        details = write_csv(processed_dir / "yield_monthly.csv", rows)
        details.update({"first": rows[0]["date"], "last": rows[-1]["date"],
                        "macro_lag_months": 2, "capacity_series": "CUMFNS",
                        "status": "exploratory_revised_vintage_pseudo_out_of_sample",
                        "confirmation": "2020-01 through 2024-12: prepared but not authorized for adaptive model selection"})
        manifest["datasets"]["yield"] = details
        print(json.dumps({"dataset": "yield", **details}))
    if args.dataset in {"all", "air"}:
        rows = parse_air(obtain("air_quality"))
        details = write_csv(processed_dir / "air_quality.csv", rows)
        details.update({"first": rows[0]["timestamp"], "last": rows[-1]["timestamp"],
                        "missing_CO": sum(r["CO"] is None for r in rows),
                        "missing_encoding": "empty CSV fields; original -200 sentinel converted to missing",
                        "timezone": "not specified by source; naive timestamps retained",
                        "confirmation": "2005-01-01 onward: prepared but not authorized for adaptive model selection"})
        manifest["datasets"]["air"] = details
        print(json.dumps({"dataset": "air", **details}))
    write_json(manifest_path, manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
