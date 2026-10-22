"""Meaningful data-boundary checks; fixtures never use future observations."""
import importlib.util
import math
from datetime import date
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("prepare_data", Path(__file__).resolve().parents[1] / "scripts" / "prepare_data.py")
data = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(data)


class DataPreparationTests(unittest.TestCase):
    def test_missing_code_and_decimal_comma(self):
        self.assertIsNone(data.numeric("-200"))
        self.assertIsNone(data.numeric("-200,0"))
        self.assertIsNone(data.numeric("NA"))
        self.assertEqual(data.numeric("2,6"), 2.6)
        self.assertEqual(data.numeric("0"), 0.0)

    def test_gsw_selects_last_complete_same_day_curve(self):
        header = "Date," + ",".join(data.YIELD_COLUMNS)
        source = "metadata\n" + header + "\n1985-01-30,1,2,3,4,5,6\n1985-01-31,9,9,9,9,9,NA\n"
        rows = data.parse_gsw(source.encode())
        self.assertEqual(rows[date(1985, 1, 1)]["observed_at"], date(1985, 1, 30))
        self.assertEqual(rows[date(1985, 1, 1)]["SVENY01"], 1)

    def test_macro_calendar_lag_crosses_year_and_uses_no_future_values(self):
        target = date(1985, 1, 1)
        gsw = {target: {"observed_at": date(1985, 1, 31), **{c: 5 for c in data.YIELD_COLUMNS}}}
        macro = {
            date(1984, 11, 1): {"FEDFUNDS": 7, "CUMFNS": 80, "CPIAUCSL": 110},
            date(1983, 11, 1): {"CPIAUCSL": 100},
            date(1984, 12, 1): {"FEDFUNDS": 999, "CUMFNS": 999, "CPIAUCSL": 999},
            date(1985, 1, 1): {"FEDFUNDS": 999, "CUMFNS": 999, "CPIAUCSL": 999},
        }
        row = data.build_yield_rows(gsw, macro, target, target)[0]
        self.assertEqual(row["macro_observed_month"], "1984-11-01")
        self.assertEqual(row["macro_fedfunds"], 7)
        self.assertEqual(row["capacity_series"], "CUMFNS")
        self.assertAlmostEqual(row["macro_inflation"], 100 * math.log(1.1))
        macro[date(1984, 11, 1)]["FEDFUNDS"] = None
        with self.assertRaisesRegex(ValueError, "no forward fill"):
            data.build_yield_rows(gsw, macro, target, target)

    def test_transform_codes_are_not_observations(self):
        source = b"sasdate,FEDFUNDS,CUMFNS,CPIAUCSL\nTransform:,2,2,6\n11/1/1984,7,80,110\n"
        rows = data.parse_macro(source)
        self.assertEqual(list(rows), [date(1984, 11, 1)])
        self.assertEqual(rows[date(1984, 11, 1)]["CPIAUCSL"], 110)

    def test_air_preserves_missing_hour_and_assigns_time_split(self):
        header = "Date;Time;" + ";".join(data.AIR_COLUMNS)
        first = "31/12/2004;23.00.00;" + ";".join(["-200"] + ["1"] * 8)
        second = "01/01/2005;00.00.00;" + ";".join(["2,6"] + ["1"] * 8)
        rows = data.parse_air((header + "\n" + first + "\n" + second + "\n;;;;;;;;;;\n").encode())
        self.assertEqual(len(rows), 2)
        self.assertIsNone(rows[0]["CO"])
        self.assertEqual(rows[0]["split"], "validation")
        self.assertEqual(rows[1]["split"], "confirmation")
        self.assertEqual(rows[1]["CO"], 2.6)

    def test_checksum_mismatch_refuses_cached_data_even_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.csv").write_bytes(b"tampered")
            source = {"id": "test", "filename": "test.csv", "sha256": data.sha256(b"expected")}
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                data.fetch_source(source, root, offline=True)


if __name__ == "__main__":
    unittest.main()
