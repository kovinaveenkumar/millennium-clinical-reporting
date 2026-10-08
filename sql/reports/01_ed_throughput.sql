-- =====================================================================
-- Report 01  ED Throughput (KPI)
-- Prompts : :start_dt, :end_dt (ED arrival date), :facility_cd (0 = all)
-- Grain   : one row per facility
-- Rules   : ED visit = encounter with arrive_dt_tm (ED arrival). Do NOT qualify on
--           encntr_type_cd = EMERGENCY: admitted ED patients are converted to INPATIENT
--           on the same encntr_id and would be dropped (see docs/data_model.md).
--           ED length of stay = arrival -> end of the first ENCNTR_LOC_HIST segment (ED).
--           Boarding = inpatient admit decision -> left the ED.
--           Excludes: cancelled registrations (active_ind = 0), test patients (ZZTEST),
--           visits still in the ED at the data cut.
-- =====================================================================
-- name: ed_throughput
WITH ed AS (
  SELECT e.encntr_id,
         fac.display                                                    AS facility,
         COALESCE(disp.cdf_meaning, 'IN HOUSE')                         AS disposition,
         CASE WHEN et.cdf_meaning = 'INPATIENT' THEN 1 ELSE 0 END       AS admitted,
         (julianday(h.end_effective_dt_tm) - julianday(e.arrive_dt_tm)) * 1440 AS ed_los_min,
         CASE WHEN et.cdf_meaning = 'INPATIENT'
              THEN (julianday(h.end_effective_dt_tm) - julianday(e.inpatient_admit_dt_tm)) * 1440 END AS boarding_min
  FROM encounter e
  JOIN person p          ON p.person_id = e.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value et     ON et.code_value = e.encntr_type_cd
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  LEFT JOIN code_value disp ON disp.code_value = e.disch_disposition_cd
  JOIN encntr_loc_hist h ON h.encntr_id = e.encntr_id AND h.active_ind = 1
                        AND h.beg_effective_dt_tm = (SELECT MIN(h2.beg_effective_dt_tm) FROM encntr_loc_hist h2
                                                     WHERE h2.encntr_id = e.encntr_id AND h2.active_ind = 1)
  WHERE e.active_ind = 1
    AND e.arrive_dt_tm >= :start_dt AND e.arrive_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
    AND h.end_effective_dt_tm < '2100-01-01'
),
seen AS (SELECT * FROM ed WHERE disposition <> 'LWBS'),
los_rank AS (
  SELECT facility, admitted, ed_los_min,
         ROW_NUMBER() OVER (PARTITION BY facility, admitted ORDER BY ed_los_min) AS rn,
         COUNT(*)     OVER (PARTITION BY facility, admitted)                     AS n
  FROM seen
),
los_med AS (SELECT facility, admitted, AVG(ed_los_min) AS med FROM los_rank
            WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY facility, admitted),
board_rank AS (
  SELECT facility, boarding_min,
         ROW_NUMBER() OVER (PARTITION BY facility ORDER BY boarding_min) AS rn,
         COUNT(*)     OVER (PARTITION BY facility)                       AS n
  FROM seen WHERE admitted = 1
),
board_med AS (SELECT facility, AVG(boarding_min) AS med FROM board_rank
              WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY facility)
SELECT ed.facility,
       COUNT(*)                                                         AS ed_visits,
       ROUND(100.0 * SUM(ed.disposition = 'LWBS') / COUNT(*), 1)        AS lwbs_pct,
       ROUND(100.0 * SUM(ed.admitted) / COUNT(*), 1)                    AS admit_pct,
       ROUND(MAX(CASE WHEN m.admitted = 0 THEN m.med END), 0)           AS median_los_discharged_min,
       ROUND(MAX(CASE WHEN m.admitted = 1 THEN m.med END), 0)           AS median_los_admitted_min,
       ROUND(MAX(b.med), 0)                                             AS median_boarding_min,
       ROUND(100.0 * SUM(ed.disposition <> 'LWBS' AND ed.ed_los_min > 240)
                   / SUM(ed.disposition <> 'LWBS'), 1)                  AS pct_over_4h
FROM ed
LEFT JOIN los_med m   ON m.facility = ed.facility AND m.admitted = ed.admitted
LEFT JOIN board_med b ON b.facility = ed.facility
GROUP BY ed.facility
ORDER BY median_boarding_min DESC;
