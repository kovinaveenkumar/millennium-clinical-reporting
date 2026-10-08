# CCL (Discern Explorer) programs

> **Honesty note:** these programs are written in CCL syntax and follow Cerner conventions, but they have **not been compiled or run**. There is no public Millennium domain. The same logic *is* run and tested as SQL in `sql/reports/` (each program header names its SQL twin). Expect small syntax fixes on first compile in a real domain.

| Program | Report | CCL techniques shown |
|---|---|---|
| `cust_rpt_ed_throughput.prg` | 01 ED throughput | prompts, `uar_get_code_by`, `parser()` optional filter, record structure, head/detail/foot, subroutine (median), `dummyt` output |
| `cust_rpt_lab_tat.prg` | 02 Lab TAT | two-pass: collect per order (`head o.order_id` = first verification), then aggregate; `alterlist` in blocks of 1,000 |
| `cust_rpt_crit_result_calls.prg` | 03 Critical calls | `outerjoin()` (the notification may not exist), point-in-time location join, summary vs detail prompt |
| `cust_rpt_readmit_30d.prg` | 04 Readmissions | prompt validation with `go to exit_script`, `cnvtlookahead("30,D", …)`, outer self-join |
| `cust_rpt_midnight_census.prg` | 05 Census | nested record (unit → day), one pass over segments with a `while` loop, `dummyt` × `dummyt` output |
| `cust_rpt_open_lab_orders.prg` | 06 Open orders | worklist output for an Operations job, `evaluate2` |
| `cust_rpt_dup_lab_orders.prg` | 07 Duplicates | self-join of ORDERS with a prompt-driven `cnvtlookbehind` window |
| `cust_ops_kpi_mp.prg` | MPage driver | `locateval`, `cnvtrectojson`, `_memory_reply_string` for `mpage/ops_kpi.html` |
| `cust_eks_dup_lab_order.prg` | Discern rule logic | EKS-callable CCL: `link_encntrid` / `link_orderid` in, `retval` / `log_message` / `log_misc1` out |

## Running in a domain (DiscernVisualDeveloper or CCL command line)
```
; compile
%i ccluserdir:cust_rpt_ed_throughput.prg
; run: output to screen, Jan-Jun 2026, all facilities
cust_rpt_ed_throughput "MINE", "01-JAN-2026 00:00:00", "30-JUN-2026 23:59:59", 0.0 go
```

## Conventions used
* Header block with purpose, SQL twin, prompts, and a mod log.
* Code values come from `cdf_meaning` / `display_key` through `uar_get_code_by`, declared once as constants. No hard-coded numbers.
* The driver table (`plan`) is qualified on an indexed date range first. Each `join` follows a key.
* `with protect` on declares and records. `nocounter` on every select. `"nl:"` for selects that only fill records.
* Optional prompt filters use `parser()`, not `(col = $X or $X = 0)`, so the indexed column stays bare.
