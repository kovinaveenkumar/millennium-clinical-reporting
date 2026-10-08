-- =====================================================================
-- Oracle versions of reports 01-05 (same logic as sql/reports/*.sql).
-- What changes from SQLite:
--   * DATE arithmetic: (d1 - d2) * 1440 = minutes; d + 6/24 = +6 hours; d - 30 = -30 days
--   * MEDIAN() aggregate replaces the ROW_NUMBER()/COUNT() median CTEs
--   * CONNECT BY LEVEL generates the census days (instead of a recursive CTE)
--   * CASE WHEN ... THEN 1 ELSE 0 END instead of summing booleans; NVL instead of COALESCE
-- Binds: :start_dt, :end_dt ('YYYY-MM-DD'), :facility_cd (0 = all), :as_of ('YYYY-MM-DD HH24:MI:SS')
-- =====================================================================
-- name: ed_throughput
WITH first_seg AS (
  SELECT encntr_id, end_effective_dt_tm
  FROM (SELECT h.encntr_id, h.end_effective_dt_tm,
               ROW_NUMBER() OVER (PARTITION BY h.encntr_id ORDER BY h.beg_effective_dt_tm) AS rn
        FROM encntr_loc_hist h WHERE h.active_ind = 1)
  WHERE rn = 1
),
ed AS (
  SELECT fac.display                                              AS facility,
         NVL(disp.cdf_meaning, 'IN HOUSE')                        AS disposition,
         CASE WHEN et.cdf_meaning = 'INPATIENT' THEN 1 ELSE 0 END AS admitted,
         (f.end_effective_dt_tm - e.arrive_dt_tm) * 1440          AS ed_los_min,
         CASE WHEN et.cdf_meaning = 'INPATIENT'
              THEN (f.end_effective_dt_tm - e.inpatient_admit_dt_tm) * 1440 END AS boarding_min
  FROM encounter e
  JOIN person p          ON p.person_id = e.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value et     ON et.code_value = e.encntr_type_cd
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  LEFT JOIN code_value disp ON disp.code_value = e.disch_disposition_cd
  JOIN first_seg f       ON f.encntr_id = e.encntr_id
  WHERE e.active_ind = 1
    AND e.arrive_dt_tm >= TO_DATE(:start_dt, 'YYYY-MM-DD') AND e.arrive_dt_tm < TO_DATE(:end_dt, 'YYYY-MM-DD') + 1
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
    AND f.end_effective_dt_tm < DATE '2100-01-01'
)
SELECT facility,
       COUNT(*)                                                                         AS ed_visits,
       ROUND(100 * SUM(CASE WHEN disposition = 'LWBS' THEN 1 ELSE 0 END) / COUNT(*), 1) AS lwbs_pct,
       ROUND(100 * SUM(admitted) / COUNT(*), 1)                                         AS admit_pct,
       ROUND(MEDIAN(CASE WHEN disposition <> 'LWBS' AND admitted = 0 THEN ed_los_min END))   AS median_los_discharged_min,
       ROUND(MEDIAN(CASE WHEN disposition <> 'LWBS' AND admitted = 1 THEN ed_los_min END))   AS median_los_admitted_min,
       ROUND(MEDIAN(CASE WHEN disposition <> 'LWBS' AND admitted = 1 THEN boarding_min END)) AS median_boarding_min,
       ROUND(100 * SUM(CASE WHEN disposition <> 'LWBS' AND ed_los_min > 240 THEN 1 ELSE 0 END)
                 / SUM(CASE WHEN disposition <> 'LWBS' THEN 1 ELSE 0 END), 1)          AS pct_over_4h
FROM ed
GROUP BY facility
ORDER BY median_boarding_min DESC

-- name: lab_tat
WITH ord AS (
  SELECT o.order_id, fac.display AS facility, cat.display AS test, od.oe_field_display_value AS priority,
         ROUND((MIN(ce.verified_dt_tm) - o.orig_order_dt_tm) * 86400) / 60 AS tat_min   -- whole seconds: exact at 60:00
  FROM orders o
  JOIN code_value st     ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'COMPLETED'
  JOIN code_value cat    ON cat.code_value = o.catalog_cd
  JOIN order_detail od   ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
  JOIN encounter e       ON e.encntr_id = o.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN clinical_event ce ON ce.order_id = o.order_id
  WHERE o.active_ind = 1
    AND o.orig_order_dt_tm >= TO_DATE(:start_dt, 'YYYY-MM-DD') AND o.orig_order_dt_tm < TO_DATE(:end_dt, 'YYYY-MM-DD') + 1
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
    AND EXISTS (SELECT 1 FROM clinical_event cur
                JOIN code_value rs ON rs.code_value = cur.result_status_cd
                WHERE cur.order_id = o.order_id
                  AND cur.valid_until_dt_tm > TO_DATE(:as_of, 'YYYY-MM-DD HH24:MI:SS')
                  AND rs.cdf_meaning IN ('AUTH', 'MODIFIED'))
  GROUP BY o.order_id, fac.display, cat.display, od.oe_field_display_value, o.orig_order_dt_tm
)
SELECT facility, priority, test,
       COUNT(*)                                        AS orders,
       ROUND(MEDIAN(tat_min))                          AS median_tat_min,
       CASE priority WHEN 'STAT' THEN 60 ELSE 240 END  AS target_min,
       ROUND(100 * SUM(CASE WHEN tat_min <= CASE priority WHEN 'STAT' THEN 60 ELSE 240 END THEN 1 ELSE 0 END)
                 / COUNT(*), 1)                        AS pct_within_target
FROM ord
GROUP BY facility, priority, test
ORDER BY priority DESC, pct_within_target

-- name: critical_compliance
WITH crit AS (
  SELECT fac.display AS facility, unit.display AS nurse_unit,
         (SELECT (MIN(n.event_end_dt_tm) - ce.verified_dt_tm) * 1440
          FROM clinical_event n
          JOIN code_value nc ON nc.code_value = n.event_cd AND nc.display = 'Critical Result Notification'
          WHERE n.encntr_id = ce.encntr_id
            AND n.valid_until_dt_tm > TO_DATE(:as_of, 'YYYY-MM-DD HH24:MI:SS')
            AND n.event_end_dt_tm >= ce.verified_dt_tm
            AND n.event_end_dt_tm <= ce.verified_dt_tm + 6 / 24) AS notify_min
  FROM clinical_event ce
  JOIN code_value nrm    ON nrm.code_value = ce.normalcy_cd AND nrm.cdf_meaning = 'CRITICAL'
  JOIN code_value rs     ON rs.code_value = ce.result_status_cd AND rs.cdf_meaning IN ('AUTH', 'MODIFIED')
  JOIN encounter e       ON e.encntr_id = ce.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = ce.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN encntr_loc_hist h ON h.encntr_id = ce.encntr_id AND h.active_ind = 1
                        AND h.beg_effective_dt_tm <= ce.verified_dt_tm AND h.end_effective_dt_tm > ce.verified_dt_tm
  JOIN code_value unit   ON unit.code_value = h.loc_nurse_unit_cd
  WHERE ce.valid_until_dt_tm > TO_DATE(:as_of, 'YYYY-MM-DD HH24:MI:SS')
    AND ce.verified_dt_tm >= TO_DATE(:start_dt, 'YYYY-MM-DD') AND ce.verified_dt_tm < TO_DATE(:end_dt, 'YYYY-MM-DD') + 1
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
)
SELECT facility, nurse_unit,
       COUNT(*)                                                         AS critical_results,
       SUM(CASE WHEN notify_min <= 30 THEN 1 ELSE 0 END)                AS notified_30min,
       SUM(CASE WHEN notify_min IS NULL THEN 1 ELSE 0 END)              AS not_documented,
       ROUND(100 * SUM(CASE WHEN notify_min <= 30 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_within_30,
       ROUND(MEDIAN(notify_min))                                        AS median_notify_min
FROM crit
GROUP BY facility, nurse_unit
ORDER BY pct_within_30

-- name: readmit_by_facility
WITH idx AS (
  SELECT fac.display AS facility,
         CASE WHEN EXISTS (SELECT 1 FROM encounter r
                           JOIN code_value rt ON rt.code_value = r.encntr_type_cd AND rt.cdf_meaning = 'INPATIENT'
                           WHERE r.person_id = e.person_id AND r.active_ind = 1 AND r.encntr_id <> e.encntr_id
                             AND r.inpatient_admit_dt_tm > e.disch_dt_tm
                             AND r.inpatient_admit_dt_tm <= e.disch_dt_tm + 30)
              THEN 1 ELSE 0 END AS readmit_30d
  FROM encounter e
  JOIN code_value et   ON et.code_value = e.encntr_type_cd AND et.cdf_meaning = 'INPATIENT'
  JOIN code_value disp ON disp.code_value = e.disch_disposition_cd AND disp.cdf_meaning <> 'EXPIRED'
  JOIN code_value fac  ON fac.code_value = e.loc_facility_cd
  JOIN person p        ON p.person_id = e.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  WHERE e.active_ind = 1
    AND e.disch_dt_tm >= TO_DATE(:start_dt, 'YYYY-MM-DD') AND e.disch_dt_tm < TO_DATE(:end_dt, 'YYYY-MM-DD') + 1
    AND e.disch_dt_tm <= TO_DATE(:as_of, 'YYYY-MM-DD HH24:MI:SS') - 30
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
)
SELECT facility, COUNT(*) AS index_discharges, SUM(readmit_30d) AS readmits_30d,
       ROUND(100 * SUM(readmit_30d) / COUNT(*), 1) AS readmit_rate_pct
FROM idx GROUP BY facility ORDER BY readmit_rate_pct DESC

-- name: census_summary
WITH days AS (
  SELECT TO_DATE(:start_dt, 'YYYY-MM-DD') + LEVEL - 1 AS census_dt
  FROM dual
  CONNECT BY LEVEL <= TO_DATE(:end_dt, 'YYYY-MM-DD') - TO_DATE(:start_dt, 'YYYY-MM-DD') + 1
),
daily AS (
  SELECT cap.loc_facility_cd, cap.loc_nurse_unit_cd, cap.staffed_beds, d.census_dt,
         COUNT(h.encntr_loc_hist_id) AS census
  FROM days d
  CROSS JOIN cust_unit_capacity cap
  LEFT JOIN encntr_loc_hist h ON h.loc_nurse_unit_cd = cap.loc_nurse_unit_cd AND h.active_ind = 1
                             AND h.beg_effective_dt_tm <= d.census_dt AND h.end_effective_dt_tm > d.census_dt
  WHERE (:facility_cd = 0 OR cap.loc_facility_cd = :facility_cd)
  GROUP BY cap.loc_facility_cd, cap.loc_nurse_unit_cd, cap.staffed_beds, d.census_dt
)
SELECT fac.display AS facility, unit.display AS nurse_unit, daily.staffed_beds,
       ROUND(AVG(census), 1)                                              AS avg_census,
       MAX(census)                                                        AS peak_census,
       ROUND(100 * AVG(census) / daily.staffed_beds, 1)                   AS avg_occupancy_pct,
       SUM(CASE WHEN census >= 0.95 * daily.staffed_beds THEN 1 ELSE 0 END) AS days_at_95pct_plus,
       COUNT(*)                                                           AS days
FROM daily
JOIN code_value unit ON unit.code_value = daily.loc_nurse_unit_cd
JOIN code_value fac  ON fac.code_value = daily.loc_facility_cd
GROUP BY fac.display, unit.display, daily.staffed_beds
ORDER BY avg_occupancy_pct DESC
