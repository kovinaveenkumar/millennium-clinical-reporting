-- =====================================================================
-- Report 02  Lab Turnaround Time (KPI)
-- Prompts : :start_dt, :end_dt (order date), :facility_cd (0 = all), :as_of (data cut)
-- Grain   : facility x priority x orderable   (+ STAT by hour-of-day block)
-- Rules   : TAT = order (orig_order_dt_tm) -> FIRST verification of the order's results.
--           Priority comes from ORDER_DETAIL (oe_field_meaning = 'COLLPRI'), not ORDERS.
--           Only orders with at least one CURRENT, non-In-Error result
--           (valid_until_dt_tm > :as_of AND result_status <> INERROR).
--           A corrected result keeps its original verification time: using the current
--           row's verified_dt_tm would add the correction delay to TAT (docs/rca_lab_tat.md).
--           Targets: STAT <= 60 min, Routine <= 240 min.
-- =====================================================================
-- name: lab_tat
WITH ord AS (
  SELECT o.order_id, fac.display AS facility, cat.display AS test, od.oe_field_display_value AS priority,
         (julianday(MIN(ce.verified_dt_tm)) - julianday(o.orig_order_dt_tm)) * 1440 AS tat_min
  FROM orders o
  JOIN code_value st     ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'COMPLETED'
  JOIN code_value cat    ON cat.code_value = o.catalog_cd
  JOIN order_detail od   ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
  JOIN encounter e       ON e.encntr_id = o.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN clinical_event ce ON ce.order_id = o.order_id
  WHERE o.active_ind = 1
    AND o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
    AND EXISTS (SELECT 1 FROM clinical_event cur
                JOIN code_value rs ON rs.code_value = cur.result_status_cd
                WHERE cur.order_id = o.order_id AND cur.valid_until_dt_tm > :as_of
                  AND rs.cdf_meaning IN ('AUTH', 'MODIFIED'))
  GROUP BY o.order_id
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY facility, priority, test ORDER BY tat_min) AS rn,
            COUNT(*)     OVER (PARTITION BY facility, priority, test)                AS n
  FROM ord
)
SELECT facility, priority, test,
       COUNT(*)                                                                  AS orders,
       ROUND(AVG(CASE WHEN rn IN ((n + 1) / 2, (n + 2) / 2) THEN tat_min END), 0) AS median_tat_min,
       CASE priority WHEN 'STAT' THEN 60 ELSE 240 END                            AS target_min,
       ROUND(100.0 * SUM(tat_min <= CASE priority WHEN 'STAT' THEN 60 ELSE 240 END) / COUNT(*), 1) AS pct_within_target
FROM ranked
GROUP BY facility, priority, test
ORDER BY priority DESC, pct_within_target;

-- name: lab_tat_stat_by_hour
WITH ord AS (
  SELECT o.order_id, fac.display AS facility, CAST(strftime('%H', o.orig_order_dt_tm) AS INTEGER) AS order_hour,
         (julianday(MIN(ce.verified_dt_tm)) - julianday(o.orig_order_dt_tm)) * 1440 AS tat_min
  FROM orders o
  JOIN code_value st     ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'COMPLETED'
  JOIN order_detail od   ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
                        AND od.oe_field_display_value = 'STAT'
  JOIN encounter e       ON e.encntr_id = o.encntr_id AND e.active_ind = 1
  JOIN person p          ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
  JOIN clinical_event ce ON ce.order_id = o.order_id
  WHERE o.active_ind = 1
    AND o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
    AND EXISTS (SELECT 1 FROM clinical_event cur
                JOIN code_value rs ON rs.code_value = cur.result_status_cd
                WHERE cur.order_id = o.order_id AND cur.valid_until_dt_tm > :as_of
                  AND rs.cdf_meaning IN ('AUTH', 'MODIFIED'))
  GROUP BY o.order_id
)
SELECT facility, order_hour, COUNT(*) AS stat_orders,
       ROUND(100.0 * SUM(tat_min <= 60) / COUNT(*), 1) AS pct_within_60
FROM ord GROUP BY facility, order_hour ORDER BY facility, order_hour;
