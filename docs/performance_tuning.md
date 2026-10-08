# Performance tuning

Reproduce with `python src/tune.py` (results in `output/perf_results.csv`). SQLite's `EXPLAIN QUERY PLAN` stands in for an Oracle explain plan. The habits are the same ones used to tune a CCL `PLAN` / `JOIN`.

| # | Query | Before | After | Change |
|---|---|---|---|---|
| 1 | One week of orders, filtered by date | 14.7 ms: `SCAN o` (every order) | 1.9 ms: `SEARCH o USING INDEX xie_ord_dt` | **~8×**: removed the function wrapped around the indexed column |
| 2 | `census_summary` report, 6 months | **2.91 s**: planner built an index on `active_ind` | **0.08 s**: uses `xie_elh_unit (unit, beg_dt)` | **~37×**: same logic, plan steered |
| 3 | `census_daily`, 181 days × 9 units | 134 ms: range join rescans segments per unit-day | 32 ms: one pass, running sum of +1/−1 | **~4×**: rewrite, output proven identical |

### 1. Keep the qualifying column bare
`WHERE date(o.orig_order_dt_tm) BETWEEN :s AND :e` hides the column inside a function, so the index on `orig_order_dt_tm` can't be used and every order is scanned. `WHERE o.orig_order_dt_tm >= :s AND o.orig_order_dt_tm < :e + 1 day` returns the same rows (the script asserts this) and searches the index. The CCL equivalent: qualify the PLAN driver with `o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)`, never with `cnvtdate(o.orig_order_dt_tm) = ...`.

### 2. Read the plan. The logic was fine; the plan was not.
`census_summary` and `census_daily` share their join logic, but one took 2.9 s and the other 0.09 s. The plan showed the slow one building an automatic index on `encntr_loc_hist.active_ind`. That column holds almost one value, so the "index" was a near-full scan for every unit-day. Writing the predicate as `+h.active_ind = 1` (unary plus) tells SQLite not to use an index for that term, so it falls back to `xie_elh_unit (loc_nurse_unit_cd, beg_effective_dt_tm)`. The Oracle / CCL equivalents are an optimizer hint (`with orahint("index(elh xie_elh_unit)")`), or fixing statistics.

### 3. Don't rescan history once per day
A per-day range join (`beg <= midnight < end`) touches every segment that started before each date. The rewrite turns each segment into +1 at the first midnight it covers and −1 after the last, then takes a running `SUM() OVER (ORDER BY day)`. That is one pass. `test_census_rewrite_is_equivalent` proves the outputs are identical. The CCL version (`ccl/cust_rpt_midnight_census.prg`) uses the same one-pass idea, adding to a record structure in the `detail` section.

### Checklist I use for a slow CCL / SQL report
* Drive from the most selective, indexed qualifier (usually a date range on the driver table). Narrow the range before testing.
* Never wrap an indexed column in a function. Compare it to converted constants instead.
* Check the explain plan for full scans and for the index actually chosen. Check that statistics are current.
* Join outward from the smallest row set. Use `outerjoin()` only where rows may truly be missing.
* Test with `maxrec` / small date ranges first. Watch out for row multiplication (one row per result version or per alias).
* Put heavy logic in a record structure and output it once (`dummyt`), rather than re-querying in nested selects.
