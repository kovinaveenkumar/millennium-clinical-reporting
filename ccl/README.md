# CCL programs

These are the CCL (Discern Explorer) versions of the reports in `sql/reports/`. The header of each program names the SQL file it matches.

**Status:** I haven't compiled these yet, because I don't have access to a Millennium domain. The logic is the same as the SQL versions, which are run and tested, and I followed standard Cerner conventions throughout. I'd expect to fix a few syntax details on the first compile.

| Program | Report | What it uses |
|---|---|---|
| `cust_rpt_ed_throughput.prg` | 01 ED throughput | prompts, `uar_get_code_by`, `parser()` for the optional facility filter, a record structure, head/detail/foot, a subroutine for the median, output through `dummyt` |
| `cust_rpt_lab_tat.prg` | 02 Lab turnaround | two passes: first collect one row per order (`head o.order_id` picks up the first verification), then summarize; `alterlist` grown in blocks of 1,000 |
| `cust_rpt_crit_result_calls.prg` | 03 Critical result calls | `outerjoin()` because the call may not have been documented, a point-in-time location join, a prompt to choose summary or worklist |
| `cust_rpt_readmit_30d.prg` | 04 Readmissions | checks the prompt and exits early (`go to exit_script`) if the date range is too recent, `cnvtlookahead("30,D", ...)`, an outer self-join |
| `cust_rpt_midnight_census.prg` | 05 Census | a nested record (unit, then day), a single pass over location history with a `while` loop |
| `cust_rpt_open_lab_orders.prg` | 06 Open orders | a worklist meant to run as a scheduled ops job, `evaluate2` |
| `cust_rpt_dup_lab_orders.prg` | 07 Duplicates | a self-join on ORDERS, with the look-back window taken from a prompt through `cnvtlookbehind` |
| `cust_ops_kpi_mp.prg` | MPage driver | `locateval`, `cnvtrectojson`, returns JSON through `_memory_reply_string` to `mpage/ops_kpi.html` |
| `cust_eks_dup_lab_order.prg` | Rule logic | called from a Discern rule: takes `link_encntrid` and `link_orderid`, sets `retval`, `log_message` and `log_misc1` |

## Running one

```
; compile
%i ccluserdir:cust_rpt_ed_throughput.prg

; run to screen for January–June 2026, all facilities
cust_rpt_ed_throughput "MINE", "01-JAN-2026 00:00:00", "30-JUN-2026 23:59:59", 0.0 go
```

## Conventions

- Every program has a header with its purpose, its matching SQL file, its prompts and a mod log.
- Code values are looked up by meaning or display key with `uar_get_code_by`, once, as constants. There are no hard-coded numbers.
- The `plan` is driven by an indexed date range, and each `join` follows a key.
- Declares and records use `with protect`. Every select uses `nocounter`. Selects that only fill a record go to `"nl:"`.
- Optional prompt filters use `parser()` rather than `(col = $X or $X = 0)`, so the indexed column isn't wrapped in an OR. Oracle's plan for the SQL version shows why: it splits that OR into two separate branches.
