# Oracle version

Millennium runs on Oracle, so I ported reports 01–05 to Oracle SQL ([`reports_oracle.sql`](reports_oracle.sql)) on the same tables ([`schema_oracle.sql`](schema_oracle.sql)). Then I compared every value with the SQLite output.

## Running it

You need Docker, and the SQLite database built first (`./run_all.sh` or `python src/generate_data.py`). The image is Oracle Database 23ai Free. The `oracledb` driver is already in `requirements.txt`.

```bash
docker run -d --name millennium-oracle -p 1521:1521 \
  -e ORACLE_PASSWORD=<admin password> -e APP_USER=millennium -e APP_USER_PASSWORD=<app password> \
  gvenzl/oracle-free:23-slim-faststart

export ORA_PASSWORD=<app password>     # required; ORA_USER and ORA_DSN default to millennium and localhost:1521/FREEPDB1

python oracle/oracle_port.py load      # creates the tables, copies 1.2M rows from SQLite, gathers stats (about 15 s)
python oracle/oracle_port.py run       # runs the Oracle reports and compares them with SQLite
```

## Result: all 238 values match

The full comparison is in [`output/oracle_reconciliation.csv`](../output/oracle_reconciliation.csv).

| Report | Rows | Values compared | Differences | Oracle run time |
|---|---|---|---|---|
| 01 ED throughput | 3 | 21 | 0 | 0.17 s |
| 02 Lab turnaround | 21 | 84 | 0 | 0.65 s |
| 03 Critical result calls | 14 | 70 | 0 | 0.10 s |
| 04 Readmissions | 3 | 9 | 0 | 0.05 s |
| 05 Census summary | 9 | 54 | 0 | 0.12 s |

## What the first comparison caught

It didn't match the first time, and both differences turned out to be worth finding.

**A median bug in my SQLite report 03.** Seven median values were off; Telemetry showed 20 minutes in SQLite but 25 in Oracle. I build the median in SQLite by numbering the rows in order. SQLite sorts NULLs first, and a NULL here means a call that was never documented, so those rows took the first positions and pushed the "middle" row too early. Oracle's `MEDIAN()` ignores NULLs, so Oracle had it right. I fixed it with `ORDER BY notify_min NULLS LAST` and added a test covering that column.

**A boundary case at exactly 60 minutes in report 02.** One lab order came back at exactly 60:00. SQLite works out time differences in floating point and landed just under 60, so it counted the order as on time. Oracle's date arithmetic landed just over 60 and didn't. I changed both versions to calculate turnaround from whole seconds, so they agree.

## Differences between the two versions

| SQLite | Oracle |
|---|---|
| `(julianday(a) - julianday(b)) * 1440` | `(a - b) * 1440` on DATE columns (rounded to whole seconds when comparing to a cut-off) |
| `datetime(x, '+6 hours')`, `datetime(x, '-30 days')` | `x + 6/24`, `x - 30` |
| median built from `ROW_NUMBER()` and `COUNT()` | `MEDIAN()` |
| `WITH RECURSIVE` to generate days | `CONNECT BY LEVEL` from `dual` |
| `SUM(condition)` | `SUM(CASE WHEN condition THEN 1 ELSE 0 END)` |
| `EXISTS(...)` in the select list | `CASE WHEN EXISTS(...) THEN 1 ELSE 0 END` |

## Explain plan

The plan for report 01 is saved in [`output/oracle_explain_ed_throughput.txt`](../output/oracle_explain_ed_throughput.txt).
- Oracle starts from the arrival-date index (XIE_ENC_ARRIVE).
- It reaches ENCNTR_LOC_HIST through XIE_ELH_ENCNTR.
- It splits the optional facility condition `(:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)` into two branches.

That last point is the reason the CCL versions use `parser()` for that filter instead.
