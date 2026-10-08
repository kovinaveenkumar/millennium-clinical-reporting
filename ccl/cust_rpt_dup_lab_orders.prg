/*****************************************************************************
  Program : cust_rpt_dup_lab_orders
  Purpose : Duplicate lab orders - same orderable on the same encounter within
            120 min of an earlier, not-cancelled order - by facility and test.
  SQL twin: sql/reports/07_duplicate_orders.sql
  Prompts : OUTDEV, START_DT, END_DT (order date), FACILITY_CD, WINDOW_MIN
  Notes   : Self-join of ORDERS (alias "prior"). Window is a prompt so the same
            program can back the Discern rule window analysis (docs/discern_rules.md).
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_dup_lab_orders go
create program cust_rpt_dup_lab_orders

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
  , "Look-back window (minutes)"  = 120
with OUTDEV, START_DT, END_DT, FACILITY_CD, WINDOW_MIN

declare canceled_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "CANCELED"))
declare completed_cd = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "COMPLETED"))
declare lab_cd       = f8 with protect, constant(uar_get_code_by("MEANING", 6000, "GENERAL LAB"))
declare window_str   = vc with protect, constant(build($WINDOW_MIN, ",MIN"))
declare fac_parser   = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0) set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD) endif

select into $OUTDEV
  facility = substring(1, 20, uar_get_code_display(e.loc_facility_cd))
, test     = substring(1, 25, uar_get_code_display(o.catalog_cd))
from orders o
   , encounter e
   , person p
   , orders prior
plan o
  where o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and o.catalog_type_cd = lab_cd
    and o.active_ind = 1
join e
  where e.encntr_id = o.encntr_id
    and e.active_ind = 1
    and parser(fac_parser)
join p
  where p.person_id = o.person_id
    and p.name_last_key != "ZZTEST*"
join prior                                                   ; earlier order of the same test, may not exist
  where prior.encntr_id = outerjoin(o.encntr_id)
    and prior.catalog_cd = outerjoin(o.catalog_cd)
    and prior.order_id != outerjoin(o.order_id)
    and prior.order_status_cd != outerjoin(canceled_cd)
    and prior.orig_order_dt_tm < outerjoin(o.orig_order_dt_tm)
    and prior.orig_order_dt_tm >= outerjoin(cnvtlookbehind(window_str, o.orig_order_dt_tm))
order by facility, test, o.order_id
head report
  col 0 "facility" col 22 "test" col 49 "orders" col 58 "duplicates" col 71 "performed" col 83 "per_1000"
  row + 1
head test
  n = 0  dup = 0  perf = 0
head o.order_id                                              ; count each order once
  n = n + 1
  if (prior.order_id > 0)
    dup = dup + 1
    if (o.order_status_cd = completed_cd) perf = perf + 1 endif
  endif
foot test
  col 0 facility col 22 test col 49 n "######" col 58 dup "#####" col 71 perf "#####" col 83 (1000.0 * dup / n) "###.#"
  row + 1
with nocounter, maxcol = 100

end
go
