"""
Query tuning experiments (the same habits used to tune a CCL PLAN/JOIN):
  1. keep the qualifying date column bare (no function around an indexed column)
  2. read the plan: same logic, wrong index chosen -> steer the planner (like an Oracle hint / CCL orahint)
  3. replace a range join that rescans history for every day with a single pass (running sum)
Prints EXPLAIN QUERY PLAN + median runtime before/after; writes output/perf_results.csv.

    python src/tune.py
"""
import statistics
import sys
import time
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_runner import ROOT, AS_OF, Prompts, bind, connect, load_queries  # noqa: E402


CENSUS_RUNNING_SUM = """
WITH RECURSIVE days(census_dt) AS (
  SELECT datetime(:start_dt) UNION ALL SELECT datetime(census_dt, '+1 day') FROM days WHERE census_dt < datetime(:end_dt)
),
seg AS (  -- first and first-after-last midnight each segment covers
  SELECT h.loc_nurse_unit_cd AS unit,
         CASE WHEN time(h.beg_effective_dt_tm) = '00:00:00' THEN datetime(h.beg_effective_dt_tm)
              ELSE datetime(date(h.beg_effective_dt_tm), '+1 day') END AS m_in,
         CASE WHEN time(h.end_effective_dt_tm) = '00:00:00' THEN datetime(h.end_effective_dt_tm)
              ELSE datetime(date(h.end_effective_dt_tm), '+1 day') END AS m_out
  FROM encntr_loc_hist h JOIN cust_unit_capacity cap ON cap.loc_nurse_unit_cd = h.loc_nurse_unit_cd
  WHERE h.active_ind = 1 AND (:facility_cd = 0 OR cap.loc_facility_cd = :facility_cd)
    AND h.end_effective_dt_tm > datetime(:start_dt) AND h.beg_effective_dt_tm <= datetime(:end_dt)
),
delta AS (SELECT unit, dt, SUM(d) AS d FROM (SELECT unit, m_in AS dt, 1 AS d FROM seg WHERE m_in < m_out
                                             UNION ALL SELECT unit, m_out, -1 FROM seg WHERE m_in < m_out)
          GROUP BY unit, dt),
base AS (SELECT unit, SUM(d) AS b FROM delta WHERE dt < datetime(:start_dt) GROUP BY unit)
SELECT fac.display AS facility, u.display AS nurse_unit, date(days.census_dt) AS census_date, cap.staffed_beds,
       COALESCE(base.b, 0) + SUM(COALESCE(delta.d, 0)) OVER (PARTITION BY cap.loc_nurse_unit_cd ORDER BY days.census_dt) AS census
FROM days CROSS JOIN cust_unit_capacity cap
JOIN code_value u   ON u.code_value = cap.loc_nurse_unit_cd
JOIN code_value fac ON fac.code_value = cap.loc_facility_cd
LEFT JOIN delta ON delta.unit = cap.loc_nurse_unit_cd AND delta.dt = days.census_dt
LEFT JOIN base  ON base.unit = cap.loc_nurse_unit_cd
WHERE (:facility_cd = 0 OR cap.loc_facility_cd = :facility_cd)
"""


def timed(con, sql, params, n=5):
    runs = []
    for _ in range(n):
        t = time.perf_counter(); con.execute(sql, params).fetchall(); runs.append(time.perf_counter() - t)
    return statistics.median(runs)


def plan(con, sql, params):
    return [r[3] for r in con.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()]


def main():
    con = connect()
    params = {"start_dt": "2026-06-01", "end_dt": "2026-06-07", "as_of": AS_OF}
    rows = []

    # 1. Function on an indexed date column -> full scan
    bad = ("SELECT o.catalog_cd, COUNT(*) FROM orders o "
           "WHERE date(o.orig_order_dt_tm) BETWEEN :start_dt AND :end_dt GROUP BY o.catalog_cd")
    good = ("SELECT o.catalog_cd, COUNT(*) FROM orders o "
            "WHERE o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day') GROUP BY o.catalog_cd")
    assert con.execute(bad, params).fetchall() == con.execute(good, params).fetchall()
    for label, sql in [("date() around orig_order_dt_tm", bad), ("bare range on orig_order_dt_tm", good)]:
        rows.append(("1 sargable date filter (1 week of orders)", label, timed(con, sql, params), " | ".join(plan(con, sql, params))))

    p = bind(con, Prompts())
    # 2. Same logic, bad plan: the planner picked an automatic index on active_ind (low cardinality)
    tuned = load_queries()["census_summary"]
    untuned = tuned.replace("+h.active_ind = 1", "h.active_ind = 1")
    assert con.execute(tuned, p).fetchall() == con.execute(untuned, p).fetchall()
    for label, sql in [("as first written", untuned), ("+h.active_ind (index use disabled on that term)", tuned)]:
        rows.append(("2 census_summary report (6 months)", label, timed(con, sql, p, 3),
                     " | ".join(x for x in plan(con, sql, p) if " h " in x)))

    # 3. Midnight census: range join (days x units x segments) vs running sum of +1/-1 deltas
    original = load_queries()["census_daily"]
    a = pd.read_sql_query(original, con, params=p)[["nurse_unit", "census_date", "census"]]
    b = pd.read_sql_query(CENSUS_RUNNING_SUM, con, params=p)[["nurse_unit", "census_date", "census"]]
    key = ["nurse_unit", "census_date"]
    assert a.sort_values(key).reset_index(drop=True).equals(b.sort_values(key).reset_index(drop=True)), "rewrite differs"
    rows.append(("3 census_daily rewrite (181 days x 9 units)", "range join: segment covers midnight",
                 timed(con, original, p, 3), "SEARCH h USING INDEX xie_elh_unit per unit-day"))
    rows.append(("3 census_daily rewrite (181 days x 9 units)", "running sum of +1/-1 deltas (identical output)",
                 timed(con, CENSUS_RUNNING_SUM, p, 3), "one pass over segments + window SUM"))

    df = pd.DataFrame(rows, columns=["experiment", "variant", "median_seconds", "query_plan"])
    df["median_seconds"] = df.median_seconds.round(4)
    (ROOT / "output").mkdir(exist_ok=True)
    df.to_csv(ROOT / "output" / "perf_results.csv", index=False)
    for r in df.itertuples():
        print(f"{r.experiment}\n  {r.variant:45s} {r.median_seconds:8.4f}s\n    plan: {r.query_plan}")


if __name__ == "__main__":
    main()
