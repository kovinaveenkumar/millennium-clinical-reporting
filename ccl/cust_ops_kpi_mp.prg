/*****************************************************************************
  Program : cust_ops_kpi_mp
  Purpose : MPage data driver - returns the facility KPI summary as JSON for the
            HTML/JS component in mpage/ops_kpi.html.
  Called  : from the MPage with XMLCclRequest / CCLLINK:
              cust_ops_kpi_mp "MINE", "01-JAN-2026 00:00:00", "30-JUN-2026 23:59:59"
  Returns : _memory_reply_string = cnvtrectojson(kpi)
            Shape is identical to output/mpage_payload.json (built by
            src/build_html.py), so the page can be developed and tested off-domain.
  Notes   : each KPI is one select using the same rules as its report program
            (cust_rpt_ed_throughput, cust_rpt_lab_tat, cust_rpt_crit_result_calls,
            cust_rpt_readmit_30d), written into one record keyed by facility.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
  001  2026-10-08  Naveen Kumar Kovi  Fill boarding, critical-call and readmission KPIs;
                                     apply test-patient and current-result rules to STAT %
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
declare lwbs_cd      = f8 with protect, constant(uar_get_code_by("MEANING", 19, "LWBS"))
declare expired_cd   = f8 with protect, constant(uar_get_code_by("MEANING", 19, "EXPIRED"))
declare critical_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 52, "CRITICAL"))
declare auth_cd      = f8 with protect, constant(uar_get_code_by("MEANING", 8, "AUTH"))
declare modified_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 8, "MODIFIED"))
declare notify_cd    = f8 with protect, constant(uar_get_code_by("DISPLAYKEY", 72, "CRITICALRESULTNOTIFICATION"))
declare now_dt       = dq8 with protect, constant(cnvtdatetime(curdate, curtime3))
declare readmit_end_dt = dq8 with protect, noconstant(cnvtdatetime($END_DT))
declare idx  = i4 with protect, noconstant(0)
declare pos  = i4 with protect, noconstant(0)
declare n    = i4 with protect, noconstant(0)
declare hit  = i4 with protect, noconstant(0)
declare bn   = i4 with protect, noconstant(0)
declare n_crit = i4 with protect, noconstant(0)
declare valid = i2 with protect, noconstant(0)
declare first_tat = f8 with protect, noconstant(0.0)

record med (                                   ; sorted boarding minutes for one facility
  1 v[*]
    2 m = f8
) with protect

if (readmit_end_dt > cnvtlookbehind("30,D", now_dt))      ; incomplete 30-day look-back otherwise
  set readmit_end_dt = cnvtlookbehind("30,D", now_dt)
endif

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

/* 1. ED visits and median boarding (same rules as cust_rpt_ed_throughput):
      visit = ED arrival, finished ED stay = first ENCNTR_LOC_HIST row has ended,
      boarding = admit decision -> left the ED, admitted (Inpatient) patients only, LWBS excluded */
select into "nl:"
  board = evaluate2(if (e.encntr_type_cd = inpatient_cd and e.disch_disposition_cd != lwbs_cd)
                      datetimediff(elh.end_effective_dt_tm, e.inpatient_admit_dt_tm, 4)
                    else -1.0 endif)
from encounter e
   , person p
   , encntr_loc_hist elh
plan e
  where e.arrive_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and e.active_ind = 1
join p
  where p.person_id = e.person_id
    and p.name_last_key != "ZZTEST*"
join elh
  where elh.encntr_id = e.encntr_id
    and elh.active_ind = 1
    and elh.beg_effective_dt_tm = (select min(h2.beg_effective_dt_tm) from encntr_loc_hist h2
                                   where h2.encntr_id = e.encntr_id and h2.active_ind = 1)
    and elh.end_effective_dt_tm < cnvtdatetime("31-DEC-2100 00:00:00")
order by e.loc_facility_cd, board                              ; sorted, so the median is a position
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n = 0  bn = 0
detail
  n = n + 1
  if (board >= 0)
    bn = bn + 1
    stat = alterlist(med->v, bn)
    med->v[bn].m = board
  endif
foot e.loc_facility_cd
  if (pos > 0)
    kpi->qual[pos].ed_visits = n
    if (bn > 0)
      kpi->qual[pos].ed_median_board_min = round((med->v[(bn + 1) / 2].m + med->v[(bn + 2) / 2].m) / 2.0, 0)
    endif
  endif
with nocounter

/* 2. STAT labs % within 60 min: order -> first verification, orders that still have a
      current Auth/Modified result (same rules as cust_rpt_lab_tat) */
select into "nl:"
from orders o
   , order_detail od
   , encounter e
   , person p
   , clinical_event ce
plan o
  where o.orig_order_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and o.order_status_cd = completed_cd
    and o.active_ind = 1
join od
  where od.order_id = o.order_id
    and od.oe_field_meaning = "COLLPRI"
    and od.oe_field_display_value = "STAT"
join e
  where e.encntr_id = o.encntr_id
    and e.active_ind = 1
join p
  where p.person_id = o.person_id
    and p.name_last_key != "ZZTEST*"
join ce
  where ce.order_id = o.order_id                                ; all versions: first verification
order by e.loc_facility_cd, o.order_id, ce.verified_dt_tm
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n = 0  hit = 0
head o.order_id
  first_tat = datetimediff(ce.verified_dt_tm, o.orig_order_dt_tm, 4)
  valid = 0
detail
  if (ce.valid_until_dt_tm > cnvtdatetime(now_dt) and ce.result_status_cd in (auth_cd, modified_cd))
    valid = 1
  endif
foot o.order_id
  if (valid = 1)
    n = n + 1
    if (first_tat <= 60) hit = hit + 1 endif
  endif
foot e.loc_facility_cd
  if (pos > 0 and n > 0) kpi->qual[pos].stat_pct_60 = round(100.0 * hit / n, 1) endif
with nocounter

/* 3. Critical results called within 30 min (same rules as cust_rpt_crit_result_calls) */
select into "nl:"
from clinical_event ce
   , encounter e
   , person p
   , clinical_event nt
plan ce
  where ce.verified_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and ce.normalcy_cd = critical_cd
    and ce.result_status_cd in (auth_cd, modified_cd)
    and ce.valid_until_dt_tm > cnvtdatetime(now_dt)
join e
  where e.encntr_id = ce.encntr_id
    and e.active_ind = 1
join p
  where p.person_id = ce.person_id
    and p.name_last_key != "ZZTEST*"
join nt                                                         ; the call may not be documented
  where nt.encntr_id = outerjoin(ce.encntr_id)
    and nt.event_cd = outerjoin(notify_cd)
    and nt.valid_until_dt_tm > outerjoin(cnvtdatetime(now_dt))
    and nt.event_end_dt_tm >= outerjoin(ce.verified_dt_tm)
    and nt.event_end_dt_tm <= outerjoin(cnvtlookahead("6,H", ce.verified_dt_tm))
order by e.loc_facility_cd, ce.clinical_event_id, nt.event_end_dt_tm
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n_crit = 0  hit = 0
head ce.clinical_event_id                                       ; first documented call wins
  n_crit = n_crit + 1
  if (nt.clinical_event_id > 0 and datetimediff(nt.event_end_dt_tm, ce.verified_dt_tm, 4) <= 30)
    hit = hit + 1
  endif
foot e.loc_facility_cd
  if (pos > 0 and n_crit > 0) kpi->qual[pos].crit_pct_30 = round(100.0 * hit / n_crit, 1) endif
with nocounter

/* 4. 30-day readmission rate (same rules as cust_rpt_readmit_30d). Index discharges are capped
      at today - 30 days so every stay has a full look-back. */
select into "nl:"
from encounter e
   , person p
   , encounter r
plan e
  where e.disch_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime(readmit_end_dt)
    and e.encntr_type_cd = inpatient_cd
    and e.disch_disposition_cd != expired_cd
    and e.active_ind = 1
join p
  where p.person_id = e.person_id
    and p.name_last_key != "ZZTEST*"
join r
  where r.person_id = outerjoin(e.person_id)
    and r.encntr_type_cd = outerjoin(inpatient_cd)
    and r.active_ind = outerjoin(1)
    and r.inpatient_admit_dt_tm > outerjoin(e.disch_dt_tm)
    and r.inpatient_admit_dt_tm <= outerjoin(cnvtlookahead("30,D", e.disch_dt_tm))
order by e.loc_facility_cd, e.encntr_id
head e.loc_facility_cd
  pos = locateval(idx, 1, kpi->fac_cnt, e.loc_facility_cd, kpi->qual[idx].facility_cd)
  n = 0  hit = 0
head e.encntr_id                                                ; each index stay once
  n = n + 1
  if (r.encntr_id > 0) hit = hit + 1 endif
foot e.loc_facility_cd
  if (pos > 0 and n > 0) kpi->qual[pos].readmit_pct = round(100.0 * hit / n, 1) endif
with nocounter

set kpi->status_data.status = "S"
set _memory_reply_string = cnvtrectojson(kpi)

end
go
