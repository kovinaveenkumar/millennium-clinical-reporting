/*****************************************************************************
  Program : cust_rpt_ed_throughput
  Purpose : ED throughput KPI by facility - visits, LWBS %, median ED LOS
            (discharged / admitted), median boarding, % over 4 hours.
  SQL twin: sql/reports/01_ed_throughput.sql   Spec: docs/report_specs.md#01
  Prompts : OUTDEV, START_DT, END_DT (ED arrival), FACILITY_CD (0 = all)
  Notes   : ED visit = arrive_dt_tm qualifies. Do NOT qualify on encntr_type_cd =
            EMERGENCY - admitted ED visits are converted to INPATIENT (see RCA).
            ED LOS = arrival -> end of first ENCNTR_LOC_HIST row.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_ed_throughput go
create program cust_rpt_ed_throughput

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
with OUTDEV, START_DT, END_DT, FACILITY_CD

declare inpatient_cd = f8 with protect, constant(uar_get_code_by("MEANING", 71, "INPATIENT"))
declare lwbs_cd      = f8 with protect, constant(uar_get_code_by("MEANING", 19, "LWBS"))
declare fac_parser   = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0)
  set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD)
endif

record rpt (
  1 cnt = i4
  1 qual[*]
    2 facility       = vc
    2 visits         = i4
    2 lwbs           = i4
    2 admitted       = i4
    2 over_4h        = i4
    2 seen           = i4
    2 med_los_dc     = f8
    2 med_los_adm    = f8
    2 med_board      = f8
) with protect

record tmp (                       ; per-facility work lists for medians
  1 dc[*]
    2 v = f8
  1 adm[*]
    2 v = f8
  1 brd[*]
    2 v = f8
) with protect

declare median(cnt = i4, which = i2) = f8 with protect   ; forward declaration (subroutine below)
declare dc_n = i4 with protect, noconstant(0)
declare adm_n = i4 with protect, noconstant(0)
declare brd_n = i4 with protect, noconstant(0)
declare los = f8 with protect, noconstant(0.0)

select into "nl:"
  facility = uar_get_code_display(e.loc_facility_cd)
from encounter e
   , person p
   , encntr_loc_hist elh
plan e
  where e.arrive_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and e.active_ind = 1
    and parser(fac_parser)
join p
  where p.person_id = e.person_id
    and p.name_last_key != "ZZTEST*"                       ; exclude test patients
join elh
  where elh.encntr_id = e.encntr_id
    and elh.active_ind = 1
    and elh.beg_effective_dt_tm = (select min(h2.beg_effective_dt_tm) from encntr_loc_hist h2
                                   where h2.encntr_id = e.encntr_id and h2.active_ind = 1)
    and elh.end_effective_dt_tm < cnvtdatetime("31-DEC-2100 00:00:00")   ; left the ED
order by facility, e.encntr_id
head report
  rpt->cnt = 0
head facility
  rpt->cnt = rpt->cnt + 1
  stat = alterlist(rpt->qual, rpt->cnt)
  rpt->qual[rpt->cnt].facility = facility
  dc_n = 0  adm_n = 0  brd_n = 0
detail
  rpt->qual[rpt->cnt].visits = rpt->qual[rpt->cnt].visits + 1
  los = datetimediff(elh.end_effective_dt_tm, e.arrive_dt_tm, 4)        ; 4 = minutes
  if (e.disch_disposition_cd = lwbs_cd)
    rpt->qual[rpt->cnt].lwbs = rpt->qual[rpt->cnt].lwbs + 1
  else
    rpt->qual[rpt->cnt].seen = rpt->qual[rpt->cnt].seen + 1
    if (los > 240) rpt->qual[rpt->cnt].over_4h = rpt->qual[rpt->cnt].over_4h + 1 endif
    if (e.encntr_type_cd = inpatient_cd)
      rpt->qual[rpt->cnt].admitted = rpt->qual[rpt->cnt].admitted + 1
      adm_n = adm_n + 1  stat = alterlist(tmp->adm, adm_n)  tmp->adm[adm_n].v = los
      brd_n = brd_n + 1  stat = alterlist(tmp->brd, brd_n)
      tmp->brd[brd_n].v = datetimediff(elh.end_effective_dt_tm, e.inpatient_admit_dt_tm, 4)
    else
      dc_n = dc_n + 1  stat = alterlist(tmp->dc, dc_n)  tmp->dc[dc_n].v = los
    endif
  endif
foot facility
  rpt->qual[rpt->cnt].med_los_dc  = median(dc_n, 1)
  rpt->qual[rpt->cnt].med_los_adm = median(adm_n, 2)
  rpt->qual[rpt->cnt].med_board   = median(brd_n, 3)
with nocounter

/* median of the first cnt values of a work list (sorts in place) */
subroutine median(cnt, which)
  declare i = i4 with private
  declare j = i4 with private
  declare t = f8 with private
  if (cnt = 0) return(0.0) endif
  for (i = 2 to cnt)                       ; insertion sort - lists are one facility at a time
    set j = i
    while (j > 1 and evaluate(which, 1, tmp->dc[j - 1].v, 2, tmp->adm[j - 1].v, tmp->brd[j - 1].v)
                   > evaluate(which, 1, tmp->dc[j].v, 2, tmp->adm[j].v, tmp->brd[j].v))
      if (which = 1) set t = tmp->dc[j].v  set tmp->dc[j].v = tmp->dc[j - 1].v  set tmp->dc[j - 1].v = t
      elseif (which = 2) set t = tmp->adm[j].v  set tmp->adm[j].v = tmp->adm[j - 1].v  set tmp->adm[j - 1].v = t
      else set t = tmp->brd[j].v  set tmp->brd[j].v = tmp->brd[j - 1].v  set tmp->brd[j - 1].v = t
      endif
      set j = j - 1
    endwhile
  endfor
  set i = (cnt + 1) / 2
  set j = (cnt + 2) / 2
  return((evaluate(which, 1, tmp->dc[i].v, 2, tmp->adm[i].v, tmp->brd[i].v)
        + evaluate(which, 1, tmp->dc[j].v, 2, tmp->adm[j].v, tmp->brd[j].v)) / 2.0)
end

/* grid output to the prompt's output device */
select into $OUTDEV
  facility                  = substring(1, 30, rpt->qual[d.seq].facility)
, ed_visits                 = rpt->qual[d.seq].visits
, lwbs_pct                  = round(100.0 * rpt->qual[d.seq].lwbs / rpt->qual[d.seq].visits, 1)
, admit_pct                 = round(100.0 * rpt->qual[d.seq].admitted / rpt->qual[d.seq].visits, 1)
, median_los_discharged_min = round(rpt->qual[d.seq].med_los_dc, 0)
, median_los_admitted_min   = round(rpt->qual[d.seq].med_los_adm, 0)
, median_boarding_min       = round(rpt->qual[d.seq].med_board, 0)
, pct_over_4h               = round(100.0 * rpt->qual[d.seq].over_4h / rpt->qual[d.seq].seen, 1)
from (dummyt d with seq = value(rpt->cnt))
plan d
order by median_boarding_min desc
with nocounter, format, separator = " "

end
go
