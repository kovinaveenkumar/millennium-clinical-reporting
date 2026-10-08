/*****************************************************************************
  Program : cust_rpt_midnight_census
  Purpose : Midnight census and occupancy vs staffed beds, by nurse unit and day.
  SQL twin: sql/reports/05_census.sql
  Prompts : OUTDEV, START_DT, END_DT (census dates), FACILITY_CD
  Notes   : One pass over ENCNTR_LOC_HIST: each segment adds 1 to every midnight it
            covers (beg <= 00:00 < end). Same result as a per-day range join, without
            rescanning history once per day. Staffed beds: CUST_UNIT_CAPACITY.
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release
*****************************************************************************/
drop program cust_rpt_midnight_census go
create program cust_rpt_midnight_census

prompt
    "Output to File/Printer/MINE" = "MINE"
  , "Start Date"                  = "CURDATE"
  , "End Date"                    = "CURDATE"
  , "Facility (0 = all)"          = 0.0
with OUTDEV, START_DT, END_DT, FACILITY_CD

declare start_dt  = dq8 with protect, constant(cnvtdatetime(cnvtdate(cnvtdatetime($START_DT)), 0))   ; 00:00 on start
declare end_dt    = dq8 with protect, constant(cnvtdatetime(cnvtdate(cnvtdatetime($END_DT)), 0))     ; 00:00 on end
declare day_cnt   = i4  with protect, constant(datetimediff(end_dt, start_dt, 1) + 1)
declare fac_parser = vc with protect, noconstant("1 = 1")
declare m = dq8 with protect
declare k = i4 with protect
if ($FACILITY_CD > 0.0) set fac_parser = build2("cap.loc_facility_cd = ", $FACILITY_CD) endif

record cen (
  1 unit_cnt = i4
  1 unit[*]
    2 unit_cd = f8
    2 name    = vc
    2 beds    = i4
    2 day[*]
      3 census = i4
) with protect

/* units in scope + their staffed beds */
select into "nl:"
from cust_unit_capacity cap
plan cap
  where parser(fac_parser)
order by cap.loc_nurse_unit_cd
detail
  cen->unit_cnt = cen->unit_cnt + 1
  stat = alterlist(cen->unit, cen->unit_cnt)
  cen->unit[cen->unit_cnt].unit_cd = cap.loc_nurse_unit_cd
  cen->unit[cen->unit_cnt].name    = uar_get_code_display(cap.loc_nurse_unit_cd)
  cen->unit[cen->unit_cnt].beds    = cap.staffed_beds
  stat = alterlist(cen->unit[cen->unit_cnt].day, day_cnt)
with nocounter

/* one pass over location segments that overlap the date range */
select into "nl:"
from encntr_loc_hist elh
   , (dummyt d with seq = value(cen->unit_cnt))
plan d
join elh
  where elh.loc_nurse_unit_cd = cen->unit[d.seq].unit_cd
    and elh.beg_effective_dt_tm <= cnvtdatetime(end_dt)
    and elh.end_effective_dt_tm >  cnvtdatetime(start_dt)
    and elh.active_ind = 1
detail
  m = cnvtdatetime(cnvtdate(elh.beg_effective_dt_tm), 0)               ; midnight on/after beg
  if (m < elh.beg_effective_dt_tm) m = cnvtlookahead("1,D", m) endif
  if (m < start_dt) m = start_dt endif
  while (m < elh.end_effective_dt_tm and m <= end_dt)
    k = datetimediff(m, start_dt, 1) + 1
    cen->unit[d.seq].day[k].census = cen->unit[d.seq].day[k].census + 1
    m = cnvtlookahead("1,D", m)
  endwhile
with nocounter

select into $OUTDEV
  nurse_unit    = substring(1, 25, cen->unit[d1.seq].name)
, census_date   = format(cnvtlookahead(build(d2.seq - 1, ",D"), start_dt), "MM/DD/YYYY;;D")
, staffed_beds  = cen->unit[d1.seq].beds
, census        = cen->unit[d1.seq].day[d2.seq].census
, occupancy_pct = round(100.0 * cen->unit[d1.seq].day[d2.seq].census / cen->unit[d1.seq].beds, 1)
from (dummyt d1 with seq = value(cen->unit_cnt))
   , (dummyt d2 with seq = value(day_cnt))
plan d1
join d2
with nocounter, format, separator = " "

end
go
