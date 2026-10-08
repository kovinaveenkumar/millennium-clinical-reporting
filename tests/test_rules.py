"""Discern rule simulator: logic and window trade-off."""
import pandas as pd
import pytest

from discern_rules import RULES, dup_rule_fires, load_orders


@pytest.fixture(scope="module")
def orders(con):
    return load_orders(con)


def orderables():
    return next(r for r in RULES if r["module_name"] == "CUST_LAB_DUP_ORDER")["logic"]["orderables"]


def test_rule_ignores_prior_order_cancelled_before_sign():
    t = pd.Timestamp
    o = pd.DataFrame({"order_id": [1, 2], "encntr_id": [9, 9], "catalog_cd": [5, 5], "orderable": ["CBC", "CBC"],
                      "orig_order_dt_tm": [t("2026-01-01 10:00"), t("2026-01-01 10:20")],
                      "cancel_dt_tm": [t("2026-01-01 10:05"), pd.NaT], "true_dup": [0, 0], "person_id": [1, 1]})
    assert dup_rule_fires(o, 60, ["CBC"]).empty
    o.loc[0, "cancel_dt_tm"] = t("2026-01-01 11:00")            # cancelled AFTER the new order was signed
    assert list(dup_rule_fires(o, 60, ["CBC"]).order_id) == [2]


def test_60_minute_window_is_accurate(orders):
    hit = dup_rule_fires(orders, 60, orderables())
    precision = hit.true_dup.mean()
    recall = hit.true_dup.sum() / orders.true_dup.sum()
    assert precision > 0.95 and recall > 0.95


def test_wide_window_floods_intended_repeats(orders):
    assert dup_rule_fires(orders, 1440, orderables()).true_dup.mean() < 0.30
