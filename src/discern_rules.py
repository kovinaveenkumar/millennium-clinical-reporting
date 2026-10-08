"""
Discern Expert rule simulator (silent mode).

Replays historical orders/results through the rules in rules/discern_rules.json, writes each
firing to EKS_MODULE_AUDIT (run_mode = 'SILENT') and measures what would happen if the rule
were turned on: alert volume per facility and, for the duplicate-order rule, how many firings
are true duplicates vs clinically intended repeats (serial troponins, daily AM labs) at several
look-back windows.

    python src/discern_rules.py
"""
import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_runner import ROOT, AS_OF, connect  # noqa: E402

RULES = json.loads((ROOT / "rules" / "discern_rules.json").read_text())["rules"]
WINDOWS = [30, 60, 120, 240, 480, 1440]


def load_orders(con):
    return pd.read_sql_query("""
        SELECT o.order_id, o.encntr_id, o.person_id, o.catalog_cd, o.orig_order_dt_tm, fac.display AS facility,
               cat.display AS orderable,
               (SELECT MIN(a.action_dt_tm) FROM order_action a JOIN code_value t ON t.code_value = a.action_type_cd
                WHERE a.order_id = o.order_id AND t.cdf_meaning = 'CANCEL') AS cancel_dt_tm,
               EXISTS (SELECT 1 FROM zz_truth_dup_order z WHERE z.order_id = o.order_id) AS true_dup
        FROM orders o
        JOIN encounter e ON e.encntr_id = o.encntr_id AND e.active_ind = 1
        JOIN person p ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
        JOIN code_value fac ON fac.code_value = e.loc_facility_cd
        JOIN code_value cat ON cat.code_value = o.catalog_cd
        WHERE o.active_ind = 1""", con, parse_dates=["orig_order_dt_tm", "cancel_dt_tm"])


def dup_rule_fires(orders, window_min, orderables):
    """Order-sign logic: an earlier order for the same orderable on the same encounter, placed within
    window_min before this one and NOT cancelled at the moment this order is signed."""
    o = orders[orders.orderable.isin(orderables)]
    pairs = o.merge(o[["encntr_id", "catalog_cd", "order_id", "orig_order_dt_tm", "cancel_dt_tm"]],
                    on=["encntr_id", "catalog_cd"], suffixes=("", "_prior"))
    gap = (pairs.orig_order_dt_tm - pairs.orig_order_dt_tm_prior).dt.total_seconds() / 60
    live = pairs.cancel_dt_tm_prior.isna() | (pairs.cancel_dt_tm_prior > pairs.orig_order_dt_tm)
    hit = pairs[(pairs.order_id != pairs.order_id_prior) & (gap > 0) & (gap <= window_min) & live].copy()
    hit["minutes_since_prior"] = gap[hit.index]
    return hit.sort_values("minutes_since_prior").drop_duplicates("order_id")


def crit_escalation_fires(con, minutes):
    return pd.read_sql_query(f"""
        SELECT ce.clinical_event_id, ce.encntr_id, ce.person_id, ce.verified_dt_tm, fac.display AS facility
        FROM clinical_event ce
        JOIN code_value nrm ON nrm.code_value = ce.normalcy_cd AND nrm.cdf_meaning = 'CRITICAL'
        JOIN code_value rs  ON rs.code_value = ce.result_status_cd AND rs.cdf_meaning IN ('AUTH', 'MODIFIED')
        JOIN encounter e    ON e.encntr_id = ce.encntr_id AND e.active_ind = 1
        JOIN person p       ON p.person_id = ce.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
        JOIN code_value fac ON fac.code_value = e.loc_facility_cd
        WHERE ce.valid_until_dt_tm > :as_of
          AND datetime(ce.verified_dt_tm, '+{minutes} minutes') < :as_of
          AND NOT EXISTS (SELECT 1 FROM clinical_event n
                          JOIN code_value nc ON nc.code_value = n.event_cd AND nc.display = 'Critical Result Notification'
                          WHERE n.encntr_id = ce.encntr_id AND n.valid_until_dt_tm > :as_of
                            AND n.event_end_dt_tm >= ce.verified_dt_tm
                            AND n.event_end_dt_tm <= datetime(ce.verified_dt_tm, '+{minutes} minutes'))""",
        con, params={"as_of": AS_OF})


def main():
    con = connect()
    con.execute("DELETE FROM eks_module_audit")
    orders = load_orders(con)
    audit = []
    out = ROOT / "output"; out.mkdir(exist_ok=True)

    dup = next(r for r in RULES if r["module_name"] == "CUST_LAB_DUP_ORDER")
    rows = []
    n_true = int(orders.true_dup.sum())
    for w in WINDOWS:
        hit = dup_rule_fires(orders, w, dup["logic"]["orderables"])
        tp = int(hit.true_dup.sum())
        rows.append(dict(window_min=w, fires=len(hit), true_duplicates=tp, intended_repeats=len(hit) - tp,
                         precision_pct=round(100 * tp / max(len(hit), 1), 1),
                         recall_pct=round(100 * tp / n_true, 1),
                         fires_per_1000_orders=round(1000 * len(hit) / len(orders), 1)))
        if w == dup["logic"]["window_min"]:
            for r in hit.itertuples():
                audit.append((dup["module_name"], r.orig_order_dt_tm.strftime("%Y-%m-%d %H:%M:%S"), 1, r.person_id,
                              r.encntr_id, r.order_id, None,
                              f"{r.orderable} ordered {r.minutes_since_prior:.0f} min after order {r.order_id_prior}", "SILENT"))
    sens = pd.DataFrame(rows)
    sens.to_csv(out / "rule_window_sensitivity.csv", index=False)

    esc = next(r for r in RULES if r["module_name"] == "CUST_CRIT_LAB_ESCALATE")
    fires = crit_escalation_fires(con, esc["logic"]["minutes"])
    for r in fires.itertuples():
        audit.append((esc["module_name"], r.verified_dt_tm, 1, r.person_id, r.encntr_id, None, r.clinical_event_id,
                      "No critical-result call documented within 30 min - escalate to charge nurse", "SILENT"))

    con.executemany("INSERT INTO eks_module_audit (module_name, begin_dt_tm, conclude, person_id, encntr_id, order_id, "
                    "clinical_event_id, action_return, run_mode) VALUES (?,?,?,?,?,?,?,?,?)", audit)
    con.commit()
    print(f"EKS_MODULE_AUDIT rows written: {len(audit):,}  (orders replayed: {len(orders):,}, "
          f"true duplicates planted: {n_true:,})\n")
    print("Duplicate-order rule: look-back window sensitivity")
    print(sens.to_string(index=False))


if __name__ == "__main__":
    main()
