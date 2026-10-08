-- =====================================================================
-- Report 05  Midnight Census & Occupancy by Nurse Unit (operational)
-- Prompts : :start_dt, :end_dt (census date), :facility_cd (0 = all)
-- Rules   : Patient counted on a unit at 00:00 if an active ENCNTR_LOC_HIST segment covers
--           midnight (beg <= 00:00 < end). Staffed beds from CUST_UNIT_CAPACITY (site table).
--           Days are generated with a recursive CTE (no calendar table needed).
-- =====================================================================
-- name: census_daily
WITH RECURSIVE days(census_dt) AS (
  SELECT datetime(:start_dt)
  UNION ALL SELECT datetime(census_dt, '+1 day') FROM days WHERE census_dt < datetime(:end_dt)
)
SELECT fac.display AS facility, unit.display AS nurse_unit, date(d.census_dt) AS census_date,
       cap.staffed_beds,
       COUNT(h.encntr_loc_hist_id) AS census,
       ROUND(100.0 * COUNT(h.encntr_loc_hist_id) / cap.staffed_beds, 1) AS occupancy_pct
FROM days d
CROSS JOIN cust_unit_capacity cap
JOIN code_value unit ON unit.code_value = cap.loc_nurse_unit_cd
JOIN code_value fac  ON fac.code_value = cap.loc_facility_cd
LEFT JOIN encntr_loc_hist h ON h.loc_nurse_unit_cd = cap.loc_nurse_unit_cd AND h.active_ind = 1
                           AND h.beg_effective_dt_tm <= d.census_dt AND h.end_effective_dt_tm > d.census_dt
WHERE (:facility_cd = 0 OR cap.loc_facility_cd = :facility_cd)
GROUP BY fac.display, unit.display, d.census_dt, cap.staffed_beds
ORDER BY facility, nurse_unit, census_date;

-- name: census_summary
WITH RECURSIVE days(census_dt) AS (
  SELECT datetime(:start_dt)
  UNION ALL SELECT datetime(census_dt, '+1 day') FROM days WHERE census_dt < datetime(:end_dt)
),
daily AS (
  SELECT cap.loc_facility_cd, cap.loc_nurse_unit_cd, cap.staffed_beds, d.census_dt,
         COUNT(h.encntr_loc_hist_id) AS census
  FROM days d
  CROSS JOIN cust_unit_capacity cap
  -- "+h.active_ind": unary plus stops the planner from building an index on the low-cardinality
  -- active_ind column and makes it use xie_elh_unit instead (2.9 s -> 0.08 s, docs/performance_tuning.md)
  LEFT JOIN encntr_loc_hist h ON h.loc_nurse_unit_cd = cap.loc_nurse_unit_cd AND +h.active_ind = 1
                             AND h.beg_effective_dt_tm <= d.census_dt AND h.end_effective_dt_tm > d.census_dt
  WHERE (:facility_cd = 0 OR cap.loc_facility_cd = :facility_cd)
  GROUP BY cap.loc_nurse_unit_cd, d.census_dt
)
SELECT fac.display AS facility, unit.display AS nurse_unit, daily.staffed_beds,
       ROUND(AVG(census), 1)                                        AS avg_census,
       MAX(census)                                                  AS peak_census,
       ROUND(100.0 * AVG(census) / daily.staffed_beds, 1)           AS avg_occupancy_pct,
       SUM(census >= 0.95 * daily.staffed_beds)                     AS days_at_95pct_plus,
       COUNT(*)                                                     AS days
FROM daily
JOIN code_value unit ON unit.code_value = daily.loc_nurse_unit_cd
JOIN code_value fac  ON fac.code_value = daily.loc_facility_cd
GROUP BY fac.display, unit.display, daily.staffed_beds
ORDER BY avg_occupancy_pct DESC;
