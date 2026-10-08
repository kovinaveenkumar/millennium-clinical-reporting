"""Static charts for the README (assets/*.png), drawn from output/csv/*.csv.   python src/make_charts.py"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CSV = ROOT / "output" / "csv"
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)

# Facility colours are fixed (colour follows the entity, never its rank): validated categorical slots 1-3
FAC_ORDER = ["Mercy North", "Mercy South", "Lakeside Regional"]
FAC_COLOR = {"Mercy North": "#2a78d6", "Mercy South": "#eb6834", "Lakeside Regional": "#1baf7a"}
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.family": "sans-serif", "font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.spines.top": False, "axes.spines.right": False,
                     "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "axes.titlesize": 12,
                     "axes.titleweight": "bold", "axes.titlelocation": "left", "axes.titlecolor": INK})


def save(fig, name):
    fig.tight_layout()
    fig.savefig(ASSETS / name, dpi=150)
    plt.close(fig)
    print("assets/" + name)


def target_line(ax, y, label, horizontal=True):
    (ax.axhline if horizontal else ax.axvline)(y, color=INK2, lw=1, ls="--", zorder=1)
    if horizontal:
        ax.text(ax.get_xlim()[1], y, f" {label}", va="center", ha="left", color=INK2, fontsize=9)
    else:
        ax.text(y, ax.get_ylim()[1], label, va="bottom", ha="center", color=INK2, fontsize=9)


# 1 ED: admitted patients' time in ED = work-up + boarding
ed = pd.read_csv(CSV / "ed_throughput.csv").set_index("facility").loc[FAC_ORDER[::-1]]
work = (ed.median_los_admitted_min - ed.median_boarding_min) / 60
board = ed.median_boarding_min / 60
fig, ax = plt.subplots(figsize=(8, 3.2))
ax.barh(ed.index, work, color="#86b6ef", height=0.55, label="Work-up (arrival to admit decision)")
ax.barh(ed.index, board, left=work + 0.03, color="#1c5cab", height=0.55, label="Boarding (admit decision to leaving ED)")
for i, (w, b) in enumerate(zip(work, board)):
    ax.text(w + b + 0.1, i, f"{w + b:.1f} h total, {b:.1f} h boarding", va="center", color=INK, fontsize=9)
ax.set_xlim(0, (work + board).max() * 1.45)
ax.set_xlabel("Median hours in the ED, admitted patients")
ax.set_title(f"Lakeside Regional: admitted ED patients board {board['Lakeside Regional']:.0f} h for a bed")
ax.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.28), ncol=2, fontsize=9)
ax.grid(axis="x", color=GRID, lw=0.6); ax.set_axisbelow(True)
save(fig, "01_ed_boarding.png")

# 2 Lab: STAT % within 60 by hour
h = pd.read_csv(CSV / "lab_tat_stat_by_hour.csv")
fig, ax = plt.subplots(figsize=(8, 3.8))
for f in FAC_ORDER:
    d = h[h.facility == f]
    ax.plot(d.order_hour, d.pct_within_60, color=FAC_COLOR[f], lw=2, marker="o", ms=4, label=f)
ax.axvspan(-0.5, 6.5, color=GRID, alpha=0.5, lw=0); ax.axvspan(18.5, 23.5, color=GRID, alpha=0.5, lw=0)
ax.text(3, 103, "night shift", ha="center", color=INK2, fontsize=9); ax.text(21, 103, "night shift", ha="center", color=INK2, fontsize=9)
ax.set_xlim(-0.5, 23.5); ax.set_ylim(0, 108); ax.set_xticks(range(0, 24, 3))
ax.set_xlabel("Hour the STAT lab was ordered", labelpad=2); ax.set_ylabel("% resulted within 60 min")
ax.axhline(80, color=INK2, lw=1, ls="--", zorder=1, label="80% target")
ax.set_title("Mercy South misses the STAT lab target mainly on night shift")
ax.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.2), fontsize=9, ncol=4)
ax.grid(axis="y", color=GRID, lw=0.6); ax.set_axisbelow(True)
save(fig, "02_stat_tat_by_hour.png")

# 3 Critical results by unit
c = pd.read_csv(CSV / "critical_compliance.csv")
c = c[c.critical_results >= 20].sort_values("pct_within_30")
fig, ax = plt.subplots(figsize=(8, 4.6))
ax.barh(c.nurse_unit, c.pct_within_30, color=[FAC_COLOR[f] for f in c.facility], height=0.62)
for i, r in enumerate(c.itertuples()):
    ax.text(r.pct_within_30 + 0.8, i, f"{r.pct_within_30:.0f}%  ({r.critical_results} results, {r.not_documented} not documented)",
            va="center", fontsize=8.5, color=INK)
ax.set_xlim(0, 130); ax.set_xlabel("% of critical results called to provider within 30 min")
ax.axvline(80, color=INK2, ls="--", lw=1); ax.text(80, len(c) - 0.3, "80% threshold", color=INK2, fontsize=9, ha="center")
handles = [plt.Rectangle((0, 0), 1, 1, color=FAC_COLOR[f]) for f in FAC_ORDER]
ax.legend(handles, FAC_ORDER, frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.14), ncol=3, fontsize=9)
worst = c.iloc[0]
ax.set_title(f"{worst.nurse_unit}: only {worst.pct_within_30:.0f}% of critical results called within 30 min")
save(fig, "03_critical_calls_by_unit.png")

# 4 Occupancy: med/surg units, 7-day rolling
cd = pd.read_csv(CSV / "census_daily.csv", parse_dates=["census_date"])
cd = cd[cd.nurse_unit.str.contains("Med/Surg")]
fig, ax = plt.subplots(figsize=(8, 3.6))
for f in FAC_ORDER:
    d = cd[cd.facility == f].set_index("census_date")
    ax.plot(d.index, d.occupancy_pct.rolling(7, min_periods=1).mean(), color=FAC_COLOR[f], lw=2, label=f)
ax.axhline(100, color=INK2, ls="--", lw=1, label="Staffed beds full")
ax.set_ylabel("Midnight occupancy %, 7-day avg"); ax.set_ylim(60, 130)
ax.set_title("Lakeside Regional Med/Surg runs at or over staffed beds")
ax.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.12), fontsize=9, ncol=4)
ax.grid(axis="y", color=GRID, lw=0.6); ax.set_axisbelow(True)
save(fig, "04_medsurg_occupancy.png")

# 5 Readmissions by disposition
rd = pd.read_csv(CSV / "readmit_by_disposition.csv")
order = ["Home/Self Care", "Home Health", "Skilled Nursing Facility", "Left Against Medical Advice"]
fig, ax = plt.subplots(figsize=(8, 3.8))
w = 0.26
for j, f in enumerate(FAC_ORDER):
    d = rd[rd.facility == f].set_index("disposition").reindex(order)
    xs = [i + (j - 1) * (w + 0.02) for i in range(len(order))]
    ax.bar(xs, d.readmit_rate_pct, width=w, color=FAC_COLOR[f], label=f)
ax.set_xticks(range(len(order))); ax.set_xticklabels(["Home", "Home health", "Skilled nursing", "Left AMA"])
ax.set_ylabel("30-day readmission %")
ax.set_title("Mercy South's readmissions are higher for every discharge type")
ax.legend(frameon=False, fontsize=9, loc="upper left")
ax.grid(axis="y", color=GRID, lw=0.6); ax.set_axisbelow(True)
save(fig, "05_readmit_by_disposition.png")

# 6 Discern rule: window sensitivity (windows on an ordinal axis, equally spaced)
s = pd.read_csv(ROOT / "output" / "rule_window_sensitivity.csv")
s = s[s.window_min <= 480].reset_index(drop=True)
x = range(len(s))
fig, ax = plt.subplots(figsize=(8, 3.8))
ax.plot(x, s.precision_pct, color="#2a78d6", lw=2, marker="o", ms=6, label="Precision: firings that are true duplicates")
ax.plot(x, s.recall_pct, color="#eb6834", lw=2, marker="s", ms=6, label="Recall: true duplicates caught")
k = int(s.index[s.window_min == 60][0]); rec = s.loc[k]
ax.axvline(k, color=INK2, ls="--", lw=1)
ax.text(k + 0.08, 47, f"60 min: {rec.precision_pct:.0f}% precision,\n{rec.recall_pct:.0f}% recall, "
        f"{rec.intended_repeats:.0f} false alerts\n(120 min: {s.loc[k + 1].intended_repeats:.0f})", fontsize=9, color=INK, va="bottom")
ax.set_xticks(list(x)); ax.set_xticklabels(s.window_min)
ax.set_xlabel("Look-back window (minutes)"); ax.set_ylabel("%"); ax.set_ylim(40, 105)
ax.set_title("Duplicate-order rule: a 60-minute window is the best trade-off")
ax.legend(frameon=False, fontsize=9, loc="upper center", bbox_to_anchor=(0.5, -0.2), ncol=2)
ax.grid(axis="y", color=GRID, lw=0.6); ax.set_axisbelow(True)
save(fig, "06_rule_window_sensitivity.png")
