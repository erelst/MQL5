//+------------------------------------------------------------------+
//|                                       TradeManagerReversalRadar.mq5|
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "2.00"
#property description "Multi-Symbol Trade Manager & Realtime Multi-Signal Reversal Radar"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMS & STRUCTURES                                               |
//+------------------------------------------------------------------+
enum ENUM_BE_OFFSET_MODE
{
   BE_OFFSET_AUTO_SPREAD,   // Auto Spread (+ Spread for Buy, - Spread for Sell)
   BE_OFFSET_ZERO,          // Exact Open Price (+0 points)
   BE_OFFSET_CUSTOM_POINTS, // Custom Lock Points
   BE_OFFSET_CUSTOM_PRICE   // Fixed SL Price (input below)
};

enum ENUM_SIGNAL_MODE
{
   SIGNAL_MODE_ANY,   // ANY (OR): Alert jika salah satu sinyal aktif terpenuhi
   SIGNAL_MODE_COMBO  // COMBO (AND): Alert jika semua sinyal aktif terpenuhi
};

enum ENUM_TRAIL_BE_MODE
{
   TRAIL_BE_PROXIMITY, // Berbasis Sisa Jarak ke TP (<= 20% dari Target Awal)
   TRAIL_BE_PROFIT     // Berbasis Profit Berjalan (>= 1.5x EWMA TR dari Open)
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
   double   trail_max_dist;
   double   atr_multiplier;
   double   trail_be_rem_dist_pct; // Sisa target ratio untuk BE (default 0.20)
   double   trail_ext_rem_dist_pct;// Sisa target ratio untuk TP Extension (default 0.20)
   bool     be_applied;            // Track if BE has already been locked
   bool     active;
};

struct SAutoBEItem
{
   ulong                ticket;
   bool                 is_position; // true = position, false = pending order
   string               symbol;
   ENUM_POSITION_TYPE   pos_type;    // or ENUM_ORDER_TYPE
   double               trigger_price;
   ENUM_BE_OFFSET_MODE  offset_mode;
   int                  custom_points;
   double               fixed_price;  // Used when offset_mode == BE_OFFSET_CUSTOM_PRICE
   bool                 active;
};

struct SRadarSymbol
{
   string               symbol;
   ENUM_TIMEFRAMES      timeframe;
   bool                 bull_enabled;
   string               bull_price_filter;
   bool                 bear_enabled;
   string               bear_price_filter;
   int                  atr_period;
   datetime             last_bull_alert_bar;
   datetime             last_bear_alert_bar;
   bool                 delay_is_tf_close;
   int                  delay_tf_pct;                     // % TF Progress delay (0-99%)
   bool                 active;                           // true = ACTIVE, false = PAUSED
   bool                 sig_engulfing;                    // Strong Engulfing Reversal
   bool                 sig_hammer_ss;                    // Strong Hammer (Buy) / Shooting Star (Sell)
   bool                 sig_stoch_ha;                     // Stochastic + Heikin Ashi Reversal
   ENUM_SIGNAL_MODE     signal_mode;                      // ANY vs COMBO
   datetime             bull_cond_start_time_main;        // TF utama
   datetime             bull_cond_start_time_fallback;    // M1 fallback
   datetime             bear_cond_start_time_main;        // TF utama
   datetime             bear_cond_start_time_fallback;    // M1 fallback
};

struct SSelectedOrder
{
   ulong                ticket;
   bool                 selected;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== GENERAL SETTINGS ==="
input int      InpTimerSeconds         = 1;          // Refresh Timer (Seconds)
input int      InpSlippage             = 10;         // Slippage Points
input ulong    InpMagicNumber          = 0;          // Filter Magic (0 = All Trades)
input ulong    InpAutoTraderMagic      = 882201;     // MultiRuleAutoTrader Magic (for auto-detection)
input bool     InpEnablePushAlerts     = true;       // Send Mobile Push Alerts
input bool     InpEnableSoundAlerts    = true;       // Enable Sound/Pop-up Alerts

input group "=== AUTO TRAIL SL & TP (EWMA TR ENGINE) ==="
input bool                 InpEnableTrail      = true;               // Default Enable Trail SL & TP
input ENUM_TRAIL_BE_MODE   InpTrailBEMode      = TRAIL_BE_PROXIMITY; // Default Trail BE Mode
input double               InpTrailBERemDistPct= 0.20;               // Default Trail BE Remaining TP Distance (0.20 = 20%)
input double               InpTrailExtRemDistPct= 0.20;              // Default TP Extension Remaining TP Distance (0.20 = 20%)
input double               InpMaxDistATR       = 1.10;               // Default Max Proximity to TP (in EWMA TR units)
input double               InpRelVolThreshold  = 1.25;               // Default RelVol Threshold (>= 1.25x)
input double               InpEWMALambda       = 0.90;               // EWMA TR Lambda Decay (0.88 - 0.92)
input int                  InpEWMABars         = 30;                 // EWMA TR Baseline Bars
input double               InpExtendFactor     = 0.70;               // TP Extension Factor (excess * ATR * factor)
input double               InpMaxExtendATR     = 1.80;               // Max TP Extension (in ATR units)

input group "=== REVERSAL SIGNALS SETTINGS ==="
input double   InpBodyRatioMultiplier  = 1.0;        // Min Body Ratio vs Previous Candle
input int      InpDefaultATRPeriod     = 14;         // Default ATR Period for 50% calculation
input bool     InpDefaultSigEng        = true;       // Default Enable Engulfing
input bool     InpDefaultSigHmrSS      = true;       // Default Enable Hammer/Shooting Star
input bool     InpDefaultSigStochHA    = true;       // Default Enable Stoch + Heikin Ashi
input ENUM_SIGNAL_MODE InpDefaultSigMode= SIGNAL_MODE_ANY; // Default Signal Mode (ANY/COMBO)

input group "=== STOCHASTIC & HEIKIN ASHI ==="
input int      InpStochLength          = 14;         // Stochastic Length
input int      InpStochK               = 1;          // %K Smoothing
input int      InpStochD               = 3;          // %D Smoothing
input double   InpStochOB              = 80.0;       // Overbought Level
input double   InpStochOS              = 20.0;       // Oversold Level

//+------------------------------------------------------------------+
//| GLOBAL OBJECTS & STATE                                           |
//+------------------------------------------------------------------+
CTrade            m_trade;
CPositionInfo     m_position;
COrderInfo        m_order;
CSymbolInfo       m_symbol_info;

SRadarSymbol      g_radar_symbols[];
SAutoBEItem       g_auto_be_list[];
SPositionTracking g_tracking_list[];
SSelectedOrder    g_selected_orders[];

int               g_active_tab = 1; // 1 = Orders Tab, 2 = Radar Tab
bool              g_form_delay_close = false;
int               g_form_delay_pct   = 30;
// Persistent Add/Edit Radar form state (mirrors AutoTrader g_form_* pattern).
string            g_form_sym          = _Symbol;
string            g_form_tf           = "5";
string            g_form_bull         = "ALL";
string            g_form_bear         = "ALL";
bool              g_form_sig_eng      = true;
bool              g_form_sig_hmr      = true;
bool              g_form_sig_stoch    = true;
ENUM_SIGNAL_MODE  g_form_sig_mode     = SIGNAL_MODE_ANY;
int               g_orders_page = 0;
int               g_editing_radar_idx = -1; // -1 = Add mode, >= 0 = Edit mode index
ENUM_BE_OFFSET_MODE g_be_offset_mode = BE_OFFSET_AUTO_SPREAD; // Selected Offset Mode for Trigger
double            g_be_fixed_price = 0.0; // Fixed SL price for BE_OFFSET_CUSTOM_PRICE (0 = off)

// Persistent Auto Trail Form Inputs (Order Manager)
double            g_form_trail_max_dist   = 1.10; // Max Dist TR
double            g_form_trail_atr_mult   = 1.25; // RelVol Thresh
double            g_form_trail_be_rem_pct = 20.0; // BE Dist % (default 20%)
double            g_form_trail_ext_rem_pct= 20.0; // EXT Dist % (default 20%)
string            g_form_trail_tf         = "5";  // TF acuan (default M5)

const int         MAX_ROWS_PER_PAGE = 8;
string            g_prefix = "TMRR_";

// UI Coordinates & Colors
#define CLR_CANVAS_BG       C'0,0,0'
#define CLR_PANEL_BG        C'8,10,14'
#define CLR_CARD_BG         C'16,19,27'
#define CLR_BORDER_HARD     C'42,55,82'
#define CLR_BORDER_SOFT     C'28,36,54'
#define CLR_TEXT_PURE       C'255,255,255'
#define CLR_TEXT_MED        C'180,198,231'
#define CLR_CYAN_NEON       C'0,229,255'   // Vibrant Neon Cyan
#define CLR_BULL_NEON       C'0,230,118'   // Vibrant Neon Green (Buy)
#define CLR_BEAR_NEON       C'255,46,77'   // Laser Scarlet Red (Sell)
#define CLR_GOLD_NEON       C'255,179,0'   // Luminous Gold (BE)
#define CLR_ROW_SELECTED    C'26,21,13'
#define CLR_ROW_ALT         C'18,24,34'
#define CLR_TAB_ACTIVE_BG   C'34,21,8'
#define CLR_POWER_ON_BG     C'8,34,18'
#define CLR_POWER_OFF_BG    C'34,8,18'

//+------------------------------------------------------------------+
//| ROBUST SYMBOL MATCHING HELPER                                    |
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
void CreateDashboardUI();
void UpdateDashboardUI();
void DestroyDashboardUI();
void CheckAutoBETriggers();
void CheckReversalRadar();
void ProcessReversalForSymbol(int index);
bool IsStrongBullishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_atr_50, double &out_broken_range, double &out_cur_price, double &out_broken_high, double &out_broken_low);
bool IsStrongBearishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_atr_50, double &out_broken_range, double &out_cur_price, double &out_broken_high, double &out_broken_low);
bool IsStrongHammer(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_low, double &out_cur_price);
bool IsStrongShootingStar(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out_high, double &out_cur_price);
bool CheckStochHA(const string sym, const ENUM_TIMEFRAMES tf, const int shift, bool check_buy);
void ApplyBulkSL(double sl_price);
void ApplyBulkTP(double tp_price);
void ApplyInstantBESpread();
void ActivateBulkAutoBE(double trigger_price, ENUM_BE_OFFSET_MODE mode, int custom_pts);
void DeactivateBulkAutoBE();
void AddRadarSymbol(string sym, ENUM_TIMEFRAMES tf, bool bull_on, string bull_filter, bool bear_on, string bear_filter, int atr_p, bool tf_close, int delay_pct, bool active_on, bool sig_eng, bool sig_hmr, bool sig_stoch, ENUM_SIGNAL_MODE sig_mode);
void UpdateRadarSymbol(int index, string sym, ENUM_TIMEFRAMES tf, bool bull_on, string bull_filter, bool bear_on, string bear_filter, int atr_p, bool tf_close, int delay_pct, bool sig_eng, bool sig_hmr, bool sig_stoch, ENUM_SIGNAL_MODE sig_mode);
void RemoveRadarSymbol(int index);
bool IsOrderSelected(ulong ticket);
void SetOrderSelected(ulong ticket, bool sel);
void SelectAllOrders(bool sel);
void SaveStateToFile();
void LoadStateFromFile();
ENUM_TIMEFRAMES AtrBaseTF(const ENUM_TIMEFRAMES tf);
double CalculateATR50(const string sym, const ENUM_TIMEFRAMES tf, int period);

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
      
   int dash_pos = StringFind(filter_str, "-");
   if(dash_pos > 0)
   {
      string s_min = StringSubstr(filter_str, 0, dash_pos);
      string s_max = StringSubstr(filter_str, dash_pos + 1);
      StringTrimLeft(s_min); StringTrimRight(s_min);
      StringTrimLeft(s_max); StringTrimRight(s_max);
      
      double min_val = StringToDouble(s_min);
      double max_val = StringToDouble(s_max);
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
   
   double exact_val = StringToDouble(filter_str);
   if(exact_val > 0)
      return (MathAbs(price - exact_val) < 0.00001);
      
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetDeviationInPoints(InpSlippage);
   
   EventSetTimer(InpTimerSeconds);
   
   LoadStateFromFile();
   
   // Default watchlist starts empty unless loaded from persistent state (ponytail: YAGNI default symbols)
   
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   
   CreateDashboardUI();
   UpdateDashboardUI();
   
   Print("TradeManagerReversalRadar initialized successfully.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveStateToFile();
   DestroyDashboardUI();
   ChartRedraw();
   Print("TradeManagerReversalRadar deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function (Instant Execution on Every Tick)           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Real-time Auto-BE check on every tick
   CheckAutoBETriggers();
   
   // Real-time Auto Trail SL/TP check on every tick
   ProcessAutoTrailSLTP();
   
   // Real-time Reversal radar scan across symbols
   CheckReversalRadar();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Background check for non-current chart symbol ticks
   CheckAutoBETriggers();
   ProcessAutoTrailSLTP();
   CheckReversalRadar();
   
   // Periodically refresh order list in UI
   UpdateDashboardUI();
}

//+------------------------------------------------------------------+
//| CAPTURE RADAR FORM INPUTS TO PERSIST VALUES ACROSS DASHBOARD UI  |
//+------------------------------------------------------------------+
void CaptureRadarFormInputs()
{
   if(ObjectFind(0, g_prefix + "INP_NEW_SYM") >= 0)
   {
      string cur_sym = ObjectGetString(0, g_prefix + "INP_NEW_SYM", OBJPROP_TEXT);
      if(cur_sym != "") g_form_sym = cur_sym;
   }
   if(ObjectFind(0, g_prefix + "INP_NEW_TF") >= 0)
   {
      string cur_tf = ObjectGetString(0, g_prefix + "INP_NEW_TF", OBJPROP_TEXT);
      if(cur_tf != "") g_form_tf = cur_tf;
   }
   if(ObjectFind(0, g_prefix + "INP_NEW_BULL") >= 0)
   {
      string b_val = ObjectGetString(0, g_prefix + "INP_NEW_BULL", OBJPROP_TEXT);
      if(b_val != "") g_form_bull = b_val;
   }
   if(ObjectFind(0, g_prefix + "INP_NEW_BEAR") >= 0)
   {
      string s_val = ObjectGetString(0, g_prefix + "INP_NEW_BEAR", OBJPROP_TEXT);
      if(s_val != "") g_form_bear = s_val;
   }
   if(!g_form_delay_close && ObjectFind(0, g_prefix + "INP_NEW_DELAY") >= 0)
   {
      string d_val = ObjectGetString(0, g_prefix + "INP_NEW_DELAY", OBJPROP_TEXT);
      if(d_val != "")
      {
         int cur_pct = (int)StringToInteger(d_val);
         if(cur_pct >= 0 && cur_pct <= 99) g_form_delay_pct = cur_pct;
      }
   }
}

void CaptureOrdersFormInputs()
{
   if(ObjectFind(0, g_prefix + "INP_TRAIL_DIST") >= 0)
   {
      double d = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_DIST", OBJPROP_TEXT));
      if(d > 0) g_form_trail_max_dist = d;
   }
   if(ObjectFind(0, g_prefix + "INP_TRAIL_MULT") >= 0)
   {
      double m = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_MULT", OBJPROP_TEXT));
      if(m > 0) g_form_trail_atr_mult = m;
   }
   if(ObjectFind(0, g_prefix + "INP_TRAIL_BE") >= 0)
   {
      double b = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_BE", OBJPROP_TEXT));
      if(b >= 0 && b <= 100) g_form_trail_be_rem_pct = b;
   }
   if(ObjectFind(0, g_prefix + "INP_TRAIL_EXT") >= 0)
   {
      double e = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_EXT", OBJPROP_TEXT));
      if(e >= 0 && e <= 100) g_form_trail_ext_rem_pct = e;
   }
   if(ObjectFind(0, g_prefix + "INP_TRAIL_TF") >= 0)
   {
      string tf_s = ObjectGetString(0, g_prefix + "INP_TRAIL_TF", OBJPROP_TEXT);
      if(tf_s != "") g_form_trail_tf = tf_s;
   }
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
      // Tab navigation
      if(sparam == g_prefix + "TAB_ORDERS")
      {
         CaptureRadarFormInputs();
         g_active_tab = 1;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "TAB_RADAR")
      {
         CaptureOrdersFormInputs();
         g_active_tab = 2;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      // Select All / Clear
      else if(sparam == g_prefix + "BTN_SEL_ALL")
      {
         SelectAllOrders(true);
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_SEL_NONE")
      {
         SelectAllOrders(false);
         UpdateDashboardUI();
         return;
      }
      // Bulk Actions
      else if(sparam == g_prefix + "BTN_APPLY_SL")
      {
         string str_sl = ObjectGetString(0, g_prefix + "INP_SL", OBJPROP_TEXT);
         double val_sl = StringToDouble(str_sl);
         if(val_sl > 0)
         {
            ApplyBulkSL(val_sl);
            UpdateDashboardUI();
         }
         else Alert("Masukkan harga Stop Loss yang valid!");
         return;
      }
      else if(sparam == g_prefix + "BTN_APPLY_TP")
      {
         string str_tp = ObjectGetString(0, g_prefix + "INP_TP", OBJPROP_TEXT);
         double val_tp = StringToDouble(str_tp);
         if(val_tp > 0)
         {
            ApplyBulkTP(val_tp);
            UpdateDashboardUI();
         }
         else Alert("Masukkan harga Take Profit yang valid!");
         return;
      }
      else if(sparam == g_prefix + "BTN_BE_MODE")
      {
         // Cycle through Offset modes: Auto Spread -> Exact Zero -> Custom Points -> Fixed Price
         if(g_be_offset_mode == BE_OFFSET_AUTO_SPREAD)
            g_be_offset_mode = BE_OFFSET_ZERO;
         else if(g_be_offset_mode == BE_OFFSET_ZERO)
            g_be_offset_mode = BE_OFFSET_CUSTOM_POINTS;
         else if(g_be_offset_mode == BE_OFFSET_CUSTOM_POINTS)
            g_be_offset_mode = BE_OFFSET_CUSTOM_PRICE;
         else
            g_be_offset_mode = BE_OFFSET_AUTO_SPREAD;

         // Preserve typed price across re-render
         string str_px = ObjectGetString(0, g_prefix + "INP_BE_PRICE", OBJPROP_TEXT);
         if(StringLen(str_px) > 0) g_be_fixed_price = StringToDouble(str_px);

         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_INSTANT_BE")
      {
         ApplyInstantBESpread();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_APPLY_BE")
      {
         string str_be = ObjectGetString(0, g_prefix + "INP_BE_TRIG", OBJPROP_TEXT);
         double val_be = StringToDouble(str_be);
         if(val_be > 0)
         {
            ActivateBulkAutoBE(val_be, g_be_offset_mode, 10);
            UpdateDashboardUI();
         }
         else Alert("Masukkan harga trigger BE yang valid!");
         return;
      }
      else if(sparam == g_prefix + "BTN_CANCEL_BE")
      {
         DeactivateBulkAutoBE();
         UpdateDashboardUI();
         return;
      }
      // Auto Trail Bulk Actions
      else if(sparam == g_prefix + "BTN_APPLY_TRAIL")
      {
         CaptureOrdersFormInputs();
         int tf_val = (int)StringToInteger(g_form_trail_tf);
         ENUM_TIMEFRAMES trail_tf = PERIOD_M5;
         if(tf_val == 1) trail_tf = PERIOD_M1;
         else if(tf_val == 5) trail_tf = PERIOD_M5;
         else if(tf_val == 15) trail_tf = PERIOD_M15;
         else if(tf_val == 30) trail_tf = PERIOD_M30;
         else if(tf_val == 60) trail_tf = PERIOD_H1;
         else if(tf_val == 240) trail_tf = PERIOD_H4;
         else if(tf_val == 1440) trail_tf = PERIOD_D1;
         
         ActivateBulkAutoTrail(g_form_trail_max_dist, g_form_trail_atr_mult, g_form_trail_be_rem_pct, g_form_trail_ext_rem_pct, trail_tf);
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_CANCEL_TRAIL")
      {
         DeactivateBulkAutoTrail();
         UpdateDashboardUI();
         return;
      }
      // Add / Update Watchlist Symbol
      else if(sparam == g_prefix + "BTN_ADD_RADAR")
      {
         string raw_sym = ObjectGetString(0, g_prefix + "INP_NEW_SYM", OBJPROP_TEXT);
         string matched_sym = FindExactOrMarketWatchSymbol(raw_sym);
         
         if(matched_sym != "")
         {
            string str_bull = ObjectGetString(0, g_prefix + "INP_NEW_BULL", OBJPROP_TEXT);
            string str_bear = ObjectGetString(0, g_prefix + "INP_NEW_BEAR", OBJPROP_TEXT);
            StringTrimLeft(str_bull); StringTrimRight(str_bull);
            StringTrimLeft(str_bear); StringTrimRight(str_bear);
            
            bool has_bull = (str_bull != "");
            bool has_bear = (str_bear != "");
            
            if(!has_bull && !has_bear)
            {
               Alert("Harap isi salah satu kondisi Bullish atau Bearish:\n- Masukkan angka harga (misal: 1.08500)\n- Operator (< 1.0850, >= 1.0900)\n- Rentang (3040-3051)\n- 'ALL' untuk deteksi bebas tanpa batas harga\n- Kosongkan jika ingin OFF");
               return;
            }
            
            int tf_idx = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_NEW_TF", OBJPROP_TEXT));
            ENUM_TIMEFRAMES tf = PERIOD_M5;
            if(tf_idx == 1) tf = PERIOD_M1;
            else if(tf_idx == 5) tf = PERIOD_M5;
            else if(tf_idx == 15) tf = PERIOD_M15;
            else if(tf_idx == 30) tf = PERIOD_M30;
            else if(tf_idx == 60) tf = PERIOD_H1;
            else if(tf_idx == 240) tf = PERIOD_H4;
            else if(tf_idx == 1440) tf = PERIOD_D1;
            
            int delay_pct = 30;
            if(!g_form_delay_close)
            {
               delay_pct = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_NEW_DELAY", OBJPROP_TEXT));
               if(delay_pct < 0) delay_pct = 0;
               if(delay_pct > 99) delay_pct = 99;
            }
            
            // Check fallback if no signals selected
            if(!g_form_sig_eng && !g_form_sig_hmr && !g_form_sig_stoch)
               g_form_sig_eng = true;
            
            if(g_editing_radar_idx >= 0 && g_editing_radar_idx < ArraySize(g_radar_symbols))
            {
               UpdateRadarSymbol(g_editing_radar_idx, matched_sym, tf, has_bull, str_bull, has_bear, str_bear, InpDefaultATRPeriod, g_form_delay_close, delay_pct, g_form_sig_eng, g_form_sig_hmr, g_form_sig_stoch, g_form_sig_mode);
               g_editing_radar_idx = -1;
            }
            else
            {
               AddRadarSymbol(matched_sym, tf, has_bull, str_bull, has_bear, str_bear, InpDefaultATRPeriod, g_form_delay_close, delay_pct, true, g_form_sig_eng, g_form_sig_hmr, g_form_sig_stoch, g_form_sig_mode);
            }
            
            // Persist typed values so they survive rebuilds
            g_form_delay_pct = delay_pct;
            g_form_bull      = str_bull;
            g_form_bear      = str_bear;
            g_form_sym       = matched_sym;
            g_form_tf        = IntegerToString((int)tf);
            
            SaveStateToFile();
            CreateDashboardUI();
            UpdateDashboardUI();
         }
         else Alert("Simbol '", raw_sym, "' tidak ditemukan di broker/Market Watch!");
         return;
      }
      // Toggle Radar Signals in Form
      else if(sparam == g_prefix + "BTN_RADAR_SIG_ENG")
      {
         CaptureRadarFormInputs();
         g_form_sig_eng = !g_form_sig_eng;
         // Mutual exclusion in COMBO mode
         if(g_form_sig_mode == SIGNAL_MODE_COMBO && g_form_sig_eng)
            g_form_sig_hmr = false;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RADAR_SIG_HMR")
      {
         CaptureRadarFormInputs();
         g_form_sig_hmr = !g_form_sig_hmr;
         // Mutual exclusion in COMBO mode
         if(g_form_sig_mode == SIGNAL_MODE_COMBO && g_form_sig_hmr)
            g_form_sig_eng = false;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RADAR_SIG_STOCH")
      {
         CaptureRadarFormInputs();
         g_form_sig_stoch = !g_form_sig_stoch;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RADAR_SIG_MODE")
      {
         CaptureRadarFormInputs();
         g_form_sig_mode = (g_form_sig_mode == SIGNAL_MODE_ANY) ? SIGNAL_MODE_COMBO : SIGNAL_MODE_ANY;
         if(g_form_sig_mode == SIGNAL_MODE_COMBO)
         {
            if(g_form_sig_eng && g_form_sig_hmr) g_form_sig_hmr = false;
         }
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      // Toggle Radar Delay Mode (% TF Progress vs TF Close)
      else if(sparam == g_prefix + "BTN_TOGGLE_RADAR_MODE")
      {
         CaptureRadarFormInputs();
         g_form_delay_close = !g_form_delay_close;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      // Reset Radar Form / Cancel Edit
      else if(sparam == g_prefix + "BTN_RESET_RADAR")
      {
         g_form_sym          = _Symbol;
         g_form_tf           = "5";
         g_form_bull         = "ALL";
         g_form_bear         = "ALL";
         g_form_delay_pct    = 30;
         g_form_delay_close  = false;
         g_form_sig_eng      = true;
         g_form_sig_hmr      = true;
         g_form_sig_stoch    = true;
         g_form_sig_mode     = SIGNAL_MODE_ANY;
         g_editing_radar_idx = -1;

         SaveStateToFile();
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      // Cancel Edit: hanya keluar dari mode edit, form tetap dipertahankan
      else if(sparam == g_prefix + "BTN_CANCEL_EDIT")
      {
         g_editing_radar_idx = -1;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      
      // Individual Order Selection Checkboxes
      if(StringFind(sparam, g_prefix + "ROW_CB_") == 0)
      {
         string str_tkt = StringSubstr(sparam, StringLen(g_prefix + "ROW_CB_"));
         ulong tkt = (ulong)StringToInteger(str_tkt);
         bool cur_sel = IsOrderSelected(tkt);
         SetOrderSelected(tkt, !cur_sel);
         UpdateDashboardUI();
         return;
      }
      
      // Test Alert Button Handler
      else if(sparam == g_prefix + "BTN_TEST_ALERT")
      {
         string test_sym = _Symbol;
         int digits = (int)SymbolInfoInteger(test_sym, SYMBOL_DIGITS);
         double point = SymbolInfoDouble(test_sym, SYMBOL_POINT);
         double pips_factor = (digits == 3 || digits == 5) ? 10.0 * point : point;
         if(pips_factor == 0) pips_factor = point;
         
         double cur_price = SymbolInfoDouble(test_sym, SYMBOL_BID);
         double test_atr50 = CalculateATR50(test_sym, PERIOD_M5, InpDefaultATRPeriod);
         
         double pips_val = test_atr50 / pips_factor;
         double points_val = test_atr50 / point;
         double test_sl = cur_price - test_atr50;
         
         string msg = StringFormat("[TEST NOTIFICATION] %s (M5)\nSignal: System Test Check\nEntry: %s | SL: %s\n50%% ATR(%d): %.1f pips (%.0f pts) | Status: OK",
                                   test_sym,
                                   DoubleToString(cur_price, digits),
                                   DoubleToString(test_sl, digits),
                                   InpDefaultATRPeriod,
                                   pips_val,
                                   points_val);
         
         if(InpEnableSoundAlerts) Alert(msg);
         
         if(InpEnablePushAlerts)
         {
            ResetLastError();
            bool sent = SendNotification(msg);
            if(!sent)
            {
               int err = GetLastError();
               PrintFormat("FAILED to send Push Notification! Error code: %d. Check Tools -> Options -> Notifications in MT5 terminal.", err);
               Alert(StringFormat("Push Notification GAGAL (Error %d). Pastikan MetaQuotes ID sudah diisi di menu Tools -> Options -> Notifications!", err));
            }
            else
            {
               Print("Push Notification sent successfully to MT5 mobile!");
            }
         }
         Print(msg);
         return;
      }
      
      // Toggle Active / Pause Watchlist Item
      if(StringFind(sparam, g_prefix + "BTN_TOGGLE_ACT_") == 0)
      {
         string str_idx = StringSubstr(sparam, StringLen(g_prefix + "BTN_TOGGLE_ACT_"));
         int idx = (int)StringToInteger(str_idx);
         if(idx >= 0 && idx < ArraySize(g_radar_symbols))
         {
            g_radar_symbols[idx].active = !g_radar_symbols[idx].active;
            SaveStateToFile();
            UpdateDashboardUI();
         }
         return;
      }
      
      // Edit Watchlist Item
      if(StringFind(sparam, g_prefix + "BTN_EDIT_RADAR_") == 0)
      {
         string str_idx = StringSubstr(sparam, StringLen(g_prefix + "BTN_EDIT_RADAR_"));
         int idx = (int)StringToInteger(str_idx);
         if(idx >= 0 && idx < ArraySize(g_radar_symbols))
         {
            g_editing_radar_idx = idx;
            // Copy selected radar into persistent form globals (single source of truth)
            g_form_delay_close  = g_radar_symbols[idx].delay_is_tf_close;
            g_form_delay_pct    = g_radar_symbols[idx].delay_tf_pct;
            g_form_sym          = g_radar_symbols[idx].symbol;
            g_form_sig_eng      = g_radar_symbols[idx].sig_engulfing;
            g_form_sig_hmr      = g_radar_symbols[idx].sig_hammer_ss;
            g_form_sig_stoch    = g_radar_symbols[idx].sig_stoch_ha;
            g_form_sig_mode     = g_radar_symbols[idx].signal_mode;
            // Preserve OFF state: if disabled, show empty (OFF) instead of "ALL"
            g_form_bull         = g_radar_symbols[idx].bull_enabled ? g_radar_symbols[idx].bull_price_filter : "";
            g_form_bear         = g_radar_symbols[idx].bear_enabled ? g_radar_symbols[idx].bear_price_filter : "";
            // normalize TF string from enum value
            if(g_radar_symbols[idx].timeframe == PERIOD_M1) g_form_tf = "1";
            else if(g_radar_symbols[idx].timeframe == PERIOD_M5) g_form_tf = "5";
            else if(g_radar_symbols[idx].timeframe == PERIOD_M15) g_form_tf = "15";
            else if(g_radar_symbols[idx].timeframe == PERIOD_M30) g_form_tf = "30";
            else if(g_radar_symbols[idx].timeframe == PERIOD_H1) g_form_tf = "60";
            else if(g_radar_symbols[idx].timeframe == PERIOD_H4) g_form_tf = "240";
            else if(g_radar_symbols[idx].timeframe == PERIOD_D1) g_form_tf = "1440";
            CreateDashboardUI();
            UpdateDashboardUI();
         }
         return;
      }
      
      // Delete Watchlist Item
      if(StringFind(sparam, g_prefix + "BTN_DEL_RADAR_") == 0)
      {
         string str_idx = StringSubstr(sparam, StringLen(g_prefix + "BTN_DEL_RADAR_"));
         int idx = (int)StringToInteger(str_idx);
         if(g_editing_radar_idx == idx) g_editing_radar_idx = -1;
         else if(g_editing_radar_idx > idx) g_editing_radar_idx--;
         RemoveRadarSymbol(idx);
         SaveStateToFile();
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| REALTIME ENGULFING BREAK DETECTION & ATR CALCULATION             |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| REALTIME REVERSAL SCAN ACROSS SYMBOLS                            |
//+------------------------------------------------------------------+
int CandidateTFs(const ENUM_TIMEFRAMES rule_tf, ENUM_TIMEFRAMES &out[])
{
   if(rule_tf == PERIOD_M5)
   {
      ArrayResize(out, 2);
      out[0] = PERIOD_M5;
      out[1] = PERIOD_M1;
      return 2;
   }
   ArrayResize(out, 1);
   out[0] = rule_tf;
   return 1;
}

void CheckReversalRadar()
{
   int total = ArraySize(g_radar_symbols);
   for(int i = 0; i < total; i++)
   {
      ProcessReversalForSymbol(i);
   }
}

void ProcessReversalForSymbol(int index)
{
   if(index < 0 || index >= ArraySize(g_radar_symbols)) return;
   
   // SAKLAR ACTIVE / PAUSE CHECK
   if(!g_radar_symbols[index].active) return;
   
   string sym = g_radar_symbols[index].symbol;
   ENUM_TIMEFRAMES tf = g_radar_symbols[index].timeframe;
   
   if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
      SymbolSelect(sym, true);
   
   ENUM_TIMEFRAMES cand_tf[];
   int cand_total = CandidateTFs(tf, cand_tf);
   
   for(int c = 0; c < cand_total; c++)
   {
      ENUM_TIMEFRAMES sig_tf = cand_tf[c];
      
      datetime cur_bar_open_time = (datetime)SeriesInfoInteger(sym, sig_tf, SERIES_LASTBAR_DATE);
      if(cur_bar_open_time <= 0) continue;
      
      long sig_tf_sec = PeriodSeconds(sig_tf);
      if(sig_tf_sec <= 0) sig_tf_sec = 300;
      
      // % TF PROGRESS DELAY GATE
      if(!g_radar_symbols[index].delay_is_tf_close && g_radar_symbols[index].delay_tf_pct > 0)
      {
         datetime bar_open_time = (datetime)SeriesInfoInteger(sym, sig_tf, SERIES_LASTBAR_DATE);
         datetime cur_tick_time = TimeCurrent();
         long elapsed_sec = cur_tick_time - bar_open_time;
         long min_required_sec = (long)((g_radar_symbols[index].delay_tf_pct / 100.0) * sig_tf_sec);
         if(elapsed_sec < min_required_sec) continue;
      }
      
      int shift_to_check = g_radar_symbols[index].delay_is_tf_close ? 1 : 0;
      
      double atr_50 = CalculateATR50(sym, AtrBaseTF(sig_tf), g_radar_symbols[index].atr_period);
      double cur_price = 0.0;
      
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      double pips_factor = (digits == 3 || digits == 5) ? 10.0 * point : point;
      if(pips_factor == 0) pips_factor = point;
      double spread = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID));
      
      // 1. EVALUASI BULLISH REVERSAL
      if(g_radar_symbols[index].bull_enabled && cur_bar_open_time != g_radar_symbols[index].last_bull_alert_bar)
      {
         bool buy_eng_valid   = false;
         bool buy_hmr_valid   = false;
         bool buy_stoch_valid = false;
         double eng_broken_h = 0.0, eng_broken_l = 0.0, eng_broken_r = 0.0;
         double hmr_low = 0.0;
         
         if(g_radar_symbols[index].sig_engulfing)
         {
            double atr_d = 0.0;
            if(IsStrongBullishEngulfingBreak(sym, sig_tf, shift_to_check, atr_d, eng_broken_r, cur_price, eng_broken_h, eng_broken_l))
               buy_eng_valid = true;
         }
         
         if(g_radar_symbols[index].sig_hammer_ss)
         {
            if(IsStrongHammer(sym, sig_tf, shift_to_check, hmr_low, cur_price))
               buy_hmr_valid = true;
         }
         
         if(g_radar_symbols[index].sig_stoch_ha)
         {
            if(CheckStochHA(sym, sig_tf, shift_to_check, true))
               buy_stoch_valid = true;
         }
         
         bool trigger_buy = false;
         string sig_name = "";
         double rec_sl = 0.0;
         
         if(g_radar_symbols[index].signal_mode == SIGNAL_MODE_COMBO)
         {
            bool all_ok = true;
            if(g_radar_symbols[index].sig_engulfing && !buy_eng_valid)   all_ok = false;
            if(g_radar_symbols[index].sig_hammer_ss && !buy_hmr_valid)   all_ok = false;
            if(g_radar_symbols[index].sig_stoch_ha  && !buy_stoch_valid) all_ok = false;
            
            if(all_ok && (g_radar_symbols[index].sig_engulfing || g_radar_symbols[index].sig_hammer_ss || g_radar_symbols[index].sig_stoch_ha))
            {
               trigger_buy = true;
               sig_name = "COMBO: ";
               if(buy_eng_valid) { sig_name += "[ENG] "; rec_sl = eng_broken_l - atr_50; }
               if(buy_hmr_valid) { sig_name += "[HAMMER] "; rec_sl = hmr_low - atr_50; }
               if(buy_stoch_valid) { sig_name += "[STOCH+HA]"; if(rec_sl == 0) rec_sl = cur_price - (atr_50 * 2.0); }
            }
         }
         else
         {
            if(g_radar_symbols[index].sig_engulfing && buy_eng_valid)
            {
               trigger_buy = true;
               sig_name = "Strong Bullish Engulfing";
               rec_sl = eng_broken_l - atr_50;
            }
            else if(g_radar_symbols[index].sig_hammer_ss && buy_hmr_valid)
            {
               trigger_buy = true;
               sig_name = "Strong Hammer Reversal";
               rec_sl = hmr_low - atr_50;
            }
            else if(g_radar_symbols[index].sig_stoch_ha && buy_stoch_valid)
            {
               trigger_buy = true;
               sig_name = "Stochastic + Heikin Ashi Buy";
               rec_sl = cur_price - (atr_50 * 2.0);
            }
         }
         
         if(trigger_buy && EvaluatePriceFilter(cur_price, g_radar_symbols[index].bull_price_filter))
         {
            string mode_tag = g_radar_symbols[index].delay_is_tf_close ? "TF CLOSE" : 
                              (g_radar_symbols[index].delay_tf_pct > 0 ? StringFormat("%d%% TF DELAY", g_radar_symbols[index].delay_tf_pct) : "REALTIME TICK");
            
            double pips_val = atr_50 / pips_factor;
            double points_val = atr_50 / point;
            
            string msg = StringFormat("[BUY] %s %s (%s)\nSignal: %s\nEntry: %s | SL: %s\n50%% ATR(%d): %.1f pips (%.0f pts) | Mode: %s",
                                      sym, EnumToString(sig_tf), sig_name,
                                      sig_name,
                                      DoubleToString(cur_price, digits),
                                      DoubleToString(rec_sl, digits),
                                      g_radar_symbols[index].atr_period,
                                      pips_val, points_val,
                                      mode_tag);
            
            if(InpEnableSoundAlerts) Alert(msg);
            if(InpEnablePushAlerts)  SendNotification(msg);
            Print(msg);
            
            g_radar_symbols[index].last_bull_alert_bar = cur_bar_open_time;
            break;
         }
      }
      
      // 2. EVALUASI BEARISH REVERSAL
      if(g_radar_symbols[index].bear_enabled && cur_bar_open_time != g_radar_symbols[index].last_bear_alert_bar)
      {
         bool sell_eng_valid   = false;
         bool sell_ss_valid    = false;
         bool sell_stoch_valid = false;
         double eng_broken_h = 0.0, eng_broken_l = 0.0, eng_broken_r = 0.0;
         double ss_high = 0.0;
         
         if(g_radar_symbols[index].sig_engulfing)
         {
            double atr_d = 0.0;
            if(IsStrongBearishEngulfingBreak(sym, sig_tf, shift_to_check, atr_d, eng_broken_r, cur_price, eng_broken_h, eng_broken_l))
               sell_eng_valid = true;
         }
         
         if(g_radar_symbols[index].sig_hammer_ss)
         {
            if(IsStrongShootingStar(sym, sig_tf, shift_to_check, ss_high, cur_price))
               sell_ss_valid = true;
         }
         
         if(g_radar_symbols[index].sig_stoch_ha)
         {
            if(CheckStochHA(sym, sig_tf, shift_to_check, false))
               sell_stoch_valid = true;
         }
         
         bool trigger_sell = false;
         string sig_name = "";
         double rec_sl = 0.0;
         
         if(g_radar_symbols[index].signal_mode == SIGNAL_MODE_COMBO)
         {
            bool all_ok = true;
            if(g_radar_symbols[index].sig_engulfing && !sell_eng_valid)   all_ok = false;
            if(g_radar_symbols[index].sig_hammer_ss && !sell_ss_valid)    all_ok = false;
            if(g_radar_symbols[index].sig_stoch_ha  && !sell_stoch_valid) all_ok = false;
            
            if(all_ok && (g_radar_symbols[index].sig_engulfing || g_radar_symbols[index].sig_hammer_ss || g_radar_symbols[index].sig_stoch_ha))
            {
               trigger_sell = true;
               sig_name = "COMBO: ";
               if(sell_eng_valid) { sig_name += "[ENG] "; rec_sl = eng_broken_h + atr_50 + spread; }
               if(sell_ss_valid)  { sig_name += "[SHOOTING STAR] "; rec_sl = ss_high + atr_50 + spread; }
               if(sell_stoch_valid) { sig_name += "[STOCH+HA]"; if(rec_sl == 0) rec_sl = cur_price + (atr_50 * 2.0) + spread; }
            }
         }
         else
         {
            if(g_radar_symbols[index].sig_engulfing && sell_eng_valid)
            {
               trigger_sell = true;
               sig_name = "Strong Bearish Engulfing";
               rec_sl = eng_broken_h + atr_50 + spread;
            }
            else if(g_radar_symbols[index].sig_hammer_ss && sell_ss_valid)
            {
               trigger_sell = true;
               sig_name = "Strong Shooting Star Reversal";
               rec_sl = ss_high + atr_50 + spread;
            }
            else if(g_radar_symbols[index].sig_stoch_ha && sell_stoch_valid)
            {
               trigger_sell = true;
               sig_name = "Stochastic + Heikin Ashi Sell";
               rec_sl = cur_price + (atr_50 * 2.0) + spread;
            }
         }
         
         if(trigger_sell && EvaluatePriceFilter(cur_price, g_radar_symbols[index].bear_price_filter))
         {
            string mode_tag = g_radar_symbols[index].delay_is_tf_close ? "TF CLOSE" : 
                              (g_radar_symbols[index].delay_tf_pct > 0 ? StringFormat("%d%% TF DELAY", g_radar_symbols[index].delay_tf_pct) : "REALTIME TICK");
            
            double pips_val = atr_50 / pips_factor;
            double points_val = atr_50 / point;
            
            string msg = StringFormat("[SELL] %s %s (%s)\nSignal: %s\nEntry: %s | SL: %s\n50%% ATR(%d): %.1f pips (%.0f pts) | Mode: %s",
                                      sym, EnumToString(sig_tf), sig_name,
                                      sig_name,
                                      DoubleToString(cur_price, digits),
                                      DoubleToString(rec_sl, digits),
                                      g_radar_symbols[index].atr_period,
                                      pips_val, points_val,
                                      mode_tag);
            
            if(InpEnableSoundAlerts) Alert(msg);
            if(InpEnablePushAlerts)  SendNotification(msg);
            Print(msg);
            
            g_radar_symbols[index].last_bear_alert_bar = cur_bar_open_time;
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FAST DIRECT ATR CALCULATION (ponytail: No indicator handles)     |
//+------------------------------------------------------------------+
// ponytail: M1 is the only exception -> 50% ATR basis comes from M5 candles
ENUM_TIMEFRAMES AtrBaseTF(const ENUM_TIMEFRAMES tf)
{
   return (tf == PERIOD_M1) ? PERIOD_M5 : tf;
}

double CalculateATR100(const string sym, const ENUM_TIMEFRAMES tf, int period)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, tf, 1, period + 1, rates); // previous completed candles
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
   return (tr_sum / (double)period); // 100% ATR
}

double CalculateATR50(const string sym, const ENUM_TIMEFRAMES tf, int period)
{
   return CalculateATR100(sym, tf, period) * 0.5; // 50% ATR
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
void RegisterPositionTracking(ulong ticket, string sym, ENUM_TIMEFRAMES tf, double atr100, double open_p, double tp_p, double trail_dist, double atr_mult, double be_rem_dist_pct, double ext_rem_dist_pct)
{
   double rem_pct = (be_rem_dist_pct > 0) ? (be_rem_dist_pct > 1.0 ? be_rem_dist_pct / 100.0 : be_rem_dist_pct) : InpTrailBERemDistPct;
   double ext_pct = (ext_rem_dist_pct > 0) ? (ext_rem_dist_pct > 1.0 ? ext_rem_dist_pct / 100.0 : ext_rem_dist_pct) : InpTrailExtRemDistPct;
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
         g_tracking_list[i].trail_max_dist    = (trail_dist > 0) ? trail_dist : InpMaxDistATR;
         g_tracking_list[i].atr_multiplier    = (atr_mult > 0)   ? atr_mult   : InpRelVolThreshold;
         g_tracking_list[i].trail_be_rem_dist_pct  = rem_pct;
         g_tracking_list[i].trail_ext_rem_dist_pct = ext_pct;
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
   g_tracking_list[size].trail_max_dist    = (trail_dist > 0) ? trail_dist : InpMaxDistATR;
   g_tracking_list[size].atr_multiplier    = (atr_mult > 0)   ? atr_mult   : InpRelVolThreshold;
   g_tracking_list[size].trail_be_rem_dist_pct  = rem_pct;
   g_tracking_list[size].trail_ext_rem_dist_pct = ext_pct;
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
      
      ulong cur_magic = m_position.Magic();
      m_trade.SetExpertMagicNumber(cur_magic);
      
      ENUM_TIMEFRAMES tf = AtrBaseTF(g_tracking_list[i].timeframe);
      // ponytail: scan unbroken profit leg (max 4 bars back: shift 1..4) where candle closed in profit territory.
      // If any bar closed at/beyond open_p (loss/breakeven), the profit leg breaks immediately.
      double curr_tr = GetTrueRange(sym, tf, 0); // start with live candle (shift 0)
      int leg_bars = 1;
      for(int s = 1; s <= 4; s++)
      {
         double c_p = iClose(sym, tf, s);
         if(c_p <= 0) break;
         bool in_profit = (ptype == POSITION_TYPE_BUY) ? (c_p > open_p) : (c_p < open_p);
         if(!in_profit) break; // chain broken by dip into loss/BE
         double tr_s = GetTrueRange(sym, tf, s);
         if(tr_s > curr_tr) curr_tr = tr_s;
         leg_bars++;
      }
      double ewma_tr  = GetEWMA_TR(sym, tf, InpEWMABars, InpEWMALambda);
      if(ewma_tr <= 0) ewma_tr = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
      double rel_vol  = curr_tr / ewma_tr;
      
      double atr_ref = CalculateATR100(sym, tf, InpDefaultATRPeriod);
      if(atr_ref <= 0) atr_ref = ewma_tr;
      
      // 1. TRAIL BE (BREAK-EVEN): MURNI BERBASIS SISA JARAK TARGET TP
      bool trigger_be = false;
      if(!g_tracking_list[i].be_applied && g_tracking_list[i].trail_cycle == 0)
      {
         if(InpTrailBEMode == TRAIL_BE_PROFIT)
         {
            if(ptype == POSITION_TYPE_BUY  && (bid - open_p) >= (1.5 * ewma_tr)) trigger_be = true;
            if(ptype == POSITION_TYPE_SELL && (open_p - ask) >= (1.5 * ewma_tr)) trigger_be = true;
         }
         else
         {
            double base_target_dist = g_tracking_list[i].initial_tp_dist;
            if(base_target_dist <= 0) base_target_dist = MathAbs(cur_tp - open_p);
            
            if(base_target_dist > 0)
            {
               double be_pct = (g_tracking_list[i].trail_be_rem_dist_pct > 0) ? g_tracking_list[i].trail_be_rem_dist_pct : InpTrailBERemDistPct;
               double max_rem_allowed = base_target_dist * be_pct;
               double min_profit_req  = base_target_dist * (1.0 - be_pct);
               if(ptype == POSITION_TYPE_BUY)
               {
                  double rem_dist = cur_tp - bid;
                  double cur_gain = bid - open_p;
                  if(rem_dist <= max_rem_allowed && cur_gain >= min_profit_req && bid > (open_p + spread))
                     trigger_be = true;
               }
               else if(ptype == POSITION_TYPE_SELL)
               {
                  double rem_dist = ask - cur_tp;
                  double cur_gain = open_p - ask;
                  if(rem_dist <= max_rem_allowed && cur_gain >= min_profit_req && ask < (open_p - spread))
                     trigger_be = true;
               }
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
                     string msg = StringFormat("[TRAIL BE] %s #%d (BUY)\nAction: Move SL to Break-Even\nNew SL: %.5f | Locked: +Spread", sym, tkt, be_sl);
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
                     string msg = StringFormat("[TRAIL BE] %s #%d (SELL)\nAction: Move SL to Break-Even\nNew SL: %.5f | Locked: -Spread", sym, tkt, be_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               else g_tracking_list[i].be_applied = true;
            }
         }
      }
      
      // 2. TRAIL TP EXTENSION: JARAK DEKAT TP + LONJAKAN VOLATILITAS NYATA
      // Pada Multi-TP (ada posisi lain dengan magic & arah sama pada simbol ini):
      // - TP1 (target terdekat) DILARANG di-extend agar profit pertama pasti secured.
      // - Hanya target paling ekstrem (tertinggi untuk BUY, terendah untuk SELL) yang di-extend!
      bool is_eligible_tp_runner = true;
      for(int p_chk = PositionsTotal() - 1; p_chk >= 0; p_chk--)
      {
         if(m_position.SelectByIndex(p_chk))
         {
            if(m_position.Symbol() == sym && m_position.Magic() == cur_magic)
            {
               if(m_position.PositionType() == ptype && m_position.Ticket() != tkt)
               {
                  double other_tp = m_position.TakeProfit();
                  if(other_tp > 0)
                  {
                     if(ptype == POSITION_TYPE_BUY  && other_tp > cur_tp) { is_eligible_tp_runner = false; break; }
                     if(ptype == POSITION_TYPE_SELL && other_tp < cur_tp) { is_eligible_tp_runner = false; break; }
                  }
               }
            }
         }
      }
      if(!m_position.SelectByTicket(tkt)) continue;

      // -------------------------------------------------------------------
      // DUAL-LAYER PROXIMITY GATE:
      // Lapis 1: Progres % Target TP (harga WAJIB sudah berjalan maju >= 80%,
      //          sisa <= EXT DIST%, mencegah trigger prematur pada scalping/TP pendek)
      // Lapis 2: Dinamika EWMA TR & Ledakan RelVol (momentum lilin market)
      // -------------------------------------------------------------------
      double base_target_dist = g_tracking_list[i].initial_tp_dist;
      if(base_target_dist <= 0) base_target_dist = MathAbs(cur_tp - open_p);

      double ext_pct = (g_tracking_list[i].trail_ext_rem_dist_pct > 0) ? g_tracking_list[i].trail_ext_rem_dist_pct : InpTrailExtRemDistPct;
      double max_ext_rem_allowed = base_target_dist * ext_pct;
      double min_ext_gain_req    = base_target_dist * (1.0 - ext_pct);

      double ext_rem_dist = 0.0;
      double ext_cur_gain = 0.0;
      if(ptype == POSITION_TYPE_BUY)
      {
         ext_rem_dist = cur_tp - bid;
         ext_cur_gain = bid - open_p;
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         ext_rem_dist = ask - cur_tp;
         ext_cur_gain = open_p - ask;
      }

      bool progress_ok = (base_target_dist > 0) ? (ext_rem_dist <= max_ext_rem_allowed && ext_cur_gain >= min_ext_gain_req) : true;

      double dist_to_tp = 0.0;
      if(ptype == POSITION_TYPE_BUY)  dist_to_tp = MathAbs(cur_tp - bid) / ewma_tr;
      if(ptype == POSITION_TYPE_SELL) dist_to_tp = MathAbs(cur_tp - ask) / ewma_tr;
      
      double max_dist_allowed = (g_tracking_list[i].trail_max_dist > 0) ? g_tracking_list[i].trail_max_dist : InpMaxDistATR;
      double relvol_threshold = (g_tracking_list[i].atr_multiplier > 0)  ? g_tracking_list[i].atr_multiplier : InpRelVolThreshold;
      
      // ponytail: live rejection check - prevent extend if live bar forms >50% rejection wick dumping from TP
      double b0_open = iOpen(sym, tf, 0);
      double b0_high = iHigh(sym, tf, 0);
      double b0_low  = iLow(sym, tf, 0);
      bool is_rejection = false;
      if(ptype == POSITION_TYPE_BUY  && bid < b0_open && (b0_high - bid) > (curr_tr * 0.5)) is_rejection = true;
      if(ptype == POSITION_TYPE_SELL && ask > b0_open && (ask - b0_low)  > (curr_tr * 0.5)) is_rejection = true;
      bool rejection_ok = !is_rejection;

      bool proximity_ok  = progress_ok && (dist_to_tp <= max_dist_allowed);
      bool volatility_ok = (rel_vol >= relvol_threshold);
      
      if(progress_ok && !(proximity_ok && volatility_ok && rejection_ok && is_eligible_tp_runner))
      {
         // ponytail: throttled diagnostic print so trader sees exact reason why TP hasn't extended
         static datetime s_last_diag = 0;
         if(TimeCurrent() - s_last_diag >= 3)
         {
            PrintFormat("[TRAIL PROXIMITY] %s #%d in Zone (sisa %.1f%%): RelVol=%.2f (need >=%.2f) | DistTR=%.2f (need <=%.2f) | LegBars=%d | Reject=%s | Runner=%s",
                        sym, tkt, (ext_rem_dist / base_target_dist) * 100.0, rel_vol, relvol_threshold, dist_to_tp, max_dist_allowed,
                        leg_bars, is_rejection ? "YES" : "NO", is_eligible_tp_runner ? "YES" : "NO (Protected TP1)");
            s_last_diag = TimeCurrent();
         }
      }
      
      if(is_eligible_tp_runner && proximity_ok && volatility_ok && rejection_ok)
      {
         double excess = rel_vol - relvol_threshold;
         double extend_amount = excess * atr_ref * InpExtendFactor;
         extend_amount = MathMin(extend_amount, InpMaxExtendATR * atr_ref);
         if(extend_amount < g_tracking_list[i].initial_tp_dist * 0.5)
            extend_amount = g_tracking_list[i].initial_tp_dist * 0.5;
         
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
                  string msg = StringFormat("[TRAIL TP EXTEND] %s #%d (BUY)\nAction: Extend TP (Cycle %d)\nNew TP: %.5f (+%.5f) | RelVol: %.2f",
                                            sym, tkt, g_tracking_list[i].trail_cycle, new_tp, extend_amount, rel_vol);
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
                  string msg = StringFormat("[TRAIL TP EXTEND] %s #%d (SELL)\nAction: Extend TP (Cycle %d)\nNew TP: %.5f (-%.5f) | RelVol: %.2f",
                                            sym, tkt, g_tracking_list[i].trail_cycle, new_tp, extend_amount, rel_vol);
                  if(InpEnableSoundAlerts) Alert(msg);
                  if(InpEnablePushAlerts)  SendNotification(msg);
               }
            }
         }
      }
      
      // 3. TRAIL SL LOCK TO PREV TP: KETIKA MENDEKATI TP BARU (CYCLE >= 1)
      if(g_tracking_list[i].trail_cycle >= 1)
      {
         double prev_tp = g_tracking_list[i].prev_tp_level;
         if(prev_tp > 0)
         {
            if(ptype == POSITION_TYPE_BUY)
            {
               double dist_to_new_tp = MathAbs(cur_tp - bid) / ewma_tr;
               if(dist_to_new_tp <= max_dist_allowed)
               {
                  double norm_prev_tp = NormalizeDouble(prev_tp, digits);
                  if(norm_prev_tp > cur_sl)
                  {
                     if(m_trade.PositionModify(tkt, norm_prev_tp, cur_tp))
                     {
                        string msg = StringFormat("[TRAIL SL LOCK] %s #%d (BUY)\nAction: Lock SL to Previous TP Level\nNew SL: %.5f | Cycle: %d",
                                                  sym, tkt, norm_prev_tp, g_tracking_list[i].trail_cycle);
                        if(InpEnableSoundAlerts) Alert(msg);
                        if(InpEnablePushAlerts)  SendNotification(msg);
                     }
                  }
               }
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               double dist_to_new_tp = MathAbs(cur_tp - ask) / ewma_tr;
               if(dist_to_new_tp <= max_dist_allowed)
               {
                  double norm_prev_tp = NormalizeDouble(prev_tp, digits);
                  if(cur_sl == 0 || norm_prev_tp < cur_sl)
                  {
                     if(m_trade.PositionModify(tkt, norm_prev_tp, cur_tp))
                     {
                        string msg = StringFormat("[TRAIL SL LOCK] %s #%d (SELL)\nAction: Lock SL to Previous TP Level\nNew SL: %.5f | Cycle: %d",
                                                  sym, tkt, norm_prev_tp, g_tracking_list[i].trail_cycle);
                        if(InpEnableSoundAlerts) Alert(msg);
                        if(InpEnablePushAlerts)  SendNotification(msg);
                     }
                  }
               }
            }
         }
      }
   }
}

void ActivateBulkAutoTrail(double max_dist, double relvol_th, double be_rem_pct, double ext_rem_pct, ENUM_TIMEFRAMES tf)
{
   int activated = 0;
   int skipped_autotrader = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         if(m_position.SelectByTicket(tkt))
         {
            ulong p_magic = m_position.Magic();
            if(p_magic == InpAutoTraderMagic)
            {
               skipped_autotrader++;
               continue; // Lindungi order milik AutoTrader
            }
            
            string sym    = m_position.Symbol();
            double open_p = m_position.PriceOpen();
            double tp_p   = m_position.TakeProfit();
            
            if(tp_p <= 0) continue; // Butuh target TP awal
            
            double atr100 = CalculateATR100(sym, AtrBaseTF(tf), InpDefaultATRPeriod);
            RegisterPositionTracking(tkt, sym, tf, atr100, open_p, tp_p, max_dist, relvol_th, be_rem_pct, ext_rem_pct);
            activated++;
         }
      }
   }
   
   string note = StringFormat("Auto Trail diaktifkan untuk %d posisi terpilih.", activated);
   if(skipped_autotrader > 0)
      note += StringFormat("\n(%d posisi dilewati karena sudah dikawal oleh AutoTrader)", skipped_autotrader);
   Alert(note);
   Print(note);
}

void DeactivateBulkAutoTrail()
{
   int count = 0;
   for(int i = 0; i < ArraySize(g_tracking_list); i++)
   {
      if(IsOrderSelected(g_tracking_list[i].ticket) && g_tracking_list[i].active)
      {
         g_tracking_list[i].active = false;
         count++;
      }
   }
   string note = StringFormat("Auto Trail dinonaktifkan untuk %d posisi terpilih.", count);
   Alert(note);
   Print(note);
}
//+------------------------------------------------------------------+
bool IsStrongBullishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                   double &out_atr_50, double &out_broken_range, double &out_cur_price,
                                   double &out_broken_high, double &out_broken_low)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   // rates[0] = Current active live forming candle
   // rates[1] = Previous candle (the candle being engulfed & broken)
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close; // live realtime tick price
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price    = cur_close;
   out_broken_high  = prev_high;
   out_broken_low   = prev_low;
   out_broken_range = prev_high - prev_low;
   
   // 1. Previous candle must be Bearish
   bool prev_is_bearish = (prev_close < prev_open);
   if(!prev_is_bearish) return false;
   
   // 2. Realtime Breakout & Strong Engulfing Condition:
   // - Live running candle is Bullish
   // - Realtime high/tick breaks above previous candle's High
   // - Low engulfs/covers previous candle's Low
   // - Current body is strictly stronger than previous candle's body
   bool is_bullish_running = (cur_close > cur_open);
   bool is_breaking_high   = (cur_close >= prev_high || cur_high >= prev_high);
   bool is_covering_low    = (cur_low <= prev_low);
   bool is_stronger_body   = ((cur_close - cur_open) > (prev_open - prev_close) * InpBodyRatioMultiplier);
   
   if(is_bullish_running && is_breaking_high && is_covering_low && is_stronger_body)
   {
      out_atr_50 = CalculateATR50(sym, AtrBaseTF(tf), InpDefaultATRPeriod);
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| REALTIME TICK-LEVEL STRONG BEARISH ENGULFING BREAK               |
//+------------------------------------------------------------------+
bool IsStrongBearishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                   double &out_atr_50, double &out_broken_range, double &out_cur_price,
                                   double &out_broken_high, double &out_broken_low)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, 3, rates) < 3) return false;
   
   // rates[0] = Current active live forming candle
   // rates[1] = Previous candle (the candle being engulfed & broken)
   
   double cur_open  = rates[0].open;
   double cur_close = rates[0].close; // live realtime tick price
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price    = cur_close;
   out_broken_high  = prev_high;
   out_broken_low   = prev_low;
   out_broken_range = prev_high - prev_low;
   
   // 1. Previous candle must be Bullish
   bool prev_is_bullish = (prev_close > prev_open);
   if(!prev_is_bullish) return false;
   
   // 2. Realtime Breakout & Strong Engulfing Condition:
   // - Live running candle is Bearish
   // - Realtime low/tick breaks below previous candle's Low
   // - High engulfs/covers previous candle's High
   // - Current body is strictly stronger than previous candle's body
   bool is_bearish_running = (cur_close < cur_open);
   bool is_breaking_low    = (cur_close <= prev_low || cur_low <= prev_low);
   bool is_covering_high   = (cur_high >= prev_high);
   bool is_stronger_body   = ((cur_open - cur_close) > (prev_close - prev_open) * InpBodyRatioMultiplier);
   
   if(is_bearish_running && is_breaking_low && is_covering_high && is_stronger_body)
   {
      out_atr_50 = CalculateATR50(sym, AtrBaseTF(tf), InpDefaultATRPeriod);
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG HAMMER REVERSAL DETECTION (BUY ONLY)             |
//+------------------------------------------------------------------+
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
   
   // Syarat 3: Low candle hammer harus lebih rendah dari low candle sebelumnya (sweep low)
   if(cur_low >= prev_low) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG SHOOTING STAR REVERSAL DETECTION (SELL ONLY)     |
//+------------------------------------------------------------------+
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
   
   // Syarat 3: High candle shooting star harus lebih tinggi dari high candle sebelumnya (sweep high)
   if(cur_high <= prev_high) return false;
   
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
   
   double k_val[];
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
   
   ha_close[0] = (raw_rates[0].open + raw_rates[0].high + raw_rates[0].low + raw_rates[0].close) / 4.0;
   ha_open[0]  = (raw_rates[0].open + raw_rates[0].close) / 2.0;
   ha_high[0]  = raw_rates[0].high;
   ha_low[0]   = raw_rates[0].low;
   
   for(int b = 1; b < n; b++)
   {
      ha_close[b] = (raw_rates[b].open + raw_rates[b].high + raw_rates[b].low + raw_rates[b].close) / 4.0;
      ha_open[b]  = (ha_open[b-1] + ha_close[b-1]) / 2.0;
      ha_high[b]  = MathMax(raw_rates[b].high, MathMax(ha_open[b], ha_close[b]));
      ha_low[b]   = MathMin(raw_rates[b].low,  MathMin(ha_open[b], ha_close[b]));
   }
   
   int cur_idx = n - 1 - shift;
   if(cur_idx < 1) return false;
   int prev_idx = cur_idx - 1;
   
   double cur_ha_size  = ha_high[cur_idx] - ha_low[cur_idx];
   double prev_ha_size = ha_high[prev_idx] - ha_low[prev_idx];
   bool cur_ha_green   = (ha_close[cur_idx] > ha_open[cur_idx]);
   bool cur_ha_red     = (ha_close[cur_idx] < ha_open[cur_idx]);
   
   if(check_buy)
   {
      bool stoch_buy = (cur_k < InpStochOS && cur_k > prev_k);
      bool ha_buy    = (cur_ha_size < prev_ha_size || cur_ha_green);
      if(!stoch_buy || !ha_buy) return false;
      
      // Syarat tambahan MTF: jika sinyal di M5 ke atas, M1 juga wajib oversold
      if(tf >= PERIOD_M5)
      {
         int m1_handle = iStochastic(sym, PERIOD_M1, InpStochLength, InpStochD, InpStochK, MODE_SMA, STO_LOWHIGH);
         if(m1_handle != INVALID_HANDLE)
         {
            double m1_k[];
            ArraySetAsSeries(m1_k, true);
            if(CopyBuffer(m1_handle, 0, shift, 1, m1_k) >= 1)
            {
               double k_m1 = m1_k[0];
               IndicatorRelease(m1_handle);
               if(k_m1 >= InpStochOS) return false; // M1 wajib oversold (< InpStochOS)
            }
            else
            {
               IndicatorRelease(m1_handle);
               return false;
            }
         }
      }
      return true;
   }
   else
   {
      bool stoch_sell = (cur_k > InpStochOB && cur_k < prev_k);
      bool ha_sell    = (cur_ha_size < prev_ha_size || cur_ha_red);
      if(!stoch_sell || !ha_sell) return false;
      
      // Syarat tambahan MTF: jika sinyal di M5 ke atas, M1 juga wajib overbought
      if(tf >= PERIOD_M5)
      {
         int m1_handle = iStochastic(sym, PERIOD_M1, InpStochLength, InpStochD, InpStochK, MODE_SMA, STO_LOWHIGH);
         if(m1_handle != INVALID_HANDLE)
         {
            double m1_k[];
            ArraySetAsSeries(m1_k, true);
            if(CopyBuffer(m1_handle, 0, shift, 1, m1_k) >= 1)
            {
               double k_m1 = m1_k[0];
               IndicatorRelease(m1_handle);
               if(k_m1 <= InpStochOB) return false; // M1 wajib overbought (> InpStochOB)
            }
            else
            {
               IndicatorRelease(m1_handle);
               return false;
            }
         }
      }
      return true;
   }
}

//+------------------------------------------------------------------+
//| REALTIME AUTO BREAK-EVEN (BE) EXECUTION ENGINE                   |
//+------------------------------------------------------------------+
void CheckAutoBETriggers()
{
   int total_be = ArraySize(g_auto_be_list);
   if(total_be == 0) return;
   
   for(int i = total_be - 1; i >= 0; i--)
   {
      if(!g_auto_be_list[i].active) continue;
      
      ulong ticket = g_auto_be_list[i].ticket;
      string sym   = g_auto_be_list[i].symbol;
      
      if(!m_symbol_info.Name(sym)) continue;
      m_symbol_info.RefreshRates();
      
      double bid = m_symbol_info.Bid();
      double ask = m_symbol_info.Ask();
      double spread = (ask - bid);
      double point  = m_symbol_info.Point();
      
      if(g_auto_be_list[i].is_position)
      {
         if(m_position.SelectByTicket(ticket))
         {
            ENUM_POSITION_TYPE ptype = m_position.PositionType();
            double open_price = m_position.PriceOpen();
            double cur_sl     = m_position.StopLoss();
            double cur_tp     = m_position.TakeProfit();
            double trig_price = g_auto_be_list[i].trigger_price;
            
            // BUY POSITION
            if(ptype == POSITION_TYPE_BUY)
            {
               // Trigger reached when Bid >= Trigger Price
               if(bid >= trig_price)
               {
                  double new_sl = open_price;
                  if(g_auto_be_list[i].offset_mode == BE_OFFSET_AUTO_SPREAD)
                     new_sl = open_price + spread;
                  else if(g_auto_be_list[i].offset_mode == BE_OFFSET_CUSTOM_POINTS)
                     new_sl = open_price + (g_auto_be_list[i].custom_points * point);
                  else if(g_auto_be_list[i].offset_mode == BE_OFFSET_CUSTOM_PRICE)
                     new_sl = g_auto_be_list[i].fixed_price;
                     
                  int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
                  new_sl = NormalizeDouble(new_sl, digits);
                  
                  if(new_sl > cur_sl)
                  {
                     m_trade.SetExpertMagicNumber(m_position.Magic());
                     if(m_trade.PositionModify(ticket, new_sl, cur_tp))
                     {
                        PrintFormat("Auto-BE executed for BUY Position #%d at SL: %.5f", ticket, new_sl);
                        g_auto_be_list[i].active = false; // Executed
                     }
                     else
                     {
                        PrintFormat("Auto-BE failed for BUY Position #%d. Retcode: %d, Err: %d", ticket, m_trade.ResultRetcode(), GetLastError());
                     }
                  }
                  else g_auto_be_list[i].active = false;
               }
            }
            // SELL POSITION
            else if(ptype == POSITION_TYPE_SELL)
            {
               // Trigger reached when Ask <= Trigger Price
               if(ask <= trig_price)
               {
                  double new_sl = open_price;
                  if(g_auto_be_list[i].offset_mode == BE_OFFSET_AUTO_SPREAD)
                     new_sl = open_price - spread;
                  else if(g_auto_be_list[i].offset_mode == BE_OFFSET_CUSTOM_POINTS)
                     new_sl = open_price - (g_auto_be_list[i].custom_points * point);
                  else if(g_auto_be_list[i].offset_mode == BE_OFFSET_CUSTOM_PRICE)
                     new_sl = g_auto_be_list[i].fixed_price;
                     
                  int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
                  new_sl = NormalizeDouble(new_sl, digits);
                  
                  if(cur_sl == 0 || new_sl < cur_sl)
                  {
                     m_trade.SetExpertMagicNumber(m_position.Magic());
                     if(m_trade.PositionModify(ticket, new_sl, cur_tp))
                     {
                        PrintFormat("Auto-BE executed for SELL Position #%d at SL: %.5f", ticket, new_sl);
                        g_auto_be_list[i].active = false; // Executed
                     }
                     else
                     {
                        PrintFormat("Auto-BE failed for SELL Position #%d. Retcode: %d, Err: %d", ticket, m_trade.ResultRetcode(), GetLastError());
                     }
                  }
                  else g_auto_be_list[i].active = false;
               }
            }
         }
         else
         {
            // Position closed, remove from BE list
            g_auto_be_list[i].active = false;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| BULK ORDER MODIFICATIONS                                         |
//+------------------------------------------------------------------+
void ApplyBulkSL(double sl_price)
{
   int modified_count = 0;
   
   // 1. Modify selected Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double norm_sl = NormalizeDouble(sl_price, digits);
         
         if(m_position.SelectByTicket(tkt))
         {
            double cur_tp = m_position.TakeProfit();
            m_trade.SetExpertMagicNumber(PositionGetInteger(POSITION_MAGIC));
            if(m_trade.PositionModify(tkt, norm_sl, cur_tp))
            {
               modified_count++;
            }
            else
            {
               PrintFormat("Failed to modify SL for Position #%d. Retcode: %d, Err: %d", tkt, m_trade.ResultRetcode(), GetLastError());
            }
         }
      }
   }
   
   // 2. Modify selected Pending Orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tkt = OrderGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         string sym = OrderGetString(ORDER_SYMBOL);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double norm_sl = NormalizeDouble(sl_price, digits);
         
         if(m_order.Select(tkt))
         {
            double cur_price = m_order.PriceOpen();
            double cur_tp    = m_order.TakeProfit();
            ENUM_ORDER_TYPE_TIME type_time = m_order.TypeTime();
            datetime expiration = m_order.TimeExpiration();
            
            m_trade.SetExpertMagicNumber(OrderGetInteger(ORDER_MAGIC));
            if(m_trade.OrderModify(tkt, cur_price, norm_sl, cur_tp, type_time, expiration))
            {
               modified_count++;
            }
            else
            {
               PrintFormat("Failed to modify SL for Order #%d. Retcode: %d, Err: %d", tkt, m_trade.ResultRetcode(), GetLastError());
            }
         }
      }
   }
   
   PrintFormat("Bulk SL (%.5f) applied to %d orders/positions.", sl_price, modified_count);
}

void ApplyBulkTP(double tp_price)
{
   int modified_count = 0;
   
   // 1. Modify selected Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double norm_tp = NormalizeDouble(tp_price, digits);
         
         if(m_position.SelectByTicket(tkt))
         {
            double cur_sl = m_position.StopLoss();
            m_trade.SetExpertMagicNumber(PositionGetInteger(POSITION_MAGIC));
            if(m_trade.PositionModify(tkt, cur_sl, norm_tp))
            {
               modified_count++;
            }
            else
            {
               PrintFormat("Failed to modify TP for Position #%d. Retcode: %d, Err: %d", tkt, m_trade.ResultRetcode(), GetLastError());
            }
         }
      }
   }
   
   // 2. Modify selected Pending Orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tkt = OrderGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         string sym = OrderGetString(ORDER_SYMBOL);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double norm_tp = NormalizeDouble(tp_price, digits);
         
         if(m_order.Select(tkt))
         {
            double cur_price = m_order.PriceOpen();
            double cur_sl    = m_order.StopLoss();
            ENUM_ORDER_TYPE_TIME type_time = m_order.TypeTime();
            datetime expiration = m_order.TimeExpiration();
            
            m_trade.SetExpertMagicNumber(OrderGetInteger(ORDER_MAGIC));
            if(m_trade.OrderModify(tkt, cur_price, cur_sl, norm_tp, type_time, expiration))
            {
               modified_count++;
            }
            else
            {
               PrintFormat("Failed to modify TP for Order #%d. Retcode: %d, Err: %d", tkt, m_trade.ResultRetcode(), GetLastError());
            }
         }
      }
   }
   
   PrintFormat("Bulk TP (%.5f) applied to %d orders/positions.", tp_price, modified_count);
}

void ApplyInstantBESpread()
{
   int modified_count = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         if(m_position.SelectByTicket(tkt))
         {
            string sym = m_position.Symbol();
            ENUM_POSITION_TYPE ptype = m_position.PositionType();
            double open_price = m_position.PriceOpen();
            double cur_tp     = m_position.TakeProfit();
            
            if(!m_symbol_info.Name(sym)) continue;
            m_symbol_info.RefreshRates();
            
            double spread = m_symbol_info.Ask() - m_symbol_info.Bid();
            double new_sl = open_price;
            
            if(ptype == POSITION_TYPE_BUY)
               new_sl = open_price + spread;
            else if(ptype == POSITION_TYPE_SELL)
               new_sl = open_price - spread;
               
            int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            new_sl = NormalizeDouble(new_sl, digits);
            
            if(m_trade.PositionModify(tkt, new_sl, cur_tp))
               modified_count++;
         }
      }
   }
   
   PrintFormat("Instant BE (+/- Spread) applied to %d positions.", modified_count);
}

void ActivateBulkAutoBE(double trigger_price, ENUM_BE_OFFSET_MODE mode, int custom_pts)
{
   double fixed_px = 0.0;
   if(mode == BE_OFFSET_CUSTOM_PRICE)
   {
      fixed_px = StringToDouble(ObjectGetString(0, g_prefix + "INP_BE_PRICE", OBJPROP_TEXT));
      if(fixed_px <= 0)
      {
         Alert("Mode FIXED PRICE aktif: isi dulu kolom SL TARGET PRICE!");
         return;
      }
   }

   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && IsOrderSelected(tkt))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         // Update or add to Auto-BE list
         bool exists = false;
         for(int j = 0; j < ArraySize(g_auto_be_list); j++)
         {
            if(g_auto_be_list[j].ticket == tkt)
            {
               g_auto_be_list[j].trigger_price = trigger_price;
               g_auto_be_list[j].offset_mode   = mode;
               g_auto_be_list[j].custom_points = custom_pts;
               g_auto_be_list[j].fixed_price   = fixed_px;
               g_auto_be_list[j].active        = true;
               exists = true;
               break;
            }
         }
         
         if(!exists)
         {
            int size = ArraySize(g_auto_be_list);
            ArrayResize(g_auto_be_list, size + 1);
            g_auto_be_list[size].ticket        = tkt;
            g_auto_be_list[size].is_position   = true;
            g_auto_be_list[size].symbol        = sym;
            g_auto_be_list[size].pos_type      = ptype;
            g_auto_be_list[size].trigger_price = trigger_price;
            g_auto_be_list[size].offset_mode   = mode;
            g_auto_be_list[size].custom_points = custom_pts;
            g_auto_be_list[size].fixed_price   = fixed_px;
            g_auto_be_list[size].active        = true;
         }
         count++;
      }
   }
   PrintFormat("Auto-BE activated for %d positions at trigger price %.5f", count, trigger_price);
}

void DeactivateBulkAutoBE()
{
   int count = 0;
   for(int i = 0; i < ArraySize(g_auto_be_list); i++)
   {
      if(IsOrderSelected(g_auto_be_list[i].ticket))
      {
         g_auto_be_list[i].active = false;
         count++;
      }
   }
   PrintFormat("Auto-BE deactivated for %d selected orders.", count);
}

//+------------------------------------------------------------------+
//| WATCHLIST & ORDER SELECTION HELPERS                              |
//+------------------------------------------------------------------+
void AddRadarSymbol(string sym, ENUM_TIMEFRAMES tf, bool bull_on, string bull_filter, bool bear_on, string bear_filter, int atr_p, bool tf_close, int delay_pct, bool active_on, bool sig_eng, bool sig_hmr, bool sig_stoch, ENUM_SIGNAL_MODE sig_mode)
{
   int size = ArraySize(g_radar_symbols);
   ArrayResize(g_radar_symbols, size + 1);
   g_radar_symbols[size].symbol              = sym;
   g_radar_symbols[size].timeframe           = tf;
   g_radar_symbols[size].bull_enabled        = bull_on;
   g_radar_symbols[size].bull_price_filter   = bull_filter;
   g_radar_symbols[size].bear_enabled        = bear_on;
   g_radar_symbols[size].bear_price_filter   = bear_filter;
   g_radar_symbols[size].atr_period          = atr_p;
   g_radar_symbols[size].last_bull_alert_bar = 0;
   g_radar_symbols[size].last_bear_alert_bar = 0;
   g_radar_symbols[size].delay_is_tf_close   = tf_close;
   g_radar_symbols[size].delay_tf_pct        = delay_pct;
   g_radar_symbols[size].active              = active_on;
   g_radar_symbols[size].sig_engulfing       = sig_eng;
   g_radar_symbols[size].sig_hammer_ss       = sig_hmr;
   g_radar_symbols[size].sig_stoch_ha        = sig_stoch;
   g_radar_symbols[size].signal_mode         = sig_mode;
   g_radar_symbols[size].bull_cond_start_time_main = 0;
   g_radar_symbols[size].bull_cond_start_time_fallback = 0;
   g_radar_symbols[size].bear_cond_start_time_main = 0;
   g_radar_symbols[size].bear_cond_start_time_fallback = 0;
}

void UpdateRadarSymbol(int index, string sym, ENUM_TIMEFRAMES tf, bool bull_on, string bull_filter, bool bear_on, string bear_filter, int atr_p, bool tf_close, int delay_pct, bool sig_eng, bool sig_hmr, bool sig_stoch, ENUM_SIGNAL_MODE sig_mode)
{
   if(index < 0 || index >= ArraySize(g_radar_symbols)) return;
   g_radar_symbols[index].symbol            = sym;
   g_radar_symbols[index].timeframe         = tf;
   g_radar_symbols[index].bull_enabled      = bull_on;
   g_radar_symbols[index].bull_price_filter = bull_filter;
   g_radar_symbols[index].bear_enabled      = bear_on;
   g_radar_symbols[index].bear_price_filter = bear_filter;
   g_radar_symbols[index].atr_period        = atr_p;
   g_radar_symbols[index].delay_is_tf_close = tf_close;
   g_radar_symbols[index].delay_tf_pct      = delay_pct;
   g_radar_symbols[index].sig_engulfing     = sig_eng;
   g_radar_symbols[index].sig_hammer_ss     = sig_hmr;
   g_radar_symbols[index].sig_stoch_ha      = sig_stoch;
   g_radar_symbols[index].signal_mode       = sig_mode;
}

void RemoveRadarSymbol(int index)
{
   int size = ArraySize(g_radar_symbols);
   if(index < 0 || index >= size) return;
   
   for(int i = index; i < size - 1; i++)
   {
      g_radar_symbols[i] = g_radar_symbols[i + 1];
   }
   ArrayResize(g_radar_symbols, size - 1);
}

bool IsOrderSelected(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_selected_orders); i++)
   {
      if(g_selected_orders[i].ticket == ticket)
         return g_selected_orders[i].selected;
   }
   return true; // Default selected
}

void SetOrderSelected(ulong ticket, bool sel)
{
   for(int i = 0; i < ArraySize(g_selected_orders); i++)
   {
      if(g_selected_orders[i].ticket == ticket)
      {
         g_selected_orders[i].selected = sel;
         return;
      }
   }
   int size = ArraySize(g_selected_orders);
   ArrayResize(g_selected_orders, size + 1);
   g_selected_orders[size].ticket   = ticket;
   g_selected_orders[size].selected = sel;
}

void SelectAllOrders(bool sel)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      SetOrderSelected(tkt, sel);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tkt = OrderGetTicket(i);
      SetOrderSelected(tkt, sel);
   }
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

void CreateLabel(string name, int x, int y, string text, color clr, int font_size = 9, bool bold = false)
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
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
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
   int win_h  = 660;
   
   // Outer Pitch-black window
   CreateRect("WIN_BG", root_x, root_y, win_w, win_h, CLR_PANEL_BG, CLR_BORDER_HARD);
   
   // Top header
   CreateRect("WIN_TOP", root_x, root_y, win_w, 40, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("WIN_TITLE", root_x + 16, root_y + 11, "TRADE MANAGER & REVERSAL RADAR", CLR_TEXT_PURE, 10, true);
   CreateLabel("WIN_TAG", root_x + 360, root_y + 12, "[MQL5 MULTI-SIGNAL REALTIME]", CLR_CYAN_NEON, 8, true);
   
   // Navigation Tabs
   int tab_y = root_y + 48;
   color tab1_bg = (g_active_tab == 1) ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG;
   color tab1_txt = (g_active_tab == 1) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   color tab2_bg = (g_active_tab == 2) ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG;
   color tab2_txt = (g_active_tab == 2) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   
   CreateButton("TAB_ORDERS", root_x + 16, tab_y, 180, 26, "ORDER MANAGER", tab1_bg, tab1_txt, CLR_BORDER_HARD);
   CreateButton("TAB_RADAR",  root_x + 204, tab_y, 180, 26, "REVERSAL RADAR", tab2_bg, tab2_txt, CLR_BORDER_HARD);
   
   if(g_active_tab == 1)
   {
      // ================= TAB 1: ORDER MANAGER =================
      int table_y = tab_y + 36;
      CreateRect("CARD_ORDERS", root_x + 16, table_y, win_w - 32, 260, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("TITLE_ORDERS", root_x + 28, table_y + 10, "ACTIVE POSITIONS & PENDING ORDERS", CLR_CYAN_NEON, 9, true);
      
      CreateButton("BTN_SEL_ALL", root_x + win_w - 210, table_y + 8, 85, 20, "SELECT ALL", CLR_PANEL_BG, CLR_TEXT_PURE, CLR_BORDER_HARD);
      CreateButton("BTN_SEL_NONE", root_x + win_w - 118, table_y + 8, 85, 20, "CLEAR", CLR_PANEL_BG, CLR_TEXT_PURE, CLR_BORDER_HARD);
      
      // Table Header Row (Well-spaced layout to prevent overlap)
      int th_y = table_y + 34;
      CreateRect("TH_ROW", root_x + 26, th_y, win_w - 52, 22, CLR_ROW_ALT, CLR_BORDER_SOFT);
      CreateLabel("TH_SEL", root_x + 34, th_y + 4, "SEL", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_TKT", root_x + 72, th_y + 4, "TICKET", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_SYM", root_x + 155, th_y + 4, "SYMBOL", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_TYP", root_x + 235, th_y + 4, "TYPE", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_VOL", root_x + 355, th_y + 4, "LOTS", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_OPN", root_x + 430, th_y + 4, "OPEN", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_SL",  root_x + 515, th_y + 4, "SL", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_TP",  root_x + 600, th_y + 4, "TP", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_BE",  root_x + 695, th_y + 4, "AUTO-BE", CLR_TEXT_MED, 8, true);
      CreateLabel("TH_TR",  root_x + 810, th_y + 4, "AUTO TRAIL", CLR_TEXT_MED, 8, true);
      
      // Action Deck (Left: SL/TP & BE, Right: Auto Trail Engine)
      int deck_y = table_y + 270;
      int gap    = 16;
      int box_w  = (win_w - 32 - gap) / 2; // (960 - 32 - 16)/2 = 456
      
      // Box A: Bulk SL/TP & Break-Even
      CreateRect("CARD_SLTP_BE", root_x + 16, deck_y, box_w, 245, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("LBL_SLTP", root_x + 28, deck_y + 10, "PRICE MODIFIER & BREAK-EVEN", CLR_CYAN_NEON, 9, true);
      
      // SL / TP Rows
      CreateLabel("LBL_INP_SL", root_x + 28, deck_y + 36, "STOP LOSS:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_SL", root_x + 120, deck_y + 32, 170, 22, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateButton("BTN_APPLY_SL", root_x + 300, deck_y + 32, 130, 22, "SET SL", C'18,8,34', CLR_BEAR_NEON, CLR_BEAR_NEON);
      
      CreateLabel("LBL_INP_TP", root_x + 28, deck_y + 64, "TAKE PROFIT:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_TP", root_x + 120, deck_y + 60, 170, 22, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateButton("BTN_APPLY_TP", root_x + 300, deck_y + 60, 130, 22, "SET TP", C'8,34,18', CLR_BULL_NEON, CLR_BULL_NEON);
      
      // BE Trigger
      CreateLabel("LBL_INP_BE", root_x + 28, deck_y + 94, "BE TRIGGER:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_BE_TRIG", root_x + 120, deck_y + 90, 170, 22, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateButton("BTN_INSTANT_BE", root_x + 300, deck_y + 90, 130, 22, "SET BE SPREAD", C'26,42,65', CLR_GOLD_NEON, CLR_GOLD_NEON);
      
      CreateLabel("LBL_BE_MODE", root_x + 28, deck_y + 122, "OFFSET MODE:", CLR_TEXT_MED, 8, true);
      string mode_str = "AUTO SPREAD (+/- Spread)";
      color mode_clr = CLR_CYAN_NEON;
      if(g_be_offset_mode == BE_OFFSET_ZERO)
      {
         mode_str = "EXACT OPEN (+0 pts)";
         mode_clr = CLR_TEXT_PURE;
      }
      else if(g_be_offset_mode == BE_OFFSET_CUSTOM_POINTS)
      {
         mode_str = "CUSTOM LOCK (+10 pts)";
         mode_clr = CLR_GOLD_NEON;
      }
      else if(g_be_offset_mode == BE_OFFSET_CUSTOM_PRICE)
      {
         mode_str = "FIXED SL PRICE (> 0)";
         mode_clr = CLR_BULL_NEON;
      }
      CreateButton("BTN_BE_MODE", root_x + 120, deck_y + 118, 310, 22, mode_str, CLR_CANVAS_BG, mode_clr, CLR_BORDER_HARD);

      CreateLabel("LBL_BE_PRICE", root_x + 28, deck_y + 150, "SL TARGET PX:", CLR_TEXT_PURE, 8, true);
      string px_default = (g_be_fixed_price > 0) ? DoubleToString(g_be_fixed_price, _Digits) : "";
      CreateEdit("INP_BE_PRICE", root_x + 120, deck_y + 146, 310, 22, px_default,
                 CLR_CANVAS_BG, g_be_offset_mode == BE_OFFSET_CUSTOM_PRICE ? CLR_BULL_NEON : CLR_TEXT_MED);

      CreateButton("BTN_APPLY_BE", root_x + 28, deck_y + 184, 250, 26, "ACTIVATE BE TRIGGER", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
      CreateButton("BTN_CANCEL_BE", root_x + 288, deck_y + 184, 142, 26, "DEACTIVATE", CLR_PANEL_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
      
      // Box B: Auto Trail Engine (EWMA TR)
      int box_b_x = root_x + 16 + box_w + gap;
      CreateRect("CARD_TRAIL", box_b_x, deck_y, box_w, 245, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("LBL_TRAIL_TITLE", box_b_x + 12, deck_y + 10, "AUTO TRAIL ENGINE (EWMA TR)", CLR_CYAN_NEON, 9, true);
      
      CreateLabel("LBL_TR_TF", box_b_x + 12, deck_y + 34, "BASE TF (MIN):", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_TRAIL_TF", box_b_x + 140, deck_y + 30, 100, 22, g_form_trail_tf, CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateLabel("LBL_TR_TF_HINT", box_b_x + 250, deck_y + 34, "(1, 5, 15, 60m...)", CLR_TEXT_MED, 7, false);
      
      CreateLabel("LBL_TR_DIST", box_b_x + 12, deck_y + 60, "MAX DIST TR:", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_TRAIL_DIST", box_b_x + 140, deck_y + 56, 100, 22, DoubleToString(g_form_trail_max_dist, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateLabel("LBL_TR_DIST_HINT", box_b_x + 250, deck_y + 60, "Proximity ke TP (1.10x)", CLR_TEXT_MED, 7, false);
      
      CreateLabel("LBL_TR_MULT", box_b_x + 12, deck_y + 86, "RELVOL THRESH:", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_TRAIL_MULT", box_b_x + 140, deck_y + 82, 100, 22, DoubleToString(g_form_trail_atr_mult, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateLabel("LBL_TR_MULT_HINT", box_b_x + 250, deck_y + 86, "Lonjakan vol (>=1.60x)", CLR_TEXT_MED, 7, false);
      
      CreateLabel("LBL_TR_BE", box_b_x + 12, deck_y + 112, "BE DIST %:", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_TRAIL_BE", box_b_x + 140, deck_y + 108, 100, 22, DoubleToString(g_form_trail_be_rem_pct, 0), CLR_CANVAS_BG, CLR_GOLD_NEON);
      CreateLabel("LBL_TR_BE_HINT", box_b_x + 250, deck_y + 112, "Sisa target lock BE (20%)", CLR_TEXT_MED, 7, false);
      
      CreateLabel("LBL_TR_EXT", box_b_x + 12, deck_y + 138, "EXT DIST %:", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_TRAIL_EXT", box_b_x + 140, deck_y + 134, 100, 22, DoubleToString(g_form_trail_ext_rem_pct, 0), CLR_CANVAS_BG, CLR_GOLD_NEON);
      CreateLabel("LBL_TR_EXT_HINT", box_b_x + 250, deck_y + 138, "Sisa target extend TP (20%)", CLR_TEXT_MED, 7, false);

      CreateLabel("LBL_TR_INFO", box_b_x + 12, deck_y + 166, "*Posisi AutoTrader ([AT TRAIL]) dilindungi otomatis agar tidak konflik.", CLR_CYAN_NEON, 7, false);
      
      CreateButton("BTN_APPLY_TRAIL", box_b_x + 12, deck_y + 196, 250, 26, "ACTIVATE AUTO TRAIL", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
      CreateButton("BTN_CANCEL_TRAIL", box_b_x + 270, deck_y + 196, 160, 26, "STOP TRAIL", CLR_PANEL_BG, CLR_BEAR_NEON, CLR_BORDER_HARD);
   }
   else if(g_active_tab == 2)
   {
      // ================= TAB 2: REVERSAL RADAR =================
      int radar_y = tab_y + 36;
      CreateRect("CARD_RADAR_LIST", root_x + 16, radar_y, win_w - 32, 240, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("TITLE_RADAR_LIST", root_x + 28, radar_y + 10, "ACTIVE MULTI-SYMBOL WATCHLIST", CLR_CYAN_NEON, 9, true);
      CreateLabel("RADAR_STATUS", root_x + win_w - 230, radar_y + 10, "* REALTIME MULTI-SIGNAL ACTIVE", CLR_BULL_NEON, 8, true);
      
      // Add Form Deck (Height expanded to 280 for signals & delay)
      int add_deck_y = radar_y + 250;
      int box_w = (win_w - 42) / 2;
      
      // Box Left: Add / Edit Watchlist Symbol Form
      CreateRect("CARD_ADD_RADAR", root_x + 16, add_deck_y, box_w, 280, CLR_CARD_BG, CLR_BORDER_HARD);
      
      bool is_edit = (g_editing_radar_idx >= 0 && g_editing_radar_idx < ArraySize(g_radar_symbols));
      string form_title = is_edit ? "EDIT SELECTED RADAR" : "ADD SYMBOL TO RADAR";
      CreateLabel("LBL_ADD_RADAR", root_x + 28, add_deck_y + 10, form_title, is_edit ? CLR_GOLD_NEON : CLR_CYAN_NEON, 9, true);
      
      string default_sym = g_form_sym;
      string default_tf  = g_form_tf;
      string default_bull = g_form_bull;
      string default_bear = g_form_bear;
      
      // Row 1: Symbol & TF
      CreateLabel("LBL_F_SYM", root_x + 28, add_deck_y + 36, "SYMBOL:", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_NEW_SYM", root_x + 105, add_deck_y + 32, 130, 22, default_sym, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      CreateLabel("LBL_F_TF", root_x + 248, add_deck_y + 36, "TF (MIN):", CLR_TEXT_MED, 8, true);
      CreateEdit("INP_NEW_TF", root_x + 312, add_deck_y + 32, 65, 22, default_tf, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      // Row 2: Signals Checkboxes
      CreateLabel("LBL_F_SIGS", root_x + 28, add_deck_y + 64, "SIGNALS:", CLR_TEXT_PURE, 8, true);
      
      color eng_bg = g_form_sig_eng ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
      color eng_cl = g_form_sig_eng ? CLR_CYAN_NEON : CLR_TEXT_MED;
      CreateButton("BTN_RADAR_SIG_ENG", root_x + 105, add_deck_y + 60, 85, 22, g_form_sig_eng ? "[X] ENGULF" : "[ ] ENGULF", eng_bg, eng_cl, eng_cl);
      
      color hmr_bg = g_form_sig_hmr ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
      color hmr_cl = g_form_sig_hmr ? CLR_GOLD_NEON : CLR_TEXT_MED;
      CreateButton("BTN_RADAR_SIG_HMR", root_x + 195, add_deck_y + 60, 85, 22, g_form_sig_hmr ? "[X] HMR/SS" : "[ ] HMR/SS", hmr_bg, hmr_cl, hmr_cl);
      
      color stoch_bg = g_form_sig_stoch ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
      color stoch_cl = g_form_sig_stoch ? CLR_BULL_NEON : CLR_TEXT_MED;
      CreateButton("BTN_RADAR_SIG_STOCH", root_x + 285, add_deck_y + 60, 92, 22, g_form_sig_stoch ? "[X] STOCH+HA" : "[ ] STOCH+HA", stoch_bg, stoch_cl, stoch_cl);
      
      // Row 3: Signal Mode Toggle (ANY vs COMBO)
      CreateLabel("LBL_F_SMODE", root_x + 28, add_deck_y + 92, "SIG MODE:", CLR_TEXT_MED, 8, true);
      string sm_txt = (g_form_sig_mode == SIGNAL_MODE_ANY) ? "MODE: ANY (OR)" : "MODE: COMBO (AND)";
      color  sm_bg  = (g_form_sig_mode == SIGNAL_MODE_COMBO) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
      color  sm_cl  = (g_form_sig_mode == SIGNAL_MODE_COMBO) ? CLR_GOLD_NEON : CLR_CYAN_NEON;
      CreateButton("BTN_RADAR_SIG_MODE", root_x + 105, add_deck_y + 88, 272, 22, sm_txt, sm_bg, sm_cl, sm_cl);
      
      // Row 4: Delay Mode (% TF Progress vs TF Close)
      CreateLabel("LBL_F_MODE", root_x + 28, add_deck_y + 120, "DELAY:", CLR_TEXT_MED, 8, true);
      string mode_btn_txt = g_form_delay_close ? "TF CLOSE" : "% TF PROGRESS";
      color  mode_btn_clr = g_form_delay_close ? CLR_GOLD_NEON : CLR_CYAN_NEON;
      CreateButton("BTN_TOGGLE_RADAR_MODE", root_x + 105, add_deck_y + 116, 170, 22, mode_btn_txt, CLR_CANVAS_BG, mode_btn_clr, CLR_BORDER_HARD);
      
      if(!g_form_delay_close)
      {
         CreateEdit("INP_NEW_DELAY", root_x + 285, add_deck_y + 116, 92, 22, IntegerToString(g_form_delay_pct) + "%", CLR_CANVAS_BG, CLR_GOLD_NEON);
      }
      
      // Row 5: Price Bounds (Bullish Buy Filter)
      CreateLabel("LBL_F_BULL", root_x + 28, add_deck_y + 148, "BULLISH :", CLR_BULL_NEON, 8, true);
      CreateEdit("INP_NEW_BULL", root_x + 105, add_deck_y + 144, 272, 22, default_bull, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      // Row 6: Price Bounds (Bearish Sell Filter)
      CreateLabel("LBL_F_BEAR", root_x + 28, add_deck_y + 176, "BEARISH :", CLR_BEAR_NEON, 8, true);
      CreateEdit("INP_NEW_BEAR", root_x + 105, add_deck_y + 172, 272, 22, default_bear, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      CreateLabel("LBL_F_HINT", root_x + 28, add_deck_y + 202, "Bound: >65724  <64164  <=  >=  64164-65814  ALL  (kosong=off)", CLR_TEXT_MED, 7, false);
      
      // Row 7: Buttons
      if(is_edit)
      {
         CreateButton("BTN_ADD_RADAR", root_x + 28, add_deck_y + 230, 250, 28, "UPDATE SELECTED RADAR", CLR_TAB_ACTIVE_BG, CLR_GOLD_NEON, CLR_GOLD_NEON);
         CreateButton("BTN_CANCEL_EDIT", root_x + 288, add_deck_y + 230, 89, 28, "CANCEL", CLR_PANEL_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
      }
      else
      {
         CreateButton("BTN_ADD_RADAR", root_x + 28, add_deck_y + 230, 250, 28, "+ SAVE TO RADAR", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
         CreateButton("BTN_RESET_RADAR", root_x + 288, add_deck_y + 230, 89, 28, "DEFAULT", CLR_PANEL_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
      }
      
      // Box Right: Push Notification Preview & Test Alert
      int box_r_x = root_x + 24 + box_w;
      CreateRect("CARD_NOTIF_PREV", box_r_x, add_deck_y, box_w, 280, CLR_CANVAS_BG, CLR_BORDER_HARD);
      CreateLabel("LBL_NOTIF_TITLE", box_r_x + 12, add_deck_y + 10, "MOBILE PUSH ALERT PREVIEW", CLR_CYAN_NEON, 9, true);
      CreateButton("BTN_TEST_ALERT", box_r_x + box_w - 110, add_deck_y + 6, 98, 22, "TEST ALERT", C'26,42,65', CLR_CYAN_NEON, CLR_CYAN_NEON);
      
      CreateLabel("NOTIF_LINE1", box_r_x + 12, add_deck_y + 42, "[REVERSAL ALERT] EURUSD (M5) [30% TF DELAY]", CLR_CYAN_NEON, 8, true);
      CreateLabel("NOTIF_LINE2", box_r_x + 12, add_deck_y + 66, "Signal: Strong Bullish Engulfing", CLR_GOLD_NEON, 8, true);
      CreateLabel("NOTIF_LINE3", box_r_x + 12, add_deck_y + 90, "Direction: BULLISH (BUY)", CLR_BULL_NEON, 8, true);
      CreateLabel("NOTIF_LINE4", box_r_x + 12, add_deck_y + 114, "Price: 1.08250 | 50% ATR: 11.5 pips (115 pts)", CLR_TEXT_PURE, 8, false);
      CreateLabel("NOTIF_LINE5", box_r_x + 12, add_deck_y + 138, "Suggested SL: 1.08135 (Low - 50% ATR)", CLR_GOLD_NEON, 8, true);
      CreateLabel("NOTIF_LINE6", box_r_x + 12, add_deck_y + 162, "Sell SL automatically includes broker spread", CLR_TEXT_MED, 7, false);
      CreateLabel("NOTIF_LINE7", box_r_x + 12, add_deck_y + 186, "Signals supported: ENG, HAMMER/SS, STOCH+HA", CLR_CYAN_NEON, 7, false);
      CreateLabel("NOTIF_LINE8", box_r_x + 12, add_deck_y + 210, "Mode supported: ANY (OR) / COMBO (AND)", CLR_GOLD_NEON, 7, false);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| DYNAMIC DATA ROWS UPDATE                                         |
//+------------------------------------------------------------------+
void UpdateDashboardUI()
{
   int root_x = 20;
   int root_y = 20;
   int win_w  = 960;
   int tab_y  = root_y + 48;
   
   if(g_active_tab == 1)
   {
      // ponytail: no ObjectsDeleteAll here. The Create* helpers only create when
      // ObjectFind fails, so existing rows are updated in place instead of being
      // destroyed and rebuilt on every 1s timer tick (that was the visible flicker).
      // Stale rows -- ones that no longer have a position/order -- are hidden below.
      int table_y = tab_y + 36;
      int start_y = table_y + 58;
      int row_idx = 0;
      
      // Render Active Positions
      int pos_total = PositionsTotal();
      for(int i = 0; i < pos_total && row_idx < MAX_ROWS_PER_PAGE; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         
         string sym       = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol       = PositionGetDouble(POSITION_VOLUME);
         double open_p    = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl        = PositionGetDouble(POSITION_SL);
         double tp        = PositionGetDouble(POSITION_TP);
         ulong  pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         int digits       = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         
         bool is_sel = IsOrderSelected(ticket);
         
         // Auto-BE status for this ticket
         string be_status = "OFF";
         color  be_color  = CLR_TEXT_MED;
         for(int b = 0; b < ArraySize(g_auto_be_list); b++)
         {
            if(g_auto_be_list[b].ticket == ticket && g_auto_be_list[b].active)
            {
               be_status = "ON " + DoubleToString(g_auto_be_list[b].trigger_price, digits);
               be_color  = CLR_GOLD_NEON;
               break;
            }
         }
         
         // Auto Trail status for this ticket
         string tr_status = "OFF";
         color  tr_color  = CLR_TEXT_MED;
         if(pos_magic == InpAutoTraderMagic)
         {
            tr_status = "AT TRAIL";
            tr_color  = CLR_CYAN_NEON;
         }
         else
         {
            for(int t = 0; t < ArraySize(g_tracking_list); t++)
            {
               if(g_tracking_list[t].ticket == ticket && g_tracking_list[t].active)
               {
                  tr_status = (g_tracking_list[t].trail_cycle > 0) ? StringFormat("ON (C%d)", g_tracking_list[t].trail_cycle) : "ON";
                  tr_color  = CLR_GOLD_NEON;
                  break;
               }
            }
         }
         
         int cur_y = start_y + (row_idx * 23);
         string r_pfx = StringFormat("R_%d_", row_idx);
         
         color row_bg = is_sel ? CLR_ROW_SELECTED : ((row_idx % 2 == 0) ? CLR_CARD_BG : CLR_PANEL_BG);
         CreateRect(r_pfx + "BG", root_x + 26, cur_y, win_w - 52, 21, row_bg, is_sel ? CLR_CYAN_NEON : CLR_BORDER_SOFT);
         
         // Checkbox button (z-order priority on top)
         CreateButton("ROW_CB_" + IntegerToString(ticket), root_x + 36, cur_y + 2, 28, 17, is_sel ? "[X]" : "[  ]", is_sel ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_sel ? CLR_CYAN_NEON : CLR_TEXT_MED, is_sel ? CLR_CYAN_NEON : CLR_BORDER_HARD);
         
         CreateLabel(r_pfx + "TKT", root_x + 72, cur_y + 3, "#" + IntegerToString(ticket), CLR_TEXT_PURE, 8, true);
         CreateLabel(r_pfx + "SYM", root_x + 155, cur_y + 3, sym, CLR_TEXT_PURE, 8, true);
         
         if(type == POSITION_TYPE_BUY)
            CreateLabel(r_pfx + "TYP", root_x + 235, cur_y + 3, "BUY", CLR_BULL_NEON, 8, true);
         else
            CreateLabel(r_pfx + "TYP", root_x + 235, cur_y + 3, "SELL", CLR_BEAR_NEON, 8, true);
            
         CreateLabel(r_pfx + "VOL", root_x + 355, cur_y + 3, DoubleToString(vol, 2), CLR_TEXT_PURE, 8, false);
         CreateLabel(r_pfx + "OPN", root_x + 430, cur_y + 3, DoubleToString(open_p, digits), CLR_TEXT_PURE, 8, false);
         CreateLabel(r_pfx + "SL",  root_x + 515, cur_y + 3, sl > 0 ? DoubleToString(sl, digits) : "-", CLR_BEAR_NEON, 8, false);
         CreateLabel(r_pfx + "TP",  root_x + 600, cur_y + 3, tp > 0 ? DoubleToString(tp, digits) : "-", CLR_BULL_NEON, 8, false);
         CreateLabel(r_pfx + "BE",  root_x + 695, cur_y + 3, be_status, be_color, 8, true);
         CreateLabel(r_pfx + "TR",  root_x + 810, cur_y + 3, tr_status, tr_color, 8, true);
         
         row_idx++;
      }
      
      // Render Pending Orders
      int ord_total = OrdersTotal();
      for(int i = 0; i < ord_total && row_idx < MAX_ROWS_PER_PAGE; i++)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket <= 0) continue;
         
         string sym       = OrderGetString(ORDER_SYMBOL);
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         double vol       = OrderGetDouble(ORDER_VOLUME_CURRENT);
         double open_p    = OrderGetDouble(ORDER_PRICE_OPEN);
         double sl        = OrderGetDouble(ORDER_SL);
         double tp        = OrderGetDouble(ORDER_TP);
         int digits       = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         
         bool is_sel = IsOrderSelected(ticket);
         
         int cur_y = start_y + (row_idx * 23);
         string r_pfx = StringFormat("R_%d_", row_idx);
         
         color row_bg = is_sel ? CLR_ROW_SELECTED : ((row_idx % 2 == 0) ? CLR_CARD_BG : CLR_PANEL_BG);
         CreateRect(r_pfx + "BG", root_x + 26, cur_y, win_w - 52, 21, row_bg, is_sel ? CLR_CYAN_NEON : CLR_BORDER_SOFT);
         
         CreateButton("ROW_CB_" + IntegerToString(ticket), root_x + 36, cur_y + 2, 28, 17, is_sel ? "[X]" : "[  ]", is_sel ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_sel ? CLR_CYAN_NEON : CLR_TEXT_MED, is_sel ? CLR_CYAN_NEON : CLR_BORDER_HARD);
         CreateLabel(r_pfx + "TKT", root_x + 72, cur_y + 3, "#" + IntegerToString(ticket), CLR_TEXT_PURE, 8, false);
         CreateLabel(r_pfx + "SYM", root_x + 155, cur_y + 3, sym, CLR_TEXT_PURE, 8, true);
         
         string str_type = "ORD";
         if(type == ORDER_TYPE_BUY_LIMIT) str_type = "BUY LIMIT";
         else if(type == ORDER_TYPE_SELL_LIMIT) str_type = "SELL LIMIT";
         else if(type == ORDER_TYPE_BUY_STOP) str_type = "BUY STOP";
         else if(type == ORDER_TYPE_SELL_STOP) str_type = "SELL STOP";
         else if(type == ORDER_TYPE_BUY) str_type = "BUY";
         else if(type == ORDER_TYPE_SELL) str_type = "SELL";
         else str_type = EnumToString(type);
         
         CreateLabel(r_pfx + "TYP", root_x + 235, cur_y + 3, str_type, CLR_GOLD_NEON, 8, false);
         CreateLabel(r_pfx + "VOL", root_x + 355, cur_y + 3, DoubleToString(vol, 2), CLR_TEXT_PURE, 8, false);
         CreateLabel(r_pfx + "OPN", root_x + 430, cur_y + 3, DoubleToString(open_p, digits), CLR_TEXT_PURE, 8, false);
         CreateLabel(r_pfx + "SL",  root_x + 515, cur_y + 3, sl > 0 ? DoubleToString(sl, digits) : "-", CLR_BEAR_NEON, 8, false);
         CreateLabel(r_pfx + "TP",  root_x + 600, cur_y + 3, tp > 0 ? DoubleToString(tp, digits) : "-", CLR_BULL_NEON, 8, false);
         CreateLabel(r_pfx + "BE",  root_x + 695, cur_y + 3, "-", CLR_TEXT_MED, 8, false);
         CreateLabel(r_pfx + "TR",  root_x + 810, cur_y + 3, "-", CLR_TEXT_MED, 8, false);
         
         row_idx++;
      }
      
      // Hide rows beyond the current count (position closed -> row must vanish).
      for(int k = row_idx; k < MAX_ROWS_PER_PAGE; k++)
      {
         string hide_pfx = StringFormat("R_%d_", k);
         ObjectsDeleteAll(0, g_prefix + hide_pfx);
      }
      
      // Checkbox names are keyed by TICKET, not row index, so they cannot be
      // cleaned by row prefix. Instead walk every object of that prefix and
      // delete only those whose ticket is no longer open (position or order).
      // Runs after both render loops: PositionSelectByTicket/OrderSelect change
      // the global selection, which would corrupt an in-flight PositionGetDouble.
      int objs = ObjectsTotal(0, -1, -1);
      for(int o = objs - 1; o >= 0; o--)
      {
         string oname = ObjectName(0, o);
         if(StringFind(oname, g_prefix + "ROW_CB_") != 0) continue;
         
         string str_tkt = StringSubstr(oname, StringLen(g_prefix + "ROW_CB_"));
         long   tkt     = StringToInteger(str_tkt);
         bool   alive   = (PositionSelectByTicket((ulong)tkt) || OrderSelect((ulong)tkt));
         if(!alive) ObjectDelete(0, oname);
      }
   }
   else if(g_active_tab == 2)
   {
      // Clean previous radar cards
      ObjectsDeleteAll(0, g_prefix + "W_");
      ObjectsDeleteAll(0, g_prefix + "BTN_EDIT_RADAR_");
      ObjectsDeleteAll(0, g_prefix + "BTN_DEL_RADAR_");
      ObjectsDeleteAll(0, g_prefix + "BTN_TOGGLE_ACT_");
      
      int radar_y = tab_y + 36;
      int start_y = radar_y + 34;
      int total_w = ArraySize(g_radar_symbols);
      
      for(int i = 0; i < total_w && i < 4; i++)
      {
         int cur_y = start_y + (i * 48);
         string r_pfx = StringFormat("W_%d_", i);
         bool is_item_editing = (g_editing_radar_idx == i);
         
         CreateRect(r_pfx + "BG", root_x + 26, cur_y, win_w - 52, 42, is_item_editing ? CLR_ROW_SELECTED : CLR_CANVAS_BG, is_item_editing ? CLR_GOLD_NEON : CLR_BORDER_HARD);
         CreateLabel(r_pfx + "SYM", root_x + 36, cur_y + 6, g_radar_symbols[i].symbol, CLR_TEXT_PURE, 10, true);
         
         string str_tf = StringSubstr(EnumToString(g_radar_symbols[i].timeframe), 7);
         CreateLabel(r_pfx + "TF", root_x + 130, cur_y + 8, "[" + str_tf + "]", CLR_CYAN_NEON, 8, true);
         
         string mode_tag = g_radar_symbols[i].delay_is_tf_close ? "CLOSE" : IntegerToString(g_radar_symbols[i].delay_tf_pct) + "%";
         CreateLabel(r_pfx + "MODE", root_x + 130, cur_y + 22, "[" + mode_tag + "]", g_radar_symbols[i].delay_is_tf_close ? CLR_GOLD_NEON : CLR_TEXT_MED, 7, false);

         string str_bull = g_radar_symbols[i].bull_enabled ? ("BULL: " + g_radar_symbols[i].bull_price_filter) : "BULL: OFF";
         string str_bear = g_radar_symbols[i].bear_enabled ? ("BEAR: " + g_radar_symbols[i].bear_price_filter) : "BEAR: OFF";

         CreateLabel(r_pfx + "COND_BULL", root_x + 195, cur_y + 6, str_bull, g_radar_symbols[i].bull_enabled ? CLR_BULL_NEON : CLR_TEXT_MED, 8, true);
         CreateLabel(r_pfx + "COND_BEAR", root_x + 195, cur_y + 22, str_bear, g_radar_symbols[i].bear_enabled ? CLR_BEAR_NEON : CLR_TEXT_MED, 8, true);

         // Signals Badges
         string sigs_tag = "";
         if(g_radar_symbols[i].sig_engulfing) sigs_tag += "[ENG] ";
         if(g_radar_symbols[i].sig_hammer_ss) sigs_tag += "[HMR/SS] ";
         if(g_radar_symbols[i].sig_stoch_ha)  sigs_tag += "[ST+HA] ";
         sigs_tag += (g_radar_symbols[i].signal_mode == SIGNAL_MODE_ANY) ? "[OR]" : "[AND]";
         CreateLabel(r_pfx + "SIGS", root_x + 440, cur_y + 12, sigs_tag, CLR_CYAN_NEON, 7, true);

         // Active / Pause Toggle Button
         string act_txt = g_radar_symbols[i].active ? "ACTIVE" : "PAUSED";
         color  act_bg  = g_radar_symbols[i].active ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
         color  act_clr = g_radar_symbols[i].active ? CLR_BULL_NEON : CLR_BEAR_NEON;
         CreateButton("BTN_TOGGLE_ACT_" + IntegerToString(i), root_x + win_w - 235, cur_y + 9, 58, 24, act_txt, act_bg, act_clr, act_clr);

         CreateButton("BTN_EDIT_RADAR_" + IntegerToString(i), root_x + win_w - 170, cur_y + 9, 52, 24, "EDIT", is_item_editing ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_item_editing ? CLR_GOLD_NEON : CLR_CYAN_NEON, is_item_editing ? CLR_GOLD_NEON : CLR_BORDER_HARD);
         CreateButton("BTN_DEL_RADAR_"  + IntegerToString(i), root_x + win_w - 110, cur_y + 9, 58, 24, "DELETE", C'18,8,34', CLR_BEAR_NEON, CLR_BEAR_NEON);
      }
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| CLEANUP ALL DASHBOARD OBJECTS                                    |
//+------------------------------------------------------------------+
void DestroyDashboardUI()
{
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| PERSISTENCE (SAVE / LOAD STATE TO FILE)                          |
//+------------------------------------------------------------------+
void SaveStateToFile()
{
   string filename = "TMRR_State_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   int handle = FileOpen(filename, FILE_WRITE|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      // Version header (7 = v7 with Auto Trail engine and tracking)
      FileWriteInteger(handle, 7);

      // 0. Save UI Active Tab & Offset Mode
      FileWriteInteger(handle, g_active_tab);
      FileWriteInteger(handle, (int)g_be_offset_mode);
      
      // 1. Save Radar Symbols
      int total_radar = ArraySize(g_radar_symbols);
      FileWriteInteger(handle, total_radar);
      for(int i = 0; i < total_radar; i++)
      {
         int sym_len = StringLen(g_radar_symbols[i].symbol);
         FileWriteInteger(handle, sym_len);
         if(sym_len > 0)
            FileWriteString(handle, g_radar_symbols[i].symbol, sym_len);
            
         FileWriteInteger(handle, (int)g_radar_symbols[i].timeframe);
         FileWriteInteger(handle, g_radar_symbols[i].bull_enabled ? 1 : 0);
         
         int bf_len = StringLen(g_radar_symbols[i].bull_price_filter);
         FileWriteInteger(handle, bf_len);
         if(bf_len > 0) FileWriteString(handle, g_radar_symbols[i].bull_price_filter, bf_len);

         FileWriteInteger(handle, g_radar_symbols[i].bear_enabled ? 1 : 0);
         
         int sf_len = StringLen(g_radar_symbols[i].bear_price_filter);
         FileWriteInteger(handle, sf_len);
         if(sf_len > 0) FileWriteString(handle, g_radar_symbols[i].bear_price_filter, sf_len);

         FileWriteInteger(handle, g_radar_symbols[i].atr_period);
         FileWriteInteger(handle, g_radar_symbols[i].delay_is_tf_close ? 1 : 0);
         FileWriteInteger(handle, g_radar_symbols[i].delay_tf_pct);
         FileWriteInteger(handle, g_radar_symbols[i].active ? 1 : 0);
         FileWriteInteger(handle, g_radar_symbols[i].sig_engulfing ? 1 : 0);
         FileWriteInteger(handle, g_radar_symbols[i].sig_hammer_ss ? 1 : 0);
         FileWriteInteger(handle, g_radar_symbols[i].sig_stoch_ha  ? 1 : 0);
         FileWriteInteger(handle, (int)g_radar_symbols[i].signal_mode);
      }
      
      // 2. Save Auto BE List
      int total_be = ArraySize(g_auto_be_list);
      FileWriteInteger(handle, total_be);
      for(int i = 0; i < total_be; i++)
      {
         FileWriteLong(handle, (long)g_auto_be_list[i].ticket);
         
         int sym_len = StringLen(g_auto_be_list[i].symbol);
         FileWriteInteger(handle, sym_len);
         if(sym_len > 0)
            FileWriteString(handle, g_auto_be_list[i].symbol, sym_len);
            
         FileWriteInteger(handle, (int)g_auto_be_list[i].pos_type);
         FileWriteDouble(handle, g_auto_be_list[i].trigger_price);
         FileWriteInteger(handle, (int)g_auto_be_list[i].offset_mode);
         FileWriteInteger(handle, g_auto_be_list[i].custom_points);
         FileWriteDouble(handle, g_auto_be_list[i].fixed_price);
         FileWriteInteger(handle, g_auto_be_list[i].active ? 1 : 0);
      }

      // 3. Global BE fixed price
      FileWriteDouble(handle, g_be_fixed_price);

      // 4. Persistent Add/Edit form state
      int sym_len = StringLen(g_form_sym);
      FileWriteInteger(handle, sym_len);
      if(sym_len > 0) FileWriteString(handle, g_form_sym, sym_len);

      int tf_len = StringLen(g_form_tf);
      FileWriteInteger(handle, tf_len);
      if(tf_len > 0) FileWriteString(handle, g_form_tf, tf_len);

      int bull_len = StringLen(g_form_bull);
      FileWriteInteger(handle, bull_len);
      if(bull_len > 0) FileWriteString(handle, g_form_bull, bull_len);

      int bear_len = StringLen(g_form_bear);
      FileWriteInteger(handle, bear_len);
      if(bear_len > 0) FileWriteString(handle, g_form_bear, bear_len);

      FileWriteInteger(handle, g_form_delay_pct);
      FileWriteInteger(handle, g_form_delay_close ? 1 : 0);
      FileWriteInteger(handle, g_form_sig_eng ? 1 : 0);
      FileWriteInteger(handle, g_form_sig_hmr ? 1 : 0);
      FileWriteInteger(handle, g_form_sig_stoch ? 1 : 0);
      FileWriteInteger(handle, (int)g_form_sig_mode);

      // 5. Save Auto Trail Tracking List
      int total_trail = ArraySize(g_tracking_list);
      FileWriteInteger(handle, total_trail);
      for(int i = 0; i < total_trail; i++)
      {
         FileWriteLong(handle, (long)g_tracking_list[i].ticket);
         int sym_len2 = StringLen(g_tracking_list[i].symbol);
         FileWriteInteger(handle, sym_len2);
         if(sym_len2 > 0) FileWriteString(handle, g_tracking_list[i].symbol, sym_len2);
         FileWriteInteger(handle, (int)g_tracking_list[i].timeframe);
         FileWriteDouble(handle, g_tracking_list[i].initial_atr100);
         FileWriteDouble(handle, g_tracking_list[i].initial_tp_dist);
         FileWriteDouble(handle, g_tracking_list[i].prev_tp_level);
         FileWriteInteger(handle, g_tracking_list[i].trail_cycle);
         FileWriteDouble(handle, g_tracking_list[i].trail_max_dist);
         FileWriteDouble(handle, g_tracking_list[i].atr_multiplier);
         FileWriteDouble(handle, g_tracking_list[i].trail_be_rem_dist_pct);
         FileWriteInteger(handle, g_tracking_list[i].be_applied ? 1 : 0);
         FileWriteInteger(handle, g_tracking_list[i].active ? 1 : 0);
      }

      // 6. Persistent Auto Trail Form Inputs
      FileWriteDouble(handle, g_form_trail_max_dist);
      FileWriteDouble(handle, g_form_trail_atr_mult);
      FileWriteDouble(handle, g_form_trail_be_rem_pct);
      int trail_tf_len = StringLen(g_form_trail_tf);
      FileWriteInteger(handle, trail_tf_len);
      if(trail_tf_len > 0) FileWriteString(handle, g_form_trail_tf, trail_tf_len);

      FileClose(handle);
   }
}

void LoadStateFromFile()
{
   string filename = "TMRR_State_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   // Fallback to legacy filename if exists
   if(!FileIsExist(filename))
      filename = "TMER_State_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   if(!FileIsExist(filename)) return;
   
   int handle = FileOpen(filename, FILE_READ|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      int first = FileReadInteger(handle);
      int version;
      if(first >= 2 && first <= 7)
      {
         version = first;
         g_active_tab = FileReadInteger(handle);
      }
      else
      {
         version = 1;
         g_active_tab = first;
      }

      if(g_active_tab != 1 && g_active_tab != 2) g_active_tab = 1;
      g_be_offset_mode = (ENUM_BE_OFFSET_MODE)FileReadInteger(handle);
      
      int total_radar = FileReadInteger(handle);
      ArrayResize(g_radar_symbols, total_radar);
      for(int i = 0; i < total_radar; i++)
      {
         int sym_len = FileReadInteger(handle);
         if(sym_len > 0)
            g_radar_symbols[i].symbol = FileReadString(handle, sym_len);
         else
            g_radar_symbols[i].symbol = "";
            
         g_radar_symbols[i].timeframe    = (ENUM_TIMEFRAMES)FileReadInteger(handle);
         g_radar_symbols[i].bull_enabled = (FileReadInteger(handle) == 1);
         
         if(version >= 3)
         {
            int bf_len = FileReadInteger(handle);
            if(bf_len > 0) g_radar_symbols[i].bull_price_filter = FileReadString(handle, bf_len);
            else g_radar_symbols[i].bull_price_filter = "ALL";

            g_radar_symbols[i].bear_enabled = (FileReadInteger(handle) == 1);
            
            int sf_len = FileReadInteger(handle);
            if(sf_len > 0) g_radar_symbols[i].bear_price_filter = FileReadString(handle, sf_len);
            else g_radar_symbols[i].bear_price_filter = "ALL";

            g_radar_symbols[i].atr_period = FileReadInteger(handle);
            g_radar_symbols[i].delay_is_tf_close = (FileReadInteger(handle) == 1);
            if(version >= 6)
            {
               g_radar_symbols[i].delay_tf_pct  = FileReadInteger(handle);
               g_radar_symbols[i].active        = (FileReadInteger(handle) == 1);
               g_radar_symbols[i].sig_engulfing = (FileReadInteger(handle) == 1);
               g_radar_symbols[i].sig_hammer_ss = (FileReadInteger(handle) == 1);
               g_radar_symbols[i].sig_stoch_ha  = (FileReadInteger(handle) == 1);
               g_radar_symbols[i].signal_mode   = (ENUM_SIGNAL_MODE)FileReadInteger(handle);
            }
            else if(version >= 4)
            {
               int old_delay = FileReadInteger(handle);
               g_radar_symbols[i].delay_tf_pct  = (old_delay > 0) ? 30 : 0;
               g_radar_symbols[i].active        = true;
               g_radar_symbols[i].sig_engulfing = true;
               g_radar_symbols[i].sig_hammer_ss = true;
               g_radar_symbols[i].sig_stoch_ha  = true;
               g_radar_symbols[i].signal_mode   = SIGNAL_MODE_ANY;
            }
            else
            {
               g_radar_symbols[i].delay_tf_pct  = 0;
               g_radar_symbols[i].active        = true;
               g_radar_symbols[i].sig_engulfing = true;
               g_radar_symbols[i].sig_hammer_ss = true;
               g_radar_symbols[i].sig_stoch_ha  = true;
               g_radar_symbols[i].signal_mode   = SIGNAL_MODE_ANY;
            }
         }
         else
         {
            double b_max = FileReadDouble(handle);
            g_radar_symbols[i].bull_price_filter = (b_max > 0) ? DoubleToString(b_max, 5) : "ALL";
            g_radar_symbols[i].bear_enabled = (FileReadInteger(handle) == 1);
            double s_min = FileReadDouble(handle);
            g_radar_symbols[i].bear_price_filter = (s_min > 0) ? DoubleToString(s_min, 5) : "ALL";
            g_radar_symbols[i].atr_period = FileReadInteger(handle);
            g_radar_symbols[i].delay_is_tf_close = false;
            g_radar_symbols[i].delay_tf_pct = 0;
            g_radar_symbols[i].active        = true;
            g_radar_symbols[i].sig_engulfing = true;
            g_radar_symbols[i].sig_hammer_ss = true;
            g_radar_symbols[i].sig_stoch_ha  = true;
            g_radar_symbols[i].signal_mode   = SIGNAL_MODE_ANY;
         }
         
         g_radar_symbols[i].last_bull_alert_bar = 0;
         g_radar_symbols[i].last_bear_alert_bar = 0;
         g_radar_symbols[i].bull_cond_start_time_main = 0;
         g_radar_symbols[i].bull_cond_start_time_fallback = 0;
         g_radar_symbols[i].bear_cond_start_time_main = 0;
         g_radar_symbols[i].bear_cond_start_time_fallback = 0;
      }
      
      // 2. Read Auto BE List
      int total_be = FileReadInteger(handle);
      ArrayResize(g_auto_be_list, total_be);
      for(int i = 0; i < total_be; i++)
      {
         g_auto_be_list[i].ticket        = (ulong)FileReadLong(handle);
         g_auto_be_list[i].is_position   = true;
         
         int sym_len = FileReadInteger(handle);
         if(sym_len > 0)
            g_auto_be_list[i].symbol = FileReadString(handle, sym_len);
         else
            g_auto_be_list[i].symbol = "";
            
         g_auto_be_list[i].pos_type      = (ENUM_POSITION_TYPE)FileReadInteger(handle);
         g_auto_be_list[i].trigger_price = FileReadDouble(handle);
         g_auto_be_list[i].offset_mode   = (ENUM_BE_OFFSET_MODE)FileReadInteger(handle);
         g_auto_be_list[i].custom_points = FileReadInteger(handle);
         if(version >= 2) g_auto_be_list[i].fixed_price = FileReadDouble(handle);
         else             g_auto_be_list[i].fixed_price = 0.0;
         g_auto_be_list[i].active        = (FileReadInteger(handle) == 1);
      }

      if(version >= 2 && FileIsEnding(handle) == false)
         g_be_fixed_price = FileReadDouble(handle);

      if(version >= 5 && FileIsEnding(handle) == false)
      {
         int form_sym_len = FileReadInteger(handle);
         string form_sym = "";
         if(form_sym_len > 0) form_sym = FileReadString(handle, form_sym_len);
         if(form_sym != "") g_form_sym = form_sym;

         int form_tf_len = FileReadInteger(handle);
         string form_tf = "5";
         if(form_tf_len > 0) form_tf = FileReadString(handle, form_tf_len);
         if(form_tf != "") g_form_tf = form_tf;

         int form_bull_len = FileReadInteger(handle);
         string form_bull = "ALL";
         if(form_bull_len > 0) form_bull = FileReadString(handle, form_bull_len);
         g_form_bull = (form_bull != "") ? form_bull : "ALL";

         int form_bear_len = FileReadInteger(handle);
         string form_bear = "ALL";
         if(form_bear_len > 0) form_bear = FileReadString(handle, form_bear_len);
         g_form_bear = (form_bear != "") ? form_bear : "ALL";

         if(version >= 6)
         {
            g_form_delay_pct   = FileReadInteger(handle);
            g_form_delay_close = (FileReadInteger(handle) == 1);
            g_form_sig_eng     = (FileReadInteger(handle) == 1);
            g_form_sig_hmr     = (FileReadInteger(handle) == 1);
            g_form_sig_stoch   = (FileReadInteger(handle) == 1);
            g_form_sig_mode    = (ENUM_SIGNAL_MODE)FileReadInteger(handle);
         }
         else
         {
            int old_d = FileReadInteger(handle);
            g_form_delay_pct   = (old_d > 0) ? 30 : 0;
            g_form_delay_close = (FileReadInteger(handle) == 1);
         }
      }

      if(version >= 7 && FileIsEnding(handle) == false)
      {
         int total_trail = FileReadInteger(handle);
         ArrayResize(g_tracking_list, total_trail);
         for(int i = 0; i < total_trail; i++)
         {
            g_tracking_list[i].ticket = (ulong)FileReadLong(handle);
            int sym_len2 = FileReadInteger(handle);
            if(sym_len2 > 0) g_tracking_list[i].symbol = FileReadString(handle, sym_len2);
            else g_tracking_list[i].symbol = "";
            g_tracking_list[i].timeframe = (ENUM_TIMEFRAMES)FileReadInteger(handle);
            g_tracking_list[i].initial_atr100 = FileReadDouble(handle);
            g_tracking_list[i].initial_tp_dist = FileReadDouble(handle);
            g_tracking_list[i].prev_tp_level = FileReadDouble(handle);
            g_tracking_list[i].trail_cycle = FileReadInteger(handle);
            g_tracking_list[i].trail_max_dist = FileReadDouble(handle);
            g_tracking_list[i].atr_multiplier = FileReadDouble(handle);
            g_tracking_list[i].trail_be_rem_dist_pct = FileReadDouble(handle);
            g_tracking_list[i].be_applied = (FileReadInteger(handle) == 1);
            g_tracking_list[i].active = (FileReadInteger(handle) == 1);
         }

         if(FileIsEnding(handle) == false)
         {
            g_form_trail_max_dist = FileReadDouble(handle);
            g_form_trail_atr_mult = FileReadDouble(handle);
            g_form_trail_be_rem_pct = FileReadDouble(handle);
            int trail_tf_len = FileReadInteger(handle);
            if(trail_tf_len > 0) g_form_trail_tf = FileReadString(handle, trail_tf_len);
         }
      }

      FileClose(handle);
   }
}
//+------------------------------------------------------------------+
