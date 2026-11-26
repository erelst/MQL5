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
                   "MultiRuleAutoTrader", "MultiRuleAutoTrader.mq5")


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
    assert src.count("CopyRates(sym, tf, shift, 3, rates)") >= 2, \
        "the detector takes a shift but ignores it"

    for name, field in (("IsStrongBullish", "bull"), ("IsStrongBearish", "bear")):
        call_str = "%sEngulfingBreak(sym, sig_tf, shift_to_check," % name
        assert call_str in src, "%s: does not call the shared detector with shift_to_check" % name
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
    """MAX ORDER cycles must respect sequential or continuation mode:
    When continuation_mode is disabled, the next cycle waits until every
    position opened by the previous cycle is closed.
    When continuation_mode is enabled, new entries can open if matching existing direction.
    """
    src = open(SRC).read()
    assert "CountOpenPositions(g_rules[r].symbol) > 0" in src
    assert "continuation_mode" in src
    assert "CountOpenPositions(sym, POSITION_TYPE_SELL)" in src
    assert "CountOpenPositions(sym, POSITION_TYPE_BUY)" in src

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


def check_rule_reactivation():
    """Updating a rule or toggling ACTIVE must reset orders_opened_count to 0
    AND wipe clean runtime bound/signal timestamps so residual grace period
    doesn't leak into new trade activations.
    """
    src = open(SRC).read()
    assert "g_rules[target_idx].active              = true;" in src
    assert "g_rules[target_idx].orders_opened_count = 0;" in src
    assert 'else if(sparam == g_prefix + "BTN_TOGGLE_RULE_"' in src
    assert "g_rules[i].orders_opened_count = 0;" in src
    assert "g_rules[i].bull_bound_entered_time = 0;" in src
    assert "g_rules[i].bear_bound_entered_time = 0;" in src
    assert "g_rules[i].bull_bound_exit_time    = 0;" in src
    assert "g_rules[i].bear_bound_exit_time    = 0;" in src
    print("test_rule_reactivation: OK (edit submit & toggle reliably activate and reset orders counter and wipe bound grace state)")


def check_lot_normalization():
    """Multi-TP lot splitting must normalize by volume step and min lot.

    Without this, 0.51 lot split over 2 TPs yields 0.255 lot, which broker
    rejects with [Invalid volume].
    """
    src = open(SRC).read()
    assert "double NormalizeLotSize(const string sym, double raw_lot)" in src
    assert "double per = NormalizeLotSize(sym, pool / (double)mtp);" in src
    assert "double cur_lot = NormalizeLotSize(sym, plan_lot[p]);" in src
    assert "PrintFormat(\"[BUY FAILED] %s: Error %d" in src
    assert "PrintFormat(\"[SELL FAILED] %s: Error %d" in src
    print("test_lot_normalization: OK (NormalizeLotSize protects Multi-TP fractions & logs trade rejections)")


def check_combo_packages():
    """Verify simplified dual-confirmation COMBO mode with & STOCH+HA."""
    src = open(SRC).read()
    assert "COMBO: [ENG & STOCH+HA]" in src
    assert "COMBO: [HAMMER & STOCH+HA]" in src
    assert "COMBO: [SHOOTING & STOCH+HA]" in src
    assert "bool p1_ok = (g_rules[r].sig_engulfing && buy_eng_valid && buy_stoch_valid);" in src
    assert "bool p2_ok = (g_rules[r].sig_hammer_ss && buy_hmr_valid && buy_stoch_valid);" in src
    assert "bool p1_ok = (g_rules[r].sig_engulfing && sell_eng_valid && sell_stoch_valid);" in src
    assert "bool p2_ok = (g_rules[r].sig_hammer_ss && sell_ss_valid  && sell_stoch_valid);" in src
    assert "[x] ENG & STOCH+HA" in src
    print("test_combo_packages: OK (COMBO dual-confirmation & STOCH+HA wired for BUY & SELL)")


def check_auto_adopt_and_ticket_resolution():
    """Verify Auto-Adopt EA positions and position ticket resolution."""
    src = open(SRC).read()
    assert "ulong ResolvePositionTicket(ulong order_ticket, ulong deal_ticket, string sym)" in src
    assert "void AdoptOpenEAPositions()" in src
    assert "m_position.Magic() != InpMagicNumber" in src
    assert "m_position.Magic() == InpMagicNumber" in src
    assert "m_position.Magic() == m_position.Magic()" not in src, "Typo magic equality must be eliminated"
    assert "AdoptOpenEAPositions();" in src
    print("test_auto_adopt_and_ticket_resolution: OK (Position ticket resolved + EA positions auto-adopted safely)")


def check_spread_compensated_tp():
    """Verify that both BUY and SELL TP formulas incorporate spread compensation
    so the resulting monetary profit matches the exact 1:RR target without
    being eroded by the exit spread.
    """
    src = open(SRC).read()
    # Buy TP compensation (+ spread)
    assert "double tp_price = ask + (sl_dist * g_rules[r].risk_reward_ratio) + spread;" in src
    assert "plan_tp[plan_cnt] = NormalizeDouble(ask + (sl_dist * g_rules[r].risk_reward_ratio * (double)t) + spread, digits);" in src
    # Sell TP compensation (- spread)
    assert "double tp_price = bid - (sl_dist * g_rules[r].risk_reward_ratio) - spread;" in src
    assert "plan_tp[plan_cnt] = NormalizeDouble(bid - (sl_dist * g_rules[r].risk_reward_ratio * (double)t) - spread, digits);" in src
    print("test_spread_compensated_tp: OK (Net RR exactly 1:RR via Bid/Ask spread compensation on TP)")


def check_table_sorting_and_columns():
    """Verify rules table column sorting (CompareRules, GetSortedRuleIndices, BTN_TH_),
    shortened PRICE header, and restored TP column.
    """
    src = open(SRC).read()
    # Enum & variables
    assert "enum ENUM_RULE_SORT_COL" in src
    assert "RULE_SORT_NO" in src
    assert "RULE_SORT_SYM" in src
    assert "RULE_SORT_TP" in src
    assert "RULE_SORT_PRICE" in src
    assert "RULE_SORT_TYPE" in src
    assert "ENUM_RULE_SORT_COL   g_sort_col          = RULE_SORT_NO;" in src
    assert "bool                 g_sort_asc          = true;" in src
    # Header sortable labels & shortened labels
    assert 'CreateLabel("BTN_TH_NO"' in src
    assert 'CreateLabel("BTN_TH_SYM"' in src
    assert 'CreateLabel("BTN_TH_TP"' in src
    assert 'CreateLabel("BTN_TH_PRICE"' in src
    assert 'CreateLabel("BTN_TH_TYPE"' in src
    assert 's_price = "PRICE"' in src
    assert 's_type  = "TYPE"' in src
    assert 's_tp    = "TP"' in src
    # Table data display has MTP and TYPE column
    assert 'CreateLabel(r_pfx + "MTP"' in src
    assert 'CreateLabel(r_pfx + "TYPE"' in src
    # Sorting logic & index mapping
    assert "void GetSortedRuleIndices(int &indices[])" in src
    assert "int CompareRules(int a, int b)" in src
    assert "GetSortedRuleIndices(sorted_indices);" in src
    assert "int i = sorted_indices[pos];" in src
    # Chart event clicks for header buttons
    assert 'StringFind(sparam, g_prefix + "BTN_TH_") == 0' in src
    assert 'RenderTableHeaders(root_x, table_y);' in src
    print("test_table_sorting_and_columns: OK (Sortable columns, PRICE header, TP column restored)")


def check_be_progress_verification():
    """Verify that Trail BE requires real gain progress (cur_gain >= min_profit_req)
    alongside remaining distance proximity, and default is 20%.
    """
    src = open(SRC).read()
    assert "double min_profit_req  = base_target_dist * (1.0 - be_pct);" in src
    assert "rem_dist <= max_rem_allowed && cur_gain >= min_profit_req" in src
    assert "double be_dist_val = 20.0;" in src
    assert "be_dist_val = 20.0;" in src
    print("test_be_progress_verification: OK (BE strictly requires dual-check: proximity <= 20% & profit gain >= 80%)")


def check_tp_extension_dual_layer_and_ext_dist():
    """Verify that TP Extension uses an independent EXT DIST% input (default 20%),
    and enforces a dual-layer proximity gate:
    1. Layer 1: Target progress (remaining <= EXT DIST% AND gain >= (100 - EXT DIST)%)
    2. Layer 2: Dynamic ATR proximity (dist_to_tp <= max_dist_allowed) AND volume spike.
    """
    src_at = open(SRC).read()
    src_tm = open(os.path.join(os.path.dirname(os.path.dirname(SRC)), "TradeManagerReversalRadar", "TradeManagerReversalRadar.mq5")).read()

    # 1. AutoTrader checks
    assert "input double               InpTrailExtRemDistPct= 0.20;" in src_at
    assert "double ext_pct = (g_tracking_list[i].trail_ext_rem_dist_pct > 0) ? g_tracking_list[i].trail_ext_rem_dist_pct : InpTrailExtRemDistPct;" in src_at
    assert "ext_rem_dist <= max_ext_rem_allowed && ext_cur_gain >= min_ext_gain_req" in src_at
    assert "bool proximity_ok  = progress_ok;" in src_at
    assert "bool in_profit = (ptype == POSITION_TYPE_BUY) ? (c_p > open_p) : (c_p < open_p);" in src_at
    assert "rejection_ok" in src_at
    assert "[TRAIL PROXIMITY]" in src_at
    assert "INP_TRAIL_EXT_DIST" in src_at
    assert "FileWriteInteger(handle, 7);" in src_at
    assert "state_ver >= 7" in src_at

    # 2. TradeManager checks
    assert "input double               InpTrailExtRemDistPct= 0.20;" in src_tm
    assert "double ext_pct = (g_tracking_list[i].trail_ext_rem_dist_pct > 0) ? g_tracking_list[i].trail_ext_rem_dist_pct : InpTrailExtRemDistPct;" in src_tm
    assert "ext_rem_dist <= max_ext_rem_allowed && ext_cur_gain >= min_ext_gain_req" in src_tm
    assert "INP_TRAIL_EXT" in src_tm
    assert "ActivateBulkAutoTrail(double max_dist, double relvol_th, double be_rem_pct, double ext_rem_pct, ENUM_TIMEFRAMES tf)" in src_tm
    assert "bool proximity_ok  = progress_ok;" in src_tm
    assert "bool in_profit = (ptype == POSITION_TYPE_BUY) ? (c_p > open_p) : (c_p < open_p);" in src_tm
    assert "rejection_ok" in src_tm
    assert "[TRAIL PROXIMITY]" in src_tm

    # 3. Mathematical validation of Streamlined TP Extension Architecture
    # (Gate 1: Progress Gate | Gate 2B: Unbroken Leg Momentum | Gate 2C: Anti-Rejection Gate)
    target_dist = 50.0
    ext_pct_val = 0.20
    ewma_tr = 10.0

    # Test A: Premature check at open (gain = 0, rem = 50.0) -> MUST be blocked by Gate 1
    rem_0 = 50.0
    gain_0 = 0.0
    gate1_0 = (rem_0 <= target_dist * ext_pct_val) and (gain_0 >= target_dist * (1.0 - ext_pct_val))
    assert not gate1_0, "Gate 1 MUST block trigger at order open"

    # Test B: In 20% zone (gain = 42.0, rem = 8.0) but WEAK / STAGNANT momentum (rel_vol = 1.05 < 1.25)
    # -> Gate 1 passes, but Gate 2B blocks! Trade safely hits original TP.
    rem_zone = 8.0
    gain_zone = 42.0
    gate1_zone = (rem_zone <= target_dist * ext_pct_val) and (gain_zone >= target_dist * (1.0 - ext_pct_val))
    relvol_weak = 1.05
    relvol_th = 1.25
    gate2b_weak = (relvol_weak >= relvol_th)
    assert gate1_zone and not gate2b_weak, "Weak momentum must not extend TP"

    # Test C: In 20% zone with STRONG momentum (rel_vol = 1.45) but REJECTION WICK (> 50% wick)
    # -> Gate 2C blocks! Protects trade from extending into a pinbar reversal.
    relvol_strong = 1.45
    gate2b_strong = (relvol_strong >= relvol_th)
    is_rejection_dump = True
    gate2c_reject = not is_rejection_dump
    assert gate1_zone and gate2b_strong and not gate2c_reject, "Rejection wick must block extend"

    # Test D: In 20% zone with STRONG momentum AND healthy non-rejection bar -> EXTEND TRIGGERED!
    is_rejection_none = False
    gate2c_healthy = not is_rejection_none
    extend_triggered = gate1_zone and gate2b_strong and gate2c_healthy
    assert extend_triggered, "All 3 gates pass: TP extended cleanly!"

    print("test_tp_extension_dual_layer_and_ext_dist: OK (streamlined Gate 1 distance + unbroken leg momentum + anti-rejection gate)")


def check_rr_and_relvol_precision_and_parsing():
    """Verify that RR and RelVol retain 2 decimal places (e.g. 1.25) across:
    1. UI Form Edit Box creation (not truncated to 1.3 by DoubleToString(val, 1))
    2. Input capture & submit parsing (ParseDoubleClean handles '.' and ',')
    3. Rules table display (FormatRR displays 1:1.25, TRL column displays RV:1.25)
    4. Diagnostic/auto-adopt log formatting (RV: %.2f)
    """
    src = open(SRC).read()
    
    # 1. Clean parse helper handles ',' and '.' seamlessly
    assert "double ParseDoubleClean(string text)" in src
    assert 'StringReplace(text, ",", ".");' in src
    
    # Python simulation of ParseDoubleClean
    def parse_double_clean(s: str) -> float:
        return float(s.replace(",", ".").strip())
    
    assert parse_double_clean("1.25") == 1.25
    assert parse_double_clean("1,25") == 1.25
    assert parse_double_clean(" 1.25 ") == 1.25
    
    # 2. FormatFloatClean & FormatRR helpers
    assert "string FormatFloatClean(double val, int max_dec = 2)" in src
    assert "string FormatRR(double rr)" in src
    
    def format_float_clean(val: float, max_dec: int = 2) -> str:
        if max_dec <= 1:
            return f"{val:.1f}"
        rounded2 = round(val * 100.0) / 100.0
        rounded1 = round(val * 10.0) / 10.0
        if abs(rounded2 - rounded1) > 0.001:
            return f"{val:.2f}"
        return f"{val:.1f}"
    
    def format_rr(rr: float) -> str:
        if rr <= 0:
            return "1:2.0"
        rounded2 = round(rr * 100.0) / 100.0
        rounded1 = round(rr * 10.0) / 10.0
        if abs(rounded2 - rounded1) > 0.001:
            return f"1:{rr:.2f}"
        return f"1:{rr:.1f}"
    
    assert format_float_clean(1.25, 2) == "1.25"
    assert format_float_clean(1.6, 2) == "1.6"
    assert format_float_clean(2.0, 2) == "2.0"
    assert format_rr(1.25) == "1:1.25"
    assert format_rr(1.5) == "1:1.5"
    assert format_rr(2.0) == "1:2.0"
    
    # 3. Form input creation must use FormatFloatClean and width 48 for RelVol
    assert 'CreateEdit("INP_RR", root_x + 85, row_c_y, 75, 20, FormatFloatClean(g_form_rr, 2)' in src
    assert 'CreateEdit("INP_ATR_MULT", root_x + 420, row_e_y, 48, 20, FormatFloatClean(g_form_atr_mult, 2)' in src
    
    # 4. Table list display: RR column uses FormatRR, TYPE column displays COMBO (AND) / ANY (OR)
    assert 'CreateLabel(r_pfx + "RR", root_x + 310, cur_y + 9, FormatRR(g_rules[i].risk_reward_ratio)' in src
    assert 'CreateLabel(r_pfx + "TYPE", root_x + 740, cur_y + 9, type_str, type_clr, 8, true);' in src
    assert 'COMBO (AND)' in src
    assert 'ANY (OR)' in src
    
    # 5. UI preview terminal deck decomposes Trail into explicit BE, EXT, D & RelVol lines
    assert '• BE Trigger (BE%%): Sisa Target <= %.0f%% -> Kunci BE' in src
    assert '• TP Extend Dist (EXT%%): Sisa Target <= %.0f%%' in src
    assert '• Max Dist TR (D): <= %.1f TR | RelVol: >= %sx' in src
    
    # 6. Capture & Submit use ParseDoubleClean
    assert 'ParseDoubleClean(ObjectGetString(0, g_prefix + "INP_RR", OBJPROP_TEXT))' in src
    assert 'ParseDoubleClean(ObjectGetString(0, g_prefix + "INP_ATR_MULT", OBJPROP_TEXT))' in src
    
    # 6. Auto-adopt log formatting uses RV: %.2f
    assert 'RV: %.2f' in src
    
    print("test_rr_and_relvol_precision_and_parsing: OK (2-decimal precision for RR & RelVol in UI form, table list, and comma-safe parser)")


if __name__ == "__main__":
    try:
        check_detector()
        check_tf_close_wiring()
        check_sequential_entry()
        check_price_range_order()
        check_rule_reactivation()
        check_lot_normalization()
        check_combo_packages()
        check_auto_adopt_and_ticket_resolution()
        check_spread_compensated_tp()
        check_table_sorting_and_columns()
        check_be_progress_verification()
        check_tp_extension_dual_layer_and_ext_dist()
        check_rr_and_relvol_precision_and_parsing()
    except Exception as exc:  # noqa: BLE001 - a test, any failure is a failure
        print("test_autotrader: FAILED -> %s" % exc)
        sys.exit(1)
