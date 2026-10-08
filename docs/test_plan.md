# Test plan and results

All of this runs automatically. `./run_all.sh` runs validation before it publishes anything, and stops if a single check fails.

## 1. Pre-publish validation: `python src/validate.py`

21 of 21 checks pass. The full results are in `output/validation_results.csv`.

**Data-quality checks.** Each of these looks for bad rows, and should find zero:

| Check | Expected | Actual |
|---|---|---|
| Encounters without a patient; orders without an encounter | 0 | 0 |
| Discharge before registration; overlapping location stays | 0 | 0 |
| Completed orders with no current result; results on a cancelled order | 0 | 0 |
| A result with more than one current version; a broken chain of versions | 0 | 0 |
| A code that doesn't resolve in the right code set; an encounter or patient without exactly one active FIN or MRN | 0 | 0 |
| Orders with no priority; lab results that aren't numeric; anything dated after the data cut-off | 0 | 0 |

**Control totals.** These compare report totals with independent counts:

| Check | Expected | Actual |
|---|---|---|
| ED visits in the report match an independent count | 51,246 | 51,246 |
| The three facilities add up to the "All facilities" total (ED, readmissions, critical results, lab turnaround) | equal | equal |
| Lab turnaround orders match the source count | 204,468 | 204,468 |
| Test patients in the critical-result worklist (30 test encounters exist in the data) | 0 | 0 |

## 2. Automated tests: `pytest`

19 tests, all passing.

| Test | What it checks |
|---|---|
| `test_ed_throughput_matches_pandas` | Visits, both medians and the over-4-hours rate are recalculated separately in pandas for every facility, and must match. |
| `test_lab_tat_matches_pandas` | Every facility, priority and test cell: order count, median and on-time rate. |
| `test_critical_compliance_matches_pandas` | Counts, the 30-minute rate and the median per unit. I added this after the Oracle comparison caught a median bug this report had. |
| `test_readmissions_match_pandas` | Index discharges and readmissions per facility. |
| `test_facility_prompt_partitions_total` (4 reports) | Running each facility separately adds up exactly to the all-facilities total. |
| `test_date_prompt_months_add_up` | Six monthly runs add up to the six-month run, so nothing is counted twice at month boundaries. |
| `test_unknown_facility_prompt_is_rejected` | A misspelled facility raises an error instead of silently returning everything. |
| `test_test_patients_never_reach_a_worklist` | No test-patient FINs show up on either worklist. |
| `test_readmission_lookback_is_complete` | No index stay is counted before its 30-day window has finished. |
| `test_rca1_...`, `test_rca2_...` | Neither of the two RCA bugs can come back. |
| `test_census_rewrite_is_equivalent` | The tuned census query returns the same rows as the original. |
| `test_rule_ignores_prior_order_cancelled_before_sign` | An edge case in the duplicate-order rule logic. |
| `test_60_minute_window_is_accurate`, `test_wide_window_floods_intended_repeats` | The window trade-off behaves as documented. |

## 3. Cross-check against Oracle: `python oracle/oracle_port.py run`

Reports 01–05 run on Oracle 23ai Free and are compared value by value with the SQLite output. All 238 values match. The details, including the two issues the comparison turned up, are in [oracle/README.md](../oracle/README.md).

## 4. Manual checks I'd add in a live domain

- Open five rows from each report in PowerChart by FIN, and confirm the results, location history and documentation line up.
- Compare totals against a report or source system people already trust, such as the lab system's volume or the ED tracking board.
- Run the CCL in CERT on a small date range first, then the full range, and compare it with the SQL version.
- Have the person who asked for the report sign off on a real week of data before it moves to production.
