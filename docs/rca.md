# Root cause analysis: two report defects

Both defects are realistic mistakes that come from the Millennium data model, not from bad arithmetic. The defective versions are kept in [`sql/archive/`](../sql/archive), [`src/rca.py`](../src/rca.py) reproduces the numbers, and regression tests in [`tests/test_reports.py`](../tests/test_reports.py) stop them from coming back.

---

## Incident 1: ED report missed one in five ED visits

**Reported problem.** The ED director said the ED throughput report showed far fewer visits than the ED tracking board, and "% over 4 hours" looked too good.

**Impact (Jan–Jun 2026, all facilities):**

| Facility | ED visits, v1 | ED visits, v2 (fixed) | % over 4 h, v1 | % over 4 h, v2 |
|---|---|---|---|---|
| Lakeside Regional | 10,365 | 12,977 | 32.0% | **48.3%** |
| Mercy North | 14,384 | 17,850 | 23.8% | **35.7%** |
| Mercy South | 16,540 | 20,419 | 27.7% | **40.2%** |
| **Total** | **41,289** | **51,246** | | |

v1 under-counted visits by **9,957 (19%)** and under-stated long stays by 12–16 points. The missing visits were the admitted patients, who have the longest ED stays. So the error hid exactly the boarding problem the report exists to show.

**Root cause.** v1 qualified ED visits with `encntr_type_cd = EMERGENCY`. When an ED patient is admitted, Millennium changes the type of the **same encounter** to Inpatient. Every admitted ED visit therefore failed the filter. v1 also measured LOS to `disch_dt_tm` (hospital discharge) rather than to leaving the ED.

**How it was found.**
1. Reconciled the v1 count against a raw count of encounters with an `arrive_dt_tm`. The gap was about 19%.
2. Pulled 10 FINs that appear in the raw count but not in the report. All 10 were type Inpatient with an ED location segment first.
3. Confirmed in `ENCNTR_LOC_HIST`: ED segment, then an inpatient unit, all on one `encntr_id`.

**Fix (v2).** Qualify on `arrive_dt_tm`. Measure ED LOS to the end of the first `ENCNTR_LOC_HIST` segment, and boarding from `inpatient_admit_dt_tm`.

**Prevention.**
* Control-total check in `validate.py`: report visits = independent source count (runs before every publish).
* Regression test `test_rca1_ed_visits_not_qualified_on_encounter_type`.
* Data-model note added for all report writers ([data_model.md](data_model.md) rule 5).

---

## Incident 2: Lab TAT report double-counted corrected results

**Reported problem.** The lab director said the STAT volume on the TAT report did not match the lab system's order count. It was much higher.

**Impact (STAT, Jan–Jun 2026):**

| Facility | v1 "results" | v2 STAT orders | % within 60 min, v1 | % within 60 min, v2 |
|---|---|---|---|---|
| Lakeside Regional | 46,392 | 26,764 | 80.3% | 81.6% |
| Mercy North | 66,769 | 38,161 | 85.4% | 86.9% |
| Mercy South | 74,326 | 42,757 | 69.7% | 70.7% |

Volume was inflated **1.74×**, and compliance was understated by 1.0–1.5 points.

**Root cause (four defects in one query).**
1. It joined every `CLINICAL_EVENT` row. The data has 6,436 superseded result rows from corrections and In Error marks, so each corrected result counted twice.
2. It had no result-status filter, so 1,563 In Error results were counted.
3. It measured TAT to each row's `verified_dt_tm`. For the 4,873 corrected results, that is the *correction's* verification, a median **19.1 hours** after the original.
4. It counted result components, not orders: a BMP is 2 results, a CBC 2.

**Fix (v2).** One row per order. TAT = order to `MIN(verified_dt_tm)` across all versions (the first time a result was available). Keep only orders that still have a current (`valid_until_dt_tm` in the future), non-In-Error result.

**Prevention.**
* DQ checks `event_with_multiple_current_versions` and `broken_version_chain` (validate.py).
* Control total: report orders = source count of completed orders with a current valid result.
* Regression test `test_rca2_lab_tat_uses_current_versions_only`, plus an independent pandas re-computation of every TAT cell (`test_lab_tat_matches_pandas`).
