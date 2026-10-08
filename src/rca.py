"""
Reproduce the two report defects written up in docs/rca.md and quantify their impact
(v1 = archived defective SQL in sql/archive/, v2 = current report).   python src/rca.py
"""
import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_runner import ROOT, AS_OF, Prompts, bind, connect, load_queries, run  # noqa: E402


def main():
    con = connect()
    p = Prompts()
    old = load_queries(ROOT / "sql" / "archive")
    params = bind(con, p)
    out = {}

    # Incident 1: ED visits qualified on encounter type
    v1 = pd.read_sql_query(old["ed_throughput_v1"], con, params=params)
    v2 = run("ed_throughput", p, con)
    m = v1.merge(v2, on="facility", suffixes=("_v1", "_v2"))
    out["ed"] = {
        "v1_visits": int(m.ed_visits_v1.sum()), "v2_visits": int(m.ed_visits_v2.sum()),
        "v1_pct_over_4h": round(float((m.pct_over_4h_v1 * m.ed_visits_v1).sum() / m.ed_visits_v1.sum()), 1),
        "v2_pct_over_4h": round(float((m.pct_over_4h_v2 * (m.ed_visits_v2 * (1 - m.lwbs_pct / 100))).sum()
                                      / (m.ed_visits_v2 * (1 - m.lwbs_pct / 100)).sum()), 1),
        "by_facility": m[["facility", "ed_visits_v1", "ed_visits_v2", "pct_over_4h_v1", "pct_over_4h_v2"]].to_dict("records"),
    }
    print("Incident 1 - ED throughput qualified on encntr_type_cd = EMERGENCY")
    print(m[["facility", "ed_visits_v1", "ed_visits_v2", "pct_over_4h_v1", "pct_over_4h_v2"]].to_string(index=False))

    # Incident 2: lab TAT on every clinical_event version
    v1 = pd.read_sql_query(old["lab_tat_v1"], con, params=params)
    v2 = run("lab_tat", p, con).query("priority == 'STAT'")
    v2f = v2.groupby("facility").apply(lambda g: pd.Series({
        "orders": g.orders.sum(), "pct_within_60": round((g.pct_within_target * g.orders).sum() / g.orders.sum(), 1)}),
        include_groups=False).reset_index()
    m2 = v1.merge(v2f, on="facility", suffixes=("_v1", "_v2"))
    q = lambda s: con.execute(s, {"as_of": AS_OF}).fetchone()[0]
    out["lab"] = {
        "superseded_rows": q("SELECT COUNT(*) FROM clinical_event WHERE order_id IS NOT NULL AND valid_until_dt_tm <= :as_of"),
        "in_error_current": q("SELECT COUNT(*) FROM clinical_event c JOIN code_value s ON s.code_value = c.result_status_cd "
                              "WHERE s.cdf_meaning = 'INERROR' AND c.valid_until_dt_tm > :as_of"),
        "corrected_events": q("SELECT COUNT(*) FROM clinical_event c JOIN code_value s ON s.code_value = c.result_status_cd "
                              "WHERE s.cdf_meaning = 'MODIFIED' AND c.valid_until_dt_tm > :as_of"),
        "median_correction_delay_h": round(float(pd.read_sql_query(
            "SELECT (julianday(n.verified_dt_tm) - julianday(o.verified_dt_tm)) * 24 AS h FROM clinical_event n "
            "JOIN clinical_event o ON o.event_id = n.event_id AND o.valid_until_dt_tm = n.valid_from_dt_tm "
            "WHERE n.valid_until_dt_tm > :as_of AND n.clinical_event_id <> o.clinical_event_id", con,
            params={"as_of": AS_OF}).h.median()), 1),
        "by_facility": m2.to_dict("records"),
    }
    print("\nIncident 2 - Lab TAT over every CLINICAL_EVENT version (STAT)")
    print(m2.to_string(index=False))
    print({k: v for k, v in out["lab"].items() if k != "by_facility"})
    (ROOT / "output").mkdir(exist_ok=True)
    (ROOT / "output" / "rca_numbers.json").write_text(json.dumps(out, indent=2, default=float))


if __name__ == "__main__":
    main()
