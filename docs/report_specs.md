# Report specifications

Each report has a SQL version (`sql/reports/`, runnable) and a CCL version (`ccl/`, written in Discern Explorer syntax). All reports share the same prompts:

| Prompt | SQL bind | CCL prompt | Notes |
|---|---|---|---|
| Output device | - | `OUTDEV` | MINE / printer / file |
| Start / end date | `:start_dt`, `:end_dt` | `START_DT`, `END_DT` | Inclusive dates; the date column each report qualifies on is listed below |
| Facility | `:facility_cd` (0 = all) | `FACILITY_CD` | Picked by display name in `report_runner.py` (like a prompt list box) |
| Data cut | `:as_of` | `curdate, curtime3` | Decides which CLINICAL_EVENT rows are current |

Common exclusions: test patients (`ZZTEST`), inactive rows, In Error results, and superseded result versions. See [data_model.md](data_model.md).

---

### 01 ED Throughput (KPI)
* **Asked by:** ED operations director. **Question:** how long do patients spend in our EDs, and how much of it is waiting for an inpatient bed?
* **Qualifies on:** `arrive_dt_tm`. **Grain:** facility.
* **Measures:** ED visits; LWBS % (disposition = Left Without Being Seen); admit %; median ED length of stay for discharged and for admitted patients (arrival to end of the first location segment); median boarding (admit decision to leaving the ED); % of seen patients over 4 hours.
* **Edge cases:** LWBS visits are left out of LOS. Visits still in the ED at the data cut are left out. Medians are computed in SQL with `ROW_NUMBER()`/`COUNT()`, because SQLite and older Oracle versions lack `MEDIAN`.
* **Alert:** median boarding > 240 min.

### 02 Lab Turnaround (KPI)
* **Asked by:** laboratory director. **Question:** are STAT labs resulted within 60 minutes, and when do we miss?
* **Qualifies on:** `orig_order_dt_tm`. **Grain:** facility × priority × orderable, plus a STAT-by-hour block.
* **Measure:** time from order to the **first** verification of the order's results. % within target (STAT 60 min, Routine 240 min). One row per *order*, not per result component.
* **Edge cases:** only orders with a current, non-In-Error result. A corrected result keeps its original verification time.
* **Alert:** facility STAT % within 60 < 80%.

### 03 Critical Result Notification (KPI + worklist)
* **Asked by:** CNO / patient safety. **Question:** are critical lab values called to a provider within 30 minutes, and where are calls late or undocumented?
* **Qualifies on:** `verified_dt_tm`. **Grain:** facility × nurse unit (where the patient was at verification), plus a worklist of every late or undocumented call with FIN, MRN, test, value and minutes.
* **Measure:** minutes from verification to the first "Critical Result Notification" event on the encounter within 6 hours.
* **Alert:** unit (≥ 20 criticals) under 80% within 30 min.

### 04 30-Day Readmissions (KPI)
* **Asked by:** quality / case management. **Grain:** discharging facility, and facility × disposition.
* **Index stay:** inpatient discharge in range, not Expired. **Readmission:** any inpatient admission for the same person at any facility within 30 days (`inpatient_admit_dt_tm`).
* **Edge cases:** discharges in the last 30 days before the data cut are excluded so every index stay has a full look-back. Not risk-adjusted, and planned readmissions are not removed. The CMS measure does both; this is an operational screen.
* **Alert:** rate > 15%.

### 05 Midnight Census & Occupancy (operational)
* **Asked by:** house supervisor / capacity management. **Grain:** unit × day (`census_daily`) and unit summary (`census_summary`).
* **Measure:** patients whose location segment covers 00:00, divided by staffed beds from `CUST_UNIT_CAPACITY`. Days are generated with a recursive CTE.
* **Alert:** average occupancy > 93%.

### 06 Open Lab Orders > 24 h (worklist)
* **Asked by:** lab supervisor. Lab orders still in Ordered status 24 h after they were placed, with current unit, FIN and a suggested action (recollect if in house; cancel or follow up if discharged). Meant to run as a daily scheduled ops job.

### 07 Duplicate Lab Orders (operational / waste)
* **Asked by:** lab director + clinical informatics. A duplicate is the same orderable on the same encounter within 120 min of an earlier order that was not cancelled. Reports duplicates, how many were drawn and run anyway, and duplicates per 1,000 orders.
* **Alert:** facility > 20 per 1,000. Feeds the Discern rule decision in [discern_rules.md](discern_rules.md).

### 08 Discern Rule Silent-Mode Summary
* Firings per rule × facility (and per day) from `EKS_MODULE_AUDIT`. It shows the projected alert load before go-live.
