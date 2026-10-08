/*****************************************************************************
  Program : cust_rpt_readmit_30d
  Purpose : 30-day all-cause inpatient readmission rate by discharging facility
            and discharge disposition.
  SQL twin: sql/reports/04_readmissions.sql
  Prompts : OUTDEV, START_DT, END_DT (index discharge), FACILITY_CD
  Notes   : Index = INPATIENT encounter discharged in range, disposition not Expired.
            Readmit = any later INPATIENT admission (any facility) within 30 days.
            END_DT must be <= today - 30 days or the look-back is incomplete.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_readmit_30d go
create program cust_rpt_readmit_30d

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
with OUTDEV, START_DT, END_DT, FACILITY_CD

declare inpatient_cd = f8 with protect, constant(uar_get_code_by("MEANING", 71, "INPATIENT"))
declare expired_cd   = f8 with protect, constant(uar_get_code_by("MEANING", 19, "EXPIRED"))
declare fac_parser   = vc with protect, noconstant("1 = 1")
if ($FACILITY_CD > 0.0) set fac_parser = build2("e.loc_facility_cd = ", $FACILITY_CD) endif

if (cnvtdatetime($END_DT) > cnvtlookbehind("30,D", cnvtdatetime(curdate, curtime3)))
  select into $OUTDEV
    msg = "End date must be at least 30 days ago so every discharge has a full 30-day look-back."
  from dummyt d
  with nocounter, format
  go to exit_script
endif

select into $OUTDEV
  facility    = substring(1, 25, uar_get_code_display(e.loc_facility_cd))
, disposition = substring(1, 30, uar_get_code_display(e.disch_disposition_cd))
, readmit     = evaluate2(if (r.encntr_id > 0) 1 else 0 endif)
from encounter e
   , person p
   , encounter r
plan e
  where e.disch_dt_tm between cnvtdatetime($START_DT) and cnvtdatetime($END_DT)
    and e.encntr_type_cd = inpatient_cd
    and e.disch_disposition_cd != expired_cd
    and e.active_ind = 1
    and parser(fac_parser)
join p
  where p.person_id = e.person_id
    and p.name_last_key != "ZZTEST*"
join r                                                       ; next admission, may not exist
  where r.person_id = outerjoin(e.person_id)
    and r.encntr_type_cd = outerjoin(inpatient_cd)
    and r.active_ind = outerjoin(1)
    and r.inpatient_admit_dt_tm > outerjoin(e.disch_dt_tm)
    and r.inpatient_admit_dt_tm <= outerjoin(cnvtlookahead("30,D", e.disch_dt_tm))
order by facility, disposition, e.encntr_id, r.inpatient_admit_dt_tm
head report
  col 0 "facility" col 27 "disposition" col 59 "index" col 67 "readmits" col 78 "rate_pct"
  row + 1
head disposition
  idx = 0  rdm = 0
head e.encntr_id                                             ; count each index stay once
  idx = idx + 1
  if (r.encntr_id > 0) rdm = rdm + 1 endif
foot disposition
  col 0 facility col 27 disposition col 59 idx "#####" col 67 rdm "#####" col 78 (100.0 * rdm / idx) "###.#"
  row + 1
with nocounter, maxcol = 100

#exit_script
end
go
