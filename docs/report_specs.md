# Report specifications

I wrote a short spec for each report before building it: who's asking, what question it answers, and exactly how each number is calculated. Every report has a SQL version in `sql/reports/` and a CCL version in `ccl/`.

## Prompts

All the reports take the same prompts.

| Prompt | SQL bind | CCL prompt | Notes |
|---|---|---|---|
| Output device | | `OUTDEV` | MINE, a printer or a file |
| Start and end date | `:start_dt`, `:end_dt` | `START_DT`, `END_DT` | Inclusive. Each report says which date it filters on. |
| Facility | `:facility_cd` (0 = all) | `FACILITY_CD` | Chosen by name in `report_runner.py`, like a prompt list box |
| Data cut-off | `:as_of` | current date/time | Decides which result rows are current |

Every report leaves out test patients, inactive rows, results marked In Error, and older versions of corrected results. [data_model.md](data_model.md) explains why.

## 01 ED Throughput

- **Asked by:** the ED operations director, who wanted to know how long patients spend in the ED and how much of that is waiting for an inpatient bed.
- **Filtered on:** ED arrival time. One row per facility.
- **Measures:**
  - number of ED visits, and the percentage who left without being seen (LWBS)
  - percentage admitted
  - median time in the ED for discharged patients, and separately for admitted patients
  - median boarding time, from the admit decision until the patient left the ED
  - percentage of patients who were seen and stayed more than 4 hours
- **Notes:** LWBS patients are excluded from the time measures, as are patients still in the ED at the cut-off. SQLite has no MEDIAN function, so I calculate medians with `ROW_NUMBER()` and `COUNT()`.
- **Alert:** median boarding over 240 minutes.

## 02 Lab Turnaround

- **Asked by:** the laboratory director, who wanted to know whether STAT labs come back within 60 minutes, and when they don't.
- **Filtered on:** order time. One row per facility, priority and test, plus a breakdown of STAT orders by hour of day.
- **Measure:** time from the order to the first verified result, and the percentage within target (60 minutes for STAT, 240 for routine). It counts orders, not individual results; a BMP has several results but counts as one order.
- **Notes:** The report only includes orders that still have a current, valid result. A corrected result keeps its original verification time, and turnaround is calculated from whole seconds so a result at exactly 60:00 counts as on time.
- **Alert:** a facility below 80% on STAT.

## 03 Critical Result Notification

- **Asked by:** nursing leadership and patient safety, who wanted to know whether critical lab values are called to a provider within 30 minutes and which units are falling behind.
- **Filtered on:** result verification time. One row per facility and unit (the unit the patient was on when the result came back), plus a worklist of every late or undocumented call with FIN, MRN, test and value.
- **Measure:** minutes from verification to the first "Critical Result Notification" documented on the encounter within the following 6 hours.
- **Alert:** any unit with at least 20 critical results and fewer than 80% called within 30 minutes.

## 04 30-Day Readmissions

- **Asked by:** quality and case management. One row per discharging facility, and per facility and disposition.
- **Index stay:** an inpatient discharge in the date range, where the patient didn't die.
- **Readmission:** any inpatient admission for the same patient, at any of the three hospitals, within 30 days.
- **Notes:** Discharges from the last 30 days before the cut-off are left out, because their 30-day window isn't over yet. This is an operational screen, not the CMS measure: it isn't risk-adjusted and doesn't exclude planned readmissions.
- **Alert:** a rate above 15%.

## 05 Midnight Census and Occupancy

- **Asked by:** the house supervisor and capacity management. One row per unit per day, plus a summary per unit.
- **Measure:** patients on the unit at midnight, divided by staffed beds. The list of days comes from a recursive CTE, so no calendar table is needed.
- **Alert:** average occupancy above 93%.

## 06 Open Lab Orders Over 24 Hours

- **Asked by:** the lab supervisor.
- **What it lists:** lab orders still in Ordered status more than 24 hours after they were placed. For each one it shows the patient's current unit and FIN, and a suggested next step: recollect if the patient is still in house, cancel or follow up if they've gone home.
- **How it runs:** it's designed to run every morning as a scheduled ops job.

## 07 Duplicate Lab Orders

- **Asked by:** the lab director and clinical informatics.
- **What counts as a duplicate:** the same test on the same encounter within 120 minutes of an earlier order that wasn't cancelled.
- **Measures:** duplicate count, how many were actually drawn and run, and duplicates per 1,000 orders.
- **Alert:** a facility above 20 per 1,000.
- This report fed into the rule decision in [discern_rules.md](discern_rules.md).

## 08 Discern Rule Silent-Mode Summary

- **What it shows:** how often each rule would have fired, by facility and per day, read from EKS_MODULE_AUDIT. It's the expected alert load if the rules were switched on.
