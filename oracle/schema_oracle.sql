-- Oracle DDL for the same Millennium-style tables (Millennium itself runs on Oracle).
-- Differences from sql/schema.sql: NUMBER / VARCHAR2 / DATE types, real DATE arithmetic.
CREATE TABLE code_value_set (code_set NUMBER PRIMARY KEY, display VARCHAR2(60) NOT NULL);
CREATE TABLE code_value (
  code_value NUMBER PRIMARY KEY, code_set NUMBER NOT NULL, display VARCHAR2(60) NOT NULL,
  display_key VARCHAR2(60) NOT NULL, cdf_meaning VARCHAR2(30), description VARCHAR2(60), active_ind NUMBER(1) DEFAULT 1 NOT NULL);
CREATE INDEX xie_cv_set_meaning ON code_value(code_set, cdf_meaning);
CREATE TABLE cust_unit_capacity (loc_nurse_unit_cd NUMBER PRIMARY KEY, loc_facility_cd NUMBER NOT NULL, staffed_beds NUMBER NOT NULL);
CREATE TABLE person (
  person_id NUMBER PRIMARY KEY, name_last VARCHAR2(60), name_first VARCHAR2(60), name_last_key VARCHAR2(60),
  name_full_formatted VARCHAR2(120), birth_dt_tm DATE, sex_cd NUMBER, active_ind NUMBER(1) DEFAULT 1 NOT NULL, updt_dt_tm DATE);
CREATE TABLE person_alias (
  person_alias_id NUMBER PRIMARY KEY, person_id NUMBER NOT NULL, alias VARCHAR2(30) NOT NULL, person_alias_type_cd NUMBER NOT NULL,
  active_ind NUMBER(1) DEFAULT 1 NOT NULL, beg_effective_dt_tm DATE, end_effective_dt_tm DATE);
CREATE TABLE prsnl (person_id NUMBER PRIMARY KEY, name_full_formatted VARCHAR2(120), position_cd NUMBER,
  physician_ind NUMBER(1) DEFAULT 0 NOT NULL, active_ind NUMBER(1) DEFAULT 1 NOT NULL);
CREATE TABLE encounter (
  encntr_id NUMBER PRIMARY KEY, person_id NUMBER NOT NULL, encntr_type_cd NUMBER NOT NULL, loc_facility_cd NUMBER NOT NULL,
  loc_nurse_unit_cd NUMBER, arrive_dt_tm DATE, reg_dt_tm DATE NOT NULL, inpatient_admit_dt_tm DATE, disch_dt_tm DATE,
  disch_disposition_cd NUMBER, active_ind NUMBER(1) DEFAULT 1 NOT NULL, updt_dt_tm DATE);
CREATE TABLE encntr_alias (
  encntr_alias_id NUMBER PRIMARY KEY, encntr_id NUMBER NOT NULL, alias VARCHAR2(30) NOT NULL, encntr_alias_type_cd NUMBER NOT NULL,
  active_ind NUMBER(1) DEFAULT 1 NOT NULL, beg_effective_dt_tm DATE, end_effective_dt_tm DATE);
CREATE TABLE encntr_loc_hist (
  encntr_loc_hist_id NUMBER PRIMARY KEY, encntr_id NUMBER NOT NULL, loc_facility_cd NUMBER NOT NULL, loc_nurse_unit_cd NUMBER NOT NULL,
  beg_effective_dt_tm DATE NOT NULL, end_effective_dt_tm DATE NOT NULL, active_ind NUMBER(1) DEFAULT 1 NOT NULL);
CREATE TABLE orders (
  order_id NUMBER PRIMARY KEY, encntr_id NUMBER NOT NULL, person_id NUMBER NOT NULL, catalog_cd NUMBER NOT NULL,
  catalog_type_cd NUMBER NOT NULL, order_status_cd NUMBER NOT NULL, orig_order_dt_tm DATE NOT NULL, status_dt_tm DATE,
  active_ind NUMBER(1) DEFAULT 1 NOT NULL);
CREATE TABLE order_detail (order_id NUMBER NOT NULL, action_sequence NUMBER NOT NULL, oe_field_meaning VARCHAR2(30) NOT NULL,
  oe_field_display_value VARCHAR2(60), PRIMARY KEY (order_id, action_sequence, oe_field_meaning));
CREATE TABLE clinical_event (
  clinical_event_id NUMBER PRIMARY KEY, event_id NUMBER NOT NULL, order_id NUMBER, encntr_id NUMBER NOT NULL, person_id NUMBER NOT NULL,
  event_cd NUMBER NOT NULL, result_val VARCHAR2(255), result_units_cd NUMBER, normalcy_cd NUMBER,
  normal_low VARCHAR2(20), normal_high VARCHAR2(20), critical_low VARCHAR2(20), critical_high VARCHAR2(20),
  result_status_cd NUMBER NOT NULL, event_end_dt_tm DATE NOT NULL, verified_dt_tm DATE, performed_prsnl_id NUMBER,
  valid_from_dt_tm DATE NOT NULL, valid_until_dt_tm DATE NOT NULL, view_level NUMBER DEFAULT 1 NOT NULL);
CREATE INDEX xie_enc_person ON encounter(person_id, reg_dt_tm);
CREATE INDEX xie_enc_arrive ON encounter(arrive_dt_tm, loc_facility_cd);
CREATE INDEX xie_enc_disch  ON encounter(disch_dt_tm);
CREATE INDEX xie_elh_encntr ON encntr_loc_hist(encntr_id, beg_effective_dt_tm);
CREATE INDEX xie_elh_unit   ON encntr_loc_hist(loc_nurse_unit_cd, beg_effective_dt_tm, end_effective_dt_tm);
CREATE INDEX xie_ord_encntr ON orders(encntr_id, catalog_cd, orig_order_dt_tm);
CREATE INDEX xie_ord_dt     ON orders(orig_order_dt_tm);
CREATE INDEX xie_ce_order   ON clinical_event(order_id);
CREATE INDEX xie_ce_event   ON clinical_event(event_id, valid_until_dt_tm);
CREATE INDEX xie_ce_encntr  ON clinical_event(encntr_id, event_cd, event_end_dt_tm);
