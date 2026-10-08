-- =====================================================================
-- Data-quality checks run before reports are published.
-- Every check returns ONE number = count of violating rows. Expected: 0.
-- =====================================================================
-- name: encounter_without_person
SELECT COUNT(*) FROM encounter e LEFT JOIN person p ON p.person_id = e.person_id WHERE p.person_id IS NULL;

-- name: order_without_encounter
SELECT COUNT(*) FROM orders o LEFT JOIN encounter e ON e.encntr_id = o.encntr_id WHERE e.encntr_id IS NULL;

-- name: discharge_before_registration
SELECT COUNT(*) FROM encounter WHERE disch_dt_tm < reg_dt_tm;

-- name: overlapping_location_segments
SELECT COUNT(*) FROM encntr_loc_hist a JOIN encntr_loc_hist b
  ON b.encntr_id = a.encntr_id AND b.encntr_loc_hist_id > a.encntr_loc_hist_id AND a.active_ind = 1 AND b.active_ind = 1
 AND b.beg_effective_dt_tm < a.end_effective_dt_tm AND a.beg_effective_dt_tm < b.end_effective_dt_tm;

-- name: completed_order_without_current_result
SELECT COUNT(*) FROM orders o
JOIN code_value s ON s.code_value = o.order_status_cd AND s.cdf_meaning = 'COMPLETED'
WHERE NOT EXISTS (SELECT 1 FROM clinical_event c WHERE c.order_id = o.order_id AND c.valid_until_dt_tm > :as_of);

-- name: result_on_cancelled_order
SELECT COUNT(*) FROM clinical_event c JOIN orders o ON o.order_id = c.order_id
JOIN code_value s ON s.code_value = o.order_status_cd AND s.cdf_meaning = 'CANCELED';

-- name: event_with_multiple_current_versions
SELECT COUNT(*) FROM (SELECT event_id FROM clinical_event WHERE valid_until_dt_tm > :as_of
                      GROUP BY event_id HAVING COUNT(*) > 1);

-- name: broken_version_chain
-- each superseded row must end exactly when the next version starts
SELECT COUNT(*) FROM clinical_event old
WHERE old.valid_until_dt_tm <= :as_of
  AND NOT EXISTS (SELECT 1 FROM clinical_event nxt WHERE nxt.event_id = old.event_id
                  AND nxt.clinical_event_id <> old.clinical_event_id AND nxt.valid_from_dt_tm = old.valid_until_dt_tm);

-- name: code_value_does_not_resolve
SELECT (SELECT COUNT(*) FROM encounter e WHERE NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = e.encntr_type_cd AND c.code_set = 71))
     + (SELECT COUNT(*) FROM encounter e WHERE NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = e.loc_facility_cd AND c.code_set = 220 AND c.cdf_meaning = 'FACILITY'))
     + (SELECT COUNT(*) FROM orders o    WHERE NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = o.order_status_cd AND c.code_set = 6004))
     + (SELECT COUNT(*) FROM orders o    WHERE NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = o.catalog_cd AND c.code_set = 200))
     + (SELECT COUNT(*) FROM clinical_event ce WHERE NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = ce.event_cd AND c.code_set = 72))
     + (SELECT COUNT(*) FROM clinical_event ce WHERE ce.normalcy_cd IS NOT NULL
                         AND NOT EXISTS (SELECT 1 FROM code_value c WHERE c.code_value = ce.normalcy_cd AND c.code_set = 52));

-- name: encounter_without_one_active_fin
SELECT COUNT(*) FROM encounter e
WHERE (SELECT COUNT(*) FROM encntr_alias a JOIN code_value t ON t.code_value = a.encntr_alias_type_cd AND t.cdf_meaning = 'FIN NBR'
       WHERE a.encntr_id = e.encntr_id AND a.active_ind = 1) <> 1;

-- name: person_without_one_active_mrn
SELECT COUNT(*) FROM person p
WHERE (SELECT COUNT(*) FROM person_alias a JOIN code_value t ON t.code_value = a.person_alias_type_cd AND t.cdf_meaning = 'MRN'
       WHERE a.person_id = p.person_id AND a.active_ind = 1) <> 1;

-- name: order_without_priority
SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_detail d WHERE d.order_id = o.order_id AND d.oe_field_meaning = 'COLLPRI');

-- name: lab_result_not_numeric
-- result_val is TEXT in Millennium; numeric lab results must convert cleanly (cnvtreal in CCL)
SELECT COUNT(*) FROM clinical_event WHERE order_id IS NOT NULL AND (result_val = '' OR result_val GLOB '*[^0-9.-]*');

-- name: event_after_data_cut
SELECT (SELECT COUNT(*) FROM encounter WHERE reg_dt_tm >= :as_of OR disch_dt_tm >= :as_of)
     + (SELECT COUNT(*) FROM orders WHERE orig_order_dt_tm >= :as_of)
     + (SELECT COUNT(*) FROM clinical_event WHERE verified_dt_tm >= :as_of);
