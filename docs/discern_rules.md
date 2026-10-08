# Discern rules and silent-mode testing

Both rules are defined in [`rules/discern_rules.json`](../rules/discern_rules.json) using the usual Discern Expert layout: what triggers the rule (evoke), the conditions it checks (logic), and what the user sees (action).

Before turning a rule on, I want to know two things: how often it will fire, and how often it will be right. So `src/discern_rules.py` replays six months of orders and results through each rule in **silent mode**. Every firing is logged to EKS_MODULE_AUDIT, but nobody gets an alert.

The duplicate-order logic is also written as a CCL program, [`ccl/cust_eks_dup_lab_order.prg`](../ccl/cust_eks_dup_lab_order.prg), that the rule can call through the EKS_EXEC_CCL_L template. It returns `retval = 100` when the condition is true and puts the details in `log_message`.

## The two rules

**CUST_LAB_DUP_ORDER: duplicate lab order**
- **Fires when:** a lab order is signed.
- **Checks:** whether the same test was already ordered on this encounter within N minutes, and that earlier order hadn't been cancelled.
- **Shows:** an interruptive alert. The provider either cancels the new order or keeps it and gives a reason.

**CUST_CRIT_LAB_ESCALATE: critical result not called**
- **Fires when:** 30 minutes have passed since a critical lab result was verified.
- **Checks:** whether a critical-result call has been documented on the encounter yet.
- **Shows:** a message to the charge nurse pool for the patient's unit, plus a task.

## Expected volume

Silent mode, January–June 2026:

| Rule | Mercy North | Mercy South | Lakeside Regional |
|---|---|---|---|
| Duplicate order (120-min window, as requested) | 3,657 (20.2 a day) | 1,270 (7.0 a day) | 818 (4.5 a day) |
| Critical-result escalation | 179 (1.0 a day) | 154 (0.9 a day) | 96 (0.5 a day) |

## Choosing the look-back window

The lab committee asked for 120 minutes. But some repeat orders inside that window are deliberate:
- a repeat lactate 1.5 to 3 hours later for sepsis
- a BMP recheck after potassium replacement
- serial troponins about 3 hours apart

Firing an interruptive alert on those is how alert fatigue starts: people learn to click through. So I ran the rule at several window sizes and compared the firings with the orders I knew were real duplicates.

| Window (min) | Firings | Real duplicates | Intended repeats (false alerts) | Precision | Recall |
|---|---|---|---|---|---|
| 30 | 3,737 | 3,735 | 2 | 99.9% | 72.0% |
| **60** | **5,221** | **5,150** | **71** | **98.6%** | **99.3%** |
| 120 | 6,143 | 5,150 | 993 | 83.8% | 99.3% |
| 240 | 8,364 | 5,150 | 3,214 | 61.6% | 99.3% |
| 1,440 | 43,362 | 5,155 | 38,207 | 11.9% | 99.4% |

![Window comparison](../assets/06_rule_window_sensitivity.png)

**My recommendation: 60 minutes.** It catches the same real duplicates as 120 minutes, with 71 false alerts instead of 993.

For go-live, I'd do three things:
1. Leave the rule in silent mode in production for another two weeks and review the audit table each week.
2. Turn it on at Mercy North first, since it has three times the duplicate rate of the other two hospitals.
3. Roll it out to the other two after that.

**One caveat.** I can only measure precision and recall here because the generator records which orders were accidental duplicates (the `zz_truth_dup_order` table). In a live system you'd get the same answer by chart-reviewing a sample of the firings.
