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
input bool     InpEnablePushAlerts     = true;       // Send Mobile Push Alerts
input bool     InpEnableSoundAlerts    = true;       // Enable Sound/Pop-up Alerts

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
   CheckReversalRadar();
   
   // Periodically refresh order list in UI
   UpdateDashboardUI();
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
         g_active_tab = 1;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "TAB_RADAR")
      {
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
         g_form_sig_stoch = !g_form_sig_stoch;
         CreateDashboardUI();
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_RADAR_SIG_MODE")
      {
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
         if(!g_form_delay_close)
         {
            int cur_pct = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_NEW_DELAY", OBJPROP_TEXT));
            if(cur_pct >= 0) g_form_delay_pct = cur_pct;
         }
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
         
         string msg = StringFormat("[ENGULFING ALERT - TEST]\nSymbol: %s (M5)\nType: Realtime Strong BULLISH Break\nPrice: %s\n50%% ATR(%d): %.1f pips (%.0f pts)\nSuggested SL: %s\nStatus: Notifications Working!",
                                   test_sym,
                                   DoubleToString(cur_price, digits),
                                   InpDefaultATRPeriod,
                                   pips_val,
                                   points_val,
                                   DoubleToString(test_sl, digits));
         
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
            
            string msg = StringFormat("[REVERSAL ALERT] %s (%s) [%s]\nSignal: %s\nDirection: BULLISH (BUY)\nPrice: %s\n50%% ATR(%d): %.1f pips (%.0f pts)\nSuggested SL: %s",
                                      sym, EnumToString(sig_tf), mode_tag, sig_name,
                                      DoubleToString(cur_price, digits),
                                      g_radar_symbols[index].atr_period,
                                      pips_val, points_val,
                                      DoubleToString(rec_sl, digits));
            
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
            
            string msg = StringFormat("[REVERSAL ALERT] %s (%s) [%s]\nSignal: %s\nDirection: BEARISH (SELL)\nPrice: %s\n50%% ATR(%d): %.1f pips (%.0f pts)\nSuggested SL: %s",
                                      sym, EnumToString(sig_tf), mode_tag, sig_name,
                                      DoubleToString(cur_price, digits),
                                      g_radar_symbols[index].atr_period,
                                      pips_val, points_val,
                                      DoubleToString(rec_sl, digits));
            
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

double CalculateATR50(const string sym, const ENUM_TIMEFRAMES tf, int period)
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
   double atr = tr_sum / (double)period;
   return (atr * 0.5); // 50% ATR
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
   
   // Syarat 3: Rentang lilin > rentang lilin sebelumnya
   double cur_range  = cur_high - cur_low;
   double prev_range = prev_high - prev_low;
   if(cur_range <= prev_range) return false;
   
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
      return (stoch_buy && ha_buy);
   }
   else
   {
      bool stoch_sell = (cur_k > InpStochOB && cur_k < prev_k);
      bool ha_sell    = (cur_ha_size < prev_ha_size || cur_ha_red);
      return (stoch_sell && ha_sell);
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
   int win_w  = 880;
   int win_h  = 640;
   
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
      CreateLabel("TH_BE",  root_x + 700, th_y + 4, "AUTO-BE", CLR_TEXT_MED, 8, true);
      
      // Action Deck (SL/TP & Auto-BE)
      int deck_y = table_y + 270;
      int box_w  = (win_w - 42) / 2;
      
      // Box A: Bulk SL/TP
      CreateRect("CARD_SLTP", root_x + 16, deck_y, box_w, 140, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("LBL_SLTP", root_x + 28, deck_y + 10, "BULK PRICE MODIFIER", CLR_CYAN_NEON, 9, true);
      
      CreateLabel("LBL_INP_SL", root_x + 28, deck_y + 42, "STOP LOSS:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_SL", root_x + 115, deck_y + 38, 140, 24, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateButton("BTN_APPLY_SL", root_x + 265, deck_y + 38, 100, 24, "SET SL", C'18,8,34', CLR_BEAR_NEON, CLR_BEAR_NEON);
      
      CreateLabel("LBL_INP_TP", root_x + 28, deck_y + 82, "TAKE PROFIT:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_TP", root_x + 115, deck_y + 78, 140, 24, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      CreateButton("BTN_APPLY_TP", root_x + 265, deck_y + 78, 100, 24, "SET TP", C'8,34,18', CLR_BULL_NEON, CLR_BULL_NEON);
      
      // Box B: Auto Break-Even
      int box_b_x = root_x + 24 + box_w;
      CreateRect("CARD_BE", box_b_x, deck_y, box_w, 168, CLR_CARD_BG, CLR_BORDER_HARD);
      CreateLabel("LBL_BE", box_b_x + 12, deck_y + 10, "BREAK-EVEN (BE) ENGINE", CLR_CYAN_NEON, 9, true);
      
      // Instant BE button (Direct Move to Open +/- Spread)
      CreateButton("BTN_INSTANT_BE", box_b_x + 210, deck_y + 8, 155, 22, "SET BE SPREAD", C'26,42,65', CLR_GOLD_NEON, CLR_GOLD_NEON);
      
      CreateLabel("LBL_INP_BE", box_b_x + 12, deck_y + 40, "TRIGGER PRICE:", CLR_TEXT_PURE, 8, true);
      CreateEdit("INP_BE_TRIG", box_b_x + 125, deck_y + 36, 240, 22, "", CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      CreateLabel("LBL_BE_MODE", box_b_x + 12, deck_y + 68, "BE OFFSET MODE:", CLR_TEXT_MED, 8, true);
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
      CreateButton("BTN_BE_MODE", box_b_x + 125, deck_y + 64, 240, 22, mode_str, CLR_CANVAS_BG, mode_clr, CLR_BORDER_HARD);

      // Fixed SL price input (blank = off). Only active in FIXED SL PRICE mode.
      CreateLabel("LBL_BE_PRICE", box_b_x + 12, deck_y + 96, "SL TARGET PRICE:", CLR_TEXT_PURE, 8, true);
      string px_default = (g_be_fixed_price > 0) ? DoubleToString(g_be_fixed_price, _Digits) : "";
      CreateEdit("INP_BE_PRICE", box_b_x + 125, deck_y + 92, 240, 22, px_default,
                 CLR_CANVAS_BG, g_be_offset_mode == BE_OFFSET_CUSTOM_PRICE ? CLR_BULL_NEON : CLR_TEXT_MED);

      CreateButton("BTN_APPLY_BE", box_b_x + 12, deck_y + 126, 190, 26, "ACTIVATE BE TRIGGER", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
      CreateButton("BTN_CANCEL_BE", box_b_x + 210, deck_y + 126, 155, 26, "DEACTIVATE", CLR_PANEL_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
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
   int win_w  = 840;
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
         CreateLabel(r_pfx + "BE",  root_x + 700, cur_y + 3, be_status, be_color, 8, true);
         
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
         CreateLabel(r_pfx + "BE",  root_x + 700, cur_y + 3, "-", CLR_TEXT_MED, 8, false);
         
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
      // Version header (6 = v6 multi-signal reversal radar with active toggle)
      FileWriteInteger(handle, 6);

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
      if(first >= 2 && first <= 6)
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

      FileClose(handle);
   }
}
//+------------------------------------------------------------------+
