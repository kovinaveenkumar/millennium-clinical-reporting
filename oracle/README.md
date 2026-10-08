# Oracle port (Oracle Database 23ai Free, Docker)

Millennium runs on Oracle, so reports 01–05 are ported to Oracle SQL ([`reports_oracle.sql`](reports_oracle.sql)) on the same tables ([`schema_oracle.sql`](schema_oracle.sql)). They are then **reconciled cell by cell** against the SQLite reports.

```bash
docker run -d --name millennium-oracle -p 1521:1521 \
  -e ORACLE_PASSWORD=<admin pw> -e APP_USER=millennium -e APP_USER_PASSWORD=<app pw> \
  gvenzl/oracle-free:23-slim-faststart
pip install oracledb
export ORA_PASSWORD=<app pw>            # ORA_USER / ORA_DSN default to millennium / localhost:1521/FREEPDB1
python oracle/oracle_port.py load       # DDL + copy 1.2M rows from data/millennium.db (~15 s) + DBMS_STATS
python oracle/oracle_port.py run        # run Oracle reports, reconcile, save explain plan
```

## Result: all 238 report values match ([`output/oracle_reconciliation.csv`](../output/oracle_reconciliation.csv))

| Report | Rows | Values compared | Different | Oracle runtime |
|---|---|---|---|---|
| 01 ED throughput | 3 | 21 | 0 | 0.17 s |
| 02 Lab turnaround | 21 | 84 | 0 | 0.65 s |
| 03 Critical result calls | 14 | 70 | 0 | 0.10 s |
| 04 Readmissions | 3 | 9 | 0 | 0.05 s |
| 05 Census summary | 9 | 54 | 0 | 0.12 s |

## The reconciliation found two real issues (both fixed)
1. **Median bug in the SQLite version of report 03.** The first comparison had 7 differences in `median_notify_min`; Telemetry showed 20 min in SQLite vs 25 in Oracle. SQLite sorts NULLs (calls never documented) *first*, so `ROW_NUMBER()` positions were shifted and the hand-built median picked a value too low. Oracle's `MEDIAN()` ignores NULLs, so Oracle was right. Fix: `ORDER BY notify_min NULLS LAST`, plus a new pandas test (`test_critical_compliance_matches_pandas`) covering that column.
2. **Exactly-60-minute boundary in report 02.** One lab order resulted at exactly 60:00. SQLite's floating-point `julianday` math landed just under 60 and counted it as on time. Oracle's decimal `DATE` math (`1/24 × 1440`) landed a hair over 60 and did not. Fix: compute TAT from whole seconds in both databases.

## SQLite → Oracle translation notes
| SQLite | Oracle |
|---|---|
| `(julianday(a) - julianday(b)) * 1440` | `(a - b) * 1440` on `DATE` (round seconds when comparing to a boundary) |
| `datetime(x, '+6 hours')`, `datetime(x, '-30 days')` | `x + 6/24`, `x - 30` |
| median via `ROW_NUMBER()` / `COUNT()` CTEs | `MEDIAN()` aggregate (ignores NULLs) |
| `WITH RECURSIVE days ...` | `SELECT start + LEVEL - 1 FROM dual CONNECT BY LEVEL <= n` |
| `SUM(condition)` | `SUM(CASE WHEN condition THEN 1 ELSE 0 END)` |
| `EXISTS(...)` in the select list | `CASE WHEN EXISTS(...) THEN 1 ELSE 0 END` |

The explain plan for report 01 is in [`output/oracle_explain_ed_throughput.txt`](../output/oracle_explain_ed_throughput.txt). Oracle drives from `XIE_ENC_ARRIVE` (date range scan) and reaches `ENCNTR_LOC_HIST` through `XIE_ELH_ENCNTR` with a pushed predicate. It also OR-expands the optional facility prompt `(:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)` into two branches (`VW_ORE_*`). That is why the CCL versions use `parser()` for optional filters instead.
