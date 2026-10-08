# Performance tuning

Run `python src/tune.py` to reproduce these numbers; it writes them to `output/perf_results.csv`. I used SQLite's `EXPLAIN QUERY PLAN` the way I'd use an explain plan in Oracle. The habits are the same ones you'd use tuning a CCL select.

| | Query | Before | After | What changed |
|---|---|---|---|---|
| 1 | A week of orders, filtered by date | 14.7 ms, full scan | 1.9 ms, index range scan | Took the function off the indexed column (about 8x faster) |
| 2 | Census summary, 6 months | 2.91 s | 0.08 s | Same logic; pushed the planner onto the right index (about 37x) |
| 3 | Daily census, 181 days x 9 units | 134 ms | 32 ms | Rewrote it as a single pass; output proven identical (about 4x) |

## 1. Don't wrap an indexed column in a function

`WHERE date(o.orig_order_dt_tm) BETWEEN :s AND :e` hides the column inside `date()`. The index on `orig_order_dt_tm` can't be used, so every order gets scanned. Writing it as a plain range, `o.orig_order_dt_tm >= :s AND o.orig_order_dt_tm < :e + 1 day`, returns the same rows (the script checks this) and uses the index.

In CCL the same rule applies. I qualify the driving table with `between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)`, never with something like `cnvtdate(o.orig_order_dt_tm) = ...`.

## 2. Read the plan, not just the SQL

The census summary and the daily census use the same join, but one took 2.9 seconds and the other under a tenth of a second. The plan for the slow one showed the database building a temporary index on `encntr_loc_hist.active_ind`. Almost every row in that column has the same value, so the "index" was close to a full scan, and it ran once for every unit and every day.

Writing the condition as `+h.active_ind = 1` tells SQLite not to use an index for that term. It then goes back to `xie_elh_unit (loc_nurse_unit_cd, beg_effective_dt_tm)`, which is the index the query should have used all along. In Oracle or CCL I'd do the same with an optimizer hint, or by checking that statistics are up to date.

## 3. Don't rescan history once per day

The straightforward census query checks, for every day, which stays cover midnight. That means it re-reads every stay that began before that day, over and over.

The rewrite turns each stay into a +1 on the first midnight it covers and a -1 after the last one, then takes a running total by day. It reads the data once. `test_census_rewrite_is_equivalent` confirms the output matches the original row for row. The CCL version of the census report works the same way, adding to a record structure as it reads each stay.

## My checklist for a slow report

- Narrow the date range first, and drive the query from the most selective indexed column.
- Never wrap an indexed column in a function. Convert the constant instead.
- Look at the plan. Check for full scans, and check which index was actually chosen. Make sure statistics are current.
- Join outward from the smallest set of rows, and only use outer joins where a row really might be missing.
- Test on a small date range or with `maxrec` first, and watch for rows multiplying through result versions or aliases.
- In CCL, collect into a record structure and output once, rather than running a select inside another select.
