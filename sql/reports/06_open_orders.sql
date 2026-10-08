-- =====================================================================
-- Report 06  Open Lab Orders > 24 h (operational worklist)
-- Prompts : :start_dt, :end_dt (order date), :facility_cd (0 = all), :as_of
-- Rules   : Lab orders still in ORDERED status more than 24 h after they were placed, as of the
--           data cut. These are possible missed collections / lost specimens.
-- =====================================================================
-- name: open_orders_summary
SELECT fac.display AS facility, cat.display AS test, od.oe_field_display_value AS priority,
       COUNT(*) AS open_over_24h,
       ROUND(AVG((julianday(:as_of) - julianday(o.orig_order_dt_tm)) * 24), 0) AS avg_hours_open
FROM orders o
JOIN code_value st   ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'ORDERED'
JOIN code_value cat  ON cat.code_value = o.catalog_cd
JOIN order_detail od ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
JOIN encounter e     ON e.encntr_id = o.encntr_id AND e.active_ind = 1
JOIN person p        ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
JOIN code_value fac  ON fac.code_value = e.loc_facility_cd
WHERE o.active_ind = 1
  AND o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
  AND o.orig_order_dt_tm < datetime(:as_of, '-24 hours')
  AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
GROUP BY fac.display, cat.display, od.oe_field_display_value
ORDER BY open_over_24h DESC;

-- name: open_orders_worklist
SELECT fac.display AS facility, unit.display AS current_unit, ea.alias AS fin, o.order_id, cat.display AS test,
       od.oe_field_display_value AS priority, o.orig_order_dt_tm,
       ROUND((julianday(:as_of) - julianday(o.orig_order_dt_tm)) * 24, 1) AS hours_open,
       CASE WHEN e.disch_dt_tm IS NOT NULL THEN 'Discharged - cancel or follow up' ELSE 'In house - recollect' END AS suggested_action
FROM orders o
JOIN code_value st   ON st.code_value = o.order_status_cd AND st.cdf_meaning = 'ORDERED'
JOIN code_value cat  ON cat.code_value = o.catalog_cd
JOIN order_detail od ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI'
JOIN encounter e     ON e.encntr_id = o.encntr_id AND e.active_ind = 1
JOIN person p        ON p.person_id = o.person_id AND p.name_last_key NOT LIKE 'ZZTEST%'
JOIN code_value fac  ON fac.code_value = e.loc_facility_cd
JOIN code_value unit ON unit.code_value = e.loc_nurse_unit_cd
JOIN encntr_alias ea ON ea.encntr_id = e.encntr_id AND ea.active_ind = 1
                    AND ea.encntr_alias_type_cd = (SELECT code_value FROM code_value WHERE code_set = 319 AND cdf_meaning = 'FIN NBR')
WHERE o.active_ind = 1
  AND o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
  AND o.orig_order_dt_tm < datetime(:as_of, '-24 hours')
  AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
ORDER BY o.orig_order_dt_tm;
