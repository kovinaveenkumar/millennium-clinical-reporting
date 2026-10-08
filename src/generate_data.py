"""
Generate a synthetic Millennium-style database (data/millennium.db). No real patients.

Three hospitals, 1 Jan - 30 Jun 2026 (+ 2-week warm-up in Dec 2025 so the census and
readmission look-backs are not empty on day 1). Patterns are planted on purpose so the
reports have something to find (see "About the data and the CCL" in the README):
  * Lakeside Regional: tight inpatient beds -> long ED boarding for admitted patients
  * Mercy South: slow STAT lab turnaround on night shift; higher 30-day readmissions
  * Mercy North: more accidental duplicate lab orders; slow critical-result calls on Telemetry
  * ~1.2% of results corrected (new CLINICAL_EVENT version), ~0.4% marked In Error
  * 10 test patients (ZZTEST), ~0.3% cancelled registrations (active_ind = 0)

Usage:  python src/generate_data.py            (about 30-60 s)
"""
import math
import random
import sqlite3
import datetime as dt
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "millennium.db"
random.seed(7)
rng = np.random.default_rng(7)

WARMUP = dt.datetime(2025, 12, 18)
START = dt.datetime(2026, 1, 1)
END = dt.datetime(2026, 7, 1)          # data "as of" (exclusive)
OPEN_DT = "2100-12-31 23:59:59"        # Millennium "still valid" date
fmt = lambda t: t.strftime("%Y-%m-%d %H:%M:%S")

# ---------------------------------------------------------------- code values
CODE_SETS = {4: "Person Alias Type", 8: "Result Status", 19: "Discharge Disposition", 52: "Normalcy",
             54: "Result Units", 57: "Sex", 71: "Encounter Type", 72: "Event Code", 88: "Position",
             200: "Order Catalog", 220: "Location", 319: "Encounter Alias Type", 6000: "Catalog Type",
             6003: "Order Action Type", 6004: "Order Status"}
CV = []                                  # (code_value, code_set, display, cdf_meaning)
def cv(code, cs, display, meaning):
    CV.append((code, cs, display, meaning)); return code

MRN = cv(10, 4, "MRN", "MRN"); FIN = cv(1077, 319, "FIN NBR", "FIN NBR")
AUTH = cv(25, 8, "Auth (Verified)", "AUTH"); MODIFIED = cv(35, 8, "Modified", "MODIFIED"); INERROR = cv(31, 8, "In Error", "INERROR")
DISP = {k: cv(c, 19, d, k) for k, c, d in [("HOME", 638660, "Home/Self Care"), ("HOMEHEALTH", 638661, "Home Health"),
        ("SNF", 638662, "Skilled Nursing Facility"), ("AMA", 638663, "Left Against Medical Advice"),
        ("EXPIRED", 638664, "Expired"), ("LWBS", 638665, "Left Without Being Seen")]}
NORMAL = cv(214, 52, "Normal", "NORMAL"); HIGH = cv(207, 52, "High", "HIGH"); LOW = cv(211, 52, "Low", "LOW")
CRITICAL = cv(203, 52, "Critical", "CRITICAL")
MALE = cv(362, 57, "Male", "MALE"); FEMALE = cv(363, 57, "Female", "FEMALE")
ET_ED = cv(309308, 71, "Emergency", "EMERGENCY"); ET_IP = cv(309310, 71, "Inpatient", "INPATIENT")
ET_OP = cv(309312, 71, "Outpatient", "OUTPATIENT")
POS = {k: cv(c, 88, d, k) for k, c, d in [("PHYSICIAN", 441, "Physician"), ("NURSE", 686, "Registered Nurse"),
       ("LABTECH", 1236, "Lab Technologist")]}
LAB = cv(2513, 6000, "Laboratory", "GENERAL LAB")
ACT = {k: cv(c, 6003, k.title(), k) for k, c in [("ORDER", 2534), ("COMPLETE", 2529), ("CANCEL", 2526)]}
OS_COMPLETED = cv(2543, 6004, "Completed", "COMPLETED"); OS_ORDERED = cv(2550, 6004, "Ordered", "ORDERED")
OS_CANCELED = cv(2542, 6004, "Canceled", "CANCELED")

UNITS = {}                                # unit code -> result unit cd
for code, d in [(270, "K/uL"), (271, "g/dL"), (272, "mmol/L"), (273, "ng/mL")]:
    UNITS[d] = cv(code, 54, d, None)
# event: (code, display, units, normal_low, normal_high, crit_low, crit_high, p_critical, decimals)
EVENTS = {
    "WBC":   (2797001, "WBC", "K/uL", 4.5, 11.0, 1.5, 30.0, 0.004, 1),
    "HGB":   (2797002, "Hemoglobin", "g/dL", 12.0, 17.5, 7.0, 20.0, 0.010, 1),
    "K":     (2797003, "Potassium", "mmol/L", 3.5, 5.1, 2.8, 6.2, 0.014, 1),
    "NA":    (2797004, "Sodium", "mmol/L", 135, 145, 120, 160, 0.004, 0),
    "TROP":  (2797005, "Troponin I", "ng/mL", 0.0, 0.04, None, 0.5, 0.035, 3),
    "LACT":  (2797006, "Lactate", "mmol/L", 0.5, 2.0, None, 4.0, 0.060, 1),
}
for k, e in EVENTS.items():
    cv(e[0], 72, e[1], None)
CRIT_NOTIFY = cv(2797099, 72, "Critical Result Notification", None)
CATALOG = {"CBC": (2780001, "CBC", ["WBC", "HGB"]), "BMP": (2780002, "Basic Metabolic Panel", ["K", "NA"]),
           "TROP": (2780003, "Troponin I", ["TROP"]), "LACT": (2780004, "Lactate", ["LACT"])}
for k, c in CATALOG.items():
    cv(c[0], 200, c[1], None)

# facilities and units (code set 220)
FAC = {
    #        code      display               ed/day admit lwbs  tr_med work board direct op/day dup   stat_day stat_night readmit
    "MN": dict(cd=2552001, name="Mercy North", ed=95, admit=.17, lwbs=.025, tr=175, work=205, board=95, direct=4, op=35,
               dup=.050, stat_d=40, stat_n=44, readmit=.105),
    "MS": dict(cd=2552002, name="Mercy South", ed=110, admit=.16, lwbs=.030, tr=185, work=215, board=115, direct=5, op=40,
               dup=.012, stat_d=42, stat_n=63, readmit=.165),
    "LR": dict(cd=2552003, name="Lakeside Regional", ed=70, admit=.18, lwbs=.060, tr=200, work=225, board=310, direct=3, op=25,
               dup=.012, stat_d=43, stat_n=47, readmit=.100),
}
TARGET_OCC = {"MN": {"MEDSURG": .86, "TELE": .90, "ICU": .80}, "MS": {"MEDSURG": .88, "TELE": .86, "ICU": .82},
              "LR": {"MEDSURG": .97, "TELE": .94, "ICU": .90}}
UNIT_NAMES = {"ED": "ED", "MEDSURG": "3W Med/Surg", "TELE": "4E Telemetry", "ICU": "ICU", "OPLAB": "Outpatient Lab"}
UNIT = {}
for i, (fk, f) in enumerate(FAC.items()):
    cv(f["cd"], 220, f["name"], "FACILITY")
    for j, (uk, un) in enumerate(UNIT_NAMES.items()):
        code = 2553000 + 10 * i + j
        UNIT[(fk, uk)] = cv(code, 220, f"{fk} {un}", "AMBULATORY" if uk == "OPLAB" else "NURSEUNIT")

# ---------------------------------------------------------------- helpers
def lognorm(median, sigma):
    return median * math.exp(sigma * random.gauss(0, 1))

def mins(m):
    return dt.timedelta(minutes=m)

HOUR_W = np.array([2, 1.5, 1.2, 1, 1, 1.2, 1.8, 2.8, 3.8, 4.5, 5, 5.2, 5.2, 5, 4.9, 4.8, 4.8, 4.9, 4.9, 4.6, 4.2, 3.6, 3, 2.4])
HOUR_W = HOUR_W / HOUR_W.sum()
DOW = [1.12, 1.03, 1.0, 0.98, 0.98, 0.95, 0.97]          # Mon..Sun

# ---------------------------------------------------------------- tables (lists of tuples)
person, person_alias, prsnl, encounter, encntr_alias, loc_hist = [], [], [], [], [], []
orders, order_detail, order_action, clinical_event, truth_dup = [], [], [], [], []
fac_pool = {k: [] for k in FAC}
ids = dict(person=0, alias=0, encntr=30_000_000, elh=50_000_000, order=400_000_000, ce=900_000_000, event=800_000_000)

def nid(k):
    ids[k] += 1; return ids[k]

PHYS = list(range(10_001, 10_121)); NURSES = list(range(20_001, 20_301)); TECHS = list(range(30_001, 30_061))
FIRST = ["James", "Mary", "John", "Linda", "Robert", "Maria", "David", "Susan", "Carlos", "Aisha", "Wei", "Priya",
         "Michael", "Karen", "Jose", "Emily", "Daniel", "Grace", "Kevin", "Fatima", "Anthony", "Nancy", "Thomas", "Rosa"]
LAST = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez", "Lee",
        "Patel", "Nguyen", "Clark", "Lewis", "Walker", "Hall", "Young", "King", "Wright", "Lopez", "Hill", "Green", "Adams"]
for p in PHYS:
    prsnl.append((p, f"{random.choice(LAST)}, {random.choice(FIRST)} MD", POS["PHYSICIAN"], 1, 1))
for p in NURSES:
    prsnl.append((p, f"{random.choice(LAST)}, {random.choice(FIRST)} RN", POS["NURSE"], 0, 1))
for p in TECHS:
    prsnl.append((p, f"{random.choice(LAST)}, {random.choice(FIRST)} MLS", POS["LABTECH"], 0, 1))
PHYS_NAME = {r[0]: r[1] for r in prsnl}

def new_person(fk, test=False):
    pid = nid("person")
    last = f"ZZTEST{pid}" if test else random.choice(LAST)
    first = random.choice(FIRST)
    bd = dt.datetime(1932, 1, 1) + dt.timedelta(days=int(rng.integers(0, 33_000)))
    person.append((pid, last, first, last.upper(), f"{last}, {first}", fmt(bd), random.choice([MALE, FEMALE]), 1, fmt(START)))
    person_alias.append((nid("alias"), pid, f"{7_000_000 + pid:08d}", MRN, 1, fmt(bd), OPEN_DT))
    if not test:
        fac_pool[fk].append(pid)
    return pid

# ---------------------------------------------------------------- orders & results
def add_result_versions(oid, eid, pid, ek, collected, verified, force_crit=False):
    code, disp, units, nlo, nhi, clo, chi, pcrit, dec = EVENTS[ek]
    def draw(crit):
        if crit:
            if clo is not None and random.random() < 0.4:
                return clo * random.uniform(0.75, 0.97)
            return chi * random.uniform(1.03, 1.6)
        r = random.random()
        if r < 0.72:
            return random.uniform(nlo, nhi)
        if r < 0.86 or clo is None:
            return random.uniform(nhi, chi * 0.97)
        return random.uniform(clo * 1.03, nlo)
    def flag(v):
        if (clo is not None and v < clo) or v >= chi:
            return CRITICAL
        return HIGH if v > nhi else LOW if v < nlo else NORMAL
    val = round(draw(force_crit or random.random() < pcrit), dec)
    event_id = nid("event")
    tech = random.choice(TECHS)
    row = lambda v, st, vfrom, vuntil, vdt: (nid("ce"), event_id, oid, eid, pid, code, f"{v:.{dec}f}", UNITS[units],
                                             flag(v), str(nlo), str(nhi), "" if clo is None else str(clo), str(chi),
                                             st, fmt(collected), fmt(vdt), tech, fmt(vfrom), vuntil, 1)
    r = random.random()
    fix_t = verified + dt.timedelta(hours=random.uniform(0.5, 36))
    if r < 0.012 and fix_t < END:          # corrected result -> two versions
        clinical_event.append(row(val, AUTH, verified, fmt(fix_t), verified))
        new_val = round(draw(random.random() < pcrit), dec)
        clinical_event.append(row(new_val, MODIFIED, fix_t, OPEN_DT, fix_t))
    elif r < 0.016 and fix_t < END:        # result marked In Error
        clinical_event.append(row(val, AUTH, verified, fmt(fix_t), verified))
        clinical_event.append(row(val, INERROR, fix_t, OPEN_DT, fix_t))
    else:
        clinical_event.append(row(val, AUTH, verified, OPEN_DT, verified))
    return flag(val) == CRITICAL

def place_order(enc, ck, t, priority, segs, dup_of=None, force_crit=False):
    """enc: dict with fac, eid, pid. Returns order_id or None."""
    if t >= END:
        return None
    fk = enc["fac"]
    oid = nid("order")
    cat_cd, _, comps = CATALOG[ck]
    doc = random.choice(PHYS)
    order_detail.append((oid, 1, "COLLPRI", priority))
    order_action.append((oid, 1, ACT["ORDER"], fmt(t), doc))
    if dup_of is not None:
        truth_dup.append((oid,))
    f = FAC[fk]
    if priority == "STAT":
        night = t.hour >= 19 or t.hour < 7
        tat = lognorm(f["stat_n"] if night else f["stat_d"], 0.33)
    else:
        tat = lognorm(95, 0.45)
    verified = t + mins(tat)
    collected = t + mins(tat * random.uniform(0.25, 0.40))
    r = random.random()
    cancel_p = 0.35 if dup_of is not None else 0.025
    if r < cancel_p:
        ct = t + mins(random.uniform(5, 60))
        orders.append((oid, enc["eid"], enc["pid"], cat_cd, LAB, OS_CANCELED, fmt(t), fmt(ct), 1))
        order_action.append((oid, 2, ACT["CANCEL"], fmt(ct), random.choice(TECHS)))
        return oid
    if r < cancel_p + 0.006 and enc["disch"] < END and random.random() < 0.85:
        # never collected; the nightly discharge ops job cancels open lab orders at discharge
        orders.append((oid, enc["eid"], enc["pid"], cat_cd, LAB, OS_CANCELED, fmt(t), fmt(enc["disch"]), 1))
        order_action.append((oid, 2, ACT["CANCEL"], fmt(enc["disch"]), None))
        return oid
    if r < cancel_p + 0.006 or verified >= END:   # never collected / still pending at data cut
        orders.append((oid, enc["eid"], enc["pid"], cat_cd, LAB, OS_ORDERED, fmt(t), fmt(t), 1))
        return oid
    orders.append((oid, enc["eid"], enc["pid"], cat_cd, LAB, OS_COMPLETED, fmt(t), fmt(verified), 1))
    order_action.append((oid, 2, ACT["COMPLETE"], fmt(verified), random.choice(TECHS)))
    for ek in comps:
        crit = add_result_versions(oid, enc["eid"], enc["pid"], ek, collected, verified,
                                   force_crit=force_crit and random.random() < 0.5)
        if crit:
            document_critical_call(enc, verified, segs, doc)
    return oid

def unit_at(segs, t):
    for uk, b, e in segs:
        if b <= t < e:
            return uk
    return segs[-1][0]

def document_critical_call(enc, verified, segs, doc):
    """Nurse documents 'Critical Result Notification' (read-back to provider) as its own CLINICAL_EVENT."""
    fk, uk = enc["fac"], unit_at(segs, verified)
    p_missing, med = 0.03, 11
    if uk == "ED":
        med = 9
    if fk == "MN" and uk == "TELE":
        p_missing, med = 0.12, 26
    if random.random() < p_missing:
        return
    t = verified + mins(max(2, lognorm(med, 0.7)))
    if t >= END:
        return
    ev = nid("event")
    clinical_event.append((nid("ce"), ev, None, enc["eid"], enc["pid"], CRIT_NOTIFY,
                           f"Called to {PHYS_NAME[doc]}; read-back verified", None, None, None, None, None, None,
                           AUTH, fmt(t), fmt(t), random.choice(NURSES), fmt(t), OPEN_DT, 1))

def order_panel(enc, t, menu, priority, segs, force_crit=False):
    f = FAC[enc["fac"]]
    for ck, p in menu.items():
        if random.random() < p:
            ot = t + mins(random.uniform(0, 8))
            oid = place_order(enc, ck, ot, priority, segs, force_crit=force_crit)
            if oid and random.random() < f["dup"]:          # accidental duplicate (two providers / re-order)
                place_order(enc, ck, ot + mins(random.uniform(2, 40)), priority, segs, dup_of=oid)

# ---------------------------------------------------------------- encounters
def inpatient_stay(fk, t_admit):
    """Return list of (unit_kind, beg, end) segments and discharge disposition."""
    r = random.random()
    uk = "MEDSURG" if r < .55 else "TELE" if r < .85 else "ICU"
    los = lognorm(3.1 if uk != "ICU" else 3.9, 0.55) * 24 * 60
    los = max(los, 18 * 60)
    disch = t_admit + mins(los)
    disch = disch.replace(hour=random.choice([10, 11, 12, 13, 14, 15, 16, 17]), minute=random.randint(0, 59))
    if disch <= t_admit + dt.timedelta(hours=12):
        disch = t_admit + dt.timedelta(hours=random.uniform(18, 30))
    if uk == "ICU" and random.random() < 0.6:          # step down to med/surg
        mid = t_admit + (disch - t_admit) * random.uniform(0.4, 0.6)
        segs = [("ICU", t_admit, mid), ("MEDSURG", mid, disch)]
    else:
        segs = [(uk, t_admit, disch)]
    d = random.choices(["HOME", "HOMEHEALTH", "SNF", "AMA", "EXPIRED"], [62, 14, 16.5, 3, 2.5])[0]
    return segs, disch, d

queue = []          # (arrive_dt, facility, person_id or None, kind, forced_admit, test)
day = WARMUP
while day < END:
    for fk, f in FAC.items():
        n = rng.poisson(f["ed"] * DOW[day.weekday()])
        for h in rng.choice(24, size=n, p=HOUR_W):
            queue.append((day + dt.timedelta(hours=int(h), minutes=random.uniform(0, 59.9)), fk, None, "ED", False, False))
        for _ in range(rng.poisson(f["direct"])):
            queue.append((day + dt.timedelta(hours=random.uniform(9, 18)), fk, None, "DIRECT", False, False))
        if day.weekday() < 5:
            for _ in range(rng.poisson(f["op"])):
                queue.append((day + dt.timedelta(hours=random.uniform(7, 16)), fk, None, "OP", False, False))
    day += dt.timedelta(days=1)
for i in range(10):                    # test patients (must be excluded from every report)
    pid = new_person("MN", test=True)
    for _ in range(3):
        queue.append((START + dt.timedelta(days=random.uniform(0, 175)), "MN", pid, "ED", False, True))

qi = 0
while qi < len(queue):
    t, fk, pid, kind, forced_admit, test = queue[qi]; qi += 1
    if t >= END:
        continue
    f = FAC[fk]
    if pid is None:
        pid = random.choice(fac_pool[fk]) if fac_pool[fk] and random.random() < 0.12 else new_person(fk)
    eid = nid("encntr")
    enc = dict(fac=fk, eid=eid, pid=pid)
    active = 0 if (kind == "ED" and not test and random.random() < 0.003) else 1
    etype, arrive, reg, ip_admit, disch, disp, segs = ET_ED, t, t + mins(random.uniform(2, 10)), None, None, None, []
    if kind == "ED":
        r = random.random()
        if r < f["lwbs"] and not forced_admit:
            disch = t + mins(lognorm(95, 0.5)); disp = "LWBS"; segs = [("ED", t, disch)]
        elif forced_admit or r < f["lwbs"] + f["admit"]:
            work = lognorm(f["work"], 0.35)
            ip_admit = t + mins(work)
            ed_out = ip_admit + mins(lognorm(f["board"], 0.6))
            ip_segs, disch, disp = inpatient_stay(fk, ed_out)
            segs = [("ED", t, ed_out)] + ip_segs
            etype = ET_IP
        else:
            disch = t + mins(max(35, lognorm(f["tr"], 0.45))); disp = "HOME"; segs = [("ED", t, disch)]
    elif kind == "DIRECT":
        etype, arrive, reg = ET_IP, None, t
        ip_admit = t
        segs, disch, disp = inpatient_stay(fk, t)
    else:
        etype, arrive, reg = ET_OP, None, t
        disch = t + mins(random.uniform(20, 60)); disp = "HOME"; segs = [("OPLAB", t, disch)]
    open_enc = disch >= END
    enc["disch"] = disch
    for uk, b, e in segs:
        if b >= END:
            break
        loc_hist.append((nid("elh"), eid, f["cd"], UNIT[(fk, uk)], fmt(b), OPEN_DT if e >= END else fmt(e), active))
    last_unit = [s for s in segs if s[1] < END][-1][0]
    encounter.append((eid, pid, etype, f["cd"], UNIT[(fk, last_unit)], fmt(arrive) if arrive else None, fmt(reg),
                      fmt(ip_admit) if ip_admit and ip_admit < END else None,
                      None if open_enc else fmt(disch), None if open_enc else DISP[disp], active, fmt(reg)))
    encntr_alias.append((nid("alias"), eid, f"{fk}{eid}", FIN, 1, fmt(reg), OPEN_DT))
    if not active:
        continue
    # ---- lab orders
    if kind == "ED" and disp != "LWBS" or (kind == "ED" and disp == "LWBS" and random.random() < 0.2):
        t0 = t + mins(random.uniform(10, 45))
        order_panel(enc, t0, {"CBC": .75, "BMP": .78, "TROP": .35, "LACT": .12}, "STAT", segs, force_crit=test)
        ed_out = segs[0][2]
        trop_t = t0 + mins(random.uniform(165, 210))       # serial troponin (clinically intended, NOT a duplicate)
        if trop_t < ed_out and random.random() < 0.20:
            place_order(enc, "TROP", trop_t, "STAT", segs)
        # clinically intended early repeats (NOT duplicates): sepsis repeat lactate, recheck BMP after K+ replacement
        for ck, p_rep, lo, hi in [("LACT", .07, 90, 180), ("BMP", .035, 60, 150)]:
            rt = t0 + mins(random.uniform(lo, hi))
            if rt < ed_out and random.random() < p_rep:
                place_order(enc, ck, rt, "STAT", segs)
    if kind == "OP":
        order_panel(enc, t + mins(5), {"CBC": .6, "BMP": .7}, "Routine", segs)
    for uk, b, e in segs:                                  # daily AM labs while on an inpatient unit
        if uk in ("ED", "OPLAB"):
            continue
        d = (b + dt.timedelta(days=1)).replace(hour=4, minute=0, second=0)
        while d < e and d < END:
            am = d + mins(random.uniform(0, 90))
            order_panel(enc, am, {"CBC": .85, "BMP": .9, "LACT": .15 if uk == "ICU" else 0}, "Routine", segs)
            if uk == "TELE" and random.random() < 0.08:
                place_order(enc, "TROP", d + dt.timedelta(hours=random.uniform(8, 20)), "STAT", segs)
            d += dt.timedelta(days=1)
    # ---- readmission
    if etype == ET_IP and not open_enc and disp != "EXPIRED" and not test:
        mult = {"HOME": .85, "HOMEHEALTH": 1.1, "SNF": 1.3, "AMA": 2.0}[disp]
        if random.random() < f["readmit"] * mult:
            back = disch + dt.timedelta(days=min(29.5, max(0.5, random.expovariate(1 / 9))))
            rf = fk if random.random() < 0.85 else random.choice(list(FAC))
            queue.append((back, rf, pid, "ED", True, False))

# ---------------------------------------------------------------- staffed beds (calibrated to target occupancy)
def midnight_census():
    days = (END - START).days
    counts = {}
    for _, eid, fcd, ucd, b, e, act in loc_hist:
        if not act:
            continue
        b = dt.datetime.fromisoformat(b); e = END if e == OPEN_DT else dt.datetime.fromisoformat(e)
        m = max(START, (b + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0) if b.time() != dt.time(0) else b)
        while m < e and m < END:
            counts[ucd] = counts.get(ucd, 0) + 1
            m += dt.timedelta(days=1)
    return {u: c / days for u, c in counts.items()}

census = midnight_census()
capacity = []
for (fk, uk), ucd in UNIT.items():
    if uk in ("ED", "OPLAB"):
        continue
    beds = max(4, round(census.get(ucd, 0) / TARGET_OCC[fk][uk]))
    capacity.append((ucd, FAC[fk]["cd"], beds))

# ---------------------------------------------------------------- write
DB.parent.mkdir(exist_ok=True)
if DB.exists():
    DB.unlink()
con = sqlite3.connect(DB)
con.executescript((ROOT / "sql" / "schema.sql").read_text())
con.executemany("INSERT INTO code_value_set VALUES (?,?)", CODE_SETS.items())
con.executemany("INSERT INTO code_value VALUES (?,?,?,?,?,?,1)",
                [(c, s, d, "".join(ch for ch in d.upper() if ch.isalnum()), m, d) for c, s, d, m in CV])
con.executemany("INSERT INTO cust_unit_capacity VALUES (?,?,?)", capacity)
con.executemany("INSERT INTO person VALUES (?,?,?,?,?,?,?,?,?)", person)
con.executemany("INSERT INTO person_alias VALUES (?,?,?,?,?,?,?)", person_alias)
con.executemany("INSERT INTO prsnl VALUES (?,?,?,?,?)", prsnl)
con.executemany("INSERT INTO encounter VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", encounter)
con.executemany("INSERT INTO encntr_alias VALUES (?,?,?,?,?,?,?)", encntr_alias)
con.executemany("INSERT INTO encntr_loc_hist VALUES (?,?,?,?,?,?,?)", loc_hist)
con.executemany("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?)", orders)
con.executemany("INSERT INTO order_detail VALUES (?,?,?,?)", order_detail)
con.executemany("INSERT INTO order_action VALUES (?,?,?,?,?)", order_action)
con.executemany("INSERT INTO clinical_event VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", clinical_event)
con.executemany("INSERT INTO zz_truth_dup_order VALUES (?)", truth_dup)
con.commit()
con.execute("ANALYZE")
for tbl in ["code_value", "person", "prsnl", "encounter", "encntr_loc_hist", "orders", "order_detail",
            "order_action", "clinical_event", "cust_unit_capacity"]:
    print(f"{tbl:20s} {con.execute(f'select count(*) from {tbl}').fetchone()[0]:>9,}")
con.close()
print("written", DB)
