-- =====================================================================
-- Report 07  Duplicate Lab Orders (operational / waste)
-- Prompts : :start_dt, :end_dt (order date), :facility_cd (0 = all)
-- Rules   : Duplicate = same orderable on the same encounter placed within 120 minutes after an
--           earlier order that was not cancelled. A serial troponin ~3 h later is
--           clinically intended and falls outside the window on purpose.
--           "Performed" = the duplicate was completed anyway (wasted draw + test).
-- =====================================================================
-- name: duplicate_orders
WITH lab AS (
  SELECT o.order_id, o.encntr_id, o.catalog_cd, o.orig_order_dt_tm, e.loc_facility_cd, st.cdf_meaning AS status
  FROM orders o
  JOIN code_value st ON st.code_value = o.order_status_cd
  JOIN encounter e   ON e.encntr_id = o.encntr_id AND e.active_ind = 1
  JOIN person p      ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
  WHERE o.active_ind = 1
    AND o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
    AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
),
flagged AS (
  SELECT l.*,
         EXISTS (SELECT 1 FROM orders prior
                 JOIN code_value ps ON ps.code_value = prior.order_status_cd AND ps.cdf_meaning <> 'CANCELED'
                 WHERE prior.encntr_id = l.encntr_id AND prior.catalog_cd = l.catalog_cd
                   AND prior.order_id <> l.order_id
                   AND prior.orig_order_dt_tm <  l.orig_order_dt_tm
                   AND prior.orig_order_dt_tm >= datetime(l.orig_order_dt_tm, '-120 minutes')) AS is_dup
  FROM lab l
)
SELECT fac.display AS facility, cat.display AS test,
       COUNT(*)                                                AS orders,
       SUM(is_dup)                                             AS duplicate_orders,
       SUM(is_dup AND status = 'COMPLETED')                    AS duplicates_performed,
       ROUND(1000.0 * SUM(is_dup) / COUNT(*), 1)               AS dup_per_1000_orders
FROM flagged
JOIN code_value fac ON fac.code_value = flagged.loc_facility_cd
JOIN code_value cat ON cat.code_value = flagged.catalog_cd
GROUP BY fac.display, cat.display
ORDER BY dup_per_1000_orders DESC;
