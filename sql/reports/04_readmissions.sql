-- =====================================================================
-- Report 04  30-Day Inpatient Readmissions (KPI)
-- Prompts : :start_dt, :end_dt (index DISCHARGE date), :facility_cd (0 = all), :as_of
-- Rules   : Index stay = INPATIENT encounter discharged in range, not Expired.
--           Readmission = any later INPATIENT admission for the same person (any facility in the
--           system) within 30 days of the index discharge; attributed to the discharging facility.
--           Uses inpatient_admit_dt_tm (for ED admits this is the admit decision, not ED arrival).
--           Look-back must be complete: index discharges after (:as_of - 30 days) are excluded.
--           Not risk-adjusted; planned readmissions are not removed (see report spec).
-- =====================================================================
-- name: readmit_by_facility
WITH idx AS (
  SELECT e.encntr_id, e.person_id, e.disch_dt_tm, fac.display AS facility, disp.display AS disposition,
         EXISTS (SELECT 1 FROM encounter r
                 JOIN code_value rt ON rt.code_value = r.encntr_type_cd AND rt.cdf_meaning = 'INPATIENT'
                 WHERE r.person_id = e.person_id AND r.active_ind = 1 AND r.encntr_id <> e.encntr_id
                   AND r.inpatient_admit_dt_tm > e.disch_dt_tm
                   AND r.inpatient_admit_dt_tm <= datetime(e.disch_dt_tm, '+30 days')) AS readmit_30d
  FROM encounter e
  JOIN code_value et   ON et.code_value = e.encntr_type_cd AND et.cdf_meaning = 'INPATIENT'
  JOIN code_value disp ON disp.code_value = e.disch_disposition_cd AND disp.cdf_meaning <> 'EXPIRED'
  JOIN code_value fac  ON fac.code_value = e.loc_facility_cd
  JOIN person p        ON p.person_id = e.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  WHERE e.active_ind = 1
    AND e.disch_dt_tm >= :start_dt AND e.disch_dt_tm < date(:end_dt, '+1 day')
    AND e.disch_dt_tm <= datetime(:as_of, '-30 days')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
)
SELECT facility, COUNT(*) AS index_discharges, SUM(readmit_30d) AS readmits_30d,
       ROUND(100.0 * SUM(readmit_30d) / COUNT(*), 1) AS readmit_rate_pct
FROM idx GROUP BY facility ORDER BY readmit_rate_pct DESC;

-- name: readmit_by_disposition
WITH idx AS (
  SELECT fac.display AS facility, disp.display AS disposition,
         EXISTS (SELECT 1 FROM encounter r
                 JOIN code_value rt ON rt.code_value = r.encntr_type_cd AND rt.cdf_meaning = 'INPATIENT'
                 WHERE r.person_id = e.person_id AND r.active_ind = 1 AND r.encntr_id <> e.encntr_id
                   AND r.inpatient_admit_dt_tm > e.disch_dt_tm
                   AND r.inpatient_admit_dt_tm <= datetime(e.disch_dt_tm, '+30 days')) AS readmit_30d
  FROM encounter e
  JOIN code_value et   ON et.code_value = e.encntr_type_cd AND et.cdf_meaning = 'INPATIENT'
  JOIN code_value disp ON disp.code_value = e.disch_disposition_cd AND disp.cdf_meaning <> 'EXPIRED'
  JOIN code_value fac  ON fac.code_value = e.loc_facility_cd
  JOIN person p        ON p.person_id = e.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  WHERE e.active_ind = 1
    AND e.disch_dt_tm >= :start_dt AND e.disch_dt_tm < date(:end_dt, '+1 day')
    AND e.disch_dt_tm <= datetime(:as_of, '-30 days')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
)
SELECT facility, disposition, COUNT(*) AS index_discharges, SUM(readmit_30d) AS readmits_30d,
       ROUND(100.0 * SUM(readmit_30d) / COUNT(*), 1) AS readmit_rate_pct
FROM idx GROUP BY facility, disposition ORDER BY facility, readmit_rate_pct DESC;
