"""
Publish the reports: runs every query with the prompt values, then writes
  output/reports.html          one self-contained page (prompt banner, alerts, KPI tiles,
                               facility filter, sortable tables, CSV links)
  output/csv/<query>.csv       full result of every query
  output/mpage_payload.json    the same KPIs in the JSON shape CCL's cnvtrectojson() returns,
                               i.e. what an MPage component would receive from ccl/cust_ops_kpi_mp.prg

    python src/build_html.py --start 2026-01-01 --end 2026-06-30 --facility All
"""
import argparse
import datetime as dt
import html
import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_runner import ROOT, Prompts, connect, run_all  # noqa: E402

OUT = ROOT / "output"
MAX_ROWS = 150          # worklists are truncated on the page; full rows are in the CSV

SECTIONS = [  # (anchor, title, [queries], spec text)
    ("ed", "01 ED Throughput", ["ed_throughput"],
     "ED visits by arrival date. LOS = arrival to leaving the ED (first location segment). Boarding = admit decision to leaving the ED. Excludes LWBS from LOS, test patients and cancelled registrations."),
    ("lab", "02 Lab Turnaround", ["lab_tat", "lab_tat_stat_by_hour"],
     "Order to first verification. STAT target 60 min, Routine 240 min. Current, non-In-Error results only; corrected results keep their original verification time."),
    ("crit", "03 Critical Result Calls", ["critical_compliance", "critical_worklist"],
     "Critical lab result to documented read-back call. Target 30 min. Unit = where the patient was when the result verified."),
    ("readmit", "04 30-Day Readmissions", ["readmit_by_facility", "readmit_by_disposition"],
     "Index = inpatient discharge (not expired) with a full 30-day look-back. Readmission = any inpatient admission in the system within 30 days. Not risk-adjusted."),
    ("census", "05 Census & Occupancy", ["census_summary"],
     "Midnight census from ENCNTR_LOC_HIST vs staffed beds (CUST_UNIT_CAPACITY). Daily rows in csv/census_daily.csv."),
    ("open", "06 Open Lab Orders > 24 h", ["open_orders_summary", "open_orders_worklist"],
     "Lab orders still in Ordered status 24 h after they were placed (possible missed collection)."),
    ("dup", "07 Duplicate Lab Orders", ["duplicate_orders"],
     "Same orderable on the same encounter within 120 min of an earlier, not-cancelled order."),
    ("rules", "08 Discern Rules - Silent Mode", ["rule_silent_mode", "rule_window_sensitivity"],
     "Rules replayed against history and logged to EKS_MODULE_AUDIT without alerting anyone. Window sensitivity: true duplicates vs clinically intended repeats."),
]
TITLES = {
    "ed_throughput": "ED throughput by facility", "lab_tat": "Turnaround by facility, priority and test",
    "lab_tat_stat_by_hour": "STAT % within 60 min by hour ordered", "critical_compliance": "Compliance by nurse unit",
    "critical_worklist": "Worklist: critical results not called within 30 min", "readmit_by_facility": "Readmission rate by facility",
    "readmit_by_disposition": "Readmission rate by discharge disposition", "census_summary": "Occupancy by nurse unit",
    "open_orders_summary": "Open orders by facility and test", "open_orders_worklist": "Worklist: open orders",
    "duplicate_orders": "Duplicates by facility and test", "rule_silent_mode": "Projected firings (silent mode)",
    "rule_window_sensitivity": "CUST_LAB_DUP_ORDER: look-back window sensitivity (all facilities)",
}


def alerts(r):
    """Threshold rules on report output -> alert banner (same idea as a Discern rule on a KPI)."""
    a = []
    for x in r["ed_throughput"].itertuples():
        if x.median_boarding_min > 240:
            a.append(f"{x.facility}: median ED boarding {x.median_boarding_min:.0f} min (threshold 240)")
    s = r["lab_tat"].query("priority == 'STAT'").groupby("facility").apply(
        lambda g: (g.pct_within_target * g.orders).sum() / g.orders.sum(), include_groups=False)
    a += [f"{f}: only {v:.0f}% of STAT labs resulted within 60 min (threshold 80%)" for f, v in s.items() if v < 80]
    for x in r["critical_compliance"].query("critical_results >= 20").itertuples():
        if x.pct_within_30 < 80:
            a.append(f"{x.nurse_unit}: {x.pct_within_30:.0f}% of critical results called within 30 min; "
                     f"{x.not_documented} never documented (threshold 80%)")
    for x in r["readmit_by_facility"].itertuples():
        if x.readmit_rate_pct > 15:
            a.append(f"{x.facility}: 30-day readmission rate {x.readmit_rate_pct}% (threshold 15%)")
    for x in r["census_summary"].itertuples():
        if x.avg_occupancy_pct > 93:
            a.append(f"{x.nurse_unit}: average occupancy {x.avg_occupancy_pct}% ({x.days_at_95pct_plus} of {x.days} days at 95%+)")
    d = r["duplicate_orders"].groupby("facility")[["duplicate_orders", "orders"]].sum()
    a += [f"{f}: {1000 * v.duplicate_orders / v.orders:.0f} duplicate lab orders per 1,000 (threshold 20)"
          for f, v in d.iterrows() if 1000 * v.duplicate_orders / v.orders > 20]
    return a


def tiles(r):
    ed, tat, crit = r["ed_throughput"], r["lab_tat"], r["critical_compliance"]
    stat = tat.query("priority == 'STAT'")
    rd = r["readmit_by_facility"]; dup = r["duplicate_orders"]
    return [
        ("ED visits", f"{ed.ed_visits.sum():,}", f"{(ed.ed_visits * ed.pct_over_4h).sum() / ed.ed_visits.sum():.0f}% stayed over 4 h"),
        ("STAT labs in 60 min", f"{(stat.pct_within_target * stat.orders).sum() / stat.orders.sum():.0f}%", f"{stat.orders.sum():,} STAT orders"),
        ("Critical calls in 30 min", f"{100 * crit.notified_30min.sum() / crit.critical_results.sum():.0f}%",
         f"{crit.critical_results.sum():,} critical results"),
        ("30-day readmissions", f"{100 * rd.readmits_30d.sum() / rd.index_discharges.sum():.1f}%", f"{rd.index_discharges.sum():,} index discharges"),
        ("Duplicate lab orders", f"{dup.duplicate_orders.sum():,}", f"{dup.duplicates_performed.sum():,} were drawn and run anyway"),
    ]


def table(name, df):
    n = len(df)
    shown = df.head(MAX_ROWS)
    head = "".join(f'<th scope="col" data-col="{i}">{html.escape(c)}</th>' for i, c in enumerate(df.columns))
    fac_col = "facility" in df.columns

    plain = [c.endswith("_id") or c.endswith("_hour") for c in df.columns]   # identifiers: no thousands separator

    def cell(v, raw):
        if isinstance(v, float):
            v = "" if pd.isna(v) else (f"{v:,.1f}" if v % 1 else f"{v:,.0f}")
        elif isinstance(v, int) and not raw:
            v = f"{v:,}"
        return f"<td>{html.escape(str(v))}</td>"
    body = "".join(
        f'<tr{f" data-fac=\"{html.escape(str(row.facility))}\"" if fac_col else ""}>'
        + "".join(cell(v, raw) for v, raw in zip(row, plain)) + "</tr>"
        for row in shown.itertuples(index=False))
    note = f'<p class="note">Showing {MAX_ROWS:,} of {n:,} rows. ' if n > MAX_ROWS else f'<p class="note">{n:,} rows. '
    note += f'<a href="csv/{name}.csv">Download CSV</a></p>'
    return (f'<h3>{html.escape(TITLES.get(name, name))}</h3><div class="scroll"><table class="rpt sortable">'
            f'<thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>{note}')


CSS = """
:root{--bg:#fcfcfb;--panel:#ffffff;--ink:#0b0b0b;--ink2:#52514e;--muted:#7a7974;--line:#e4e3df;--head:#f3f2ef;
--accent:#2a78d6;--crit-bg:#fdecec;--crit:#b42318;--ok:#067647;--ok-bg:#e7f6ec;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#1a1a19;--panel:#222220;--ink:#ffffff;--ink2:#c3c2b7;
--muted:#9b9a92;--line:#3a3a37;--head:#2b2b29;--accent:#3987e5;--crit-bg:#3a1f1d;--crit:#f97066;--ok:#47cd89;--ok-bg:#16301f;}}
:root[data-theme="dark"]{--bg:#1a1a19;--panel:#222220;--ink:#ffffff;--ink2:#c3c2b7;--muted:#9b9a92;--line:#3a3a37;--head:#2b2b29;
--accent:#3987e5;--crit-bg:#3a1f1d;--crit:#f97066;--ok:#47cd89;--ok-bg:#16301f;}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{padding:20px 16px 8px;max-width:1200px;margin:auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:28px 0 4px}
h3{font-size:14px;margin:18px 0 6px;color:var(--ink2)}main{max-width:1200px;margin:auto;padding:0 16px 48px}
.prompts{display:flex;flex-wrap:wrap;gap:6px 16px;color:var(--ink2);font-size:13px}.prompts b{color:var(--ink)}
nav{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 16px;z-index:2}
nav .in{max-width:1200px;margin:auto;display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center}
nav a{color:var(--accent);text-decoration:none;font-size:13px}select{font:inherit;padding:4px 6px;background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:6px}
.badge{font-size:12px;padding:2px 8px;border-radius:10px;background:var(--ok-bg);color:var(--ok)}.badge.fail{background:var(--crit-bg);color:var(--crit)}
.alert{background:var(--crit-bg);border-left:4px solid var(--crit);padding:8px 14px;margin:14px 0;border-radius:4px}
.alert ul{margin:6px 0;padding-left:18px}.alert b{color:var(--crit)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin:14px 0}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px}.tile .k{font-size:12px;color:var(--ink2)}
.tile .v{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums}.tile .s{font-size:12px;color:var(--muted)}
.spec{color:var(--ink2);font-size:13px;margin:0 0 4px}.note{font-size:12px;color:var(--muted);margin:4px 0}.note a{color:var(--accent)}
.scroll{overflow-x:auto;border:1px solid var(--line);border-radius:6px;max-height:460px;overflow-y:auto}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums;background:var(--panel)}
th{position:sticky;top:0;background:var(--head);text-align:left;font-weight:600;cursor:pointer;white-space:nowrap}
th,td{padding:5px 10px;border-bottom:1px solid var(--line);white-space:nowrap}th[aria-sort="ascending"]::after{content:" \\25B2"}th[aria-sort="descending"]::after{content:" \\25BC"}
footer{color:var(--muted);font-size:12px;max-width:1200px;margin:auto;padding:0 16px 32px}
"""

JS = """
const sel=document.getElementById('fac');
sel.addEventListener('change',()=>{const v=sel.value;document.querySelectorAll('tr[data-fac]').forEach(r=>{r.hidden=!(v==='All'||r.dataset.fac===v)});});
document.querySelectorAll('table.sortable th').forEach(th=>th.addEventListener('click',()=>{
 const t=th.closest('table'),i=+th.dataset.col,asc=th.getAttribute('aria-sort')!=='ascending';
 t.querySelectorAll('th').forEach(h=>h.removeAttribute('aria-sort'));th.setAttribute('aria-sort',asc?'ascending':'descending');
 const num=s=>{const n=parseFloat(s.replace(/,/g,''));return isNaN(n)?null:n};
 const rows=[...t.tBodies[0].rows].sort((a,b)=>{const x=a.cells[i].innerText,y=b.cells[i].innerText,nx=num(x),ny=num(y);
  const c=(nx!==null&&ny!==null)?nx-ny:x.localeCompare(y);return asc?c:-c});rows.forEach(r=>t.tBodies[0].appendChild(r));}));
"""


def mpage_payload(r, prompts):
    """Mirror of the CCL record structure in ccl/cust_ops_kpi_mp.prg -> cnvtrectojson(kpi)."""
    ed = r["ed_throughput"]; stat = r["lab_tat"].query("priority == 'STAT'"); crit = r["critical_compliance"]
    rd = r["readmit_by_facility"].set_index("facility")
    qual = []
    for f in ed.itertuples():
        s = stat[stat.facility == f.facility]; c = crit[crit.facility == f.facility]
        qual.append({"FACILITY": f.facility, "ED_VISITS": int(f.ed_visits),
                     "ED_MEDIAN_BOARD_MIN": float(f.median_boarding_min),
                     "STAT_PCT_60": round(float((s.pct_within_target * s.orders).sum() / s.orders.sum()), 1),
                     "CRIT_PCT_30": round(float(100 * c.notified_30min.sum() / c.critical_results.sum()), 1),
                     "READMIT_PCT": float(rd.loc[f.facility, "readmit_rate_pct"])})
    return {"KPI": {"STATUS_DATA": {"STATUS": "S"}, "START_DT": prompts.start_dt, "END_DT": prompts.end_dt,
                    "FAC_CNT": len(qual), "QUAL": qual}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default=Prompts.start_dt)
    ap.add_argument("--end", default=Prompts.end_dt)
    ap.add_argument("--facility", default="All")
    a = ap.parse_args()
    p = Prompts(a.start, a.end, a.facility)
    con = connect()
    res = run_all(p, con)
    r = {k: v[0] for k, v in res.items()}
    sens_f = OUT / "rule_window_sensitivity.csv"
    if sens_f.exists():
        r["rule_window_sensitivity"] = pd.read_csv(sens_f)
    (OUT / "csv").mkdir(parents=True, exist_ok=True)
    for k, df in r.items():
        df.to_csv(OUT / "csv" / f"{k}.csv", index=False)
    (OUT / "mpage_payload.json").write_text(json.dumps(mpage_payload(r, p), indent=2))

    val_f = OUT / "validation_results.csv"
    if val_f.exists():
        v = pd.read_csv(val_f); ok = int(v.passed.sum())
        badge = f'<span class="badge{"" if ok == len(v) else " fail"}">Validation {ok}/{len(v)} checks passed</span>'
    else:
        badge = '<span class="badge fail">Validation not run</span>'
    facs = sorted(set(r["ed_throughput"].facility))
    al = alerts(r)
    tiles_html = "".join(f'<div class="tile"><div class="k">{k}</div><div class="v">{v}</div><div class="s">{s}</div></div>'
                         for k, v, s in tiles(r))
    nav = "".join(f'<a href="#{a_}">{t.split(" ", 1)[1]}</a>' for a_, t, _, _ in SECTIONS)
    body = ""
    for anchor, title, queries, spec in SECTIONS:
        body += f'<section id="{anchor}"><h2>{title}</h2><p class="spec">{html.escape(spec)}</p>'
        body += "".join(table(q, r[q]) for q in queries if q in r) + "</section>"
    runtime = sum(s for _, s in res.values())
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Operational KPI Reports</title><style>{CSS}</style></head><body>
<header><h1>Operational KPI Reports: 3-Hospital System</h1>
<div class="prompts"><span>Start <b>{p.start_dt}</b></span><span>End <b>{p.end_dt}</b></span><span>Facility <b>{html.escape(p.facility)}</b></span>
<span>Data as of <b>{p.as_of}</b></span><span>Generated <b>{dt.datetime.now():%Y-%m-%d %H:%M}</b></span>{badge}</div></header>
<nav><div class="in"><label>Facility filter <select id="fac"><option>All</option>{''.join(f'<option>{html.escape(f)}</option>' for f in facs)}</select></label>{nav}</div></nav>
<main><div class="alert"><b>{len(al)} alerts</b><ul>{''.join(f'<li>{html.escape(x)}</li>' for x in al) or '<li>No threshold breaches</li>'}</ul></div>
<div class="tiles">{tiles_html}</div>{body}</main>
<footer>Synthetic data on a Millennium-style schema (no real patients). {len(res)} queries ran in {runtime:.1f} s.
SQL: sql/reports/ &middot; CCL versions: ccl/ &middot; Specs: docs/report_specs.md</footer>
<script>{JS}</script></body></html>"""
    (OUT / "reports.html").write_text(page)
    print(f"output/reports.html written: {len(res)} queries in {runtime:.1f}s, {len(al)} alerts")
    for x in al:
        print("  ALERT:", x)


if __name__ == "__main__":
    main()
