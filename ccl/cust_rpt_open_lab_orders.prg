/*****************************************************************************
  Program : cust_rpt_open_lab_orders
  Purpose : Worklist of lab orders still in Ordered status > 24 h after placement
            (possible missed collections), with a suggested action.
  SQL twin: sql/reports/06_open_orders.sql
  Prompts : OUTDEV, START_DT, END_DT (order date), FACILITY_CD
  Ops job : intended to run daily 06:00 via Operations scheduling, output to a
            shared printer/file for the lab supervisor.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_open_lab_orders go
create program cust_rpt_open_lab_orders

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
with OUTDEV, START_DT, END_DT, FACILITY_CD

declare ordered_cd = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "ORDERED"))
declare lab_cd     = f8 with protect, constant(uar_get_code_by("MEANING", 6000, "GENERAL LAB"))
declare fin_cd     = f8 with protect, constant(uar_get_code_by("MEANING", 319, "FIN NBR"))
declare cutoff_dt  = dq8 with protect, constant(cnvtlookbehind("24,H", cnvtdatetime(curdate, curtime3)))
declare fac_parser = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0) set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD) endif

select into $OUTDEV
  facility         = substring(1, 20, uar_get_code_display(e.loc_facility_cd))
, current_unit     = substring(1, 20, uar_get_code_display(e.loc_nurse_unit_cd))
, fin              = substring(1, 15, ea.alias)
, order_id         = o.order_id
, test             = substring(1, 25, uar_get_code_display(o.catalog_cd))
, priority         = substring(1, 8, od.oe_field_display_value)
, ordered          = format(o.orig_order_dt_tm, "MM/DD/YYYY HH:MM;;D")
, hours_open       = round(datetimediff(cnvtdatetime(curdate, curtime3), o.orig_order_dt_tm, 3), 1)
, suggested_action = evaluate2(if (e.disch_dt_tm != null) "Discharged - cancel or follow up"
                               else "In house - recollect" endif)
from orders o
   , order_detail od
   , encounter e
   , person p
   , encntr_alias ea
plan o
  where o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and o.orig_order_dt_tm < cnvtdatetime(cutoff_dt)
    and o.order_status_cd = ordered_cd
    and o.catalog_type_cd = lab_cd
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
join ea
  where ea.encntr_id = e.encntr_id
    and ea.encntr_alias_type_cd = fin_cd
    and ea.active_ind = 1
order by o.orig_order_dt_tm
with nocounter, format, separator = " "

end
go
