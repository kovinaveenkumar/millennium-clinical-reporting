"""
Port to Oracle and prove the numbers match.

    docker run -d --name millennium-oracle -p 1521:1521 -e ORACLE_PASSWORD=<pw> \
        -e APP_USER=millennium -e APP_USER_PASSWORD=<pw> gvenzl/oracle-free:23-slim-faststart
    python oracle/oracle_port.py load     # create tables in Oracle, copy rows from data/millennium.db
    python oracle/oracle_port.py run      # run oracle/reports_oracle.sql, reconcile with the SQLite reports

Connection: ORA_PASSWORD (required), ORA_USER (default millennium), ORA_DSN (default localhost:1521/FREEPDB1).
Writes output/oracle_reconciliation.csv and output/oracle_explain_ed_throughput.txt.
"""
import datetime as dt
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

import oracledb
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from report_runner import AS_OF, DB, Prompts, bind, connect, run  # noqa: E402

TABLES = ["code_value_set", "code_value", "cust_unit_capacity", "person", "person_alias", "prsnl", "encounter",
          "encntr_alias", "encntr_loc_hist", "orders", "order_detail", "clinical_event"]
KEYS = {"ed_throughput": ["facility"], "lab_tat": ["facility", "priority", "test"],
        "critical_compliance": ["facility", "nurse_unit"], "readmit_by_facility": ["facility"],
        "census_summary": ["facility", "nurse_unit"]}


def ora():
    user = os.environ.get("ORA_USER", "millennium")
    dsn = os.environ.get("ORA_DSN", "localhost:1521/FREEPDB1")
    password = os.environ.get("ORA_PASSWORD")
    if not password:
        sys.exit("Set ORA_PASSWORD to the APP_USER_PASSWORD you gave the Oracle container (see oracle/README.md).")
    try:
        return oracledb.connect(user=user, password=password, dsn=dsn)
    except oracledb.Error as e:
        msg = str(e).splitlines()[0]
        if "ORA-01017" in msg:
            sys.exit(f"Oracle rejected the login for {user}@{dsn}. Check ORA_USER / ORA_PASSWORD.")
        if "DPY-6005" in msg or "DPY-6000" in msg:
            sys.exit(f"Could not reach Oracle at {dsn}. Is the container running (docker ps)? "
                     "A fresh container needs about 30 seconds before it accepts logins.")
        sys.exit(f"Could not connect to Oracle at {dsn}: {msg}")


def to_dt(v):
    return dt.datetime.fromisoformat(v) if isinstance(v, str) and len(v) == 19 and v[4] == "-" and v[13] == ":" else v


def load():
    src = sqlite3.connect(DB)
    con = ora(); cur = con.cursor()
    for t in reversed(TABLES):
        try:
            cur.execute(f"DROP TABLE {t} PURGE")
        except oracledb.DatabaseError:
            pass
    for stmt in (Path(__file__).parent / "schema_oracle.sql").read_text().split(";"):
        body = "\n".join(l for l in stmt.splitlines() if not l.strip().startswith("--")).strip()
        if body:
            cur.execute(body)
    for t in TABLES:
        t0 = time.perf_counter()
        scur = src.execute(f"SELECT * FROM {t}")
        cols = [c[0] for c in scur.description]
        sql = f"INSERT INTO {t} ({', '.join(cols)}) VALUES ({', '.join(':' + str(i + 1) for i in range(len(cols)))})"
        n = 0
        while rows := scur.fetchmany(20000):
            cur.executemany(sql, [tuple(to_dt(v) for v in r) for r in rows])
            n += len(rows)
        con.commit()
        print(f"{t:18s} {n:>9,} rows  {time.perf_counter() - t0:5.1f}s")
    for t in TABLES:
        cur.callproc("DBMS_STATS.GATHER_TABLE_STATS", [con.username.upper(), t.upper()])
    print("statistics gathered")


def load_oracle_queries():
    parts = re.split(r"^-- name: (\w+)\s*$", (Path(__file__).parent / "reports_oracle.sql").read_text(), flags=re.M)
    return {n: q.strip() for n, q in zip(parts[1::2], parts[2::2])}


def run_and_reconcile():
    con = ora(); cur = con.cursor()
    lite = connect()
    p = Prompts()
    params = bind(lite, p)
    rows = []
    for name, sql in load_oracle_queries().items():
        used = {k: v for k, v in params.items() if f":{k}" in sql}
        t0 = time.perf_counter()
        try:
            cur.execute(sql, used)
        except oracledb.DatabaseError as e:
            if "ORA-00942" in str(e):
                sys.exit("The tables don't exist in Oracle yet. Run: python oracle/oracle_port.py load")
            raise
        o = pd.DataFrame(cur.fetchall(), columns=[d[0].lower() for d in cur.description])
        secs = time.perf_counter() - t0
        s = run(name, p, lite)
        k = KEYS[name]
        m = s.merge(o, on=k, how="outer", suffixes=("_sqlite", "_oracle"), indicator=True)
        cells = mismatched = 0
        worst = 0.0
        for c in [c for c in s.columns if c not in k]:
            a = pd.to_numeric(m[c + "_sqlite"]); b = pd.to_numeric(m[c + "_oracle"])
            diff = (a - b).abs().fillna(0)
            cells += len(diff); mismatched += int((diff > 0).sum()); worst = max(worst, float(diff.max()))
        rows.append(dict(report=name, rows_sqlite=len(s), rows_oracle=len(o), rows_unmatched=int((m._merge != "both").sum()),
                         cells_compared=cells, cells_different=mismatched, max_abs_diff=worst, oracle_seconds=round(secs, 2)))
    df = pd.DataFrame(rows)
    out = ROOT / "output"
    df.to_csv(out / "oracle_reconciliation.csv", index=False)
    print(df.to_string(index=False))

    # explain plan for the ED report, as an analyst would attach to a tuning ticket
    sql = load_oracle_queries()["ed_throughput"]
    cur.execute("EXPLAIN PLAN SET STATEMENT_ID = 'ED' FOR " + sql, {k: v for k, v in params.items() if f":{k}" in sql})
    cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'ED', 'BASIC +ROWS'))")
    plan = "\n".join(r[0] for r in cur.fetchall())
    (out / "oracle_explain_ed_throughput.txt").write_text(plan + "\n")
    print("\n" + plan)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd not in ("load", "run"):
        sys.exit("usage: python oracle/oracle_port.py [load|run]")
    load() if cmd == "load" else run_and_reconcile()
