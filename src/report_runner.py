"""
Report runner: loads the named queries in sql/reports/*.sql, binds the prompt values
(the same idea as CCL prompts $START_DT / $END_DT / $FACILITY) and returns DataFrames.

    python src/report_runner.py --start 2026-01-01 --end 2026-06-30 --facility "Mercy South"
"""
import argparse
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "millennium.db"
REPORT_DIR = ROOT / "sql" / "reports"
AS_OF = "2026-07-01 00:00:00"          # data cut: everything after this has not happened yet


@dataclass
class Prompts:
    start_dt: str = "2026-01-01"
    end_dt: str = "2026-06-30"
    facility: str = "All"              # facility display, or "All"
    as_of: str = AS_OF


def connect(db=DB):
    if not Path(db).exists():
        raise SystemExit(f"{db} not found - run: python src/generate_data.py")
    return sqlite3.connect(db)


def load_queries(report_dir=REPORT_DIR):
    """Return {query_name: sql} in file order. Files hold one or more '-- name: x' blocks."""
    queries = {}
    for f in sorted(Path(report_dir).glob("*.sql")):
        parts = re.split(r"^-- name: (\w+)\s*$", f.read_text(), flags=re.M)
        for name, sql in zip(parts[1::2], parts[2::2]):
            queries[name] = sql.strip()
    return queries


def facility_cd(con, display):
    """uar_get_code_by("DISPLAY", 220, display) equivalent; 0 means all facilities."""
    if display in (None, "", "All"):
        return 0
    row = con.execute("SELECT code_value FROM code_value WHERE code_set = 220 AND cdf_meaning = 'FACILITY' "
                      "AND display = ? AND active_ind = 1", (display,)).fetchone()
    if row is None:
        raise ValueError(f"unknown facility prompt value: {display!r}")
    return row[0]


def bind(con, prompts: Prompts):
    return {"start_dt": prompts.start_dt, "end_dt": prompts.end_dt,
            "facility_cd": facility_cd(con, prompts.facility), "as_of": prompts.as_of}


def run(name, prompts=None, con=None):
    con = con or connect()
    sql = load_queries()[name]
    params = bind(con, prompts or Prompts())
    return pd.read_sql_query(sql, con, params=params)


def run_all(prompts=None, con=None):
    """Run every query; returns {name: (DataFrame, seconds)}."""
    con = con or connect()
    params = bind(con, prompts or Prompts())
    out = {}
    for name, sql in load_queries().items():
        t = time.perf_counter()
        df = pd.read_sql_query(sql, con, params=params)
        out[name] = (df, time.perf_counter() - t)
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--start", default=Prompts.start_dt)
    ap.add_argument("--end", default=Prompts.end_dt)
    ap.add_argument("--facility", default="All")
    ap.add_argument("--report", help="run one named query only")
    a = ap.parse_args()
    p = Prompts(a.start, a.end, a.facility)
    pd.set_option("display.width", 200, "display.max_columns", 20)
    results = {a.report: (run(a.report, p), 0)} if a.report else run_all(p)
    for name, (df, sec) in results.items():
        print(f"\n=== {name}  ({len(df)} rows, {sec:.2f}s)")
        print(df.head(15).to_string(index=False))
