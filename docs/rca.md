# Root-cause analysis: two report bugs

Neither of these was an arithmetic mistake. Both came from misreading how Millennium stores data, which is exactly why they're easy to miss. I kept the broken queries in [`sql/archive/`](../sql/archive). `src/rca.py` reproduces the numbers below, and there's a regression test for each bug in `tests/test_reports.py`.

## 1. The ED report was missing one in five visits

**What was reported.** The ED report showed far fewer visits than the ED tracking board, and the "over 4 hours" figure looked better than anyone believed.

**How big the gap was** (January–June 2026):

| Facility | Visits, first version | Visits, fixed | Over 4 h, first version | Over 4 h, fixed |
|---|---|---|---|---|
| Lakeside Regional | 10,365 | 12,977 | 32.0% | 48.3% |
| Mercy North | 14,384 | 17,850 | 23.8% | 35.7% |
| Mercy South | 16,540 | 20,419 | 27.7% | 40.2% |
| **Total** | **41,289** | **51,246** | | |

The first version missed 9,957 visits, about 19%, and understated long stays by 12 to 16 points. The missing visits were the admitted patients, who have the longest stays. So the bug hid the exact problem the report was built to show.

**Cause.** I filtered ED visits on `encntr_type_cd = EMERGENCY`. When an ED patient is admitted, Millennium changes the type on the same encounter to Inpatient, so every admitted ED visit failed the filter. I was also measuring length of stay to hospital discharge rather than to the time the patient left the ED.

**How I found it.**
1. I counted encounters with an ED arrival time directly from the table. That came out about 19% higher than the report.
2. I pulled ten FINs that were in the raw count but not in the report. All ten were Inpatient encounters.
3. Their location history showed an ED stay first, then an inpatient unit, all on the same encounter.

**Fix.** Count ED visits by `arrive_dt_tm`. Measure ED time to the end of the first location in ENCNTR_LOC_HIST, and boarding from `inpatient_admit_dt_tm`.

**Prevention.**
- `validate.py` now checks the report total against an independent count before anything is published.
- A regression test fails if the encounter-type filter ever comes back.
- The rule is written down in [data_model.md](data_model.md) (rule 5).

## 2. The lab turnaround report counted corrected results twice

**What was reported.** The lab director said the STAT volume on the report was much higher than the order count in the lab system.

**How big the gap was** (STAT orders, January–June 2026):

| Facility | "Results", first version | STAT orders, fixed | Within 60 min, first version | Within 60 min, fixed |
|---|---|---|---|---|
| Lakeside Regional | 46,392 | 26,764 | 80.3% | 81.6% |
| Mercy North | 66,769 | 38,161 | 85.4% | 86.9% |
| Mercy South | 74,326 | 42,757 | 69.7% | 70.7% |

Volume was inflated 1.74 times, and the on-time rate was understated by 1 to 1.5 points.

**Cause.** There were four problems in the same query:
1. It joined every CLINICAL_EVENT row. The data has 6,436 older versions left behind by corrections and In Error marks, so a corrected result was counted twice.
2. It didn't filter on result status, so 1,563 results marked In Error were included.
3. It took turnaround from each row's own verification time. For the 4,873 corrected results, that's when the *correction* was verified, a median of 19.1 hours after the original result.
4. It counted results instead of orders. A BMP or CBC produces two results, so each one counted twice.

**Fix.** One row per order. Turnaround runs from the order to the earliest verification across all versions, which is when a result was first available. Only orders that still have a current, valid result are included.

**Prevention.**
- Two data-quality checks: no result can have more than one current version, and every superseded row has to link to the version that replaced it.
- A control total: the orders in the report must match an independent count from the source tables.
- A regression test, plus a test that recalculates every cell of the report in pandas and compares.
