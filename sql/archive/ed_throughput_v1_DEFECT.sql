-- ARCHIVED v1 of Report 01 - kept for the RCA in docs/rca.md. DO NOT USE.
-- Defect: qualifies ED visits on encntr_type_cd = EMERGENCY. Millennium converts an admitted ED
-- patient's encounter to INPATIENT on the same encntr_id, so every admitted ED visit is dropped
-- and the admitted patients - the ones with the longest ED stays - disappear from LOS.
-- name: ed_throughput_v1
SELECT fac.display AS facility, COUNT(*) AS ed_visits,
       ROUND(AVG((julianday(e.disch_dt_tm) - julianday(e.arrive_dt_tm)) * 1440), 0) AS avg_los_min,
       ROUND(100.0 * SUM((julianday(e.disch_dt_tm) - julianday(e.arrive_dt_tm)) * 1440 > 240) / COUNT(*), 1) AS pct_over_4h
FROM encounter e
JOIN code_value et  ON et.code_value = e.encntr_type_cd AND et.cdf_meaning = 'EMERGENCY'
JOIN code_value fac ON fac.code_value = e.loc_facility_cd
WHERE e.arrive_dt_tm >= :start_dt AND e.arrive_dt_tm < date(:end_dt, '+1 day')
  AND e.disch_dt_tm IS NOT NULL
GROUP BY fac.display ORDER BY fac.display;
