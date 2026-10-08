-- =====================================================================
-- Report 03  Critical Result Notification Compliance (KPI + worklist)
-- Prompts : :start_dt, :end_dt (result verified date), :facility_cd (0 = all), :as_of
-- Rules   : Critical result = CURRENT clinical_event row (valid_until_dt_tm > :as_of),
--           normalcy CRITICAL, status AUTH/MODIFIED.
--           Notification = first "Critical Result Notification" event documented on the same
--           encounter within 6 h after verification. Target: <= 30 min.
--           Unit = where the patient was when the result verified (point-in-time join to
--           ENCNTR_LOC_HIST: beg <= verified < end).
-- =====================================================================
-- name: critical_compliance
WITH crit AS (
  SELECT ce.clinical_event_id, ce.encntr_id, ce.verified_dt_tm, fac.display AS facility, unit.display AS nurse_unit,
         (SELECT (julianday(MIN(n.event_end_dt_tm)) - julianday(ce.verified_dt_tm)) * 1440
          FROM clinical_event n
          JOIN code_value nc ON nc.code_value = n.event_cd AND nc.display = 'Critical Result Notification'
          WHERE n.encntr_id = ce.encntr_id AND n.valid_until_dt_tm > :as_of
            AND n.event_end_dt_tm >= ce.verified_dt_tm
            AND n.event_end_dt_tm <= datetime(ce.verified_dt_tm, '+6 hours'))   AS notify_min
  FROM clinical_event ce
  JOIN code_value nrm    ON nrm.code_value = ce.normalcy_cd AND nrm.cdf_meaning = 'CRITICAL'
  JOIN code_value rs     ON rs.code_value = ce.result_status_cd AND rs.cdf_meaning IN ('AUTH', 'MODIFIED')
  JOIN encounter e       ON e.encntr_id = ce.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = ce.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN encntr_loc_hist h ON h.encntr_id = ce.encntr_id AND h.active_ind = 1
                        AND h.beg_effective_dt_tm <= ce.verified_dt_tm AND h.end_effective_dt_tm > ce.verified_dt_tm
  JOIN code_value unit   ON unit.code_value = h.loc_nurse_unit_cd
  WHERE ce.valid_until_dt_tm > :as_of
    AND ce.verified_dt_tm >= :start_dt AND ce.verified_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
),
ranked AS (
  -- NULLS LAST: undocumented calls (NULL) must not take the first positions, or the median shifts
  SELECT *, ROW_NUMBER() OVER (PARTITION BY facility, nurse_unit ORDER BY notify_min NULLS LAST) AS rn,
            COUNT(notify_min) OVER (PARTITION BY facility, nurse_unit)              AS n
  FROM crit
)
SELECT facility, nurse_unit,
       COUNT(*)                                                    AS critical_results,
       SUM(notify_min <= 30)                                       AS notified_30min,
       SUM(notify_min IS NULL)                                     AS not_documented,
       ROUND(100.0 * SUM(notify_min <= 30) / COUNT(*), 1)          AS pct_within_30,
       ROUND(AVG(CASE WHEN notify_min IS NOT NULL AND rn IN ((n + 1) / 2, (n + 2) / 2) THEN notify_min END), 0) AS median_notify_min
FROM ranked
GROUP BY facility, nurse_unit
ORDER BY pct_within_30;

-- name: critical_worklist
-- Operational worklist for nurse managers: every critical result NOT called within 30 minutes.
WITH crit AS (
  SELECT ce.clinical_event_id, ce.encntr_id, ce.person_id, ce.event_cd, ce.result_val, ce.verified_dt_tm,
         fac.display AS facility, unit.display AS nurse_unit,
         (SELECT (julianday(MIN(n.event_end_dt_tm)) - julianday(ce.verified_dt_tm)) * 1440
          FROM clinical_event n
          JOIN code_value nc ON nc.code_value = n.event_cd AND nc.display = 'Critical Result Notification'
          WHERE n.encntr_id = ce.encntr_id AND n.valid_until_dt_tm > :as_of
            AND n.event_end_dt_tm >= ce.verified_dt_tm
            AND n.event_end_dt_tm <= datetime(ce.verified_dt_tm, '+6 hours'))   AS notify_min
  FROM clinical_event ce
  JOIN code_value nrm    ON nrm.code_value = ce.normalcy_cd AND nrm.cdf_meaning = 'CRITICAL'
  JOIN code_value rs     ON rs.code_value = ce.result_status_cd AND rs.cdf_meaning IN ('AUTH', 'MODIFIED')
  JOIN encounter e       ON e.encntr_id = ce.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = ce.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN encntr_loc_hist h ON h.encntr_id = ce.encntr_id AND h.active_ind = 1
                        AND h.beg_effective_dt_tm <= ce.verified_dt_tm AND h.end_effective_dt_tm > ce.verified_dt_tm
  JOIN code_value unit   ON unit.code_value = h.loc_nurse_unit_cd
  WHERE ce.valid_until_dt_tm > :as_of
    AND ce.verified_dt_tm >= :start_dt AND ce.verified_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
)
SELECT c.facility, c.nurse_unit, ea.alias AS fin, pa.alias AS mrn, ev.display AS result_name, c.result_val,
       c.verified_dt_tm,
       COALESCE(CAST(CAST(ROUND(c.notify_min) AS INTEGER) AS TEXT), 'NOT DOCUMENTED') AS minutes_to_call
FROM crit c
JOIN code_value ev   ON ev.code_value = c.event_cd
JOIN encntr_alias ea ON ea.encntr_id = c.encntr_id AND ea.active_ind = 1
                    AND ea.encntr_alias_type_cd = (SELECT code_value FROM code_value WHERE code_set = 319 AND cdf_meaning = 'FIN NBR')
JOIN person_alias pa ON pa.person_id = c.person_id AND pa.active_ind = 1
                    AND pa.person_alias_type_cd = (SELECT code_value FROM code_value WHERE code_set = 4 AND cdf_meaning = 'MRN')
WHERE c.notify_min IS NULL OR c.notify_min > 30
ORDER BY c.verified_dt_tm DESC;
