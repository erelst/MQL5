//+------------------------------------------------------------------+
//|                                   MultiRuleAutoTrader.mq5        |
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "3.00"
#property description "Multi-Rule Auto Execution EA on Realtime Reversals with Flexible Price Bounds & Max Orders Control"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMS & STRUCTS                                                  |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION
{
   TRADE_DIR_BOTH, // Buy and Sell
   TRADE_DIR_BUY,  // Buy Only
   TRADE_DIR_SELL  // Sell Only
};

enum ENUM_LOT_MODE
{
   LOT_FIXED,      // Fixed Lot Size
   LOT_RISK_PCT    // Risk Percentage (% Balance per SL)
};

enum ENUM_SIGNAL_MODE
{
   SIGNAL_MODE_ANY,   // ANY (OR): Entri jika salah satu sinyal valid
   SIGNAL_MODE_COMBO  // COMBO (AND): Entri jika semua sinyal terpilih valid
};

enum ENUM_TRAIL_BE_MODE
{
   TRAIL_BE_PROFIT,   // Opsi 1: Berbasis Profit Berjalan (1.5x EWMA TR dari Open)
   TRAIL_BE_PROXIMITY // Opsi 2: Berbasis Kedekatan TP (sisa jarak <= 1.1x EWMA TR)
};

struct AutoTraderRule
{
   string               symbol;
   ENUM_TRADE_DIRECTION direction;
   double               risk_reward_ratio;
   ENUM_TIMEFRAMES      timeframe;
   ENUM_LOT_MODE        lot_mode;
   double               lot_value;
   bool                 enable_trail;
   double               trail_trigger_pct; // Legacy trigger % or fallback
   double               atr_multiplier;
   string               bull_price_filter; // e.g. "< 1.0850", "<= 1.0820", "4040-4078", "ALL"
   string               bear_price_filter; // e.g. "> 1.0900", ">= 1.0910", "4040-4078", "ALL"
   int                  max_orders;        // 1 = 1x open then paused, 0/-1 = Unlimited
   int                  entry_multiplier;  // Number of positions to open per trigger (1 = 1 order)
   int                  multi_tp;          // Number of TP tiers per entry (1 = single TP / no splitting)
   int                  delay_tf_pct;      // % TF progress delay (0..99%, 30 = default)
   bool                 delay_is_tf_close; // true = wait for TF candle close, false = % TF progress
   int                  orders_opened_count; // Tracks total opened orders for this rule lifecycle
   bool                 active;
   // Signal Selection Flags
   bool                 sig_engulfing;     // Strong Engulfing Reversal
   bool                 sig_hammer_ss;     // Strong Hammer (Buy) / Strong Shooting Star (Sell)
   bool                 sig_stoch_ha;      // Stochastic + Heikin Ashi Reversal
   ENUM_SIGNAL_MODE     signal_mode;       // ANY (OR) vs COMBO (AND)
   // Runtime State (RAM only - not in .bin)
   datetime             bull_bound_entered_time; // When price was inside bull bound
   datetime             bear_bound_entered_time; // When price was inside bear bound
   datetime             bull_bound_exit_time;    // When price left bull bound (starts 1.5x TF grace)
   datetime             bear_bound_exit_time;    // When price left bear bound (starts 1.5x TF grace)
   datetime             last_bull_bar[2];        // [0]=own TF, [1]=M1 fallback (M5 rules only)
   datetime             last_bear_bar[2];
   datetime             bull_last_checked_bar[2];// TF Close check per signal TF
   datetime             bear_last_checked_bar[2];
};

struct SPositionTracking
{
   ulong    ticket;
   string   symbol;
   ENUM_TIMEFRAMES timeframe;
   double   initial_atr100;
   double   initial_tp_dist;
   double   prev_tp_level;
   int      trail_cycle;
   double   trail_trigger_pct;
   double   atr_multiplier;
   bool     be_applied;       // Track if BE has already been locked
   bool     active;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== DEFAULT NEW RULE SETTINGS ==="
input ENUM_TRADE_DIRECTION InpTradeDirection   = TRADE_DIR_BOTH; // Default Direction
input double               InpRiskRewardRatio  = 2.0;            // Default RR Ratio (1:RR)
input int                  InpMaxOrders        = 1;              // Default Max Orders (1 = 1x open then paused, 0 = Unlimited)
input int                  InpEntryMultiplier  = 1;              // Default Entri Multiplier (Multi-Position per Trigger)
input int                  InpMultiTP          = 1;              // Default Multi TP (Tiered Take Profit per entry; 1 = single TP)
input int                  InpDelayTFPct       = 30;             // Default Entry Delay (% TF Progress, 0..99)
input bool                 InpDelayIsTfClose   = false;          // Default Entry Delay Mode (false = % TF Progress, true = TF Close)
input int                  InpSlippage         = 10;             // Max Slippage (Points)
input ulong                InpMagicNumber      = 882201;         // Magic Number

input group "=== SIGNALS & COMBO CONFIGURATION ==="
input bool                 InpDefaultSigEng    = true;           // Default Enable Engulfing Reversal
input bool                 InpDefaultSigHmrSS  = true;           // Default Enable Hammer/Shooting Star
input bool                 InpDefaultSigStochHA= true;           // Default Enable Stoch + Heikin Ashi
input ENUM_SIGNAL_MODE     InpDefaultSigMode   = SIGNAL_MODE_ANY;// Default Signal Mode (ANY/COMBO)

input group "=== AUTO TRAIL SL & TP (EWMA TR ENGINE) ==="
input bool                 InpEnableTrail      = true;           // Default Enable Trail SL & TP
input ENUM_TRAIL_BE_MODE   InpTrailBEMode      = TRAIL_BE_PROXIMITY; // Default Trail BE Mode
input double               InpTrailTriggerPct  = 5.0;            // Fallback Trigger Pct (%)
input double               InpEWMALambda       = 0.90;           // EWMA TR Lambda Decay (0.88 - 0.92)
input int                  InpEWMABars         = 30;             // EWMA TR Baseline Bars
input double               InpRelVolThreshold  = 1.60;           // Relative Volatility Threshold (>= 1.60x)
input double               InpMaxDistATR       = 1.10;           // Max Proximity to TP (in EWMA TR units)
input double               InpExtendFactor     = 0.70;           // TP Extension Factor (excess * ATR * factor)
input double               InpMaxExtendATR     = 1.80;           // Max TP Extension (in ATR units)

input group "=== STOCHASTIC & HEIKIN ASHI ==="
input int                  InpStochLength      = 14;             // Stochastic Length
input int                  InpStochK           = 1;              // %K Smoothing
input int                  InpStochD           = 3;              // %D Smoothing
input double               InpStochOB          = 80.0;           // Overbought Level
input double               InpStochOS          = 20.0;           // Oversold Level

input group "=== NOTIFICATIONS & ALERTS ==="
input bool                 InpEnablePushAlerts = true;           // Send Mobile Push Notifications
input bool                 InpEnableSoundAlerts= true;           // Enable Terminal / Sound Alerts

input group "=== MONEY MANAGEMENT ==="
input ENUM_LOT_MODE        InpLotMode          = LOT_RISK_PCT;   // Default Lot Mode
input double               InpFixedLot         = 0.01;           // Default Fixed Lot Size
input double               InpRiskPercent      = 1.0;            // Default Risk Percent (% Balance)

input group "=== ATR & BODY SETTINGS ==="
input ENUM_TIMEFRAMES      InpTimeframe        = PERIOD_M5;      // Default Timeframe
input int                  InpATRPeriod        = 14;             // ATR Period for 50% calculation
input double               InpBodyRatioMult    = 1.0;            // Min Body Ratio vs Previous Candle

// UI Colors
#define CLR_CANVAS_BG       C'0,0,0'
#define CLR_PANEL_BG        C'8,10,14'
#define CLR_CARD_BG         C'16,19,27'
#define CLR_CARD_ALT        C'20,25,36'
#define CLR_BORDER_HARD     C'42,55,82'
#define CLR_BORDER_SOFT     C'28,36,54'
#define CLR_TEXT_PURE       C'255,255,255'
#define CLR_TEXT_MED        C'180,198,231'
#define CLR_CYAN_NEON       C'0,229,255'
#define CLR_BULL_NEON       C'0,230,118'
#define CLR_BEAR_NEON       C'255,46,77'
#define CLR_GOLD_NEON       C'255,179,0'
#define CLR_TAB_ACTIVE_BG   C'34,21,8'
#define CLR_POWER_ON_BG     C'8,34,18'
#define CLR_POWER_OFF_BG    C'34,8,18'
#define CLR_ROW_SELECTED    C'20,38,60'

//+------------------------------------------------------------------+
//| GLOBALS & DYNAMIC STATE                                          |
//+------------------------------------------------------------------+
CTrade               m_trade;
CPositionInfo        m_position;
CSymbolInfo          m_symbol_info;

string               g_prefix = "EAT_";
bool                 g_master_power_enabled = true;

// Active Form & Preview States (Persistent across rule additions)
string               g_form_sym         = _Symbol;
ENUM_TRADE_DIRECTION g_form_direction   = TRADE_DIR_BOTH;
double               g_form_rr          = 2.00;
ENUM_TIMEFRAMES      g_form_tf          = PERIOD_M5;
ENUM_LOT_MODE        g_form_lot_mode    = LOT_RISK_PCT;
double               g_form_lot_val     = 1.0;
bool                 g_form_trail_on    = true;
double               g_form_trail_pct   = 5.0;
double               g_form_atr_mult    = 1.6;
int                  g_form_max_orders  = 1;
int                  g_form_entry_mult  = 1;
int                  g_form_multi_tp   = 1;
int                  g_form_delay_pct   = 30; // % TF progress delay (0..99)
bool                 g_form_delay_close = false;
bool                 g_form_sig_eng     = true;
bool                 g_form_sig_hmr     = true;
bool                 g_form_sig_stoch   = true;
ENUM_SIGNAL_MODE     g_form_sig_mode    = SIGNAL_MODE_ANY;
string               g_form_bmax        = "ALL";
string               g_form_smin        = "ALL";

int                  g_selected_rule_idx = 0;
int                  g_editing_rule_idx  = -1; // -1 = Add mode, >=0 = Edit mode
int                  g_rules_page        = 0;
const int            RULES_PER_PAGE      = 5;

AutoTraderRule       g_rules[];
SPositionTracking    g_tracking_list[];

// Forward declarations
void CreateDashboardUI();
void UpdateDashboardUI();
void UpdatePreviewTerminalBox();
void DestroyDashboardUI();
void SaveStateToFile();
void LoadStateFromFile();
void ProcessAutoTrailSLTP();
void RegisterPositionTracking(ulong ticket, string sym, ENUM_TIMEFRAMES tf, double atr100, double open_p, double tp_p, double trail_pct, double atr_mult);
string FindExactOrMarketWatchSymbol(string input_sym);
bool EvaluatePriceFilter(double price, string filter_str);
double GetTrueRange(const string sym, const ENUM_TIMEFRAMES tf, int shift = 0);
double GetEWMA_TR(const string sym, const ENUM_TIMEFRAMES tf, int barsToUse = 30, double lambda = 0.90);
bool CheckAndExtendTP(ulong ticket, double relVolThreshold, double maxDistATR, double extendFactor, double maxExtendATR, double lambda);
bool IsStrongHammer(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_low, double &out_cur_price);
bool IsStrongShootingStar(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_high, double &out_cur_price);
bool CheckStochHA(const string sym, const ENUM_TIMEFRAMES tf, const int shift, bool check_buy);

//+------------------------------------------------------------------+
//| FLEXIBLE PRICE FILTER EVALUATION (<, >, <=, >=, RANGE, ALL)       |
//+------------------------------------------------------------------+
bool EvaluatePriceFilter(double price, string filter_str)
{
   StringTrimLeft(filter_str);
   StringTrimRight(filter_str);
   StringToUpper(filter_str);
   
   if(filter_str == "" || filter_str == "ALL" || filter_str == "BEBAS" || filter_str == "FREE")
      return true;
      
   // Check range format e.g. "4040-4078" or "1.0820-1.0850"
   int dash_pos = StringFind(filter_str, "-");
   if(dash_pos > 0)
   {
      string s_min = StringSubstr(filter_str, 0, dash_pos);
      string s_max = StringSubstr(filter_str, dash_pos + 1);
      StringTrimLeft(s_min); StringTrimRight(s_min);
      StringTrimLeft(s_max); StringTrimRight(s_max);
      
      double min_val = StringToDouble(s_min);
      double max_val = StringToDouble(s_max);
      // Order does not matter: "3051-3040" is the same band as "3040-3051".
      // Without this, a reversed range required price >= 3051 AND price <= 3040,
      // which is impossible, so the rule silently never opened an order.
      if(min_val > max_val)
      {
         double tmp = min_val;
         min_val = max_val;
         max_val = tmp;
      }
      if(min_val > 0 && max_val > 0 && price >= min_val && price <= max_val)
         return true;
      return false;
   }
   
   // Check operators: <=, >=, <, >
   if(StringFind(filter_str, "<=") == 0)
   {
      double val = StringToDouble(StringSubstr(filter_str, 2));
      return (price <= val);
   }
   if(StringFind(filter_str, ">=") == 0)
   {
      double val = StringToDouble(StringSubstr(filter_str, 2));
      return (price >= val);
   }
   if(StringFind(filter_str, "<") == 0)
   {
      double val = StringToDouble(StringSubstr(filter_str, 1));
      return (price < val);
   }
   if(StringFind(filter_str, ">") == 0)
   {
      double val = StringToDouble(StringSubstr(filter_str, 1));
      return (price > val);
   }
   
   // Strict Validation: Plain number without operator or range is rejected
   return false;
}

//+------------------------------------------------------------------+
//| FAST DIRECT ATR CALCULATION                                      |
//+------------------------------------------------------------------+
double CalculateATR100(const string sym, const ENUM_TIMEFRAMES tf, int period)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, tf, 1, period + 1, rates);
   if(copied < period) return 0.0;
   
   double tr_sum = 0.0;
   for(int i = 0; i < period; i++)
   {
      double h_l = rates[i].high - rates[i].low;
      double h_pc = MathAbs(rates[i].high - rates[i + 1].close);
      double l_pc = MathAbs(rates[i].low - rates[i + 1].close);
      double tr = MathMax(h_l, MathMax(h_pc, l_pc));
      tr_sum += tr;
   }
   return (tr_sum / (double)period);
}

double CalculateATR50(const string sym, const ENUM_TIMEFRAMES tf, int period)
{
   return CalculateATR100(sym, tf, period) * 0.5;
}

// ponytail: M1 is the only exception -> ATR(14) basis comes from M5 candles
ENUM_TIMEFRAMES AtrBaseTF(const ENUM_TIMEFRAMES rule_tf)
{
   return (rule_tf == PERIOD_M1) ? PERIOD_M5 : rule_tf;
}

// ponytail: M5 rule also accepts M1 engulfing signals; every other TF stays exclusive
int CandidateTFs(const ENUM_TIMEFRAMES rule_tf, ENUM_TIMEFRAMES &out[])
{
   if(rule_tf == PERIOD_M5)
   {
      ArrayResize(out, 2);
      out[0] = PERIOD_M5;   // priority: the rule's own TF first
      out[1] = PERIOD_M1;   // fallback early signal
      return 2;
   }
   ArrayResize(out, 1);
   out[0] = rule_tf;
   return 1;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG BULLISH ENGULFING BREAK DETECTION                |
//+------------------------------------------------------------------+
// ponytail: shift=0 reads the live candle (seconds mode), shift=1 the bar that
// just closed (TF CLOSE mode). One predicate for both modes: the hand-typed
// TF CLOSE copy this replaces had drifted (SELL body divided in live mode).
bool IsStrongBullishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                   double &out_atr_50, double &out_broken_low, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close;
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price   = cur_close;
   out_broken_low  = prev_low;
   
   if(prev_close >= prev_open) return false;
   
   bool is_bullish_running = (cur_close > cur_open);
   bool is_breaking_high   = (cur_close >= prev_high || cur_high >= prev_high);
   bool is_covering_low    = (cur_low <= prev_low);
   bool is_stronger_body   = ((cur_close - cur_open) > (prev_open - prev_close) * InpBodyRatioMult);
   
   if(is_bullish_running && is_breaking_high && is_covering_low && is_stronger_body)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG BEARISH ENGULFING BREAK DETECTION                |
//+------------------------------------------------------------------+
bool IsStrongBearishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                   double &out_atr_50, double &out_broken_high, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close;
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price    = cur_close;
   out_broken_high  = prev_high;
   
   if(prev_close <= prev_open) return false;
   
   bool is_bearish_running = (cur_close < cur_open);
   bool is_breaking_low    = (cur_close <= prev_low || cur_low <= prev_low);
   bool is_covering_high   = (cur_high >= prev_high);
   // ponytail: unified with the BUY side (multiply). This used to divide, so
   // seconds mode and TF CLOSE disagreed whenever InpBodyRatioMult != 1.
   bool is_stronger_body   = ((cur_open - cur_close) > (prev_close - prev_open) * InpBodyRatioMult);
   
   if(is_bearish_running && is_breaking_low && is_covering_high && is_stronger_body)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG HAMMER REVERSAL DETECTION (BUY ONLY)             |
//+------------------------------------------------------------------+
// Syarat:
// 1. Lower shadow >= 3x body
// 2. Upper shadow <= 0.8x body (ekor atas kecil/minimalis)
// 3. Rentang lilin (high - low) > rentang lilin sebelumnya (prev_high - prev_low)
bool IsStrongHammer(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                    double &out_low, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close;
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price = cur_close;
   out_low       = cur_low;
   
   double body_top    = MathMax(cur_open, cur_close);
   double body_bottom = MathMin(cur_open, cur_close);
   double body_size   = body_top - body_bottom;
   if(body_size <= 0) body_size = SymbolInfoDouble(sym, SYMBOL_POINT); // Prevent zero division
   
   double lower_shadow = body_bottom - cur_low;
   double upper_shadow = cur_high - body_top;
   
   // Syarat 1: Lower shadow >= 3x body
   if(lower_shadow < 3.0 * body_size) return false;
   
   // Syarat 2: Upper shadow <= 0.8x body
   if(upper_shadow > 0.8 * body_size) return false;
   
   // Syarat 3: Rentang lilin > rentang lilin sebelumnya
   double cur_range  = cur_high - cur_low;
   double prev_range = prev_high - prev_low;
   if(cur_range <= prev_range) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG SHOOTING STAR REVERSAL DETECTION (SELL ONLY)     |
//+------------------------------------------------------------------+
// Syarat:
// 1. Upper shadow >= 3x body
// 2. Lower shadow <= 0.8x body (ekor bawah kecil/minimalis)
// 3. Rentang lilin (high - low) > rentang lilin sebelumnya (prev_high - prev_low)
bool IsStrongShootingStar(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                          double &out_high, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close;
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price = cur_close;
   out_high      = cur_high;
   
   double body_top    = MathMax(cur_open, cur_close);
   double body_bottom = MathMin(cur_open, cur_close);
   double body_size   = body_top - body_bottom;
   if(body_size <= 0) body_size = SymbolInfoDouble(sym, SYMBOL_POINT);
   
   double upper_shadow = cur_high - body_top;
   double lower_shadow = body_bottom - cur_low;
   
   // Syarat 1: Upper shadow >= 3x body
   if(upper_shadow < 3.0 * body_size) return false;
   
   // Syarat 2: Lower shadow <= 0.8x body
   if(lower_shadow > 0.8 * body_size) return false;
   
   // Syarat 3: Rentang lilin > rentang lilin sebelumnya
   double cur_range  = cur_high - cur_low;
   double prev_range = prev_high - prev_low;
   if(cur_range <= prev_range) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| STOCHASTIC + HEIKIN ASHI MOMENTUM REVERSAL CHECK                 |
//+------------------------------------------------------------------+
bool CheckStochHA(const string sym, const ENUM_TIMEFRAMES tf, const int shift, bool check_buy)
{
   // 1. Stochastic Indicator Check
   int stoch_handle = iStochastic(sym, tf, InpStochLength, InpStochD, InpStochK, MODE_SMA, STO_LOWHIGH);
   if(stoch_handle == INVALID_HANDLE) return false;
   
   double k_val[2];
   ArraySetAsSeries(k_val, true);
   if(CopyBuffer(stoch_handle, 0, shift, 2, k_val) < 2)
   {
      IndicatorRelease(stoch_handle);
      return false;
   }
   IndicatorRelease(stoch_handle);
   
   double cur_k  = k_val[0];
   double prev_k = k_val[1];
   
   // 2. Heikin Ashi Calculation
   // Need at least 30 bars to get reliable HA open smoothing
   int bars_needed = 30 + shift;
   MqlRates raw_rates[];
   ArraySetAsSeries(raw_rates, false); // Oldest to newest for HA recursion
   if(CopyRates(sym, tf, 0, bars_needed, raw_rates) < bars_needed) return false;
   
   int n = ArraySize(raw_rates);
   double ha_open[];
   double ha_close[];
   double ha_high[];
   double ha_low[];
   ArrayResize(ha_open, n);
   ArrayResize(ha_close, n);
   ArrayResize(ha_high, n);
   ArrayResize(ha_low, n);
   
   ha_open[0]  = (raw_rates[0].open + raw_rates[0].close) / 2.0;
   ha_close[0] = (raw_rates[0].open + raw_rates[0].high + raw_rates[0].low + raw_rates[0].close) / 4.0;
   ha_high[0]  = MathMax(raw_rates[0].high, MathMax(ha_open[0], ha_close[0]));
   ha_low[0]   = MathMin(raw_rates[0].low, MathMin(ha_open[0], ha_close[0]));
   
   for(int b = 1; b < n; b++)
   {
      ha_close[b] = (raw_rates[b].open + raw_rates[b].high + raw_rates[b].low + raw_rates[b].close) / 4.0;
      ha_open[b]  = (ha_open[b-1] + ha_close[b-1]) / 2.0;
      ha_high[b]  = MathMax(raw_rates[b].high, MathMax(ha_open[b], ha_close[b]));
      ha_low[b]   = MathMin(raw_rates[b].low, MathMin(ha_open[b], ha_close[b]));
   }
   
   int cur_idx  = n - 1 - shift;
   int prev_idx = cur_idx - 1;
   if(prev_idx < 0) return false;
   
   double cur_ha_size  = ha_high[cur_idx] - ha_low[cur_idx];
   double prev_ha_size = ha_high[prev_idx] - ha_low[prev_idx];
   bool cur_ha_green   = (ha_close[cur_idx] > ha_open[cur_idx]);
   bool cur_ha_red     = (ha_close[cur_idx] < ha_open[cur_idx]);
   
   if(check_buy)
   {
      // buyCondition = k < stochOversold and k > k[1] and (haSize < haSize[1] or haColor == color.green)
      bool stoch_buy = (cur_k < InpStochOS && cur_k > prev_k);
      bool ha_buy    = (cur_ha_size < prev_ha_size || cur_ha_green);
      return (stoch_buy && ha_buy);
   }
   else
   {
      // sellCondition = k > stochOverbought and k < k[1] and (haSize < haSize[1] or haColor == color.red)
      bool stoch_sell = (cur_k > InpStochOB && cur_k < prev_k);
      bool ha_sell    = (cur_ha_size < prev_ha_size || cur_ha_red);
      return (stoch_sell && ha_sell);
   }
}

//+------------------------------------------------------------------+
//| LOT SIZE CALCULATION (FIXED OR RISK %)                           |
//+------------------------------------------------------------------+
double CalculateLotSize(const string sym, ENUM_LOT_MODE mode, double lot_val, double entry_price, double sl_price)
{
   if(mode == LOT_FIXED) return lot_val;
   
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (lot_val / 100.0);
   double sl_distance = MathAbs(entry_price - sl_price);
   if(sl_distance <= 0) return 0.01;
   
   double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0 || tick_value <= 0) return 0.01;
   
   double point_loss_per_lot = (sl_distance / tick_size) * tick_value;
   if(point_loss_per_lot <= 0) return 0.01;
   
   double calculated_lot = risk_amount / point_loss_per_lot;
   double min_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   
   calculated_lot = MathFloor(calculated_lot / lot_step) * lot_step;
   if(calculated_lot < min_lot) calculated_lot = min_lot;
   if(calculated_lot > max_lot) calculated_lot = max_lot;
   
   return calculated_lot;
}

//+------------------------------------------------------------------+
//| COUNT OPEN TRADES FOR THIS EA ON THIS SYMBOL                     |
//+------------------------------------------------------------------+
int CountOpenPositions(const string sym)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == sym && m_position.Magic() == InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| TRUE RANGE & EWMA TR REALTIME VOLATILITY ENGINE                  |
//+------------------------------------------------------------------+
double GetTrueRange(const string sym, const ENUM_TIMEFRAMES tf, int shift = 0)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 2, rates) < 2)
   {
      double h = iHigh(sym, tf, shift);
      double l = iLow(sym, tf, shift);
      return MathMax(0.0, h - l);
   }
   double cur_h  = rates[0].high;
   double cur_l  = rates[0].low;
   double prev_c = rates[1].close;
   
   double r1 = cur_h - cur_l;
   double r2 = MathAbs(cur_h - prev_c);
   double r3 = MathAbs(cur_l - prev_c);
   return MathMax(r1, MathMax(r2, r3));
}

double GetEWMA_TR(const string sym, const ENUM_TIMEFRAMES tf, int barsToUse = 30, double lambda = 0.90)
{
   if(barsToUse < 5) barsToUse = 5;
   if(lambda <= 0.0 || lambda >= 1.0) lambda = 0.90;
   
   // Seed EWMA with oldest completed bar in window
   double ewma = GetTrueRange(sym, tf, barsToUse);
   for(int i = barsToUse - 1; i >= 1; i--)
   {
      double tr = GetTrueRange(sym, tf, i);
      ewma = lambda * ewma + (1.0 - lambda) * tr;
   }
   return ewma;
}

//+------------------------------------------------------------------+
//| POSITION TRACKING MANAGEMENT (AUTO TRAIL SL & TRAIL TP)          |
//+------------------------------------------------------------------+
void RegisterPositionTracking(ulong ticket, string sym, ENUM_TIMEFRAMES tf, double atr100, double open_p, double tp_p, double trail_pct, double atr_mult)
{
   int size = ArraySize(g_tracking_list);
   for(int i = 0; i < size; i++)
   {
      if(g_tracking_list[i].ticket == ticket)
      {
         g_tracking_list[i].symbol            = sym;
         g_tracking_list[i].timeframe         = tf;
         g_tracking_list[i].initial_atr100    = atr100;
         g_tracking_list[i].initial_tp_dist   = MathAbs(tp_p - open_p);
         g_tracking_list[i].prev_tp_level     = 0.0;
         g_tracking_list[i].trail_cycle       = 0;
         g_tracking_list[i].trail_trigger_pct = trail_pct;
         g_tracking_list[i].atr_multiplier    = atr_mult;
         g_tracking_list[i].be_applied        = false;
         g_tracking_list[i].active            = true;
         return;
      }
   }
   
   ArrayResize(g_tracking_list, size + 1);
   g_tracking_list[size].ticket            = ticket;
   g_tracking_list[size].symbol            = sym;
   g_tracking_list[size].timeframe         = tf;
   g_tracking_list[size].initial_atr100    = atr100;
   g_tracking_list[size].initial_tp_dist   = MathAbs(tp_p - open_p);
   g_tracking_list[size].prev_tp_level     = 0.0;
   g_tracking_list[size].trail_cycle       = 0;
   g_tracking_list[size].trail_trigger_pct = trail_pct;
   g_tracking_list[size].atr_multiplier    = atr_mult;
   g_tracking_list[size].be_applied        = false;
   g_tracking_list[size].active            = true;
}

void ProcessAutoTrailSLTP()
{
   int size = ArraySize(g_tracking_list);
   if(size == 0) return;
   
   for(int i = size - 1; i >= 0; i--)
   {
      if(!g_tracking_list[i].active) continue;
      
      ulong tkt = g_tracking_list[i].ticket;
      if(!m_position.SelectByTicket(tkt))
      {
         g_tracking_list[i].active = false;
         continue;
      }
      
      string sym = m_position.Symbol();
      if(!m_symbol_info.Name(sym)) continue;
      m_symbol_info.RefreshRates();
      
      ENUM_POSITION_TYPE ptype = m_position.PositionType();
      double open_p  = m_position.PriceOpen();
      double cur_sl  = m_position.StopLoss();
      double cur_tp  = m_position.TakeProfit();
      double bid     = m_symbol_info.Bid();
      double ask     = m_symbol_info.Ask();
      double spread  = ask - bid;
      int digits     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      
      if(cur_tp <= 0) continue;
      
      m_trade.SetExpertMagicNumber(m_position.Magic());
      
      ENUM_TIMEFRAMES tf = AtrBaseTF(g_tracking_list[i].timeframe);
      double curr_tr  = GetTrueRange(sym, tf, 0);
      double ewma_tr  = GetEWMA_TR(sym, tf, InpEWMABars, InpEWMALambda);
      if(ewma_tr <= 0) ewma_tr = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
      double rel_vol  = curr_tr / ewma_tr;
      
      double atr_ref = CalculateATR100(sym, tf, InpATRPeriod);
      if(atr_ref <= 0) atr_ref = ewma_tr;
      
      // ===================================================================
      // 1. TRAIL BE (BREAK-EVEN): MURNI BERBASIS JARAK TANPA VOLATILITAS
      // ===================================================================
      bool trigger_be = false;
      if(!g_tracking_list[i].be_applied && g_tracking_list[i].trail_cycle == 0)
      {
         if(InpTrailBEMode == TRAIL_BE_PROFIT)
         {
            // Opsi 1: Running profit >= 1.5x EWMA TR dari open
            if(ptype == POSITION_TYPE_BUY  && (bid - open_p) >= (1.5 * ewma_tr)) trigger_be = true;
            if(ptype == POSITION_TYPE_SELL && (open_p - ask) >= (1.5 * ewma_tr)) trigger_be = true;
         }
         else
         {
            // Opsi 2 (Default): Kedekatan ke TP (sisa jarak <= 1.1x EWMA TR atau <= trigger_pct)
            double legacy_ratio = g_tracking_list[i].trail_trigger_pct / 100.0;
            if(legacy_ratio <= 0) legacy_ratio = 0.05;
            
            if(ptype == POSITION_TYPE_BUY)
            {
               double rem_dist = cur_tp - bid;
               double tot_dist = cur_tp - open_p;
               if((rem_dist <= InpMaxDistATR * ewma_tr || rem_dist <= tot_dist * legacy_ratio) && bid > open_p)
                  trigger_be = true;
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               double rem_dist = ask - cur_tp;
               double tot_dist = open_p - cur_tp;
               if((rem_dist <= InpMaxDistATR * ewma_tr || rem_dist <= tot_dist * legacy_ratio) && ask < open_p)
                  trigger_be = true;
            }
         }
         
         if(trigger_be)
         {
            double be_sl = 0.0;
            if(ptype == POSITION_TYPE_BUY)
            {
               be_sl = NormalizeDouble(open_p + spread, digits);
               if(be_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     g_tracking_list[i].be_applied = true;
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL moved to BE\nNew SL: %.5f", sym, tkt, be_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               else g_tracking_list[i].be_applied = true;
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               be_sl = NormalizeDouble(open_p - spread, digits);
               if(cur_sl == 0 || be_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     g_tracking_list[i].be_applied = true;
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL moved to BE\nNew SL: %.5f", sym, tkt, be_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               else g_tracking_list[i].be_applied = true;
            }
         }
      }
      
      // ===================================================================
      // 2. TRAIL TP EXTENSION: JARAK DEKAT TP + LONJAKAN VOLATILITAS NYATA
      // ===================================================================
      double dist_to_tp = 0.0;
      if(ptype == POSITION_TYPE_BUY)  dist_to_tp = MathAbs(cur_tp - bid) / ewma_tr;
      if(ptype == POSITION_TYPE_SELL) dist_to_tp = MathAbs(cur_tp - ask) / ewma_tr;
      
      bool proximity_ok  = (dist_to_tp <= InpMaxDistATR);
      bool volatility_ok = (rel_vol >= InpRelVolThreshold);
      
      if(proximity_ok && volatility_ok)
      {
         double excess = rel_vol - InpRelVolThreshold;
         double extend_amount = excess * atr_ref * InpExtendFactor;
         extend_amount = MathMin(extend_amount, InpMaxExtendATR * atr_ref);
         if(extend_amount < g_tracking_list[i].initial_tp_dist * 0.5)
            extend_amount = g_tracking_list[i].initial_tp_dist * 0.5; // Minimum 0.5x base target
         
         double new_tp = 0.0;
         double new_sl = cur_sl;
         
         if(ptype == POSITION_TYPE_BUY)
         {
            new_tp = NormalizeDouble(cur_tp + extend_amount, digits);
            if(new_tp > cur_tp)
            {
               if(g_tracking_list[i].trail_cycle == 0)
               {
                  double be_sl = NormalizeDouble(open_p + spread, digits);
                  if(be_sl > cur_sl) new_sl = be_sl;
               }
               else if(g_tracking_list[i].trail_cycle >= 1)
               {
                  double prev_tp = g_tracking_list[i].prev_tp_level;
                  if(prev_tp > cur_sl) new_sl = NormalizeDouble(prev_tp, digits);
               }
               
               if(m_trade.PositionModify(tkt, new_sl, new_tp))
               {
                  g_tracking_list[i].prev_tp_level = cur_tp;
                  g_tracking_list[i].trail_cycle++;
                  g_tracking_list[i].be_applied = true;
                  string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (BUY)\nRelVol: %.2f | Extend: +%.5f\nNew TP: %.5f (Cycle %d)",
                                            sym, tkt, rel_vol, extend_amount, new_tp, g_tracking_list[i].trail_cycle);
                  if(InpEnableSoundAlerts) Alert(msg);
                  if(InpEnablePushAlerts)  SendNotification(msg);
               }
            }
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            new_tp = NormalizeDouble(cur_tp - extend_amount, digits);
            if(new_tp < cur_tp)
            {
               if(g_tracking_list[i].trail_cycle == 0)
               {
                  double be_sl = NormalizeDouble(open_p - spread, digits);
                  if(cur_sl == 0 || be_sl < cur_sl) new_sl = be_sl;
               }
               else if(g_tracking_list[i].trail_cycle >= 1)
               {
                  double prev_tp = g_tracking_list[i].prev_tp_level;
                  if(cur_sl == 0 || prev_tp < cur_sl) new_sl = NormalizeDouble(prev_tp, digits);
               }
               
               if(m_trade.PositionModify(tkt, new_sl, new_tp))
               {
                  g_tracking_list[i].prev_tp_level = cur_tp;
                  g_tracking_list[i].trail_cycle++;
                  g_tracking_list[i].be_applied = true;
                  string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (SELL)\nRelVol: %.2f | Extend: -%.5f\nNew TP: %.5f (Cycle %d)",
                                            sym, tkt, rel_vol, extend_amount, new_tp, g_tracking_list[i].trail_cycle);
                  if(InpEnableSoundAlerts) Alert(msg);
                  if(InpEnablePushAlerts)  SendNotification(msg);
               }
            }
         }
      }
      
      // ===================================================================
      // 3. TRAIL SL LOCK TO PREV TP: KETIKA MENDEKATI TP BARU (CYCLE >= 1)
      // ===================================================================
      if(g_tracking_list[i].trail_cycle >= 1 && proximity_ok)
      {
         double prev_tp = g_tracking_list[i].prev_tp_level;
         if(prev_tp > 0)
         {
            if(ptype == POSITION_TYPE_BUY)
            {
               double lock_sl = NormalizeDouble(prev_tp, digits);
               if(lock_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, lock_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL locked to Prev TP\nNew SL: %.5f", sym, tkt, lock_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               double lock_sl = NormalizeDouble(prev_tp, digits);
               if(cur_sl == 0 || lock_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, lock_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL locked to Prev TP\nNew SL: %.5f", sym, tkt, lock_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SYMBOL MATCHER HELPER                                            |
//+------------------------------------------------------------------+
string FindExactOrMarketWatchSymbol(string input_sym)
{
   StringTrimLeft(input_sym);
   StringTrimRight(input_sym);
   if(input_sym == "") return "";
   
   // First check if symbol exists in Market Watch using SymbolSelect to add it if needed
   if(!SymbolSelect(input_sym, true))
   {
      // SymbolSelect failed, symbol doesn't exist - check all symbols for match
      int total_symbols = SymbolsTotal(false);
      string input_upper = input_sym;
      StringToUpper(input_upper);
      
      for(int i = 0; i < total_symbols; i++)
      {
         string cur_name = SymbolName(i, false);
         string cur_upper = cur_name;
         StringToUpper(cur_upper);
         if(cur_upper == input_upper || StringFind(cur_upper, input_upper) >= 0)
         {
            SymbolSelect(cur_name, true);
            return cur_name;
         }
      }
      return "";
   }
   
   // If SymbolSelect succeeded, symbol now exists in Market Watch
   return input_sym;
}

//+------------------------------------------------------------------+
//| UI PRIMITIVE HELPERS                                             |
//+------------------------------------------------------------------+
void CreateRect(string name, int x, int y, int w, int h, color bg_color, color border_color)
{
   name = g_prefix + name;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_color);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border_color);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
}

void CreateLabel(string name, int x, int y, string text, color clr, int font_size = 8, bool bold = false)
{
   name = g_prefix + name;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Segoe UI Bold" : "Segoe UI");
}

void CreateButton(string name, int x, int y, int w, int h, string text, color bg_clr, color text_clr, color border_clr)
{
   name = g_prefix + name;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_COLOR, text_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border_clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Bold");
}

void CreateEdit(string name, int x, int y, int w, int h, string text, color bg_clr, color text_clr)
{
   name = g_prefix + name;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_READONLY, false);
      ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_CENTER);
      ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_COLOR, text_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, CLR_BORDER_HARD);
}

//+------------------------------------------------------------------+
//| DASHBOARD UI RENDERING                                           |
//+------------------------------------------------------------------+
void CreateDashboardUI()
{
   DestroyDashboardUI();
   
   int root_x = 20;
   int root_y = 20;
   int win_w  = 960;
   int win_h  = 620;
   
   CreateRect("WIN_BG", root_x, root_y, win_w, win_h, CLR_PANEL_BG, CLR_BORDER_HARD);
   CreateRect("WIN_TOP", root_x, root_y, win_w, 36, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("WIN_TITLE", root_x + 14, root_y + 9, "MULTIRULE AUTO TRADER", CLR_TEXT_PURE, 10, true);
   CreateLabel("WIN_TAG", root_x + 220, root_y + 10, "[MULTI-RULE REALTIME TICK ENGINE - REVERSAL]", CLR_CYAN_NEON, 8, true);
   
   string status_txt = g_master_power_enabled ? "ALL ACTIVE" : "ALL PAUSED";
   color status_bg  = g_master_power_enabled ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
   color status_clr = g_master_power_enabled ? CLR_BULL_NEON : CLR_BEAR_NEON;
   CreateButton("BTN_TOGGLE_MASTER", root_x + win_w - 115, root_y + 6, 100, 24, status_txt, status_bg, status_clr, status_clr);
   
   int upper_y = root_y + 44;
   int form_w  = 540; // Perlebar form kiri agar teks tidak terpotong dan tidak tumpang tindih
   int prev_w  = win_w - form_w - 36;
   int prev_x  = root_x + form_w + 22;
   
   // 1A. Form Deck (Kiri) - Diperlebar
   CreateRect("CARD_FORM_DECK", root_x + 14, upper_y, form_w, 275, CLR_CARD_BG, CLR_BORDER_HARD);
   
   string form_header_txt = (g_editing_rule_idx >= 0) ? StringFormat("EDIT RULE #%d CONFIGURATION", g_editing_rule_idx + 1) : "ADD AUTO TRADER RULE";
   color form_header_clr = (g_editing_rule_idx >= 0) ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateLabel("LBL_FORM_HEADER", root_x + 22, upper_y + 6, form_header_txt, form_header_clr, 9, true);
   
   // Row A: Symbol & Direction Toggle Buttons (y = upper_y + 24)
   int row_a_y = upper_y + 24;
   CreateLabel("LBL_SYM", root_x + 22, row_a_y + 3, "SYMBOL:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_SYM", root_x + 85, row_a_y, 85, 20, g_form_sym, CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   color btn_both_bg = (g_form_direction == TRADE_DIR_BOTH) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color btn_both_cl = (g_form_direction == TRADE_DIR_BOTH) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   color btn_buy_bg  = (g_form_direction == TRADE_DIR_BUY) ? CLR_POWER_ON_BG : CLR_PANEL_BG;
   color btn_buy_cl  = (g_form_direction == TRADE_DIR_BUY) ? CLR_BULL_NEON : CLR_TEXT_MED;
   color btn_sell_bg = (g_form_direction == TRADE_DIR_SELL) ? CLR_POWER_OFF_BG : CLR_PANEL_BG;
   color btn_sell_cl = (g_form_direction == TRADE_DIR_SELL) ? CLR_BEAR_NEON : CLR_TEXT_MED;
   
   CreateButton("BTN_DIR_BOTH", root_x + 180, row_a_y, 110, 20, "BUY & SELL", btn_both_bg, btn_both_cl, btn_both_cl);
   CreateButton("BTN_DIR_BUY",  root_x + 296, row_a_y, 110, 20, "BUY ONLY",  btn_buy_bg,  btn_buy_cl,  btn_buy_cl);
   CreateButton("BTN_DIR_SELL", root_x + 412, row_a_y, 110, 20, "SELL ONLY", btn_sell_bg, btn_sell_cl, btn_sell_cl);
   
   // Row B: Sinyal & Mode Combo (y = upper_y + 48)
   int row_b_y = upper_y + 48;
   CreateLabel("LBL_SIGS", root_x + 22, row_b_y + 3, "SIGNALS:", CLR_TEXT_PURE, 8, true);
   
   // Checkbox 1: Engulfing
   color eng_bg = g_form_sig_eng ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color eng_cl = g_form_sig_eng ? CLR_CYAN_NEON : CLR_TEXT_MED;
   CreateButton("BTN_SIG_ENG", root_x + 85, row_b_y, 75, 20, "[x] ENG", eng_bg, eng_cl, eng_cl);
   
   // Checkbox 2: Hammer / Shooting Star (Dinamis sesuai arah)
   string hmr_label = "[x] HMR/SS";
   if(g_form_direction == TRADE_DIR_BUY)  hmr_label = "[x] HAMMER";
   if(g_form_direction == TRADE_DIR_SELL) hmr_label = "[x] SHOOTING";
   color hmr_bg = g_form_sig_hmr ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color hmr_cl = g_form_sig_hmr ? CLR_GOLD_NEON : CLR_TEXT_MED;
   CreateButton("BTN_SIG_HMR", root_x + 165, row_b_y, 95, 20, hmr_label, hmr_bg, hmr_cl, hmr_cl);
   
   // Checkbox 3: Stoch + Heikin Ashi
   color stoch_bg = g_form_sig_stoch ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color stoch_cl = g_form_sig_stoch ? CLR_BULL_NEON : CLR_TEXT_MED;
   CreateButton("BTN_SIG_STOCH", root_x + 265, row_b_y, 90, 20, "[x] STOCH+HA", stoch_bg, stoch_cl, stoch_cl);
   
   // Toggle Signal Mode: ANY (OR) vs COMBO (AND)
   string sm_str = (g_form_sig_mode == SIGNAL_MODE_ANY) ? "MODE: ANY (OR)" : "MODE: COMBO (AND)";
   color sm_bg = (g_form_sig_mode == SIGNAL_MODE_COMBO) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color sm_cl = (g_form_sig_mode == SIGNAL_MODE_COMBO) ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateButton("BTN_TOGGLE_SIG_MODE", root_x + 365, row_b_y, 155, 20, sm_str, sm_bg, sm_cl, sm_cl);
   
   // Row C: Risk Reward & Timeframe (y = upper_y + 72)
   int row_c_y = upper_y + 72;
   CreateLabel("LBL_RR", root_x + 22, row_c_y + 3, "RR RATIO:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_RR", root_x + 85, row_c_y, 75, 20, DoubleToString(g_form_rr, 2), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_TF", root_x + 175, row_c_y + 3, "TIMEFRAME (MIN):", CLR_TEXT_PURE, 8, true);
   int tf_min = 5;
   if(g_form_tf == PERIOD_M1) tf_min = 1;
   else if(g_form_tf == PERIOD_M5) tf_min = 5;
   else if(g_form_tf == PERIOD_M15) tf_min = 15;
   else if(g_form_tf == PERIOD_M30) tf_min = 30;
   else if(g_form_tf == PERIOD_H1) tf_min = 60;
   else if(g_form_tf == PERIOD_H4) tf_min = 240;
   else if(g_form_tf == PERIOD_D1) tf_min = 1440;
   CreateEdit("INP_TF", root_x + 295, row_c_y, 60, 20, IntegerToString(tf_min), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_MAX_ORD", root_x + 365, row_c_y + 3, "MAX ORDER:", CLR_TEXT_PURE, 8, true);
   string max_ord_str = (g_form_max_orders <= 0) ? "UNL" : IntegerToString(g_form_max_orders);
   CreateEdit("INP_MAX_ORD", root_x + 440, row_c_y, 45, 20, max_ord_str, CLR_CANVAS_BG, CLR_GOLD_NEON);
   string max_btn_lbl = (g_form_max_orders <= 0) ? "UNL" : IntegerToString(g_form_max_orders) + "x";
   CreateButton("BTN_TOGGLE_MAX_ORD", root_x + 490, row_c_y, 32, 20, max_btn_lbl, CLR_PANEL_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
   
   // Row D: Lot Mode & Value & Multiplier (y = upper_y + 96)
   int row_d_y = upper_y + 96;
   CreateLabel("LBL_LOT_MODE", root_x + 22, row_d_y + 3, "LOT MODE:", CLR_TEXT_PURE, 8, true);
   string lot_mode_str = (g_form_lot_mode == LOT_FIXED) ? "FIXED LOT" : "% RISK";
   color lot_mode_clr = (g_form_lot_mode == LOT_FIXED) ? CLR_CYAN_NEON : CLR_GOLD_NEON;
   CreateButton("BTN_TOGGLE_LOT_MODE", root_x + 85, row_d_y, 75, 20, lot_mode_str, CLR_CANVAS_BG, lot_mode_clr, CLR_BORDER_HARD);
   CreateEdit("INP_LOT", root_x + 165, row_d_y, 50, 20, DoubleToString(g_form_lot_val, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   CreateLabel("LBL_ENTRI_MULT", root_x + 225, row_d_y + 3, "ENTRY MULTIPLIER:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_ENTRI_MULT", root_x + 345, row_d_y, 40, 20, IntegerToString(g_form_entry_mult), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   CreateLabel("LBL_MULTI_TP", root_x + 395, row_d_y + 3, "MULTI TP:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_MULTI_TP", root_x + 460, row_d_y, 45, 20, IntegerToString(g_form_multi_tp), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   // Row E: Trailing EWMA TR Settings (y = upper_y + 120)
   int row_e_y = upper_y + 120;
   CreateLabel("LBL_TRAIL", root_x + 22, row_e_y + 3, "TRAIL EWMA:", CLR_TEXT_PURE, 8, true);
   string trail_mode_str = g_form_trail_on ? "ON" : "OFF";
   color trail_mode_clr = g_form_trail_on ? CLR_GOLD_NEON : CLR_TEXT_MED;
   CreateButton("BTN_TOGGLE_TRAIL", root_x + 105, row_e_y, 55, 20, trail_mode_str, CLR_CANVAS_BG, trail_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_TRAIL_PCT", root_x + 175, row_e_y + 3, "BE TP%:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_TRAIL_PCT", root_x + 225, row_e_y, 45, 20, DoubleToString(g_form_trail_pct, 1), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   CreateLabel("LBL_ATR_MULT_LBL", root_x + 280, row_e_y + 3, "RELVOL THR:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_ATR_MULT", root_x + 355, row_e_y, 45, 20, DoubleToString(g_form_atr_mult, 1), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   // Row F: % TF Progress Delay vs TF Close (y = upper_y + 144)
   int row_f_y = upper_y + 144;
   CreateLabel("LBL_DELAY_MODE", root_x + 22, row_f_y + 3, "DELAY MODE:", CLR_TEXT_PURE, 8, true);
   string delay_mode_str = g_form_delay_close ? "TF CLOSE" : "% TF PROGRESS";
   color delay_mode_clr = g_form_delay_close ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateButton("BTN_TOGGLE_DELAY_MODE", root_x + 105, row_f_y, 115, 20, delay_mode_str, CLR_CANVAS_BG, delay_mode_clr, CLR_BORDER_HARD);
   
   if(!g_form_delay_close)
   {
      CreateLabel("LBL_DELAY_SEC", root_x + 230, row_f_y + 3, "% TF DELAY:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_DELAY_SEC", root_x + 310, row_f_y, 45, 20, IntegerToString(g_form_delay_pct), CLR_CANVAS_BG, CLR_GOLD_NEON);
      CreateLabel("LBL_SEC_UNIT", root_x + 360, row_f_y + 3, "% umur lilin (0=instan)", CLR_TEXT_MED, 7, false);
   }
   
   // Row G: Price Bounds with Grace Period Note (y = upper_y + 172)
   int row_g_y = upper_y + 172;
   if(g_form_direction == TRADE_DIR_BOTH)
   {
      CreateLabel("LBL_BULL_MAX", root_x + 22, row_g_y + 3, "BUY BOUND:", CLR_BULL_NEON, 8, true);
      CreateEdit("INP_BULL_MAX", root_x + 100, row_g_y, 150, 20, g_form_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      CreateLabel("LBL_BEAR_MIN", root_x + 265, row_g_y + 3, "SELL BOUND:", CLR_BEAR_NEON, 8, true);
      CreateEdit("INP_BEAR_MIN", root_x + 345, row_g_y, 150, 20, g_form_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   else if(g_form_direction == TRADE_DIR_BUY)
   {
      CreateLabel("LBL_BULL_MAX", root_x + 22, row_g_y + 3, "BUY BOUND (cth: <1.0850 atau 4040-4078):", CLR_BULL_NEON, 8, true);
      CreateEdit("INP_BULL_MAX", root_x + 280, row_g_y, 220, 20, g_form_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   else if(g_form_direction == TRADE_DIR_SELL)
   {
      CreateLabel("LBL_BEAR_MIN", root_x + 22, row_g_y + 3, "SELL BOUND (cth: >1.0900 atau 4040-4078):", CLR_BEAR_NEON, 8, true);
      CreateEdit("INP_BEAR_MIN", root_x + 280, row_g_y, 220, 20, g_form_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   CreateLabel("LBL_GRACE_NOTE", root_x + 22, row_g_y + 24, "*Toleransi keluar area: 1.5x TF (wajib masuk area terlebih dahulu)", CLR_TEXT_MED, 7, false);
   
   // Row H: Form Action Buttons (y = upper_y + 228)
   int row_h_y = upper_y + 228;
   if(g_editing_rule_idx >= 0)
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_h_y, 280, 28, "UPDATE RULE #" + IntegerToString(g_editing_rule_idx + 1), CLR_TAB_ACTIVE_BG, CLR_GOLD_NEON, CLR_GOLD_NEON);
      CreateButton("BTN_DEFAULT_RULE", root_x + 310, row_h_y, 100, 28, "DEFAULT", CLR_CARD_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
      CreateButton("BTN_CANCEL_EDIT", root_x + 418, row_h_y, 95, 28, "CANCEL", CLR_CARD_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
   }
   else
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_h_y, 385, 28, "+ ADD AUTO TRADER RULE", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
      CreateButton("BTN_DEFAULT_RULE", root_x + 415, row_h_y, 100, 28, "DEFAULT", CLR_CARD_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
   }
   
   // 1B. Live Simulation & Active Settings Box (Kanan) - Lebih Ramping & Bermanfaat
   CreateRect("CARD_SIM_BOX", prev_x, upper_y, prev_w, 275, CLR_CANVAS_BG, CLR_BORDER_HARD);
   CreateRect("SIM_BOX_TOP", prev_x, upper_y, prev_w, 24, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("SIM_BOX_TITLE", prev_x + 10, upper_y + 5, "ACTIVE SETTINGS & TRAIL SIMULATION", CLR_CYAN_NEON, 8, true);
   CreateLabel("SIM_BOX_TAG", prev_x + prev_w - 95, upper_y + 5, "[LIVE ENGINE]", CLR_GOLD_NEON, 8, true);
   
   // ================= SECTION 2: RULES TABLE (BOTTOM) =================
   int table_y = upper_y + 285;
   CreateRect("CARD_TABLE", root_x + 14, table_y, win_w - 28, 255, CLR_CANVAS_BG, CLR_BORDER_HARD);
   
   // Table Header Bar
   CreateRect("TH_BG", root_x + 14, table_y, win_w - 28, 24, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("TH_NO",     root_x + 24,  table_y + 6, "NO",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_SYM",    root_x + 55,  table_y + 6, "SYMBOL",    CLR_TEXT_MED, 8, true);
   CreateLabel("TH_DIR",    root_x + 130, table_y + 6, "DIRECTION", CLR_TEXT_MED, 8, true);
   CreateLabel("TH_SIGS",   root_x + 215, table_y + 6, "SIGNALS",   CLR_CYAN_NEON, 8, true);
   CreateLabel("TH_LOT",    root_x + 335, table_y + 6, "LOT/RISK",  CLR_TEXT_MED, 8, true);
   CreateLabel("TH_RR",     root_x + 400, table_y + 6, "RR",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_TF",     root_x + 445, table_y + 6, "TF",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_MAX",    root_x + 480, table_y + 6, "MAX",       CLR_TEXT_MED, 8, true);
   CreateLabel("TH_MULT",   root_x + 515, table_y + 6, "MULT",      CLR_GOLD_NEON, 8, true);
   CreateLabel("TH_DELAY",  root_x + 555, table_y + 6, "DELAY",     CLR_CYAN_NEON, 8, true);
   CreateLabel("TH_FILTER", root_x + 615, table_y + 6, "PRICE BOUNDS", CLR_TEXT_MED, 8, true);
   CreateLabel("TH_TRAIL",  root_x + 725, table_y + 6, "AUTO TRAIL",CLR_TEXT_MED, 8, true);
   CreateLabel("TH_STATUS", root_x + 820, table_y + 6, "STATUS",    CLR_TEXT_MED, 8, true);
   CreateLabel("TH_ACT",    root_x + 890, table_y + 6, "ACTIONS",   CLR_TEXT_MED, 8, true);
   
   UpdatePreviewTerminalBox();
   UpdateDashboardUI();
   ChartRedraw();
}

void UpdatePreviewTerminalBox()
{
   int root_x  = 20;
   int root_y  = 20;
   int win_w   = 960;
   int upper_y = root_y + 44;
   int form_w  = 540;
   int prev_w  = win_w - form_w - 36;
   int prev_x  = root_x + form_w + 22;
   int line_y  = upper_y + 32;
   
   ObjectsDeleteAll(0, g_prefix + "SIM_L");
   
   string prev_sym   = g_form_sym;
   string prev_dir   = "BUY & SELL";
   if(g_form_direction == TRADE_DIR_BUY) prev_dir = "BUY ONLY";
   else if(g_form_direction == TRADE_DIR_SELL) prev_dir = "SELL ONLY";
   
   string prev_tf    = StringSubstr(EnumToString(g_form_tf), 7);
   double prev_rr    = g_form_rr;
   string prev_lot   = (g_form_lot_mode == LOT_FIXED) ? DoubleToString(g_form_lot_val, 2) + " Lot" : DoubleToString(g_form_lot_val, 1) + "% Risk";
   bool   prev_trail = g_form_trail_on;
   double prev_pct   = g_form_trail_pct;
   double prev_atr_m = g_form_atr_mult;
   int    prev_mult  = g_form_entry_mult;
   int    prev_mtp   = g_form_multi_tp;
   string prev_sm    = (g_form_sig_mode == SIGNAL_MODE_ANY) ? "ANY (OR)" : "COMBO (AND)";
   string prev_rule_tag = (g_editing_rule_idx >= 0) ? StringFormat("[RULE #%d EDIT]", g_editing_rule_idx + 1) : "[FORM INPUT]";
   
   int total_rules = ArraySize(g_rules);
   if(g_selected_rule_idx >= 0 && g_selected_rule_idx < total_rules && g_editing_rule_idx < 0)
   {
      int idx = g_selected_rule_idx;
      prev_sym   = g_rules[idx].symbol;
      prev_tf    = StringSubstr(EnumToString(g_rules[idx].timeframe), 7);
      prev_rr    = g_rules[idx].risk_reward_ratio;
      prev_lot   = (g_rules[idx].lot_mode == LOT_FIXED) ? DoubleToString(g_rules[idx].lot_value, 2) + " Lot" : DoubleToString(g_rules[idx].lot_value, 1) + "% Risk";
      prev_trail = g_rules[idx].enable_trail;
      prev_pct   = g_rules[idx].trail_trigger_pct;
      prev_atr_m = g_rules[idx].atr_multiplier;
      prev_mult  = g_rules[idx].entry_multiplier;
      prev_mtp   = g_rules[idx].multi_tp;
      prev_sm    = (g_rules[idx].signal_mode == SIGNAL_MODE_ANY) ? "ANY (OR)" : "COMBO (AND)";
      if(g_rules[idx].direction == TRADE_DIR_BUY)  prev_dir = "BUY ONLY";
      else if(g_rules[idx].direction == TRADE_DIR_SELL) prev_dir = "SELL ONLY";
      prev_rule_tag = StringFormat("[RULE #%d PREVIEW]", idx + 1);
   }
   
   string l1 = StringFormat("Target: %s (%s) | %s | %s", prev_sym, prev_tf, prev_dir, prev_rule_tag);
   string l2 = StringFormat("Rasio RR: 1:%.2f | Mode Lot: %s", prev_rr, prev_lot);
   string l3 = StringFormat("Entry Mult: %dx | Multi TP: %dx tingkat | Sinyal: %s", prev_mult, prev_mtp, prev_sm);
   string l4 = "-------------------------------------------------------------";
   
   CreateLabel("SIM_L1", prev_x + 10, line_y, l1, CLR_TEXT_PURE, 8, true);
   CreateLabel("SIM_L2", prev_x + 10, line_y + 18, l2, CLR_CYAN_NEON, 8, false);
   CreateLabel("SIM_L3", prev_x + 10, line_y + 36, l3, CLR_GOLD_NEON, 8, true);
   CreateLabel("SIM_L4", prev_x + 10, line_y + 52, l4, CLR_BORDER_HARD, 7, false);
   
   if(prev_trail)
   {
      string l5 = "Auto Trail BE (Jarak Mandiri): Sisa <= 1.1x EWMA TR -> Kunci BE";
      string l6 = StringFormat("Trail TP Extend: RelVol >= %.2fx EWMA -> TP Extend Proporsional", prev_atr_m);
      string l7 = "Trail SL Lock: Sisa <= 1.1x ke TP baru -> Kunci ke Prev TP";
      
      CreateLabel("SIM_L5", prev_x + 10, line_y + 68, l5, CLR_GOLD_NEON, 8, true);
      CreateLabel("SIM_L6", prev_x + 10, line_y + 90, l6, CLR_CYAN_NEON, 8, true);
      CreateLabel("SIM_L7", prev_x + 10, line_y + 112, l7, CLR_BULL_NEON, 8, true);
      CreateLabel("SIM_L8", prev_x + 10, line_y + 140, "*Multi TP dipantau independen dari TP terdekat", CLR_TEXT_MED, 7, false);
   }
   else
   {
      CreateLabel("SIM_L5", prev_x + 10, line_y + 70, "Auto Trail Engine: OFF", CLR_BEAR_NEON, 8, true);
      CreateLabel("SIM_L6", prev_x + 10, line_y + 92, "Take Profit & Stop Loss tetap di level awal tanpa trailing.", CLR_TEXT_MED, 8, false);
      CreateLabel("SIM_L8", prev_x + 10, line_y + 140, "Klik baris rule di tabel bawah untuk mengganti preview", CLR_TEXT_MED, 7, false);
   }
}

void UpdateDashboardUI()
{
   int root_x  = 20;
   int root_y  = 20;
   int win_w   = 960;
   int upper_y = root_y + 44;
   int table_y = upper_y + 285;
   int start_y = table_y + 28;
   
   ObjectsDeleteAll(0, g_prefix + "ROW_");
   ObjectsDeleteAll(0, g_prefix + "BTN_EDIT_RULE_");
   ObjectsDeleteAll(0, g_prefix + "BTN_DEL_RULE_");
   ObjectsDeleteAll(0, g_prefix + "BTN_TOGGLE_RULE_");
   ObjectsDeleteAll(0, g_prefix + "BTN_RULES_PREV");
   ObjectsDeleteAll(0, g_prefix + "BTN_RULES_NEXT");
   ObjectsDeleteAll(0, g_prefix + "LBL_RULES_PAGE");
   
   int total_rules = ArraySize(g_rules);
   
   if(total_rules == 0)
   {
      CreateLabel("ROW_EMPTY", root_x + 350, start_y + 20, "Belum ada aturan Auto Trader. Tambahkan rule di atas!", CLR_TEXT_MED, 9, false);
      ChartRedraw();
      return;
   }
   
   int max_pages = (total_rules + RULES_PER_PAGE - 1) / RULES_PER_PAGE;
   if(g_rules_page >= max_pages) g_rules_page = max_pages - 1;
   if(g_rules_page < 0) g_rules_page = 0;
   
   int start_idx = g_rules_page * RULES_PER_PAGE;
   int end_idx   = start_idx + RULES_PER_PAGE;
   if(end_idx > total_rules) end_idx = total_rules;
   
   for(int i = start_idx, r = 0; i < end_idx; i++, r++)
   {
      int cur_y = start_y + (r * 38);
      string r_pfx = StringFormat("ROW_%d_", i);
      bool is_selected = (g_selected_rule_idx == i || g_editing_rule_idx == i);
      
      color row_bg = is_selected ? CLR_ROW_SELECTED : ((r % 2 == 0) ? CLR_CARD_BG : CLR_PANEL_BG);
      CreateRect(r_pfx + "BG", root_x + 20, cur_y, win_w - 40, 32, row_bg, is_selected ? CLR_GOLD_NEON : CLR_BORDER_SOFT);
      
      CreateLabel(r_pfx + "NO", root_x + 24, cur_y + 9, StringFormat("#%d", i + 1), CLR_TEXT_PURE, 8, true);
      CreateLabel(r_pfx + "SYM", root_x + 55, cur_y + 9, g_rules[i].symbol, CLR_TEXT_PURE, 8, true);
      
      string dir_str = "BUY & SELL";
      color  dir_clr = CLR_CYAN_NEON;
      if(g_rules[i].direction == TRADE_DIR_BUY)  { dir_str = "BUY ONLY";  dir_clr = CLR_BULL_NEON; }
      if(g_rules[i].direction == TRADE_DIR_SELL) { dir_str = "SELL ONLY"; dir_clr = CLR_BEAR_NEON; }
      CreateLabel(r_pfx + "DIR", root_x + 130, cur_y + 9, dir_str, dir_clr, 8, true);
      
      // Signals column: [ENG] [HMR/SS] [ST+HA] [OR/AND]
      string sigs_str = "";
      if(g_rules[i].sig_engulfing) sigs_str += "[ENG] ";
      if(g_rules[i].sig_hammer_ss) sigs_str += "[HMR/SS] ";
      if(g_rules[i].sig_stoch_ha)  sigs_str += "[ST+HA] ";
      sigs_str += (g_rules[i].signal_mode == SIGNAL_MODE_ANY) ? "[OR]" : "[AND]";
      CreateLabel(r_pfx + "SIGS", root_x + 215, cur_y + 9, sigs_str, CLR_CYAN_NEON, 7, true);
      
      string lot_str = (g_rules[i].lot_mode == LOT_FIXED) ? DoubleToString(g_rules[i].lot_value, 2) + "L" : DoubleToString(g_rules[i].lot_value, 1) + "%R";
      CreateLabel(r_pfx + "LOT", root_x + 335, cur_y + 9, lot_str, CLR_TEXT_PURE, 8, false);
      
      CreateLabel(r_pfx + "RR", root_x + 400, cur_y + 9, StringFormat("1:%.1f", g_rules[i].risk_reward_ratio), CLR_CYAN_NEON, 8, true);
      
      string str_tf = StringSubstr(EnumToString(g_rules[i].timeframe), 7);
      CreateLabel(r_pfx + "TF", root_x + 445, cur_y + 9, "[" + str_tf + "]", CLR_GOLD_NEON, 8, true);
      
      string max_ord_disp = (g_rules[i].max_orders <= 0) ? "UNL" : IntegerToString(g_rules[i].max_orders);
      CreateLabel(r_pfx + "MAX", root_x + 480, cur_y + 9, max_ord_disp, CLR_TEXT_PURE, 8, true);
      
      int mult_disp = (g_rules[i].entry_multiplier <= 0) ? 1 : g_rules[i].entry_multiplier;
      CreateLabel(r_pfx + "MULT", root_x + 515, cur_y + 9, IntegerToString(mult_disp) + "x", CLR_GOLD_NEON, 8, true);
      
      string delay_disp = g_rules[i].delay_is_tf_close ? "TF Close" : (IntegerToString(g_rules[i].delay_tf_pct) + "%");
      CreateLabel(r_pfx + "DELAY", root_x + 555, cur_y + 9, delay_disp, CLR_CYAN_NEON, 8, false);
      
      string f_str = "";
      if(g_rules[i].direction == TRADE_DIR_BUY)
      {
         f_str = "B:" + g_rules[i].bull_price_filter;
      }
      else if(g_rules[i].direction == TRADE_DIR_SELL)
      {
         f_str = "S:" + g_rules[i].bear_price_filter;
      }
      else
      {
         f_str = "B:" + g_rules[i].bull_price_filter + " | S:" + g_rules[i].bear_price_filter;
      }
      CreateLabel(r_pfx + "FLT", root_x + 615, cur_y + 9, f_str, CLR_TEXT_MED, 7, false);
      
      string trail_str = g_rules[i].enable_trail ? StringFormat("ON (EWMA %.1fx)", g_rules[i].atr_multiplier) : "OFF";
      CreateLabel(r_pfx + "TRL", root_x + 725, cur_y + 9, trail_str, g_rules[i].enable_trail ? CLR_GOLD_NEON : CLR_TEXT_MED, 8, false);
      
      string r_status_txt = g_rules[i].active ? "ACTIVE" : "PAUSED";
      color  r_status_bg  = g_rules[i].active ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
      color  r_status_clr = g_rules[i].active ? CLR_BULL_NEON : CLR_BEAR_NEON;
      CreateButton("BTN_TOGGLE_RULE_" + IntegerToString(i), root_x + 815, cur_y + 5, 58, 22, r_status_txt, r_status_bg, r_status_clr, r_status_clr);
      
      CreateButton("BTN_EDIT_RULE_" + IntegerToString(i), root_x + 880, cur_y + 5, 42, 22, "EDIT", is_selected ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_selected ? CLR_GOLD_NEON : CLR_CYAN_NEON, is_selected ? CLR_GOLD_NEON : CLR_BORDER_HARD);
      CreateButton("BTN_DEL_RULE_"  + IntegerToString(i), root_x + 926, cur_y + 5, 28, 22, "X",  C'34,8,18', CLR_BEAR_NEON, CLR_BEAR_NEON);
   }
   
   // Render pagination buttons dynamically if rules exceed RULES_PER_PAGE
   if(max_pages > 1)
   {
      int pag_y = table_y + 224;
      CreateButton("BTN_RULES_PREV", root_x + win_w - 180, pag_y, 50, 20, "< PREV", CLR_CARD_BG, g_rules_page > 0 ? CLR_CYAN_NEON : CLR_TEXT_MED, CLR_BORDER_HARD);
      CreateLabel("LBL_RULES_PAGE", root_x + win_w - 120, pag_y + 3, StringFormat("Hal %d/%d", g_rules_page + 1, max_pages), CLR_TEXT_PURE, 8, true);
      CreateButton("BTN_RULES_NEXT", root_x + win_w - 65, pag_y, 50, 20, "NEXT >", CLR_CARD_BG, g_rules_page < max_pages - 1 ? CLR_CYAN_NEON : CLR_TEXT_MED, CLR_BORDER_HARD);
   }
   
   ChartRedraw();
}

void DestroyDashboardUI()
{
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| PERSISTENCE (SAVE / LOAD STATE TO FILE - FORMAT V4)              |
//+------------------------------------------------------------------+
void SaveStateToFile()
{
   string filename = "EAT_MultiRules_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   int handle = FileOpen(filename, FILE_WRITE|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      FileWriteInteger(handle, g_master_power_enabled ? 1 : 0);
      FileWriteInteger(handle, 4); // v4 = v3 plus signal selection flags, combo mode, and % TF delay
      
      int total_rules = ArraySize(g_rules);
      FileWriteInteger(handle, total_rules);
      
      for(int i = 0; i < total_rules; i++)
      {
         int sym_len = StringLen(g_rules[i].symbol);
         FileWriteInteger(handle, sym_len);
         if(sym_len > 0) FileWriteString(handle, g_rules[i].symbol, sym_len);
            
         FileWriteInteger(handle, (int)g_rules[i].direction);
         FileWriteDouble(handle, g_rules[i].risk_reward_ratio);
         FileWriteInteger(handle, (int)g_rules[i].timeframe);
         FileWriteInteger(handle, (int)g_rules[i].lot_mode);
         FileWriteDouble(handle, g_rules[i].lot_value);
         FileWriteInteger(handle, g_rules[i].enable_trail ? 1 : 0);
         FileWriteDouble(handle, g_rules[i].trail_trigger_pct);
         FileWriteDouble(handle, g_rules[i].atr_multiplier);
         
         int bf_len = StringLen(g_rules[i].bull_price_filter);
         FileWriteInteger(handle, bf_len);
         if(bf_len > 0) FileWriteString(handle, g_rules[i].bull_price_filter, bf_len);
         
         int sf_len = StringLen(g_rules[i].bear_price_filter);
         FileWriteInteger(handle, sf_len);
         if(sf_len > 0) FileWriteString(handle, g_rules[i].bear_price_filter, sf_len);
         
         FileWriteInteger(handle, g_rules[i].max_orders);
         FileWriteInteger(handle, g_rules[i].entry_multiplier);
         FileWriteInteger(handle, g_rules[i].multi_tp);
         FileWriteInteger(handle, g_rules[i].delay_tf_pct);
         FileWriteInteger(handle, g_rules[i].delay_is_tf_close ? 1 : 0);
         FileWriteInteger(handle, g_rules[i].orders_opened_count);
         FileWriteInteger(handle, g_rules[i].active ? 1 : 0);
         
         // V4 additions per rule
         FileWriteInteger(handle, g_rules[i].sig_engulfing ? 1 : 0);
         FileWriteInteger(handle, g_rules[i].sig_hammer_ss ? 1 : 0);
         FileWriteInteger(handle, g_rules[i].sig_stoch_ha  ? 1 : 0);
         FileWriteInteger(handle, (int)g_rules[i].signal_mode);
      }

      // 3. Persistent Add/Edit form state (so re-attach keeps last typed values)
      int form_sym_len = StringLen(g_form_sym);
      FileWriteInteger(handle, form_sym_len);
      if(form_sym_len > 0) FileWriteString(handle, g_form_sym, form_sym_len);

      FileWriteInteger(handle, (int)g_form_tf);
      FileWriteDouble(handle, g_form_rr);

      int form_bf_len = StringLen(g_form_bmax);
      FileWriteInteger(handle, form_bf_len);
      if(form_bf_len > 0) FileWriteString(handle, g_form_bmax, form_bf_len);

      int form_sf_len = StringLen(g_form_smin);
      FileWriteInteger(handle, form_sf_len);
      if(form_sf_len > 0) FileWriteString(handle, g_form_smin, form_sf_len);

      FileWriteInteger(handle, g_form_delay_pct);
      FileWriteInteger(handle, g_form_delay_close ? 1 : 0);

      FileWriteInteger(handle, g_form_max_orders);
      FileWriteInteger(handle, g_form_entry_mult);
      FileWriteInteger(handle, g_form_multi_tp);

      FileWriteInteger(handle, (int)g_form_direction);
      FileWriteInteger(handle, (int)g_form_lot_mode);
      FileWriteDouble(handle, g_form_lot_val);
      FileWriteInteger(handle, g_form_trail_on ? 1 : 0);
      FileWriteDouble(handle, g_form_trail_pct);
      FileWriteDouble(handle, g_form_atr_mult);

      // V4 additions for form state
      FileWriteInteger(handle, g_form_sig_eng ? 1 : 0);
      FileWriteInteger(handle, g_form_sig_hmr ? 1 : 0);
      FileWriteInteger(handle, g_form_sig_stoch ? 1 : 0);
      FileWriteInteger(handle, (int)g_form_sig_mode);

      FileClose(handle);
   }
}

void LoadStateFromFile()
{
   string filename = "EAT_MultiRules_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   if(!FileIsExist(filename))
   {
      ArrayResize(g_rules, 1);
      g_rules[0].symbol            = _Symbol;
      g_rules[0].direction         = InpTradeDirection;
      g_rules[0].risk_reward_ratio = InpRiskRewardRatio;
      g_rules[0].timeframe         = InpTimeframe;
      g_rules[0].lot_mode          = InpLotMode;
      g_rules[0].lot_value         = (InpLotMode == LOT_FIXED) ? InpFixedLot : InpRiskPercent;
      g_rules[0].enable_trail      = InpEnableTrail;
      g_rules[0].trail_trigger_pct = InpTrailTriggerPct;
      g_rules[0].atr_multiplier    = InpRelVolThreshold;
      g_rules[0].bull_price_filter = "ALL";
      g_rules[0].bear_price_filter = "ALL";
      g_rules[0].max_orders        = InpMaxOrders;
      g_rules[0].entry_multiplier  = InpEntryMultiplier;
      g_rules[0].multi_tp          = InpMultiTP;
      g_rules[0].delay_tf_pct      = InpDelayTFPct;
      g_rules[0].delay_is_tf_close = InpDelayIsTfClose;
      g_rules[0].orders_opened_count = 0;
      g_rules[0].active            = true;
      g_rules[0].sig_engulfing     = InpDefaultSigEng;
      g_rules[0].sig_hammer_ss     = InpDefaultSigHmrSS;
      g_rules[0].sig_stoch_ha      = InpDefaultSigStochHA;
      g_rules[0].signal_mode       = InpDefaultSigMode;
      g_rules[0].bull_bound_entered_time = 0;
      g_rules[0].bear_bound_entered_time = 0;
      g_rules[0].bull_bound_exit_time    = 0;
      g_rules[0].bear_bound_exit_time    = 0;
      for(int k = 0; k < 2; k++)
      {
         g_rules[0].last_bull_bar[k] = 0;
         g_rules[0].last_bear_bar[k] = 0;
         g_rules[0].bull_last_checked_bar[k] = 0;
         g_rules[0].bear_last_checked_bar[k] = 0;
      }
      return;
   }
   
   int handle = FileOpen(filename, FILE_READ|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      g_master_power_enabled = (FileReadInteger(handle) == 1);
      int state_ver = FileReadInteger(handle); // v4 = 4; v3 = 3; v2 = 2; v1 legacy
      int total_rules;
      if(state_ver >= 2)
         total_rules = FileReadInteger(handle);
      else
         total_rules = state_ver;
      if(total_rules < 0 || total_rules > 1000) { FileClose(handle); return; }
      ArrayResize(g_rules, total_rules);
      
      for(int i = 0; i < total_rules; i++)
      {
         int sym_len = FileReadInteger(handle);
         if(sym_len > 0) g_rules[i].symbol = FileReadString(handle, sym_len);
         else g_rules[i].symbol = "";
            
         g_rules[i].direction         = (ENUM_TRADE_DIRECTION)FileReadInteger(handle);
         g_rules[i].risk_reward_ratio = FileReadDouble(handle);
         g_rules[i].timeframe         = (ENUM_TIMEFRAMES)FileReadInteger(handle);
         g_rules[i].lot_mode          = (ENUM_LOT_MODE)FileReadInteger(handle);
         g_rules[i].lot_value         = FileReadDouble(handle);
         g_rules[i].enable_trail      = (FileReadInteger(handle) == 1);
         g_rules[i].trail_trigger_pct = FileReadDouble(handle);
         g_rules[i].atr_multiplier    = FileReadDouble(handle);
         
         int bf_len = FileReadInteger(handle);
         if(bf_len > 0) g_rules[i].bull_price_filter = FileReadString(handle, bf_len);
         else g_rules[i].bull_price_filter = "ALL";
         
         int sf_len = FileReadInteger(handle);
         if(sf_len > 0) g_rules[i].bear_price_filter = FileReadString(handle, sf_len);
         else g_rules[i].bear_price_filter = "ALL";
         
         g_rules[i].max_orders        = FileReadInteger(handle);
         g_rules[i].entry_multiplier  = FileReadInteger(handle);
         if(g_rules[i].entry_multiplier <= 0) g_rules[i].entry_multiplier = 1;
         g_rules[i].multi_tp          = FileReadInteger(handle);
         if(g_rules[i].multi_tp <= 0) g_rules[i].multi_tp = 1;
         g_rules[i].delay_tf_pct      = FileReadInteger(handle);
         g_rules[i].delay_is_tf_close = (FileReadInteger(handle) == 1);
         g_rules[i].orders_opened_count = FileReadInteger(handle);
         g_rules[i].active            = (FileReadInteger(handle) == 1);
         
         if(state_ver >= 4)
         {
            g_rules[i].sig_engulfing = (FileReadInteger(handle) == 1);
            g_rules[i].sig_hammer_ss = (FileReadInteger(handle) == 1);
            g_rules[i].sig_stoch_ha  = (FileReadInteger(handle) == 1);
            g_rules[i].signal_mode   = (ENUM_SIGNAL_MODE)FileReadInteger(handle);
         }
         else
         {
            g_rules[i].sig_engulfing = true;
            g_rules[i].sig_hammer_ss = true;
            g_rules[i].sig_stoch_ha  = true;
            g_rules[i].signal_mode   = SIGNAL_MODE_ANY;
         }
         
         g_rules[i].bull_bound_entered_time = 0;
         g_rules[i].bear_bound_entered_time = 0;
         g_rules[i].bull_bound_exit_time    = 0;
         g_rules[i].bear_bound_exit_time    = 0;
         for(int k = 0; k < 2; k++)
         {
            g_rules[i].last_bull_bar[k] = 0;
            g_rules[i].last_bear_bar[k] = 0;
            g_rules[i].bull_last_checked_bar[k] = 0;
            g_rules[i].bear_last_checked_bar[k] = 0;
         }
      }
      
      // 3. Persistent Add/Edit form state
      if(state_ver >= 3 && FileIsEnding(handle) == false)
      {
         int form_sym_len = FileReadInteger(handle);
         string form_sym = "";
         if(form_sym_len > 0) form_sym = FileReadString(handle, form_sym_len);
         if(form_sym != "") g_form_sym = form_sym;

         int form_tf_val = FileReadInteger(handle);
         if(form_tf_val > 0) g_form_tf = (ENUM_TIMEFRAMES)form_tf_val;

         double form_rr_val = FileReadDouble(handle);
         if(form_rr_val > 0) g_form_rr = form_rr_val;

         int form_bf_len = FileReadInteger(handle);
         string form_bull = "ALL";
         if(form_bf_len > 0) form_bull = FileReadString(handle, form_bf_len);
         g_form_bmax = (form_bull != "") ? form_bull : "ALL";

         int form_sf_len = FileReadInteger(handle);
         string form_bear = "ALL";
         if(form_sf_len > 0) form_bear = FileReadString(handle, form_sf_len);
         g_form_smin = (form_bear != "") ? form_bear : "ALL";

         g_form_delay_pct   = FileReadInteger(handle);
         g_form_delay_close = (FileReadInteger(handle) == 1);

         g_form_max_orders  = FileReadInteger(handle);
         g_form_entry_mult  = FileReadInteger(handle);
         g_form_multi_tp   = FileReadInteger(handle);

         g_form_direction   = (ENUM_TRADE_DIRECTION)FileReadInteger(handle);
         g_form_lot_mode    = (ENUM_LOT_MODE)FileReadInteger(handle);
         g_form_lot_val     = FileReadDouble(handle);
         g_form_trail_on    = (FileReadInteger(handle) == 1);
         g_form_trail_pct   = FileReadDouble(handle);
         g_form_atr_mult    = FileReadDouble(handle);
         
         if(state_ver >= 4 && FileIsEnding(handle) == false)
         {
            g_form_sig_eng   = (FileReadInteger(handle) == 1);
            g_form_sig_hmr   = (FileReadInteger(handle) == 1);
            g_form_sig_stoch = (FileReadInteger(handle) == 1);
            g_form_sig_mode  = (ENUM_SIGNAL_MODE)FileReadInteger(handle);
         }
      }
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   
   LoadStateFromFile();
   
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   
   CreateDashboardUI();
   
   PrintFormat("MultiRuleAutoTrader Initialized | Multi-Rules Active: %d rules loaded", ArraySize(g_rules));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveStateToFile();
   DestroyDashboardUI();
   Print("MultiRuleAutoTrader Deinitialized.");
}

//+------------------------------------------------------------------+
//| ChartEvent function                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == g_prefix + "BTN_TOGGLE_MASTER")
      {
         g_master_power_enabled = !g_master_power_enabled;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DIR_BOTH" || sparam == g_prefix + "BTN_DIR_BUY" || sparam == g_prefix + "BTN_DIR_SELL")
      {
         // Capture current form edits before switching direction
         string cur_sym = ObjectGetString(0, g_prefix + "INP_SYM", OBJPROP_TEXT);
         if(cur_sym != "") g_form_sym = cur_sym;
         
         double cur_rr = StringToDouble(ObjectGetString(0, g_prefix + "INP_RR", OBJPROP_TEXT));
         if(cur_rr > 0) g_form_rr = cur_rr;
         
         double cur_lot = StringToDouble(ObjectGetString(0, g_prefix + "INP_LOT", OBJPROP_TEXT));
         if(cur_lot > 0) g_form_lot_val = cur_lot;
         
         double cur_tpct = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_PCT", OBJPROP_TEXT));
         if(cur_tpct > 0) g_form_trail_pct = cur_tpct;
         
         double cur_amult = StringToDouble(ObjectGetString(0, g_prefix + "INP_ATR_MULT", OBJPROP_TEXT));
         if(cur_amult > 0) g_form_atr_mult = cur_amult;
         
         int cur_mord = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MAX_ORD", OBJPROP_TEXT));
         if(cur_mord >= 0) g_form_max_orders = cur_mord;
         
         int cur_entri_mult = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_ENTRI_MULT", OBJPROP_TEXT));
         if(cur_entri_mult > 0) g_form_entry_mult = cur_entri_mult;
         
         int cur_multi_tp = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MULTI_TP", OBJPROP_TEXT));
         if(cur_multi_tp > 0) g_form_multi_tp = cur_multi_tp;
         
         // Object is absent in TF CLOSE mode; keep the stored value instead of
         // reading "" as 0.
         if(!g_form_delay_close)
         {
            int cur_pct = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
            if(cur_pct >= 0) g_form_delay_pct = cur_pct;
         }
         
         if(g_form_direction == TRADE_DIR_BOTH)
         {
            string b_val = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
            if(b_val != "") g_form_bmax = b_val;
            string s_val = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
            if(s_val != "") g_form_smin = s_val;
         }
         else if(g_form_direction == TRADE_DIR_BUY)
         {
            string b_val = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
            if(b_val != "") g_form_bmax = b_val;
         }
         else if(g_form_direction == TRADE_DIR_SELL)
         {
            string s_val = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
            if(s_val != "") g_form_smin = s_val;
         }
         
         if(sparam == g_prefix + "BTN_DIR_BOTH") g_form_direction = TRADE_DIR_BOTH;
         else if(sparam == g_prefix + "BTN_DIR_BUY") g_form_direction = TRADE_DIR_BUY;
         else if(sparam == g_prefix + "BTN_DIR_SELL") g_form_direction = TRADE_DIR_SELL;
         
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_SIG_ENG")
      {
         g_form_sig_eng = !g_form_sig_eng;
         if(g_form_sig_mode == SIGNAL_MODE_COMBO && g_form_sig_eng && g_form_sig_hmr)
            g_form_sig_hmr = false; // Mutual exclusion
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_SIG_HMR")
      {
         g_form_sig_hmr = !g_form_sig_hmr;
         if(g_form_sig_mode == SIGNAL_MODE_COMBO && g_form_sig_hmr && g_form_sig_eng)
            g_form_sig_eng = false;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_SIG_STOCH")
      {
         g_form_sig_stoch = !g_form_sig_stoch;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_TOGGLE_SIG_MODE")
      {
         if(g_form_sig_mode == SIGNAL_MODE_ANY)
         {
            g_form_sig_mode = SIGNAL_MODE_COMBO;
            g_form_sig_eng   = true;
            g_form_sig_hmr   = false;
            g_form_sig_stoch = true;
         }
         else
         {
            g_form_sig_mode = SIGNAL_MODE_ANY;
            g_form_sig_eng   = true;
            g_form_sig_hmr   = true;
            g_form_sig_stoch = true;
         }
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_TOGGLE_LOT_MODE")
      {
         // Read current input value before switching
         double cur_lot = StringToDouble(ObjectGetString(0, g_prefix + "INP_LOT", OBJPROP_TEXT));
         if(cur_lot > 0) g_form_lot_val = cur_lot;
         
         if(g_form_lot_mode == LOT_FIXED)
         {
            g_form_lot_mode = LOT_RISK_PCT;
            g_form_lot_val = 1.0; // Default Risk%
         }
         else
         {
            g_form_lot_mode = LOT_FIXED;
            g_form_lot_val = 0.01; // Default Fixed Lot
         }
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_TOGGLE_DELAY_MODE")
      {
         // Object is absent in TF CLOSE mode, so only read it when present.
         if(!g_form_delay_close)
         {
            int cur_pct = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
            if(cur_pct >= 0) g_form_delay_pct = cur_pct;
         }
         
         g_form_delay_close = !g_form_delay_close;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_TOGGLE_MAX_ORD")
      {
         if(g_form_max_orders <= 0) g_form_max_orders = 1;
         else g_form_max_orders = 0; // Unlimited
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_TOGGLE_TRAIL")
      {
         g_form_trail_on = !g_form_trail_on;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_CANCEL_EDIT")
      {
         g_editing_rule_idx = -1;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DEFAULT_RULE")
      {
         g_form_sym        = _Symbol;
         g_form_direction  = InpTradeDirection;
         g_form_rr         = InpRiskRewardRatio;
         g_form_tf         = InpTimeframe;
         g_form_lot_mode   = InpLotMode;
         g_form_lot_val    = (InpLotMode == LOT_FIXED) ? InpFixedLot : InpRiskPercent;
         g_form_trail_on   = InpEnableTrail;
         g_form_trail_pct  = InpTrailTriggerPct;
         g_form_atr_mult   = InpRelVolThreshold;
         g_form_max_orders = InpMaxOrders;
         g_form_entry_mult = InpEntryMultiplier;
         g_form_multi_tp  = InpMultiTP;
         g_form_delay_pct  = InpDelayTFPct;
         g_form_delay_close= InpDelayIsTfClose;
         g_form_sig_eng    = InpDefaultSigEng;
         g_form_sig_hmr    = InpDefaultSigHmrSS;
         g_form_sig_stoch  = InpDefaultSigStochHA;
         g_form_sig_mode   = InpDefaultSigMode;
         g_form_bmax       = "ALL";
         g_form_smin       = "ALL";
         g_editing_rule_idx = -1;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RULES_PREV")
      {
         if(g_rules_page > 0) g_rules_page--;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RULES_NEXT")
      {
         int total_rules = ArraySize(g_rules);
         int max_pages = (total_rules + RULES_PER_PAGE - 1) / RULES_PER_PAGE;
         if(g_rules_page < max_pages - 1) g_rules_page++;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_SUBMIT_RULE")
      {
         string raw_sym = ObjectGetString(0, g_prefix + "INP_SYM", OBJPROP_TEXT);
         string valid_sym = FindExactOrMarketWatchSymbol(raw_sym);
         if(valid_sym == "")
         {
            Alert("Simbol '" + raw_sym + "' tidak ditemukan di Market Watch!");
            return;
         }
         
         double rr_val = StringToDouble(ObjectGetString(0, g_prefix + "INP_RR", OBJPROP_TEXT));
         if(rr_val <= 0) rr_val = 2.0;
         
         int tf_input = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_TF", OBJPROP_TEXT));
         ENUM_TIMEFRAMES tf_val = PERIOD_M5;
         if(tf_input == 1) tf_val = PERIOD_M1;
         else if(tf_input == 5) tf_val = PERIOD_M5;
         else if(tf_input == 15) tf_val = PERIOD_M15;
         else if(tf_input == 30) tf_val = PERIOD_M30;
         else if(tf_input == 60) tf_val = PERIOD_H1;
         else if(tf_input == 240) tf_val = PERIOD_H4;
         else if(tf_input == 1440) tf_val = PERIOD_D1;
         
         double lot_val = StringToDouble(ObjectGetString(0, g_prefix + "INP_LOT", OBJPROP_TEXT));
         if(lot_val <= 0) lot_val = 0.01;
         
         double trail_pct = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_PCT", OBJPROP_TEXT));
         if(trail_pct <= 0) trail_pct = 5.0;
         
         double atr_mult = StringToDouble(ObjectGetString(0, g_prefix + "INP_ATR_MULT", OBJPROP_TEXT));
         if(atr_mult <= 0) atr_mult = 1.6;
         
         int max_ord_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MAX_ORD", OBJPROP_TEXT));
         
         int mult_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_ENTRI_MULT", OBJPROP_TEXT));
         if(mult_val <= 0) mult_val = 1;
         
         int multi_tp_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MULTI_TP", OBJPROP_TEXT));
         if(multi_tp_val <= 0) multi_tp_val = 1;
         
         int delay_pct_val = g_form_delay_pct;
         if(!g_form_delay_close)
            delay_pct_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
         if(delay_pct_val < 0) delay_pct_val = 0;
         if(delay_pct_val > 99) delay_pct_val = 99;
         
         string b_filter = "ALL";
         string s_filter = "ALL";
         
         if(g_form_direction == TRADE_DIR_BOTH)
         {
            b_filter = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
            s_filter = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
         }
         else if(g_form_direction == TRADE_DIR_BUY)
         {
            b_filter = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
         }
         else if(g_form_direction == TRADE_DIR_SELL)
         {
            s_filter = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
         }
         
         // Strict Validation of Price Filters
         if(b_filter != "" && b_filter != "ALL" && b_filter != "BEBAS")
         {
            double dummy_test = 0.0;
            if(!EvaluatePriceFilter(dummy_test, b_filter) && StringFind(b_filter, "-") < 0 && StringFind(b_filter, "<") < 0 && StringFind(b_filter, ">") < 0)
            {
               Alert("Format Price Bound BUY salah! Harus menggunakan operator (<, >, <=, >=) atau rentang (Min-Max, cth: 4040-4078), atau ketik 'ALL'.");
               return;
            }
         }
         
         if(s_filter != "" && s_filter != "ALL" && s_filter != "BEBAS")
         {
            double dummy_test = 0.0;
            if(!EvaluatePriceFilter(dummy_test, s_filter) && StringFind(s_filter, "-") < 0 && StringFind(s_filter, "<") < 0 && StringFind(s_filter, ">") < 0)
            {
               Alert("Format Price Bound SELL salah! Harus menggunakan operator (<, >, <=, >=) atau rentang (Min-Max, cth: 4040-4078), atau ketik 'ALL'.");
               return;
            }
         }
         
         // Capture form state to persist after submit
         g_form_sym       = valid_sym;
         g_form_rr        = rr_val;
         g_form_tf        = tf_val;
         g_form_lot_val   = lot_val;
         g_form_trail_pct = trail_pct;
         g_form_atr_mult  = atr_mult;
         g_form_entry_mult= mult_val;
         g_form_multi_tp = multi_tp_val;
         g_form_delay_pct = delay_pct_val;
         g_form_max_orders= max_ord_val;
         g_form_bmax      = b_filter;
         g_form_smin      = s_filter;
         
         int target_idx = g_editing_rule_idx;
         if(target_idx < 0)
         {
            target_idx = ArraySize(g_rules);
            ArrayResize(g_rules, target_idx + 1);
            g_rules[target_idx].active = true;
            g_rules[target_idx].orders_opened_count = 0;
         }
         
         g_rules[target_idx].symbol              = valid_sym;
         g_rules[target_idx].direction           = g_form_direction;
         g_rules[target_idx].risk_reward_ratio   = rr_val;
         g_rules[target_idx].timeframe           = tf_val;
         g_rules[target_idx].lot_mode            = g_form_lot_mode;
         g_rules[target_idx].lot_value           = lot_val;
         g_rules[target_idx].enable_trail        = g_form_trail_on;
         g_rules[target_idx].trail_trigger_pct   = trail_pct;
         g_rules[target_idx].atr_multiplier      = atr_mult;
         g_rules[target_idx].bull_price_filter   = b_filter;
         g_rules[target_idx].bear_price_filter   = s_filter;
         g_rules[target_idx].max_orders          = max_ord_val;
         g_rules[target_idx].entry_multiplier    = mult_val;
         g_rules[target_idx].multi_tp          = multi_tp_val;
         g_rules[target_idx].delay_tf_pct        = delay_pct_val;
         g_rules[target_idx].delay_is_tf_close   = g_form_delay_close;
         g_rules[target_idx].sig_engulfing       = g_form_sig_eng;
         g_rules[target_idx].sig_hammer_ss       = g_form_sig_hmr;
         g_rules[target_idx].sig_stoch_ha        = g_form_sig_stoch;
         g_rules[target_idx].signal_mode         = g_form_sig_mode;
         g_rules[target_idx].bull_bound_entered_time = 0;
         g_rules[target_idx].bear_bound_entered_time = 0;
         g_rules[target_idx].bull_bound_exit_time    = 0;
         g_rules[target_idx].bear_bound_exit_time    = 0;
         for(int k = 0; k < 2; k++)
         {
            g_rules[target_idx].last_bull_bar[k] = 0;
            g_rules[target_idx].last_bear_bar[k] = 0;
            g_rules[target_idx].bull_last_checked_bar[k] = 0;
            g_rules[target_idx].bear_last_checked_bar[k] = 0;
         }
         
         g_selected_rule_idx = target_idx;
         g_editing_rule_idx  = -1;
         SaveStateToFile();
         CreateDashboardUI();
         Alert(StringFormat("Auto Trader Rule untuk %s berhasil disimpan!", valid_sym));
         return;
      }
      
      int total_rules = ArraySize(g_rules);
      for(int i = 0; i < total_rules; i++)
      {
         string r_pfx = StringFormat("ROW_%d_", i);
         if(sparam == g_prefix + r_pfx + "BG" || sparam == g_prefix + r_pfx + "SYM" || 
            sparam == g_prefix + r_pfx + "NO" || sparam == g_prefix + r_pfx + "DIR" ||
            sparam == g_prefix + r_pfx + "LOT" || sparam == g_prefix + r_pfx + "RR" ||
            sparam == g_prefix + r_pfx + "TF" || sparam == g_prefix + r_pfx + "FLT" ||
            sparam == g_prefix + r_pfx + "TRL" || sparam == g_prefix + r_pfx + "MTP" ||
            sparam == g_prefix + r_pfx + "SIGS")
         {
            g_selected_rule_idx = i;
            UpdatePreviewTerminalBox();
            UpdateDashboardUI();
            return;
         }
         else if(sparam == g_prefix + "BTN_EDIT_RULE_" + IntegerToString(i))
         {
            g_editing_rule_idx  = i;
            g_selected_rule_idx = i;
            g_form_sym          = g_rules[i].symbol;
            g_form_direction    = g_rules[i].direction;
            g_form_rr           = g_rules[i].risk_reward_ratio;
            g_form_tf           = g_rules[i].timeframe;
            g_form_lot_mode     = g_rules[i].lot_mode;
            g_form_lot_val      = g_rules[i].lot_value;
            g_form_trail_on     = g_rules[i].enable_trail;
            g_form_trail_pct    = g_rules[i].trail_trigger_pct;
            g_form_atr_mult     = g_rules[i].atr_multiplier;
            g_form_entry_mult   = g_rules[i].entry_multiplier;
            g_form_multi_tp    = g_rules[i].multi_tp;
            g_form_delay_pct    = g_rules[i].delay_tf_pct;
            g_form_delay_close  = g_rules[i].delay_is_tf_close;
            g_form_sig_eng      = g_rules[i].sig_engulfing;
            g_form_sig_hmr      = g_rules[i].sig_hammer_ss;
            g_form_sig_stoch    = g_rules[i].sig_stoch_ha;
            g_form_sig_mode     = g_rules[i].signal_mode;
            g_form_max_orders   = g_rules[i].max_orders;
            g_form_bmax         = g_rules[i].bull_price_filter;
            g_form_smin         = g_rules[i].bear_price_filter;
            CreateDashboardUI();
            return;
         }
         else if(sparam == g_prefix + "BTN_DEL_RULE_" + IntegerToString(i))
         {
            for(int d = i; d < total_rules - 1; d++)
               g_rules[d] = g_rules[d + 1];
            ArrayResize(g_rules, total_rules - 1);
            
            if(g_editing_rule_idx == i) g_editing_rule_idx = -1;
            else if(g_editing_rule_idx > i) g_editing_rule_idx--;
            
            if(g_selected_rule_idx >= ArraySize(g_rules))
               g_selected_rule_idx = ArraySize(g_rules) - 1;
            if(g_selected_rule_idx < 0) g_selected_rule_idx = 0;
            
            SaveStateToFile();
            CreateDashboardUI();
            return;
         }
         else if(sparam == g_prefix + "BTN_TOGGLE_RULE_" + IntegerToString(i))
         {
            g_rules[i].active = !g_rules[i].active;
            if(g_rules[i].active && g_rules[i].max_orders > 0 && g_rules[i].orders_opened_count >= g_rules[i].max_orders)
               g_rules[i].orders_opened_count = 0; // Reset counter on manual reactivation
            g_selected_rule_idx = i;
            SaveStateToFile();
            UpdatePreviewTerminalBox();
            UpdateDashboardUI();
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function (Multi-Rule Realtime Tick Scanning)         |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_master_power_enabled) return;
   
   ProcessAutoTrailSLTP();
   
   int total_rules = ArraySize(g_rules);
   if(total_rules == 0) return;
   
   for(int r = 0; r < total_rules; r++)
   {
      if(!g_rules[r].active) continue;
      
      // Check max orders limit (e.g. max_orders = 1 means 1x open then paused)
      if(g_rules[r].max_orders > 0 && g_rules[r].orders_opened_count >= g_rules[r].max_orders)
      {
         if(g_rules[r].active)
         {
            g_rules[r].active = false; // Auto pause
            SaveStateToFile();
            UpdateDashboardUI();
            PrintFormat("Auto Trader Rule #%d (%s) auto-paused: reached max orders limit (%d)", r + 1, g_rules[r].symbol, g_rules[r].max_orders);
         }
         continue;
      }
      
      // Sequential entries: no new cycle while the previous batch is still open.
      // CountOpenPositions matches symbol + magic, i.e. only positions THIS EA
      // opened; a manual trade carries a different magic and cannot block entry.
      // Deliberately NOT conditioned on orders_opened_count: manual reactivation
      // resets that counter to 0, which would bypass this gate while the previous
      // batch was still running.
      // ponytail: symbol-keyed, so two rules on the SAME symbol block each other.
      if(CountOpenPositions(g_rules[r].symbol) > 0)
         continue;
      
      string sym = g_rules[r].symbol;
      ENUM_TIMEFRAMES tf = g_rules[r].timeframe;
      
      if(!m_symbol_info.Name(sym)) continue;
      m_symbol_info.RefreshRates();
      
      double ask = m_symbol_info.Ask();
      double bid = m_symbol_info.Bid();
      double spread = ask - bid;
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      
      // Realtime ATR 50%: basis = own TF, except M1 which uses M5 candles
      ENUM_TIMEFRAMES atr_tf = AtrBaseTF(tf);
      double atr_50 = CalculateATR50(sym, atr_tf, InpATRPeriod);
      if(atr_50 <= 0) continue;
      
      ENUM_TIMEFRAMES cand_tf[];
      int cand_total = CandidateTFs(tf, cand_tf);
      
      // ===================================================================
      // PRICE BOUND GRACE PERIOD (1.5x TF) TRACKING
      // ===================================================================
      // Toleransi 1.5x TF:
      // - Harus pernah masuk zona bound terlebih dahulu (entered_time > 0).
      // - Saat keluar dari bound, exit_time dicatat dan memberi toleransi 1.5x TF durasi.
      // - Jika masuk kembali sebelum batas waktu, exit_time direset ke 0.
      datetime now_time = TimeCurrent();
      int rule_tf_sec   = PeriodSeconds(tf);
      int grace_period  = (int)(1.5 * rule_tf_sec);
      
      bool bull_bound_now = EvaluatePriceFilter(ask, g_rules[r].bull_price_filter);
      bool bull_bound_eligible = false;
      if(g_rules[r].bull_price_filter == "" || g_rules[r].bull_price_filter == "ALL" || g_rules[r].bull_price_filter == "BEBAS")
      {
         bull_bound_eligible = true;
      }
      else
      {
         if(bull_bound_now)
         {
            g_rules[r].bull_bound_entered_time = now_time;
            g_rules[r].bull_bound_exit_time    = 0; // Reset exit timer while inside
            bull_bound_eligible = true;
         }
         else
         {
            // Currently outside: check if previously entered and still within 1.5x TF grace
            if(g_rules[r].bull_bound_entered_time > 0)
            {
               if(g_rules[r].bull_bound_exit_time == 0)
                  g_rules[r].bull_bound_exit_time = now_time;
               
               if((now_time - g_rules[r].bull_bound_exit_time) <= grace_period)
                  bull_bound_eligible = true;
               else
                  g_rules[r].bull_bound_entered_time = 0; // Grace expired, must re-enter
            }
         }
      }
      
      bool bear_bound_now = EvaluatePriceFilter(bid, g_rules[r].bear_price_filter);
      bool bear_bound_eligible = false;
      if(g_rules[r].bear_price_filter == "" || g_rules[r].bear_price_filter == "ALL" || g_rules[r].bear_price_filter == "BEBAS")
      {
         bear_bound_eligible = true;
      }
      else
      {
         if(bear_bound_now)
         {
            g_rules[r].bear_bound_entered_time = now_time;
            g_rules[r].bear_bound_exit_time    = 0;
            bear_bound_eligible = true;
         }
         else
         {
            if(g_rules[r].bear_bound_entered_time > 0)
            {
               if(g_rules[r].bear_bound_exit_time == 0)
                  g_rules[r].bear_bound_exit_time = now_time;
               
               if((now_time - g_rules[r].bear_bound_exit_time) <= grace_period)
                  bear_bound_eligible = true;
               else
                  g_rules[r].bear_bound_entered_time = 0;
            }
         }
      }
      
      // A. CHECK BUY REVERSAL SIGNALS
      if((g_rules[r].direction == TRADE_DIR_BOTH || g_rules[r].direction == TRADE_DIR_BUY) && bull_bound_eligible)
      {
         for(int c = 0; c < cand_total; c++)
         {
            if(g_rules[r].max_orders > 0 && g_rules[r].orders_opened_count >= g_rules[r].max_orders)
               break;
            if(CountOpenPositions(sym) > 0)
               break;
            
            ENUM_TIMEFRAMES sig_tf = cand_tf[c];
            int sig_tf_sec = PeriodSeconds(sig_tf);
            double broken_level = 0.0;
            double cur_price = 0.0;
            double atr_dummy = 0.0;
            
            datetime cur_bar_open_time = (datetime)SeriesInfoInteger(sym, sig_tf, SERIES_LASTBAR_DATE);
            int slot = (c == 0) ? 0 : 1;
            
            int shift_to_check = 0;
            bool delay_gate_ok = false;
            
            if(g_rules[r].delay_is_tf_close)
            {
               shift_to_check = 1;
               datetime prev_chk = g_rules[r].bull_last_checked_bar[slot];
               if(prev_chk != cur_bar_open_time)
               {
                  g_rules[r].bull_last_checked_bar[slot] = cur_bar_open_time;
                  if(prev_chk != 0) delay_gate_ok = true;
               }
            }
            else
            {
               shift_to_check = 0;
               // % TF Progress Gate (Skenario A)
               // Lilin harus sudah berjalan minimal delay_tf_pct% dari durasinya
               int candle_age = (int)(now_time - cur_bar_open_time);
               if(candle_age < 0) candle_age = 0;
               double age_pct = ((double)candle_age / (double)sig_tf_sec) * 100.0;
               int req_pct = g_rules[r].delay_tf_pct;
               if(req_pct < 0) req_pct = 0;
               if(req_pct > 99) req_pct = 99;
               
               if(age_pct >= req_pct && g_rules[r].last_bull_bar[slot] != cur_bar_open_time)
                  delay_gate_ok = true;
            }
            
            if(!delay_gate_ok) continue;
            
            // Check Individual Signals for BUY
            bool buy_eng_valid   = false;
            double eng_sl_level  = 0.0;
            if(g_rules[r].sig_engulfing)
            {
               double eng_broken = 0.0;
               if(IsStrongBullishEngulfingBreak(sym, sig_tf, shift_to_check, atr_dummy, eng_broken, cur_price))
               {
                  buy_eng_valid = true;
                  eng_sl_level  = eng_broken - atr_50;
               }
            }
            
            bool buy_hmr_valid  = false;
            double hmr_sl_level = 0.0;
            if(g_rules[r].sig_hammer_ss)
            {
               double hmr_low = 0.0;
               if(IsStrongHammer(sym, sig_tf, shift_to_check, hmr_low, cur_price))
               {
                  buy_hmr_valid = true;
                  hmr_sl_level  = hmr_low - atr_50; // Opsi A: Low - 50% ATR (Buy: no spread needed)
               }
            }
            
            bool buy_stoch_valid = false;
            if(g_rules[r].sig_stoch_ha)
            {
               if(CheckStochHA(sym, sig_tf, shift_to_check, true))
                  buy_stoch_valid = true;
            }
            
            // Evaluate Execution Mode: ANY (OR) vs COMBO (AND)
            bool trigger_buy = false;
            double chosen_sl = 0.0;
            
            if(g_rules[r].signal_mode == SIGNAL_MODE_COMBO)
            {
               // COMBO (AND): Semua sinyal yang aktif harus terpenuhi
               bool all_active_ok = true;
               if(g_rules[r].sig_engulfing && !buy_eng_valid)   all_active_ok = false;
               if(g_rules[r].sig_hammer_ss && !buy_hmr_valid)   all_active_ok = false;
               if(g_rules[r].sig_stoch_ha  && !buy_stoch_valid) all_active_ok = false;
               
               if(all_active_ok && (g_rules[r].sig_engulfing || g_rules[r].sig_hammer_ss || g_rules[r].sig_stoch_ha))
               {
                  trigger_buy = true;
                  if(buy_eng_valid)       chosen_sl = eng_sl_level;
                  else if(buy_hmr_valid)  chosen_sl = hmr_sl_level;
                  else                    chosen_sl = ask - atr_50 * 2.0;
               }
            }
            else
            {
               // ANY (OR): Salah satu sinyal aktif terpenuhi
               if(g_rules[r].sig_engulfing && buy_eng_valid)
               {
                  trigger_buy = true;
                  chosen_sl   = eng_sl_level;
               }
               else if(g_rules[r].sig_hammer_ss && buy_hmr_valid)
               {
                  trigger_buy = true;
                  chosen_sl   = hmr_sl_level;
               }
               else if(g_rules[r].sig_stoch_ha && buy_stoch_valid)
               {
                  trigger_buy = true;
                  chosen_sl   = ask - atr_50 * 2.0;
               }
            }
            
            if(!trigger_buy) continue;
            
            g_rules[r].last_bull_bar[slot] = cur_bar_open_time;
            
            datetime sig_bar_time = g_rules[r].delay_is_tf_close
                                    ? (datetime)(cur_bar_open_time - sig_tf_sec)
                                    : cur_bar_open_time;
            double sl_price = chosen_sl;
            double sl_dist  = ask - sl_price;
            if(sl_dist <= 0) continue;
            
            double tp_price = ask + (sl_dist * g_rules[r].risk_reward_ratio);
            sl_price = NormalizeDouble(sl_price, digits);
            tp_price = NormalizeDouble(tp_price, digits);
            double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, ask, sl_price);
            
            int mult = g_rules[r].entry_multiplier;
            if(mult <= 0) mult = 1;
            int mtp = g_rules[r].multi_tp;
            if(mtp <= 0) mtp = 1;
            if(mtp > 16) mtp = 16;
            
            int   plan_cnt = 0;
            double plan_tp[16];
            double plan_lot[16];
            int   plan_ent[16];
            
            if(mtp > 1 && mult >= mtp)
            {
               int base_n = mult / mtp;
               int rem_n = mult % mtp;
               for(int t = 1; t <= mtp; t++)
               {
                  int cnt = base_n + ((t <= rem_n) ? 1 : 0);
                  if(cnt <= 0) continue;
                  plan_tp[plan_cnt] = NormalizeDouble(ask + (sl_dist * g_rules[r].risk_reward_ratio * (double)t), digits);
                  plan_lot[plan_cnt] = lots;
                  plan_ent[plan_cnt] = cnt;
                  plan_cnt++;
               }
            }
            else if(mtp > 1)
            {
               double pool = lots * (double)mult;
               double per = pool / (double)mtp;
               for(int t = 1; t <= mtp; t++)
               {
                  plan_tp[plan_cnt] = NormalizeDouble(ask + (sl_dist * g_rules[r].risk_reward_ratio * (double)t), digits);
                  plan_lot[plan_cnt] = per;
                  plan_ent[plan_cnt] = 1;
                  plan_cnt++;
               }
            }
            else
            {
               plan_tp[0] = tp_price;
               plan_lot[0] = lots;
               plan_ent[0] = mult;
               plan_cnt = 1;
            }
            
            int opened = 0;
            int m_ord = 0;
            for(int p = 0; p < plan_cnt; p++)
            {
               for(int e = 0; e < plan_ent[p]; e++)
               {
                  int m = m_ord;
                  m_ord++;
                  double cur_tp = plan_tp[p];
                  double cur_lot = plan_lot[p];
                  if(m_trade.Buy(cur_lot, sym, ask, sl_price, cur_tp, StringFormat("MultiRule Buy #%d (RR 1:%.1f)", m + 1, g_rules[r].risk_reward_ratio)))
                  {
                     ulong deal_tkt = m_trade.ResultOrder();
                     opened++;
                     
                     double atr100 = atr_50 * 2.0;
                     if(g_rules[r].enable_trail)
                        RegisterPositionTracking(deal_tkt, sym, tf, atr100, ask, cur_tp, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                     
                     string msg = StringFormat("[AUTO TRADER - ORDER OPENED (%d/%d)]\nSymbol: %s (%s signal)\nTicket: #%d (BUY)\nLot: %.2f | Ask: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)",
                                               m + 1, plan_cnt, sym, EnumToString(sig_tf), deal_tkt, cur_lot, ask, sl_price, cur_tp, g_rules[r].risk_reward_ratio);
                     msg += " | Signal bar: " + TimeToString(sig_bar_time);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
            
            if(opened > 0)
            {
               g_rules[r].orders_opened_count++;
               SaveStateToFile();
               UpdateDashboardUI();
            }
         }
      }
      
      // B. CHECK SELL REVERSAL SIGNALS
      if((g_rules[r].direction == TRADE_DIR_BOTH || g_rules[r].direction == TRADE_DIR_SELL) && bear_bound_eligible)
      {
         for(int c = 0; c < cand_total; c++)
         {
            if(g_rules[r].max_orders > 0 && g_rules[r].orders_opened_count >= g_rules[r].max_orders)
               break;
            if(CountOpenPositions(sym) > 0)
               break;
            
            ENUM_TIMEFRAMES sig_tf = cand_tf[c];
            int sig_tf_sec = PeriodSeconds(sig_tf);
            double broken_level = 0.0;
            double cur_price = 0.0;
            double atr_dummy = 0.0;
            
            datetime cur_bar_open_time = (datetime)SeriesInfoInteger(sym, sig_tf, SERIES_LASTBAR_DATE);
            int slot = (c == 0) ? 0 : 1;
            
            int shift_to_check = 0;
            bool delay_gate_ok = false;
            
            if(g_rules[r].delay_is_tf_close)
            {
               shift_to_check = 1;
               datetime prev_chk = g_rules[r].bear_last_checked_bar[slot];
               if(prev_chk != cur_bar_open_time)
               {
                  g_rules[r].bear_last_checked_bar[slot] = cur_bar_open_time;
                  if(prev_chk != 0) delay_gate_ok = true;
               }
            }
            else
            {
               shift_to_check = 0;
               int candle_age = (int)(now_time - cur_bar_open_time);
               if(candle_age < 0) candle_age = 0;
               double age_pct = ((double)candle_age / (double)sig_tf_sec) * 100.0;
               int req_pct = g_rules[r].delay_tf_pct;
               if(req_pct < 0) req_pct = 0;
               if(req_pct > 99) req_pct = 99;
               
               if(age_pct >= req_pct && g_rules[r].last_bear_bar[slot] != cur_bar_open_time)
                  delay_gate_ok = true;
            }
            
            if(!delay_gate_ok) continue;
            
            // Check Individual Signals for SELL
            bool sell_eng_valid   = false;
            double eng_sl_level   = 0.0;
            if(g_rules[r].sig_engulfing)
            {
               double eng_broken = 0.0;
               if(IsStrongBearishEngulfingBreak(sym, sig_tf, shift_to_check, atr_dummy, eng_broken, cur_price))
               {
                  sell_eng_valid = true;
                  eng_sl_level   = eng_broken + atr_50 + spread;
               }
            }
            
            bool sell_ss_valid   = false;
            double ss_sl_level   = 0.0;
            if(g_rules[r].sig_hammer_ss)
            {
               double ss_high = 0.0;
               if(IsStrongShootingStar(sym, sig_tf, shift_to_check, ss_high, cur_price))
               {
                  sell_ss_valid = true;
                  ss_sl_level   = ss_high + atr_50 + spread; // High + 50% ATR + Spread
               }
            }
            
            bool sell_stoch_valid = false;
            if(g_rules[r].sig_stoch_ha)
            {
               if(CheckStochHA(sym, sig_tf, shift_to_check, false))
                  sell_stoch_valid = true;
            }
            
            // Evaluate Execution Mode: ANY (OR) vs COMBO (AND)
            bool trigger_sell = false;
            double chosen_sl  = 0.0;
            
            if(g_rules[r].signal_mode == SIGNAL_MODE_COMBO)
            {
               bool all_active_ok = true;
               if(g_rules[r].sig_engulfing && !sell_eng_valid)   all_active_ok = false;
               if(g_rules[r].sig_hammer_ss && !sell_ss_valid)    all_active_ok = false;
               if(g_rules[r].sig_stoch_ha  && !sell_stoch_valid) all_active_ok = false;
               
               if(all_active_ok && (g_rules[r].sig_engulfing || g_rules[r].sig_hammer_ss || g_rules[r].sig_stoch_ha))
               {
                  trigger_sell = true;
                  if(sell_eng_valid)      chosen_sl = eng_sl_level;
                  else if(sell_ss_valid)  chosen_sl = ss_sl_level;
                  else                    chosen_sl = bid + atr_50 * 2.0 + spread;
               }
            }
            else
            {
               if(g_rules[r].sig_engulfing && sell_eng_valid)
               {
                  trigger_sell = true;
                  chosen_sl    = eng_sl_level;
               }
               else if(g_rules[r].sig_hammer_ss && sell_ss_valid)
               {
                  trigger_sell = true;
                  chosen_sl    = ss_sl_level;
               }
               else if(g_rules[r].sig_stoch_ha && sell_stoch_valid)
               {
                  trigger_sell = true;
                  chosen_sl    = bid + atr_50 * 2.0 + spread;
               }
            }
            
            if(!trigger_sell) continue;
            
            g_rules[r].last_bear_bar[slot] = cur_bar_open_time;
            
            datetime sig_bar_time = g_rules[r].delay_is_tf_close
                                    ? (datetime)(cur_bar_open_time - sig_tf_sec)
                                    : cur_bar_open_time;
            double sl_price = chosen_sl;
            double sl_dist  = sl_price - bid;
            if(sl_dist <= 0) continue;
            
            double tp_price = bid - (sl_dist * g_rules[r].risk_reward_ratio);
            sl_price = NormalizeDouble(sl_price, digits);
            tp_price = NormalizeDouble(tp_price, digits);
            double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, bid, sl_price);
            
            int mult_s = g_rules[r].entry_multiplier;
            if(mult_s <= 0) mult_s = 1;
            int mtp = g_rules[r].multi_tp;
            if(mtp <= 0) mtp = 1;
            if(mtp > 16) mtp = 16;
            
            int   plan_cnt = 0;
            double plan_tp[16];
            double plan_lot[16];
            int   plan_ent[16];
            
            if(mtp > 1 && mult_s >= mtp)
            {
               int base_n = mult_s / mtp;
               int rem_n = mult_s % mtp;
               for(int t = 1; t <= mtp; t++)
               {
                  int cnt = base_n + ((t <= rem_n) ? 1 : 0);
                  if(cnt <= 0) continue;
                  plan_tp[plan_cnt] = NormalizeDouble(bid - (sl_dist * g_rules[r].risk_reward_ratio * (double)t), digits);
                  plan_lot[plan_cnt] = lots;
                  plan_ent[plan_cnt] = cnt;
                  plan_cnt++;
               }
            }
            else if(mtp > 1)
            {
               double pool = lots * (double)mult_s;
               double per = pool / (double)mtp;
               for(int t = 1; t <= mtp; t++)
               {
                  plan_tp[plan_cnt] = NormalizeDouble(bid - (sl_dist * g_rules[r].risk_reward_ratio * (double)t), digits);
                  plan_lot[plan_cnt] = per;
                  plan_ent[plan_cnt] = 1;
                  plan_cnt++;
               }
            }
            else
            {
               plan_tp[0] = tp_price;
               plan_lot[0] = lots;
               plan_ent[0] = mult_s;
               plan_cnt = 1;
            }
            
            int opened = 0;
            int m_ord = 0;
            for(int p = 0; p < plan_cnt; p++)
            {
               for(int e = 0; e < plan_ent[p]; e++)
               {
                  int m = m_ord;
                  m_ord++;
                  double cur_tp = plan_tp[p];
                  double cur_lot = plan_lot[p];
                  if(m_trade.Sell(cur_lot, sym, bid, sl_price, cur_tp, StringFormat("MultiRule Sell #%d (RR 1:%.1f)", m + 1, g_rules[r].risk_reward_ratio)))
                  {
                     ulong deal_tkt = m_trade.ResultOrder();
                     opened++;
                     
                     double atr100 = atr_50 * 2.0;
                     if(g_rules[r].enable_trail)
                        RegisterPositionTracking(deal_tkt, sym, tf, atr100, bid, cur_tp, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                     
                     string msg = StringFormat("[AUTO TRADER - ORDER OPENED (%d/%d)]\nSymbol: %s (%s signal)\nTicket: #%d (SELL)\nLot: %.2f | Bid: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)",
                                               m + 1, plan_cnt, sym, EnumToString(sig_tf), deal_tkt, cur_lot, bid, sl_price, cur_tp, g_rules[r].risk_reward_ratio);
                     msg += " | Signal bar: " + TimeToString(sig_bar_time);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
            
            if(opened > 0)
            {
               g_rules[r].orders_opened_count++;
               SaveStateToFile();
               UpdateDashboardUI();
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
