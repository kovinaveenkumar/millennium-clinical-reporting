/*****************************************************************************
  Program : cust_rpt_crit_result_calls
  Purpose : Critical lab result notification compliance - % of critical results
            with a documented read-back call within 30 min, by facility / unit,
            plus a worklist of the ones that were late or never documented.
  SQL twin: sql/reports/03_critical_results.sql
  Prompts : OUTDEV, START_DT, END_DT (result verified), FACILITY_CD, DETAIL_IND
  Notes   : - Current version only (valid_until_dt_tm > now), status Auth/Modified.
            - Unit = point-in-time ENCNTR_LOC_HIST row covering the verify time.
            - Notification = first "Critical Result Notification" clinical event on
              the encounter within 6 h after verification (OUTERJOIN: may not exist).
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_crit_result_calls go
create program cust_rpt_crit_result_calls

prompt
    "Output to File/Printer/MINE"        = "MINE"
  , "Start Date"                         = "CURDATE"
  , "End Date"                           = "CURDATE"
  , "Facility (0 = all)"                 = 0.0
  , "Detail worklist (1) or summary (0)" = 0
with OUTDEV, START_DT, END_DT, FACILITY_CD, DETAIL_IND

declare critical_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 52, "CRITICAL"))
declare auth_cd      = f8 with protect, constant(uar_get_code_by("MEANING", 8, "AUTH"))
declare modified_cd  = f8 with protect, constant(uar_get_code_by("MEANING", 8, "MODIFIED"))
declare notify_cd    = f8 with protect, constant(uar_get_code_by("DISPLAYKEY", 72, "CRITICALRESULTNOTIFICATION"))
declare fin_cd       = f8 with protect, constant(uar_get_code_by("MEANING", 319, "FIN NBR"))
declare now_dt       = dq8 with protect, constant(cnvtdatetime(curdate, curtime3))
declare fac_parser   = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0) set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD) endif

record crit (
  1 cnt = i4
  1 qual[*]
    2 facility   = vc
    2 unit       = vc
    2 fin        = vc
    2 result     = vc
    2 value      = vc
    2 verified   = dq8
    2 notify_min = f8      ; -1 = not documented
) with protect

select into "nl:"
from clinical_event ce
   , encounter e
   , person p
   , encntr_loc_hist elh
   , encntr_alias ea
   , clinical_event n
plan ce
  where ce.verified_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and ce.normalcy_cd = critical_cd
    and ce.result_status_cd in (auth_cd, modified_cd)
    and ce.valid_until_dt_tm > cnvtdatetime(now_dt)               ; current version only
join e
  where e.encntr_id = ce.encntr_id
    and e.active_ind = 1
    and parser(fac_parser)
join p
  where p.person_id = ce.person_id
    and p.name_last_key != "ZZTEST*"
join elh                                                          ; where was the patient at verify time
  where elh.encntr_id = ce.encntr_id
    and elh.active_ind = 1
    and elh.beg_effective_dt_tm <= ce.verified_dt_tm
    and elh.end_effective_dt_tm >  ce.verified_dt_tm
join ea
  where ea.encntr_id = e.encntr_id
    and ea.encntr_alias_type_cd = fin_cd
    and ea.active_ind = 1
join n                                                            ; notification may not exist
  where n.encntr_id = outerjoin(ce.encntr_id)
    and n.event_cd = outerjoin(notify_cd)
    and n.valid_until_dt_tm > outerjoin(cnvtdatetime(now_dt))
    and n.event_end_dt_tm >= outerjoin(ce.verified_dt_tm)
    and n.event_end_dt_tm <= outerjoin(cnvtlookahead("6,H", ce.verified_dt_tm))
order by ce.clinical_event_id, n.event_end_dt_tm
head report
  crit->cnt = 0
head ce.clinical_event_id                                         ; first notification row wins
  crit->cnt = crit->cnt + 1
  if (mod(crit->cnt, 100) = 1) stat = alterlist(crit->qual, crit->cnt + 99) endif
  crit->qual[crit->cnt].facility = uar_get_code_display(e.loc_facility_cd)
  crit->qual[crit->cnt].unit     = uar_get_code_display(elh.loc_nurse_unit_cd)
  crit->qual[crit->cnt].fin      = ea.alias
  crit->qual[crit->cnt].result   = uar_get_code_display(ce.event_cd)
  crit->qual[crit->cnt].value    = ce.result_val
  crit->qual[crit->cnt].verified = ce.verified_dt_tm
  if (n.clinical_event_id > 0)
    crit->qual[crit->cnt].notify_min = datetimediff(n.event_end_dt_tm, ce.verified_dt_tm, 4)
  else
    crit->qual[crit->cnt].notify_min = -1
  endif
foot report
  stat = alterlist(crit->qual, crit->cnt)
with nocounter

if ($DETAIL_IND = 1)
  /* worklist: late or undocumented calls */
  select into $OUTDEV
    facility        = substring(1, 20, crit->qual[d.seq].facility)
  , nurse_unit      = substring(1, 20, crit->qual[d.seq].unit)
  , fin             = substring(1, 15, crit->qual[d.seq].fin)
  , result_name     = substring(1, 20, crit->qual[d.seq].result)
  , result_val      = substring(1, 10, crit->qual[d.seq].value)
  , verified        = format(crit->qual[d.seq].verified, "MM/DD/YYYY HH:MM;;D")
  , minutes_to_call = evaluate2(if (crit->qual[d.seq].notify_min < 0) "NOT DOCUMENTED"
                                else trim(cnvtstring(crit->qual[d.seq].notify_min)) endif)
  from (dummyt d with seq = value(crit->cnt))
  plan d
    where crit->qual[d.seq].notify_min < 0 or crit->qual[d.seq].notify_min > 30
  order by crit->qual[d.seq].verified desc
  with nocounter, format, separator = " "
else
  /* summary by facility / unit */
  select into $OUTDEV
    facility   = substring(1, 20, crit->qual[d.seq].facility)
  , nurse_unit = substring(1, 20, crit->qual[d.seq].unit)
  from (dummyt d with seq = value(crit->cnt))
  plan d
  order by facility, nurse_unit
  head report
    col 0 "facility" col 22 "nurse_unit" col 44 "critical" col 54 "within_30" col 66 "not_doc" col 76 "pct_within_30"
    row + 1
  head nurse_unit
    tot = 0  ok30 = 0  nodoc = 0
  detail
    tot = tot + 1
    if (crit->qual[d.seq].notify_min < 0) nodoc = nodoc + 1
    elseif (crit->qual[d.seq].notify_min <= 30) ok30 = ok30 + 1
    endif
  foot nurse_unit
    col 0 facility col 22 nurse_unit col 44 tot "#####" col 54 ok30 "#####" col 66 nodoc "####"
    col 76 (100.0 * ok30 / tot) "###.#"
    row + 1
  with nocounter, maxcol = 120
endif

end
go
