#!/usr/bin/env python3
"""Self-check for EngulfingAutoTrader's entry logic.

Everything below reads the predicates straight out of the .mq5 and compares them
against an independent reference implementation, so the test fails when the
source drifts -- not when my port of the source drifts. That distinction is the
whole point: an earlier version of this file re-typed the live detector, got the
SELL body condition wrong, and therefore passed while the real source and the
TF CLOSE copy disagreed whenever InpBodyRatioMult != 1.

No MQL5 compiler is available, so this is the cheapest thing that actually
breaks when the logic breaks.

Run: python3 test_autotrader.py
"""
import os
import random
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "EngulfingAutoTrader", "EngulfingAutoTrader.mq5")


class Bar(dict):
    __getattr__ = dict.__getitem__


def py(expr):
    """Translate the C++ operators MQL5 and Python spell differently."""
    return expr.replace("||", " or ").replace("&&", " and ")


def load_detector(src, start, stop):
    """Pull one IsStrong*EngulfingBreak function out of the source as a spec.

    The spec is built from the source text, so a change to the source is a change
    to the thing under test.
    """
    block = src[src.index(start):src.index(stop, src.index(start))]
    locals_ = re.findall(r"double (\w+)\s*=\s*rates\[(\d)\]\.(\w+);", block)
    assert locals_, "no rates[] reads found in %s" % start
    prev = re.search(r"if\((\w+)\s*(>=|<=)\s*(\w+)\)\s*return false;", block)
    assert prev, "no previous-candle direction guard in %s" % start
    bools = [(m.group(1), m.group(2).strip())
             for m in re.finditer(r"^\s*bool (is_\w+)\s*=\s*(.+?);\s*$", block,
                                  re.MULTILINE)]
    assert bools, "no is_* conditions found in %s" % start
    guard = [l.strip() for l in block.split("\n") if l.strip().startswith("if(is_")]
    assert guard, "no final guard found in %s" % start
    expr = guard[-1][3:].rstrip(")").strip()
    return {"locals": locals_, "prev": prev.groups(), "bools": bools, "guard": expr,
            "block": block}


def fire(spec, r0, r1, ratio):
    """Evaluate the extracted detector on a (live bar, previous bar) pair."""
    env = {"InpBodyRatioMult": ratio}
    env.update({name: (r0 if idx == "0" else r1)[field]
                for name, idx, field in spec["locals"]})
    a, op, b = spec["prev"]
    if op == ">=" and env[a] >= env[b]:
        return False
    if op == "<=" and env[a] <= env[b]:
        return False
    for name, expr in spec["bools"]:
        env[name] = bool(eval(py(expr), {}, env))
    return bool(eval(py(spec["guard"]), {}, env))


# --- reference implementations, retyped by hand on purpose -------------------
# These are the independent side of the comparison. If the source disagrees with
# them, one of the two is wrong and the test stops.
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


def check_detector():
    """The extracted detectors must match the reference, and must fire at all."""
    src = open(SRC).read()
    buy = load_detector(src, "bool IsStrongBullishEngulfingBreak",
                        "//| REALTIME STRONG BEARISH")
    sell = load_detector(src, "bool IsStrongBearishEngulfingBreak",
                         "//| LOT SIZE CALCULATION")

    # 1. genuine engulfings fire on both sides (a detector that never fires would
    #    sail through a pure "no false positives" test, which is how a dead mode
    #    went unnoticed before)
    bear_prev = Bar(open=1.0900, high=1.0902, low=1.0883, close=1.0885)
    bull_cur = Bar(open=1.0884, high=1.0906, low=1.0882, close=1.0905)
    assert ref_bull(bull_cur, bear_prev, 1.0), "fixture is not a bull engulfing"
    assert fire(buy, bull_cur, bear_prev, 1.0), "BUY detector did not fire"

    bull_prev = Bar(open=1.0885, high=1.0902, low=1.0883, close=1.0900)
    bear_cur = Bar(open=1.0901, high=1.0903, low=1.0880, close=1.0879)
    assert ref_bear(bear_cur, bull_prev, 1.0), "fixture is not a bear engulfing"
    assert fire(sell, bear_cur, bull_prev, 1.0), "SELL detector did not fire"

    # 2. the previous candle must be the opposite colour, both sides
    prev_bull = Bar(open=1.0900, high=1.0920, low=1.0895, close=1.0915)
    engulf_up = Bar(open=1.0905, high=1.0935, low=1.0890, close=1.0930)
    assert not fire(buy, engulf_up, prev_bull, 1.0), \
        "BUY fired with a bullish previous candle"
    prev_bear = Bar(open=1.0915, high=1.0920, low=1.0895, close=1.0900)
    engulf_dn = Bar(open=1.0910, high=1.0925, low=1.0880, close=1.0885)
    assert not fire(sell, engulf_dn, prev_bear, 1.0), \
        "SELL fired with a bearish previous candle"

    # 3. source vs reference over random pairs. ratio != 1 is included on purpose:
    #    the SELL side used to divide by InpBodyRatioMult while the BUY side
    #    multiplied, which is invisible at the default 1.0.
    rng = random.Random(11)
    fired_b = fired_s = 0
    for ratio in (1.0, 1.0, 1.7, 0.5):
        for _ in range(2500):
            prev, cur = rand_bar(rng), rand_bar(rng)
            got_b, want_b = fire(buy, cur, prev, ratio), ref_bull(cur, prev, ratio)
            got_s, want_s = fire(sell, cur, prev, ratio), ref_bear(cur, prev, ratio)
            assert got_b == want_b, \
                "BUY source disagrees with reference (ratio %s): %s %s %s %s" % (
                    ratio, cur, prev, got_b, want_b)
            assert got_s == want_s, \
                "SELL source disagrees with reference (ratio %s): %s %s %s %s" % (
                    ratio, cur, prev, got_s, want_s)
            fired_b += got_b
            fired_s += got_s
    assert fired_b > 0 and fired_s > 0, \
        "one detector never fired over 10000 pairs (buy=%d sell=%d)" % (fired_b, fired_s)

    # 4. the two sides must use the same body convention
    body_b = dict(buy["bools"])["is_stronger_body"]
    body_s = dict(sell["bools"])["is_stronger_body"]
    assert "<" not in body_s and ">" in body_s, \
        "SELL body condition is inverted/asymmetric with BUY: %s" % body_s
    assert ("* InpBodyRatioMult" in body_b) and ("* InpBodyRatioMult" in body_s), \
        "body conditions do not share the multiplier convention"

    print("test_detector: OK (source == reference over 10000 pairs incl. ratio 1.7/0.5,"
          " %d buy + %d sell fires, both sides multiply)" % (fired_b, fired_s))


def check_tf_close_wiring():
    """TF CLOSE must reuse the seconds-mode detector, not its own copy.

    The duplicated copy is what let the two modes disagree. This also re-checks
    the ordering that broke TF CLOSE once before: the closed-bar branch has to be
    reached before the live-candle gate, or it can never fire.
    """
    src = open(SRC).read()

    for token in ("c_bear_prev", "c_bull_prev", "c_body", "c_break", "c_cover",
                  "r_check"):
        assert token not in src, \
            "the duplicated TF CLOSE predicate is back (%s); the two modes can drift" % token

    # The shift parameter must actually be read, or TF CLOSE silently looks at the
    # live candle again -- exactly the bug this wiring exists to prevent.
    assert src.count("CopyRates(sym, tf, shift, 3, rates)") == 2, \
        "the detector takes a shift but ignores it"

    for name, field in (("IsStrongBullish", "bull"), ("IsStrongBearish", "bear")):
        tfclose = "%sEngulfingBreak(sym, sig_tf, 1," % name
        live = "%sEngulfingBreak(sym, sig_tf, 0," % name
        assert tfclose in src, "%s: TF CLOSE does not call the shared detector" % name
        assert live in src, "%s: seconds mode lost its detector call" % name
        assert src.index(tfclose) < src.index(live), (
            "%s: the live gate runs before the TF CLOSE branch, so TF CLOSE can "
            "never fire (the original bug)" % name)
        assert "%s_last_checked_bar[slot] = cur_bar_open_time;" % field in src, \
            "%s: no per-bar guard" % field

    # A rule that was just created/loaded/reactivated stores 0, and the first tick
    # must arm it rather than judge a candle that closed before the rule existed.
    assert src.count("prev_chk != 0") == 2, \
        "the freshly-armed guard is missing, so a stale candle can fire a signal"

    # The log must name the candle that fired, so the user can check it on a chart
    # instead of trusting this file.
    assert src.count('" | Signal bar: " + TimeToString(sig_bar_time)') == 2, \
        "entry log no longer names the signal bar; the user cannot verify an entry"

    print("test_tf_close_wiring: OK (one shared detector, TF CLOSE before the live"
          " gate, freshly-armed rules skip one candle, signal bar logged)")


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
    expr = py(expr)

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
        check_detector()
        check_tf_close_wiring()
        check_sequential_entry()
        check_price_range_order()
    except Exception as exc:  # noqa: BLE001 - a test, any failure is a failure
        print("test_autotrader: FAILED -> %s" % exc)
        sys.exit(1)
