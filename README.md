# Millennium-Style Clinical Operations Reporting (SQL · CCL · HTML)

**Business question:** *Across a 3-hospital system, where are the throughput and patient-safety gaps in the ED, the lab and the nursing units? Which reports and alerts should operations leaders get every morning?*

This project builds the whole reporting cycle a Cerner CCL/reporting analyst owns, on a schema modeled on **Cerner Millennium**:

* **Data:** 13 tables structured like Millennium's (`ENCOUNTER`, `ENCNTR_LOC_HIST`, `ORDERS`, `ORDER_DETAIL`, versioned `CLINICAL_EVENT`, `CODE_VALUE`, …), filled with 6 months of synthetic data.
* **Reports:** 7 KPI and operational reports in SQL, with CCL-style prompts.
* **CCL:** the same reports as **CCL (Discern Explorer) programs**.
* **HTML:** a filterable report page with alerts, and an MPage component fed by a CCL JSON driver.
* **Discern rules:** a duplicate-order rule and a critical-result escalation rule, evaluated in silent mode.
* **Validation, testing and docs:** 21 validation checks, 18 automated tests, 2 root-cause analyses, performance tuning, and release documentation.

![Operational KPI report page](assets/reports_page.png)
*`output/reports.html`: prompt banner, validation badge, threshold alerts, KPI tiles, facility filter, sortable tables, CSV download for every query.*

## What the reports found (Jan–Jun 2026, synthetic data)

| # | Finding | Report | Action recommended |
|---|---|---|---|
| 1 | **Lakeside Regional ED boarding: 311 min median.** Admitted patients spend 9.2 h in the ED vs 5.2–5.8 h elsewhere; 48% of ED patients stay over 4 h. Its Med/Surg unit averages **96% occupancy** (at 95%+ on 95 of 181 days). | 01, 05 | Bed-flow review at Lakeside: discharge-before-noon, transfer center to the sister hospitals |
| 2 | **Mercy South STAT labs: 71% within 60 min** vs 82–87% elsewhere. The gap is entirely **night shift: 44% vs 86% on days.** | 02 | Night-shift lab staffing / courier review at Mercy South |
| 3 | **Mercy North 4E Telemetry calls only 56% of critical results within 30 min** (every other unit 83–95%), and 15 calls were never documented. | 03 | Daily critical-result worklist to the unit manager; turn on escalation rule `CUST_CRIT_LAB_ESCALATE` |
| 4 | **Mercy South 30-day readmissions: 17.1%** vs 11.0–11.4%, higher for every discharge disposition | 04 | Case-management focus on SNF and AMA discharges |
| 5 | **Mercy North: 48 duplicate lab orders per 1,000** (3× the others). 2,408 duplicates were drawn and run anyway. | 07 | Duplicate-order Discern rule with a **60-min** window (98.6% precision, 99.3% recall; 14× fewer false alerts than the requested 120 min) |
| 6 | 193 lab orders open > 24 h; 186 belong to discharged patients | 06 | Daily ops-job worklist for the lab supervisor |

![ED boarding](assets/01_ed_boarding.png)
![STAT TAT by hour](assets/02_stat_tat_by_hour.png)
![Critical calls by unit](assets/03_critical_calls_by_unit.png)

<details><summary>More charts</summary>

![Occupancy](assets/04_medsurg_occupancy.png)
![Readmissions](assets/05_readmit_by_disposition.png)
![Rule window](assets/06_rule_window_sensitivity.png)
</details>

## How this maps to a CCL / Reporting Analyst role

| Job requirement | Where it is in this project |
|---|---|
| Cerner Millennium data architecture & tables | [`sql/schema.sql`](sql/schema.sql), [docs/data_model.md](docs/data_model.md): code sets, aliases, location history, order details, result versioning, and the 9 rules every report follows |
| CCL programming | [`ccl/`](ccl): 7 report programs + MPage JSON driver + EKS logic program (prompts, `uar_get_code_by`, record structures, `outerjoin`, `parser`, `head/detail/foot`, `cnvtrectojson`) |
| SQL | [`sql/reports/`](sql/reports): window functions, SQL medians, recursive CTE census, point-in-time joins, correlated `EXISTS`, self-joins |
| HTML | [`output/reports.html`](output/reports.html) report page; [`mpage/ops_kpi.html`](mpage/ops_kpi.html) MPage component (XMLCclRequest → CCL JSON, with an off-domain fallback) |
| KPI / operational reports | 7 reports, 13 queries, specs in [docs/report_specs.md](docs/report_specs.md) |
| Discern Rules | [`rules/discern_rules.json`](rules/discern_rules.json), [`src/discern_rules.py`](src/discern_rules.py), [docs/discern_rules.md](docs/discern_rules.md): silent-mode firing volume, precision/recall, window recommendation |
| Filtering, alerting | Facility/date prompts on every report; threshold alert banner; critical-result and open-order worklists |
| Troubleshooting, RCA | [docs/rca.md](docs/rca.md): ED visits under-counted 19% (encounter-type filter); lab volume inflated 1.74× (result versions) |
| Database querying / tuning | [docs/performance_tuning.md](docs/performance_tuning.md): sargable dates (8×), explain-plan index fix (2.9 s → 0.08 s), one-pass census rewrite (4×) |
| Validation / testing / deployment / documentation | [docs/test_plan.md](docs/test_plan.md) (21 checks + 18 tests), [docs/release_runbook.md](docs/release_runbook.md) (DEV → CERT → PROD, ops jobs, silent-mode rules) |

## ⚠ What is real and what is assumed
* **All data is synthetic** ([`src/generate_data.py`](src/generate_data.py), fixed seed). No real patients, providers or facilities. Volumes are realistic in size: 72K encounters, 62K patients, 227K orders, 414K result rows, 84K location segments.
* **The findings above were planted on purpose** by the generator: Lakeside boarding, Mercy South night-shift lab TAT and readmissions, Mercy North duplicates and telemetry calls. The point is that the reports *detect* them correctly. 30 test-patient encounters, cancelled registrations, ~1.2% corrected results and ~0.4% In Error results are also planted, so the exclusion logic is exercised.
* Staffed beds (`CUST_UNIT_CAPACITY`) are calibrated by the generator to a target occupancy per unit.
* **The SQL runs; the CCL has not been compiled.** There is no public Millennium domain. The CCL is written to Cerner conventions and mirrors the tested SQL one-to-one (see [ccl/README.md](ccl/README.md)).
* The schema is a simplified subset of Millennium (far fewer columns; no `CE_*` child tables, `ORDER_CATALOG`, `LOCATION` hierarchy, etc.).

## Project structure
| Path | What |
|---|---|
| [`sql/schema.sql`](sql/schema.sql) | Millennium-style DDL + indexes |
| [`sql/reports/`](sql/reports) | 8 report files, 13 named queries (`-- name:` blocks) with prompt binds |
| [`sql/dq_checks.sql`](sql/dq_checks.sql) | 14 data-quality checks (each returns a count of bad rows) |
| [`sql/archive/`](sql/archive) | the two defective v1 queries kept for the RCA |
| [`src/`](src) | `generate_data.py`, `report_runner.py` (prompt binding), `validate.py`, `discern_rules.py`, `build_html.py`, `make_charts.py`, `rca.py`, `tune.py` |
| [`ccl/`](ccl) | CCL programs |
| [`mpage/`](mpage) | HTML/JS MPage component |
| [`tests/`](tests) | pytest: independent pandas re-computation, prompts, exclusions, RCA regressions, rule logic |
| [`output/`](output) | `reports.html`, `csv/` (every query), `mpage_payload.json`, validation / perf / rule results |
| [`docs/`](docs) | data model, report specs, RCA, tuning, Discern rules, test plan, release runbook, interview prep |

## Reproduce
```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
./run_all.sh          # generate -> rules -> validate (stops on failure) -> publish HTML -> charts -> RCA -> tuning -> tests
```
~1 minute end to end. The 200 MB SQLite database is git-ignored and rebuilt by `src/generate_data.py`. Run one report with other prompt values:
```bash
python src/report_runner.py --start 2026-04-01 --end 2026-06-30 --facility "Mercy South"
```

## Limitations / next steps
* Port the schema and reports to **Oracle** (Millennium's database), e.g. Oracle Database Free in Docker, and swap SQLite date math for Oracle `DATE` arithmetic.
* Compile and run the CCL in a real domain; build a Discern Explorer layout (DVDev Layout Builder) version of one report.
* Readmissions are not risk-adjusted and do not exclude planned readmissions (the CMS measure does both).
* Add a BusinessObjects/DA2-style semantic layer (business-friendly views over the base tables).
