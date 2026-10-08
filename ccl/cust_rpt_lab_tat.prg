/*****************************************************************************
  Program : cust_rpt_lab_tat
  Purpose : Lab turnaround (order -> first verification) by facility / priority /
            orderable, % within target (STAT 60 min, Routine 240 min).
  SQL twin: sql/reports/02_lab_turnaround.sql
  Prompts : OUTDEV, START_DT, END_DT (order date), FACILITY_CD (0 = all)
  Notes   : - Priority lives on ORDER_DETAIL (oe_field_meaning = "COLLPRI").
            - Only orders with a CURRENT (valid_until in the future), non-In-Error
              result. TAT uses the FIRST verification (min over versions) so a
              corrected result does not add the correction delay (RCA incident 2).
            - One row per ORDER, not per result component (a BMP has 2+ results).
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_lab_tat go
create program cust_rpt_lab_tat

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
with OUTDEV, START_DT, END_DT, FACILITY_CD

declare completed_cd = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "COMPLETED"))
declare auth_cd      = f8 with protect, constant(uar_get_code_by("MEANING", 8, "AUTH"))
declare modified_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 8, "MODIFIED"))
declare inerror_cd   = f8 with protect, constant(uar_get_code_by("MEANING", 8, "INERROR"))
declare fac_parser   = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0) set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD) endif

record ord (
  1 cnt = i4
  1 qual[*]
    2 facility  = vc
    2 priority  = vc
    2 test      = vc
    2 tat_min   = f8
    2 has_valid = i2
) with protect

record tmp_tat (
  1 v[*]
    2 m = f8
) with protect
declare n = i4 with protect, noconstant(0)
declare within = i4 with protect, noconstant(0)
declare target = f8 with protect, noconstant(0.0)

/* pass 1: one row per order with first verification and "has a current valid result" flag */
select into "nl:"
from orders o
   , order_detail od
   , encounter e
   , person p
   , clinical_event ce
plan o
  where o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)  ; driver: indexed date
    and o.order_status_cd = completed_cd
    and o.active_ind = 1
join od
  where od.order_id = o.order_id
    and od.oe_field_meaning = "COLLPRI"
join e
  where e.encntr_id = o.encntr_id
    and e.active_ind = 1
    and parser(fac_parser)
join p
  where p.person_id = o.person_id
    and p.name_last_key != "ZZTEST*"
join ce
  where ce.order_id = o.order_id                ; ALL versions: needed for first verification
order by o.order_id, ce.verified_dt_tm
head report
  ord->cnt = 0
head o.order_id
  ord->cnt = ord->cnt + 1
  if (mod(ord->cnt, 1000) = 1) stat = alterlist(ord->qual, ord->cnt + 999) endif
  ord->qual[ord->cnt].facility = uar_get_code_display(e.loc_facility_cd)
  ord->qual[ord->cnt].priority = od.oe_field_display_value
  ord->qual[ord->cnt].test     = uar_get_code_display(o.catalog_cd)
  ord->qual[ord->cnt].tat_min  = datetimediff(ce.verified_dt_tm, o.orig_order_dt_tm, 4)   ; first row = first verify
detail
  if (ce.valid_until_dt_tm > cnvtdatetime(curdate, curtime3)
      and ce.result_status_cd in (auth_cd, modified_cd))
    ord->qual[ord->cnt].has_valid = 1
  endif
foot report
  stat = alterlist(ord->qual, ord->cnt)
with nocounter

/* pass 2: aggregate (median via sorted position within each group) */
select into $OUTDEV
  facility          = substring(1, 30, ord->qual[d.seq].facility)
, priority          = substring(1, 10, ord->qual[d.seq].priority)
, test              = substring(1, 30, ord->qual[d.seq].test)
, tat               = ord->qual[d.seq].tat_min
from (dummyt d with seq = value(ord->cnt))
plan d
  where ord->qual[d.seq].has_valid = 1
order by facility, priority, test, tat
head report
  col 0 "facility" col 32 "priority" col 44 "test" col 76 "orders" col 86 "median_tat" col 99 "pct_within_target"
  row + 1
head test
  n = 0  within = 0  target = evaluate2(if (priority = "STAT") 60.0 else 240.0 endif)
  stat = initrec(tmp_tat)
detail
  n = n + 1
  if (tat <= target) within = within + 1 endif
  stat = alterlist(tmp_tat->v, n)  tmp_tat->v[n].m = tat
foot test
  col 0 facility col 32 priority col 44 test
  col 76 n "######"
  col 86 ((tmp_tat->v[(n + 1) / 2].m + tmp_tat->v[(n + 2) / 2].m) / 2.0) "#####.#"
  col 99 (100.0 * within / n) "###.#"
  row + 1
with nocounter, maxcol = 200

end
go
