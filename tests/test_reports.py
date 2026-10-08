"""
Report tests. Each KPI is re-computed independently in pandas from the raw tables and
compared with the SQL report, so a logic error has to be made twice, in two languages,
to slip through. Also: prompt behaviour, exclusions, and regression tests for the RCA defects.
"""
import re

import pandas as pd
import pytest

from report_runner import AS_OF, ROOT, Prompts, bind, load_queries, run

FACS = ["Mercy North", "Mercy South", "Lakeside Regional"]


def median(s):
    return float(s.median())


# ---------------------------------------------------------------- data quality
def test_all_dq_checks_return_zero(con):
    parts = re.split(r"^-- name: (\w+)\s*$", (ROOT / "sql" / "dq_checks.sql").read_text(), flags=re.M)
    bad = {n: con.execute(q, {"as_of": AS_OF} if ":as_of" in q else {}).fetchone()[0]
           for n, q in zip(parts[1::2], parts[2::2])}
    assert bad and all(v == 0 for v in bad.values()), bad


# ---------------------------------------------------------------- independent re-computation
@pytest.fixture(scope="module")
def raw(con):
    q = lambda s: pd.read_sql_query(s, con)
    return dict(
        enc=q("SELECT e.*, p.name_last_key FROM encounter e JOIN person p USING (person_id)"),
        elh=q("SELECT * FROM encntr_loc_hist WHERE active_ind = 1"),
        cv=q("SELECT code_value, code_set, display, cdf_meaning FROM code_value"),
    )


def test_ed_throughput_matches_pandas(con, raw):
    cv = raw["cv"].set_index("code_value")
    e = raw["enc"]
    e = e[(e.active_ind == 1) & ~e.name_last_key.str.startswith("ZZTEST") & e.arrive_dt_tm.notna()
          & (e.arrive_dt_tm >= "2026-01-01") & (e.arrive_dt_tm < "2026-07-01")]
    first = raw["elh"].sort_values("beg_effective_dt_tm").drop_duplicates("encntr_id")
    e = e.merge(first[["encntr_id", "end_effective_dt_tm"]], on="encntr_id")
    e = e[e.end_effective_dt_tm < "2100"]
    e["los"] = (pd.to_datetime(e.end_effective_dt_tm) - pd.to_datetime(e.arrive_dt_tm)).dt.total_seconds() / 60
    e["facility"] = e.loc_facility_cd.map(cv.display)
    e["lwbs"] = e.disch_disposition_cd.map(cv.cdf_meaning) == "LWBS"
    e["admitted"] = e.encntr_type_cd.map(cv.cdf_meaning) == "INPATIENT"
    rpt = run("ed_throughput", Prompts(), con).set_index("facility")
    for f in FACS:
        g = e[e.facility == f]; seen = g[~g.lwbs]
        assert rpt.loc[f, "ed_visits"] == len(g)
        assert rpt.loc[f, "median_los_discharged_min"] == round(median(seen[~seen.admitted].los))
        assert rpt.loc[f, "median_los_admitted_min"] == round(median(seen[seen.admitted].los))
        assert rpt.loc[f, "pct_over_4h"] == pytest.approx(100 * (seen.los > 240).mean(), abs=0.05)


def test_lab_tat_matches_pandas(con):
    o = pd.read_sql_query("""
        SELECT o.order_id, o.orig_order_dt_tm, fac.display AS facility, cat.display AS test, od.oe_field_display_value AS priority,
               ce.verified_dt_tm, ce.valid_until_dt_tm, rs.cdf_meaning AS status
        FROM orders o JOIN code_value st ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'COMPLETED'
        JOIN order_detail od ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
        JOIN encounter e ON e.encntr_id = o.encntr_id AND e.active_ind = 1
        JOIN person p ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
        JOIN code_value fac ON fac.code_value = e.loc_facility_cd JOIN code_value cat ON cat.code_value = o.catalog_cd
        JOIN clinical_event ce ON ce.order_id = o.order_id JOIN code_value rs ON rs.code_value = ce.result_status_cd
        WHERE o.orig_order_dt_tm >= '2026-01-01' AND o.orig_order_dt_tm < '2026-07-01'""", con)
    ok = o[(o.valid_until_dt_tm > AS_OF) & o.status.isin(["AUTH", "MODIFIED"])].order_id.unique()
    g = o[o.order_id.isin(ok)].groupby(["order_id", "facility", "test", "priority", "orig_order_dt_tm"]).verified_dt_tm.min().reset_index()
    g["tat"] = (pd.to_datetime(g.verified_dt_tm) - pd.to_datetime(g.orig_order_dt_tm)).dt.total_seconds() / 60
    g["target"] = g.priority.map({"STAT": 60, "Routine": 240})
    rpt = run("lab_tat", Prompts(), con).set_index(["facility", "priority", "test"])
    exp = g.groupby(["facility", "priority", "test"]).apply(lambda x: pd.Series({
        "orders": len(x), "median": round(median(x.tat)), "pct": 100 * (x.tat <= x.target).mean()}), include_groups=False)
    assert len(rpt) == len(exp)
    for key, row in exp.iterrows():
        assert rpt.loc[key, "orders"] == row.orders
        assert rpt.loc[key, "median_tat_min"] == row["median"]
        assert rpt.loc[key, "pct_within_target"] == pytest.approx(row.pct, abs=0.05)


def test_readmissions_match_pandas(con, raw):
    cv = raw["cv"].set_index("code_value")
    e = raw["enc"][(raw["enc"].active_ind == 1)].copy()
    e["type"] = e.encntr_type_cd.map(cv.cdf_meaning)
    ip = e[e.type == "INPATIENT"]
    idx = ip[ip.disch_dt_tm.notna() & (ip.disch_dt_tm >= "2026-01-01") & (ip.disch_dt_tm <= "2026-06-01 00:00:00")
             & (ip.disch_disposition_cd.map(cv.cdf_meaning) != "EXPIRED") & ~ip.name_last_key.str.startswith("ZZTEST")]
    adm = ip[["person_id", "encntr_id", "inpatient_admit_dt_tm"]].dropna()
    m = idx[["encntr_id", "person_id", "disch_dt_tm", "loc_facility_cd"]].merge(adm, on="person_id", suffixes=("", "_r"))
    d = pd.to_datetime(m.inpatient_admit_dt_tm) - pd.to_datetime(m.disch_dt_tm)
    hit = set(m[(m.encntr_id != m.encntr_id_r) & (d > pd.Timedelta(0)) & (d <= pd.Timedelta(days=30))].encntr_id)
    idx = idx.assign(readmit=idx.encntr_id.isin(hit), facility=idx.loc_facility_cd.map(cv.display))
    rpt = run("readmit_by_facility", Prompts(), con).set_index("facility")
    for f in FACS:
        g = idx[idx.facility == f]
        assert rpt.loc[f, "index_discharges"] == len(g)
        assert rpt.loc[f, "readmits_30d"] == g.readmit.sum()


def test_critical_compliance_matches_pandas(con):
    """Includes the median: a NULL-ordering bug here was caught by the Oracle reconciliation."""
    c = pd.read_sql_query("""
        SELECT ce.clinical_event_id, ce.encntr_id, ce.verified_dt_tm, fac.display AS facility, unit.display AS nurse_unit
        FROM clinical_event ce
        JOIN code_value nrm ON nrm.code_value = ce.normalcy_cd AND nrm.cdf_meaning = 'CRITICAL'
        JOIN code_value rs ON rs.code_value = ce.result_status_cd AND rs.cdf_meaning IN ('AUTH', 'MODIFIED')
        JOIN encounter e ON e.encntr_id = ce.encntr_id AND e.active_ind = 1
        JOIN person p ON p.person_id = ce.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
        JOIN code_value fac ON fac.code_value = e.loc_facility_cd
        JOIN encntr_loc_hist h ON h.encntr_id = ce.encntr_id AND h.active_ind = 1
             AND h.beg_effective_dt_tm <= ce.verified_dt_tm AND h.end_effective_dt_tm > ce.verified_dt_tm
        JOIN code_value unit ON unit.code_value = h.loc_nurse_unit_cd
        WHERE ce.valid_until_dt_tm > ? AND ce.verified_dt_tm >= '2026-01-01' AND ce.verified_dt_tm < '2026-07-01'""",
                          con, params=(AS_OF,))
    n = pd.read_sql_query("""SELECT n.encntr_id, n.event_end_dt_tm FROM clinical_event n JOIN code_value nc
        ON nc.code_value = n.event_cd AND nc.display = 'Critical Result Notification' WHERE n.valid_until_dt_tm > ?""",
                          con, params=(AS_OF,))
    m = c.merge(n, on="encntr_id", how="left")
    m["gap"] = (pd.to_datetime(m.event_end_dt_tm) - pd.to_datetime(m.verified_dt_tm)).dt.total_seconds() / 60
    m.loc[(m.gap < 0) | (m.gap > 360), "gap"] = None
    first = m.groupby(["clinical_event_id", "facility", "nurse_unit"]).gap.min().reset_index()
    rpt = run("critical_compliance", Prompts(), con).set_index(["facility", "nurse_unit"])
    for key, g in first.groupby(["facility", "nurse_unit"]):
        assert rpt.loc[key, "critical_results"] == len(g)
        assert rpt.loc[key, "notified_30min"] == (g.gap <= 30).sum()
        assert rpt.loc[key, "not_documented"] == g.gap.isna().sum()
        if g.gap.notna().any():
            assert rpt.loc[key, "median_notify_min"] == round(g.gap.median())


# ---------------------------------------------------------------- prompts & exclusions
@pytest.mark.parametrize("name,col", [("ed_throughput", "ed_visits"), ("critical_compliance", "critical_results"),
                                      ("duplicate_orders", "orders"), ("open_orders_summary", "open_over_24h")])
def test_facility_prompt_partitions_total(con, name, col):
    total = run(name, Prompts(), con)[col].sum()
    assert total == sum(run(name, Prompts(facility=f), con)[col].sum() for f in FACS)


def test_date_prompt_months_add_up(con):
    months = [("2026-01-01", "2026-01-31"), ("2026-02-01", "2026-02-28"), ("2026-03-01", "2026-03-31"),
              ("2026-04-01", "2026-04-30"), ("2026-05-01", "2026-05-31"), ("2026-06-01", "2026-06-30")]
    total = run("ed_throughput", Prompts(), con).ed_visits.sum()
    assert total == sum(run("ed_throughput", Prompts(s, e), con).ed_visits.sum() for s, e in months)


def test_unknown_facility_prompt_is_rejected(con):
    with pytest.raises(ValueError):
        bind(con, Prompts(facility="Not A Hospital"))


def test_test_patients_never_reach_a_worklist(con):
    test_fins = {r[0] for r in con.execute("SELECT a.alias FROM encntr_alias a JOIN encounter e USING (encntr_id) "
                                           "JOIN person p USING (person_id) WHERE p.name_last_key LIKE 'ZZTEST%'")}
    assert test_fins, "generator should create test patients"
    for name in ["critical_worklist", "open_orders_worklist"]:
        assert not test_fins & set(run(name, Prompts(), con).fin)


def test_readmission_lookback_is_complete(con):
    """Discharges in the last 30 days before the data cut must not be index stays."""
    june = run("readmit_by_facility", Prompts("2026-06-02", "2026-06-30"), con)
    assert june.empty or june.index_discharges.sum() == 0


# ---------------------------------------------------------------- RCA regression tests
def test_rca1_ed_visits_not_qualified_on_encounter_type(con):
    sql = load_queries()["ed_throughput"]
    assert "cdf_meaning = 'EMERGENCY'" not in sql
    v1 = pd.read_sql_query(load_queries(ROOT / "sql" / "archive")["ed_throughput_v1"], con, params=bind(con, Prompts()))
    v2 = run("ed_throughput", Prompts(), con)
    assert v2.ed_visits.sum() > v1.ed_visits.sum() * 1.15      # v1 silently dropped admitted ED visits


def test_rca2_lab_tat_uses_current_versions_only(con):
    sql = load_queries()["lab_tat"]
    assert "valid_until_dt_tm > :as_of" in sql and "'AUTH', 'MODIFIED'" in sql
    superseded = con.execute("SELECT COUNT(*) FROM clinical_event WHERE valid_until_dt_tm <= ?", (AS_OF,)).fetchone()[0]
    assert superseded > 0, "generator should create corrected results"


def test_census_rewrite_is_equivalent(con):
    from tune import CENSUS_RUNNING_SUM
    p = bind(con, Prompts("2026-03-01", "2026-03-31"))
    a = pd.read_sql_query(load_queries()["census_daily"], con, params=p)[["nurse_unit", "census_date", "census"]]
    b = pd.read_sql_query(CENSUS_RUNNING_SUM, con, params=p)[["nurse_unit", "census_date", "census"]]
    k = ["nurse_unit", "census_date"]
    pd.testing.assert_frame_equal(a.sort_values(k).reset_index(drop=True), b.sort_values(k).reset_index(drop=True))
