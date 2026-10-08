# Discern rules: silent-mode evaluation

Two rules are defined in [`rules/discern_rules.json`](../rules/discern_rules.json) using the Discern Expert structure: **EVOKE** (trigger), **LOGIC** (conditions) and **ACTION** (what the user sees). [`src/discern_rules.py`](../src/discern_rules.py) replays six months of orders and results through the logic in **silent mode**: every time the logic is true it writes a row to `EKS_MODULE_AUDIT`, and nobody is alerted. That is the usual way to measure a rule before turning it on: how often will it fire, and how often will it be right?

The logic for the duplicate-order rule also exists as an EKS-callable CCL program, [`ccl/cust_eks_dup_lab_order.prg`](../ccl/cust_eks_dup_lab_order.prg). It sets `retval = 100` for true and fills `log_message`, so the rule can run it through the EKS_EXEC_CCL_L template.

| Rule | Evoke | Logic | Action (in production) |
|---|---|---|---|
| `CUST_LAB_DUP_ORDER` | Lab order signed | Same orderable on this encounter within N min, and that earlier order not cancelled at sign time | Interruptive alert: cancel the new order, or keep it with a reason |
| `CUST_CRIT_LAB_ESCALATE` | 30 min after a critical lab result verifies | No "Critical Result Notification" documented on the encounter since verification | Message to the unit's charge nurse pool, plus a task |

## Projected volume (silent mode, Jan–Jun 2026)

| Rule | Mercy North | Mercy South | Lakeside Regional |
|---|---|---|---|
| CUST_LAB_DUP_ORDER (120-min window as requested) | 3,657 (20.2/day) | 1,270 (7.0/day) | 818 (4.5/day) |
| CUST_CRIT_LAB_ESCALATE | 179 (1.0/day) | 154 (0.9/day) | 96 (0.5/day) |

## Choosing the duplicate-order window

The lab committee asked for a 120-minute window. Some fast repeats are intended, though: a repeat lactate at 1.5–3 h for sepsis, a recheck BMP after potassium replacement, and a serial troponin at ~3 h. An interruptive alert on those trains clinicians to click through, which is alert fatigue. Replaying the rule at several windows against the generator's ground truth gives:

| Window (min) | Firings | True duplicates | Intended repeats (false alerts) | Precision | Recall |
|---|---|---|---|---|---|
| 30 | 3,737 | 3,735 | 2 | 99.9% | 72.0% |
| **60** | **5,221** | **5,150** | **71** | **98.6%** | **99.3%** |
| 120 | 6,143 | 5,150 | 993 | 83.8% | 99.3% |
| 240 | 8,364 | 5,150 | 3,214 | 61.6% | 99.3% |
| 1,440 | 43,362 | 5,155 | 38,207 | 11.9% | 99.4% |

![window sensitivity](../assets/06_rule_window_sensitivity.png)

**Recommendation.** Go live with **60 minutes**. It catches the same true duplicates as 120 minutes with **14× fewer false alerts** (71 vs 993). Go-live plan: keep silent mode for 2 more weeks in production, review the audit weekly, then move to production at Mercy North first, since that facility has 3× the duplicate rate of the others.

*Caveat:* precision and recall can be measured here only because the data generator records which orders were accidental duplicates (`zz_truth_dup_order`). In a live domain, the same table would be built by chart review of a sample of firings.
