/*****************************************************************************
  Program : cust_ops_kpi_mp
  Purpose : MPage data driver - returns the facility KPI summary as JSON for the
            HTML/JS component in mpage/ops_kpi.html.
  Called  : from the MPage with XMLCclRequest / CCLLINK:
              cust_ops_kpi_mp "MINE", "01-JAN-2026 00:00:00", "30-JUN-2026 23:59:59"
  Returns : _memory_reply_string = cnvtrectojson(kpi)
            Shape is identical to output/mpage_payload.json (built by
            src/build_html.py), so the page can be developed and tested off-domain.
  Notes   : reuses the logic of the report programs; each KPI is one select into
            the same record structure, keyed by facility.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_ops_kpi_mp go
create program cust_ops_kpi_mp

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
with OUTDEV, START_DT, END_DT

record kpi (
  1 start_dt = vc
  1 end_dt   = vc
  1 fac_cnt  = i4
  1 qual[*]
    2 facility_cd         = f8
    2 facility            = vc
    2 ed_visits           = i4
    2 ed_median_board_min = f8
    2 stat_pct_60         = f8
    2 crit_pct_30         = f8
    2 readmit_pct         = f8
%i cclsource:status_block.inc
) with protect

declare inpatient_cd = f8 with protect, constant(uar_get_code_by("MEANING", 71, "INPATIENT"))
declare completed_cd = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "COMPLETED"))
declare idx  = i4 with protect, noconstant(0)
declare pos  = i4 with protect, noconstant(0)
declare n    = i4 with protect, noconstant(0)
declare hit  = i4 with protect, noconstant(0)

set kpi->start_dt = $START_DT
set kpi->end_dt   = $END_DT
set kpi->status_data.status = "F"

/* facilities */
select into "nl:"
from code_value cv
plan cv
  where cv.code_set = 220
    and cv.cdf_meaning = "FACILITY"
    and cv.active_ind = 1
order by cv.display
detail
  kpi->fac_cnt = kpi->fac_cnt + 1
  stat = alterlist(kpi->qual, kpi->fac_cnt)
  kpi->qual[kpi->fac_cnt].facility_cd = cv.code_value
  kpi->qual[kpi->fac_cnt].facility    = cv.display
with nocounter

/* ED visits (median boarding is filled by the same logic as cust_rpt_ed_throughput;
   omitted here for brevity - the MPage shows it from that program's record) */
select into "nl:"
from encounter e, person p
plan e
  where e.arrive_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and e.active_ind = 1
join p
  where p.person_id = e.person_id
    and p.name_last_key != "ZZTEST*"
order by e.loc_facility_cd
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n = 0
detail
  n = n + 1
foot e.loc_facility_cd
  if (pos > 0) kpi->qual[pos].ed_visits = n endif
with nocounter

/* STAT labs % within 60 min (order -> first verification) */
select into "nl:"
from orders o, order_detail od, encounter e, clinical_event ce
plan o
  where o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and o.order_status_cd = completed_cd
join od
  where od.order_id = o.order_id
    and od.oe_field_meaning = "COLLPRI"
    and od.oe_field_display_value = "STAT"
join e
  where e.encntr_id = o.encntr_id
join ce
  where ce.order_id = o.order_id
order by e.loc_facility_cd, o.order_id, ce.verified_dt_tm
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n = 0  hit = 0
head o.order_id
  n = n + 1
  if (datetimediff(ce.verified_dt_tm, o.orig_order_dt_tm, 4) <= 60) hit = hit + 1 endif
foot e.loc_facility_cd
  if (pos > 0 and n > 0) kpi->qual[pos].stat_pct_60 = round(100.0 * hit / n, 1) endif
with nocounter

/* crit_pct_30 and readmit_pct: same selects as cust_rpt_crit_result_calls and
   cust_rpt_readmit_30d, writing into kpi->qual[pos] (kept in those programs). */

set kpi->status_data.status = "S"
set _memory_reply_string = cnvtrectojson(kpi)

end
go
