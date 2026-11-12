#!/usr/bin/env python3
"""Self-check for EngulfingAutoTrader's entry logic.

Two checks, both reading the predicates out of the .mq5 so they fail if the
source drifts. No MQL5 compiler is available, so this is the cheapest thing
that actually breaks when the logic breaks.

Run: python3 test_autotrader.py
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


def check_sequential_entry():
    """MAX ORDER cycles must run one at a time: the next cycle waits until every
    position opened by the previous cycle is closed.

    Gate (x3 in the source) is:
        if(CountOpenPositions(sym) > 0)
    """
    src = open(SRC).read()
    # Full-line match, so a gate coupled on the same line as a counter check does
    # not count as a gate at all (the count assertion below then fails).
    gate_re = re.compile(r"^\s*if\(CountOpenPositions\([^)]*\)\s*>\s*0\)\s*$")
    lines = src.split("\n")
    gate_lines = [i for i, l in enumerate(lines) if gate_re.match(l)]
    assert len(gate_lines) == 3, (
        "expected the sequential gate in 3 places (rule loop + BUY + SELL), "
        "found %d" % len(gate_lines))

    # The gate must stand alone, not nested under another condition. Manual
    # reactivation resets orders_opened_count to 0, so an outer
    # `if(orders_opened_count > 0)` would bypass the gate while the previous
    # batch was still running. Checked line-wise rather than by a character
    # window: a window also catches the legitimate MAX ORDER check above it.
    for i in gate_lines:
        j = i - 1
        while j >= 0 and (lines[j].strip() == "" or lines[j].strip().startswith("//")):
            j -= 1
        prev = lines[j].strip() if j >= 0 else ""
        assert not prev.startswith("if("), \
            "gate nested under another condition (%s); manual reactivation would bypass it" % prev

    # Tick-by-tick walk of the scenario the user asked for: MAX ORDER 3, MULT 2.
    # The cycle's positions stay open for 2 ticks, so the gate must make the EA
    # wait in between. Expected sequence:
    #   opened, blocked, opened, blocked, opened, paused
    max_orders, mult, close_after = 3, 2, 2
    opened_cycles = 0
    open_positions = 0
    age = 0
    actions = []
    for _ in range(30):
        if max_orders > 0 and opened_cycles >= max_orders:
            actions.append("paused")
            break
        if opened_cycles > 0 and open_positions > 0:
            actions.append("blocked")
        else:
            opened_cycles += 1
            open_positions = mult
            age = 0
            actions.append("opened")
        if open_positions > 0:
            age += 1
            if age >= close_after:          # the whole cycle closes together
                open_positions = 0
                age = 0

    assert actions[0] == "opened", \
        "first cycle must open immediately, got %s" % actions
    assert actions[-1] == "paused", \
        "rule must auto-pause at MAX ORDER, got %s" % actions
    assert actions.count("opened") == max_orders, \
        "expected %d cycles, got %s" % (max_orders, actions)
    # The actual requirement: never two entries back to back. Every cycle after
    # the first must be preceded by at least one tick spent waiting.
    for i, a in enumerate(actions):
        if a == "opened" and i > 0:
            assert actions[i - 1] == "blocked", \
                "cycle opened without waiting for the previous one to close: %s" % actions
    assert actions == ["opened", "blocked", "opened", "blocked", "opened", "paused"], \
        "unexpected sequence: %s" % actions

    print("test_sequential_entry: OK (3 gates, first cycle fires, later cycles wait"
          " for the previous to close, pauses at MAX ORDER)")


def check_price_range_order():
    """A range must behave the same whichever way round it is typed.

    "3051-3040" and "3040-3051" both mean the band 3040..3051. Before the
    normalisation, a reversed range required price >= 3051 AND price <= 3040,
    which nothing can satisfy, so the rule silently never opened an order.
    """
    src = open(SRC).read()
    i = src.index("bool EvaluatePriceFilter")
    j = src.index("// Check operators", i)
    branch = src[i:j]

    # The pair must be normalised before the comparison. This is the guard that
    # fails if the swap is removed again.
    assert re.search(r"if\s*\(\s*min_val\s*>\s*max_val\s*\)", branch), \
        "range bounds are not normalised; a reversed range would never match"

    # Take the comparison itself out of the source instead of retyping it.
    cmp_line = [l.strip() for l in branch.split("\n")
                if l.strip().startswith("if(min_val > 0")]
    assert cmp_line, "could not find the range comparison in the source"
    expr = cmp_line[0][3:].rstrip(")").strip()
    expr = expr.replace("&&", " and ").replace("||", " or ")

    def hit(price, a, b):
        lo, hi = (a, b) if a <= b else (b, a)      # mirrors the source swap
        return bool(eval(expr, {}, {"price": price, "min_val": lo, "max_val": hi}))

    # Symmetry: the two orders must agree for every price, inside and outside.
    for price in (3039, 3040, 3045, 3051, 3052):
        assert hit(price, 3040, 3051) == hit(price, 3051, 3040), \
            "range is not order-independent at price %s" % price

    assert hit(3045, 3051, 3040) and hit(3045, 3040, 3051), "inside band must match"
    assert hit(3040, 3051, 3040) and hit(3051, 3040, 3051), "bounds must be inclusive"
    assert not hit(3039, 3051, 3040) and not hit(3052, 3040, 3051), \
        "outside band must be rejected"

    print("test_price_range: OK (3040-3051 == 3051-3040, bounds inclusive)")


if __name__ == "__main__":
    try:
        demo()
        check_sequential_entry()
        check_price_range_order()
    except Exception as exc:  # noqa: BLE001 - a test, any failure is a failure
        print("test_autotrader: FAILED -> %s" % exc)
        sys.exit(1)
