-- ARCHIVED v1 of Report 02 - kept for the RCA in docs/rca.md. DO NOT USE.
-- Defects: (1) joins every CLINICAL_EVENT row, so a corrected result counts once per version;
-- (2) no result_status filter, so In Error results are included; (3) TAT uses each row's
-- verified_dt_tm, so a correction's verification time (hours later) is reported as turnaround;
-- (4) counts result rows (components), not orders, so a BMP counts twice.
-- name: lab_tat_v1
SELECT fac.display AS facility, od.oe_field_display_value AS priority,
       COUNT(*) AS results,
       ROUND(100.0 * SUM((julianday(ce.verified_dt_tm) - julianday(o.orig_order_dt_tm)) * 1440 <= 60) / COUNT(*), 1) AS pct_within_60
FROM orders o
JOIN order_detail od   ON od.order_id = o.order_id AND od.oe_field_meaning = 'COLLPRI' AND od.oe_field_display_value = 'STAT'
JOIN encounter e       ON e.encntr_id = o.encntr_id
JOIN code_value fac    ON fac.code_value = e.loc_facility_cd
JOIN clinical_event ce ON ce.order_id = o.order_id
WHERE o.orig_order_dt_tm >= :start_dt AND o.orig_order_dt_tm < date(:end_dt, '+1 day')
GROUP BY fac.display, od.oe_field_display_value ORDER BY fac.display;
