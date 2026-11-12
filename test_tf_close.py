#!/usr/bin/env python3
"""Self-check for EngulfingAutoTrader's closed-bar (TF CLOSE) signal predicate.

Extracts the c_* predicate lines straight from the .mq5 so this test fails if
the source drifts. No MQL5 compiler is available, so this is the cheapest thing
that actually breaks when the logic breaks.

Run: python3 test_tf_close.py
"""
import os
import random
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "EngulfingAutoTrader", "EngulfingAutoTrader.mq5")


def predicates(src):
    """Return (buy_src, sell_src) predicate text blocks from the .mq5."""
    def grab(anchor, stop):
        i = src.index(anchor)
        j = src.index(stop, i)
        return src[i:j]

    buy = grab("bool c_bear_prev", "EvaluatePriceFilter(r_check[0].close, g_rules[r].bull_price_filter)")
    sell = grab("bool c_bull_prev", "EvaluatePriceFilter(r_check[0].close, g_rules[r].bear_price_filter)")
    return buy, sell


class Bar(dict):
    __getattr__ = dict.__getitem__


def eval_block(block, r0, r1, ratio):
    """Evaluate a predicate block, translating C++ operators to Python."""
    ns = {"r_check": [r0, r1], "InpBodyRatioMult": ratio}
    for line in block.split("\n"):
        line = line.strip()
        m = re.match(r"bool (c_\w+)\s*=\s*(.+);$", line)
        if m:
            ns[m.group(1)] = eval(translate(m.group(2)), {}, ns)
    guard = [l.strip() for l in block.split("\n") if l.strip().startswith("if(c_")]
    assert guard, "closed-bar block has no final guard"
    expr = guard[0][3:].split("&& EvaluatePriceFilter")[0].strip()
    expr = expr.rstrip(" )").rstrip("&").strip()
    return bool(eval(translate(expr), {}, ns))


def translate(expr):
    return expr.replace("||", " or ").replace("&&", " and ")


# --- reference implementations: ports of the live-bar detectors -------------
def ref_bull(cur, prev, ratio):
    if prev["close"] >= prev["open"]:
        return False
    return (cur["close"] > cur["open"]
            and (cur["close"] >= prev["high"] or cur["high"] >= prev["high"])
            and cur["low"] <= prev["low"]
            and (cur["close"] - cur["open"]) > (prev["open"] - prev["close"]) * ratio)


def ref_bear(cur, prev, ratio):
    if prev["close"] <= prev["open"]:
        return False
    return (cur["close"] < cur["open"]
            and (cur["close"] <= prev["low"] or cur["low"] <= prev["low"])
            and cur["high"] >= prev["high"]
            and (cur["open"] - cur["close"]) > (prev["close"] - prev["open"]) * ratio)


def rand_bar(rng):
    o = round(rng.uniform(1.09, 1.10), 5)
    c = round(o + rng.uniform(-0.002, 0.002), 5)
    h = round(max(o, c) + rng.uniform(0, 0.001), 5)
    l = round(min(o, c) - rng.uniform(0, 0.001), 5)
    return Bar(open=o, high=h, low=l, close=c)


def demo():
    src = open(SRC).read()
    buy, sell = predicates(src)

    # 1. The regression that motivated this test: a bullish prev candle must NOT
    #    produce a BUY signal. Before the c_bear_prev fix this fired.
    prev_bull = Bar(open=1.0900, high=1.0920, low=1.0895, close=1.0915)
    engulfing_up = Bar(open=1.0905, high=1.0935, low=1.0890, close=1.0930)
    assert not eval_block(buy, engulfing_up, prev_bull, 1.0), \
        "BUY fired with a bullish prev candle (c_bear_prev missing?)"

    # Mirror case for SELL.
    prev_bear = Bar(open=1.0915, high=1.0920, low=1.0895, close=1.0900)
    engulfing_dn = Bar(open=1.0910, high=1.0925, low=1.0880, close=1.0885)
    assert not eval_block(sell, engulfing_dn, prev_bear, 1.0), \
        "SELL fired with a bearish prev candle (c_bull_prev missing?)"

    # 2. a genuine engulfing pair still fires
    bear_prev = Bar(open=1.0900, high=1.0905, low=1.0880, close=1.0885)
    bull_cur = Bar(open=1.0884, high=1.0910, low=1.0880, close=1.0908)
    assert eval_block(buy, bull_cur, bear_prev, 1.0), "genuine BUY engulfing did not fire"
    assert ref_bull(bull_cur, bear_prev, 1.0), "reference disagrees on genuine BUY"

    bull_prev = Bar(open=1.0885, high=1.0910, low=1.0880, close=1.0908)
    bear_cur = Bar(open=1.0909, high=1.0912, low=1.0870, close=1.0872)
    assert eval_block(sell, bear_cur, bull_prev, 1.0), "genuine SELL engulfing did not fire"
    assert ref_bear(bear_cur, bull_prev, 1.0), "reference disagrees on genuine SELL"

    # 3. exhaustive-ish equivalence with the reference detectors
    rng = random.Random(11)
    mism_b = mism_s = 0
    for _ in range(5000):
        prev, cur = rand_bar(rng), rand_bar(rng)
        if eval_block(buy, cur, prev, 1.0) != ref_bull(cur, prev, 1.0):
            mism_b += 1
        if eval_block(sell, cur, prev, 1.0) != ref_bear(cur, prev, 1.0):
            mism_s += 1
    assert mism_b == 0 and mism_s == 0, \
        "closed-bar predicate diverged from reference: buy=%d sell=%d" % (mism_b, mism_s)

    print("test_tf_close: OK (prev-direction enforced, genuine engulfings fire,"
          " 0 mismatches vs reference over 5000 random pairs)")


if __name__ == "__main__":
    try:
        demo()
    except Exception as exc:  # noqa: BLE001 - a test, any failure is a failure
        print("test_tf_close: FAILED -> %s" % exc)
        sys.exit(1)
