"""
Pre-publish validation: data-quality checks (sql/dq_checks.sql) + report control totals.
Writes output/validation_results.csv and exits 1 if anything fails (so run_all.sh stops
before publishing, the same way a failed validation should block a report migration).

    python src/validate.py
"""
import re
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_runner import ROOT, AS_OF, Prompts, connect, run  # noqa: E402

FACILITIES = ["Mercy North", "Mercy South", "Lakeside Regional"]


def dq_checks(con):
    sql = (ROOT / "sql" / "dq_checks.sql").read_text()
    parts = re.split(r"^-- name: (\w+)\s*$", sql, flags=re.M)
    rows = []
    for name, q in zip(parts[1::2], parts[2::2]):
        bad = con.execute(q, {"as_of": AS_OF} if ":as_of" in q else {}).fetchone()[0]
        rows.append(("data quality", name, 0, bad, bad == 0))
    return rows


def control_totals(con):
    """Reconcile report output to independent counts from the source tables."""
    rows = []
    p = Prompts()
    ed = run("ed_throughput", p, con)
    src = con.execute("""
        SELECT COUNT(*) FROM encounter e JOIN person p ON p.person_id = e.person_id
        WHERE e.active_ind = 1 AND p.name_last_key NOT LIKE 'ZZTEST%' AND e.arrive_dt_tm >= ? AND e.arrive_dt_tm < ?
          AND NOT EXISTS (SELECT 1 FROM encntr_loc_hist h WHERE h.encntr_id = e.encntr_id
                          AND h.end_effective_dt_tm > '2100-01-01'
                          AND h.beg_effective_dt_tm = (SELECT MIN(beg_effective_dt_tm) FROM encntr_loc_hist WHERE encntr_id = e.encntr_id))
        """, ("2026-01-01", "2026-07-01")).fetchone()[0]
    rows.append(("control total", "ED visits: report = source", src, int(ed.ed_visits.sum()), src == ed.ed_visits.sum()))

    for name, col in [("ed_throughput", "ed_visits"), ("readmit_by_facility", "index_discharges"),
                      ("critical_compliance", "critical_results"), ("lab_tat", "orders")]:
        total = run(name, p, con)[col].sum()
        parts = sum(run(name, Prompts(facility=f), con)[col].sum() for f in FACILITIES)
        rows.append(("control total", f"{name}: sum of facility prompts = All", int(total), int(parts), total == parts))

    tat = run("lab_tat", p, con)
    src = con.execute("""
        SELECT COUNT(DISTINCT o.order_id) FROM orders o
        JOIN code_value s ON s.code_value = o.order_status_cd AND s.cdf_meaning = 'COMPLETED'
        JOIN person p ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
        JOIN encounter e ON e.encntr_id = o.encntr_id AND e.active_ind = 1
        JOIN clinical_event c ON c.order_id = o.order_id AND c.valid_until_dt_tm > ?
        JOIN code_value rs ON rs.code_value = c.result_status_cd AND rs.cdf_meaning <> 'INERROR'
        WHERE o.orig_order_dt_tm >= '2026-01-01' AND o.orig_order_dt_tm < '2026-07-01'""", (AS_OF,)).fetchone()[0]
    rows.append(("control total", "Lab TAT orders: report = source", src, int(tat.orders.sum()), src == tat.orders.sum()))

    test_enc = con.execute("SELECT COUNT(*) FROM encounter e JOIN person p ON p.person_id = e.person_id "
                           "WHERE p.name_last_key LIKE 'ZZTEST%'").fetchone()[0]
    wl = run("critical_worklist", p, con)
    fins = set(wl.fin)
    leaked = con.execute("SELECT COUNT(*) FROM encntr_alias a JOIN encounter e ON e.encntr_id = a.encntr_id "
                         "JOIN person p ON p.person_id = e.person_id WHERE p.name_last_key LIKE 'ZZTEST%' "
                         f"AND a.alias IN ({','.join('?' * len(fins))})", tuple(fins)).fetchone()[0]
    rows.append(("control total", f"test patients excluded ({test_enc} test encounters in source)", 0, leaked, leaked == 0))
    return rows


def main():
    con = connect()
    rows = dq_checks(con) + control_totals(con)
    df = pd.DataFrame(rows, columns=["type", "check", "expected", "actual", "passed"])
    out = ROOT / "output"; out.mkdir(exist_ok=True)
    df.to_csv(out / "validation_results.csv", index=False)
    for r in df.itertuples():
        print(f"{'PASS' if r.passed else 'FAIL'}  {r.type:13s} {r.check}  (expected {r.expected}, got {r.actual})")
    n_fail = (~df.passed).sum()
    print(f"\n{len(df) - n_fail}/{len(df)} checks passed")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
