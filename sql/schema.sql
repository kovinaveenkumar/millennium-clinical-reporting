-- =====================================================================
-- Millennium-style reporting schema (SQLite; synthetic data only)
-- Table and column names follow Cerner Millennium conventions:
--   *_cd     -> foreign key to CODE_VALUE (one row per coded value, grouped by code_set)
--   *_dt_tm  -> date/time
--   active_ind, beg/end_effective_dt_tm, valid_from/valid_until_dt_tm -> row-validity logic
-- Simplified: real Millennium tables have many more columns.
-- CUST_* tables are site-maintained reference tables (not Millennium).
-- =====================================================================
DROP TABLE IF EXISTS eks_module_audit;
DROP TABLE IF EXISTS clinical_event;
DROP TABLE IF EXISTS order_action;
DROP TABLE IF EXISTS order_detail;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS encntr_loc_hist;
DROP TABLE IF EXISTS encntr_alias;
DROP TABLE IF EXISTS encounter;
DROP TABLE IF EXISTS prsnl;
DROP TABLE IF EXISTS person_alias;
DROP TABLE IF EXISTS person;
DROP TABLE IF EXISTS cust_unit_capacity;
DROP TABLE IF EXISTS code_value;
DROP TABLE IF EXISTS code_value_set;
DROP TABLE IF EXISTS zz_truth_dup_order;

-- ---------- Reference / code tables ----------
CREATE TABLE code_value_set (
  code_set     INTEGER PRIMARY KEY,
  display      TEXT NOT NULL
);
CREATE TABLE code_value (
  code_value   INTEGER PRIMARY KEY,
  code_set     INTEGER NOT NULL REFERENCES code_value_set(code_set),
  display      TEXT    NOT NULL,
  display_key  TEXT    NOT NULL,        -- upper-case, no spaces/punctuation (used by uar_get_code_by("DISPLAYKEY", ...))
  cdf_meaning  TEXT,                    -- stable meaning; code programs on this, never on the numeric code_value
  description  TEXT,
  active_ind   INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX xie_cv_set_meaning ON code_value(code_set, cdf_meaning);

CREATE TABLE cust_unit_capacity (       -- site-maintained: staffed beds per nurse unit
  loc_nurse_unit_cd INTEGER PRIMARY KEY REFERENCES code_value(code_value),
  loc_facility_cd   INTEGER NOT NULL REFERENCES code_value(code_value),
  staffed_beds      INTEGER NOT NULL
);

-- ---------- Person / provider ----------
CREATE TABLE person (
  person_id            INTEGER PRIMARY KEY,
  name_last            TEXT, name_first TEXT,
  name_last_key        TEXT,            -- upper-case search key (test patients: 'ZZTEST...')
  name_full_formatted  TEXT,
  birth_dt_tm          TEXT,
  sex_cd               INTEGER REFERENCES code_value(code_value),
  active_ind           INTEGER NOT NULL DEFAULT 1,
  updt_dt_tm           TEXT
);
CREATE TABLE person_alias (             -- MRN
  person_alias_id       INTEGER PRIMARY KEY,
  person_id             INTEGER NOT NULL REFERENCES person(person_id),
  alias                 TEXT NOT NULL,
  person_alias_type_cd  INTEGER NOT NULL REFERENCES code_value(code_value),   -- code set 4
  active_ind            INTEGER NOT NULL DEFAULT 1,
  beg_effective_dt_tm   TEXT, end_effective_dt_tm TEXT
);
CREATE TABLE prsnl (
  person_id            INTEGER PRIMARY KEY,
  name_full_formatted  TEXT,
  position_cd          INTEGER REFERENCES code_value(code_value),             -- code set 88
  physician_ind        INTEGER NOT NULL DEFAULT 0,
  active_ind           INTEGER NOT NULL DEFAULT 1
);

-- ---------- Encounter ----------
CREATE TABLE encounter (
  encntr_id             INTEGER PRIMARY KEY,
  person_id             INTEGER NOT NULL REFERENCES person(person_id),
  encntr_type_cd        INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 71 (ED visits that are admitted become INPATIENT)
  loc_facility_cd       INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 220
  loc_nurse_unit_cd     INTEGER REFERENCES code_value(code_value),           -- current/last unit
  arrive_dt_tm          TEXT,
  reg_dt_tm             TEXT NOT NULL,
  inpatient_admit_dt_tm TEXT,
  disch_dt_tm           TEXT,
  disch_disposition_cd  INTEGER REFERENCES code_value(code_value),           -- code set 19
  active_ind            INTEGER NOT NULL DEFAULT 1,                          -- 0 = cancelled registration
  updt_dt_tm            TEXT
);
CREATE TABLE encntr_alias (             -- FIN
  encntr_alias_id       INTEGER PRIMARY KEY,
  encntr_id             INTEGER NOT NULL REFERENCES encounter(encntr_id),
  alias                 TEXT NOT NULL,
  encntr_alias_type_cd  INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 319
  active_ind            INTEGER NOT NULL DEFAULT 1,
  beg_effective_dt_tm   TEXT, end_effective_dt_tm TEXT
);
CREATE TABLE encntr_loc_hist (          -- one row per location segment (ED -> unit -> ...)
  encntr_loc_hist_id    INTEGER PRIMARY KEY,
  encntr_id             INTEGER NOT NULL REFERENCES encounter(encntr_id),
  loc_facility_cd       INTEGER NOT NULL REFERENCES code_value(code_value),
  loc_nurse_unit_cd     INTEGER NOT NULL REFERENCES code_value(code_value),
  beg_effective_dt_tm   TEXT NOT NULL,
  end_effective_dt_tm   TEXT NOT NULL,   -- '2100-12-31 23:59:59' while still there
  active_ind            INTEGER NOT NULL DEFAULT 1
);

-- ---------- Orders ----------
CREATE TABLE orders (
  order_id              INTEGER PRIMARY KEY,
  encntr_id             INTEGER NOT NULL REFERENCES encounter(encntr_id),
  person_id             INTEGER NOT NULL REFERENCES person(person_id),
  catalog_cd            INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 200
  catalog_type_cd       INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 6000
  order_status_cd       INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 6004
  orig_order_dt_tm      TEXT NOT NULL,
  status_dt_tm          TEXT,
  active_ind            INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE order_detail (             -- order entry fields (priority lives here, not on ORDERS)
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  action_sequence       INTEGER NOT NULL,
  oe_field_meaning      TEXT NOT NULL,   -- e.g. 'COLLPRI' = collection priority
  oe_field_display_value TEXT,
  PRIMARY KEY (order_id, action_sequence, oe_field_meaning)
);
CREATE TABLE order_action (
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  action_sequence       INTEGER NOT NULL,
  action_type_cd        INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 6003
  action_dt_tm          TEXT NOT NULL,
  action_personnel_id   INTEGER REFERENCES prsnl(person_id),
  PRIMARY KEY (order_id, action_sequence)
);

-- ---------- Results / documentation ----------
-- CLINICAL_EVENT is versioned: a correction ends the old row (valid_until_dt_tm = correction time)
-- and inserts a new row with the same event_id. The current row has valid_until_dt_tm = 2100-12-31.
CREATE TABLE clinical_event (
  clinical_event_id     INTEGER PRIMARY KEY,
  event_id              INTEGER NOT NULL,                                    -- shared by all versions
  order_id              INTEGER REFERENCES orders(order_id),
  encntr_id             INTEGER NOT NULL REFERENCES encounter(encntr_id),
  person_id             INTEGER NOT NULL REFERENCES person(person_id),
  event_cd              INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 72
  result_val            TEXT,                                                -- stored as text, like Millennium
  result_units_cd       INTEGER REFERENCES code_value(code_value),           -- code set 54
  normalcy_cd           INTEGER REFERENCES code_value(code_value),           -- code set 52
  normal_low TEXT, normal_high TEXT, critical_low TEXT, critical_high TEXT,
  result_status_cd      INTEGER NOT NULL REFERENCES code_value(code_value),  -- code set 8
  event_end_dt_tm       TEXT NOT NULL,                                       -- clinically significant time
  verified_dt_tm        TEXT,
  performed_prsnl_id    INTEGER REFERENCES prsnl(person_id),
  valid_from_dt_tm      TEXT NOT NULL,
  valid_until_dt_tm     TEXT NOT NULL DEFAULT '2100-12-31 23:59:59',
  view_level            INTEGER NOT NULL DEFAULT 1
);

-- ---------- Discern Expert (rule) audit, written by src/discern_rules.py ----------
CREATE TABLE eks_module_audit (
  rec_id                INTEGER PRIMARY KEY,
  module_name           TEXT NOT NULL,
  begin_dt_tm           TEXT NOT NULL,
  conclude              INTEGER NOT NULL,   -- 1 = logic true, action fired
  person_id             INTEGER, encntr_id INTEGER, order_id INTEGER, clinical_event_id INTEGER,
  action_return         TEXT,
  run_mode              TEXT NOT NULL       -- 'SILENT' (logged only) or 'PRODUCTION'
);

-- ---------- Generator ground truth (NOT Millennium; used only by tests and rule evaluation) ----------
CREATE TABLE zz_truth_dup_order (order_id INTEGER PRIMARY KEY);

-- ---------- Indexes on what reports qualify on (same idea as tuning a CCL PLAN) ----------
CREATE INDEX xie_enc_person   ON encounter(person_id, reg_dt_tm);
CREATE INDEX xie_enc_arrive   ON encounter(arrive_dt_tm, loc_facility_cd);
CREATE INDEX xie_enc_disch    ON encounter(disch_dt_tm);
CREATE INDEX xie_elh_encntr   ON encntr_loc_hist(encntr_id, beg_effective_dt_tm);
CREATE INDEX xie_elh_unit     ON encntr_loc_hist(loc_nurse_unit_cd, beg_effective_dt_tm, end_effective_dt_tm);
CREATE INDEX xie_ord_encntr   ON orders(encntr_id, catalog_cd, orig_order_dt_tm);
CREATE INDEX xie_ord_dt       ON orders(orig_order_dt_tm);
CREATE INDEX xie_ce_order     ON clinical_event(order_id);
CREATE INDEX xie_ce_event     ON clinical_event(event_id, valid_until_dt_tm);
CREATE INDEX xie_ce_encntr    ON clinical_event(encntr_id, event_cd, event_end_dt_tm);
-- NOTE: no index on clinical_event(normalcy_cd ...) on purpose: docs/performance_tuning.md adds it and measures the change.
