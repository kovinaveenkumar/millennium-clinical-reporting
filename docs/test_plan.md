# Test plan and validation evidence

Everything below is automated. `./run_all.sh` runs it in order and stops before publishing if validation fails.

## 1. Pre-publish validation: `python src/validate.py`, 21/21 pass
Results: `output/validation_results.csv`.

| Type | Check | Expected | Result |
|---|---|---|---|
| Data quality | encounter without person; order without encounter | 0 | 0 |
| Data quality | discharge before registration; overlapping location segments | 0 | 0 |
| Data quality | completed order without a current result; result on a cancelled order | 0 | 0 |
| Data quality | event with more than one current version; broken version chain | 0 | 0 |
| Data quality | code value does not resolve (right code set); FIN / MRN not exactly one active | 0 | 0 |
| Data quality | order without priority; non-numeric lab result; event after the data cut | 0 | 0 |
| Control total | ED visits: report = independent source count | 51,246 | 51,246 |
| Control total | sum of the 3 facility prompts = "All" (ED, readmissions, critical results, lab TAT) | equal | equal |
| Control total | lab TAT orders: report = source count | 204,468 | 204,468 |
| Control total | test-patient FINs in the critical worklist (30 test encounters exist) | 0 | 0 |

## 2. Unit / regression tests: `pytest`, 18 pass

| Test | What it proves |
|---|---|
| `test_ed_throughput_matches_pandas` | visits, both medians and % over 4 h re-computed independently in pandas, for every facility |
| `test_lab_tat_matches_pandas` | every facility × priority × test cell: orders, median, % within target |
| `test_readmissions_match_pandas` | index discharges and readmissions per facility |
| `test_facility_prompt_partitions_total` (×4) | facility prompt splits the total exactly |
| `test_date_prompt_months_add_up` | six monthly runs add up to the half-year run (no boundary double-counting) |
| `test_unknown_facility_prompt_is_rejected` | bad prompt value raises an error instead of returning "all" |
| `test_test_patients_never_reach_a_worklist` | ZZTEST FINs absent from both worklists |
| `test_readmission_lookback_is_complete` | no index stays without a full 30-day look-back |
| `test_rca1_*`, `test_rca2_*` | the two RCA defects cannot come back |
| `test_census_rewrite_is_equivalent` | tuned census query = original, row for row |
| `test_rule_ignores_prior_order_cancelled_before_sign` | rule logic edge case (hand-built 2-order case) |
| `test_60_minute_window_is_accurate`, `test_wide_window_floods_intended_repeats` | rule window trade-off |

## 3. Manual checks before sign-off (what I would do in a live domain)
* Spot-check 5 rows per report by FIN in PowerChart (results, location history, documentation).
* Compare totals with an existing trusted report or source system (LIS volume, ED tracking board).
* Run the CCL in the CERT domain with a small date range and `maxrec`, then the full range. Compare the output with the SQL version.
* Get user acceptance from the requester on a real week of data before the production move.
