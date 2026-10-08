-- =====================================================================
-- Report 08  Discern Rule Silent-Mode Firing Summary
-- Prompts : :start_dt, :end_dt (firing date), :facility_cd (0 = all)
-- Source  : EKS_MODULE_AUDIT rows written by src/discern_rules.py (run_mode = 'SILENT')
-- Purpose : projected alert burden before a rule is moved to production.
-- =====================================================================
-- name: rule_silent_mode
SELECT a.module_name, fac.display AS facility,
       COUNT(*)                                                         AS fires,
       ROUND(COUNT(*) * 1.0 / (julianday(date(:end_dt, '+1 day')) - julianday(:start_dt)), 1) AS fires_per_day,
       COUNT(DISTINCT a.encntr_id)                                      AS encounters
FROM eks_module_audit a
JOIN encounter e    ON e.encntr_id = a.encntr_id
JOIN code_value fac ON fac.code_value = e.loc_facility_cd
WHERE a.conclude = 1 AND a.run_mode = 'SILENT'
  AND a.begin_dt_tm >= :start_dt AND a.begin_dt_tm < date(:end_dt, '+1 day')
  AND (:facility_cd = 0 OR e.loc_facility_cd = :facility_cd)
GROUP BY a.module_name, fac.display
ORDER BY a.module_name, fires DESC;
