//+------------------------------------------------------------------+
//|                                   EngulfingAutoTrader.mq5        |
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "2.20"
#property description "Multi-Rule Auto Execution EA on Realtime Strong Engulfing Break with Flexible Price Bounds & Max Orders Control"

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

struct AutoTraderRule
{
   string               symbol;
   ENUM_TRADE_DIRECTION direction;
   double               risk_reward_ratio;
   ENUM_TIMEFRAMES      timeframe;
   ENUM_LOT_MODE        lot_mode;
   double               lot_value;
   bool                 enable_trail;
   double               trail_trigger_pct;
   double               atr_multiplier;
   string               bull_price_filter; // e.g. "< 1.0850", "<= 1.0820", "4040-4078", "ALL"
   string               bear_price_filter; // e.g. "> 1.0900", ">= 1.0910", "4040-4078", "ALL"
   int                  max_orders;        // 1 = 1x open then paused, 0/-1 = Unlimited
   int                  entry_multiplier;  // Number of positions to open per trigger (1 = 1 order)
   int                  delay_seconds;     // Delay in seconds (5 = default, 0 = instant)
   bool                 delay_is_tf_close; // true = wait for TF candle close, false = seconds delay
   int                  orders_opened_count; // Tracks total opened orders for this rule lifecycle
   bool                 active;
   datetime             last_bull_bar;
   datetime             last_bear_bar;
   datetime             bull_cond_start_time; // Tracks continuous valid seconds for Buy
   datetime             bear_cond_start_time; // Tracks continuous valid seconds for Sell
   datetime             bull_last_checked_bar; // Tracks candle close check
   datetime             bear_last_checked_bar; // Tracks candle close check
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
   bool     active;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== DEFAULT NEW RULE SETTINGS ==="
input ENUM_TRADE_DIRECTION InpTradeDirection   = TRADE_DIR_BOTH; // Default Direction
input double               InpRiskRewardRatio  = 2.0;            // Default RR Ratio (1:RR)
input int                  InpMaxOrders        = 1;              // Default Max Orders (1 = 1x open then paused, 0 = Unlimited)
input int                  InpEntryMultiplier  = 1;              // Default Entry Multiplier (Multi-Position per Trigger)
input int                  InpDelaySeconds     = 5;              // Default Entry Delay Seconds (0 = Instant)
input bool                 InpDelayIsTfClose   = false;          // Default Entry Delay Mode (false = Seconds, true = TF Close)
input int                  InpSlippage         = 10;             // Max Slippage (Points)
input ulong                InpMagicNumber      = 882201;         // Magic Number

input group "=== AUTO TRAIL SL & TP ENGINE ==="
input bool                 InpEnableTrail      = true;           // Default Enable Trail SL & TP
input double               InpTrailTriggerPct  = 5.0;            // Sisa Jarak Menuju TP Trigger (%)
input double               InpATRMultiplier    = 1.5;            // Min ATR Multiplier for Trail TP (>= 1.5x)

input group "=== NOTIFICATIONS & ALERTS ==="
input bool                 InpEnablePushAlerts = true;           // Send Mobile Push Notifications
input bool                 InpEnableSoundAlerts= true;           // Enable Terminal / Sound Alerts

input group "=== MONEY MANAGEMENT ==="
input ENUM_LOT_MODE        InpLotMode          = LOT_RISK_PCT;   // Default Lot Mode
input double               InpFixedLot         = 0.01;           // Default Fixed Lot Size
input double               InpRiskPercent      = 1.0;            // Default Risk Percent (% Balance)

input group "=== ENGULFING & ATR SETTINGS ==="
input ENUM_TIMEFRAMES      InpTimeframe        = PERIOD_M1;      // Default Timeframe
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
ENUM_TIMEFRAMES      g_form_tf          = PERIOD_M1;
ENUM_LOT_MODE        g_form_lot_mode    = LOT_RISK_PCT;
double               g_form_lot_val     = 1.0;
bool                 g_form_trail_on    = true;
double               g_form_trail_pct   = 5.0;
double               g_form_atr_mult    = 1.5;
int                  g_form_max_orders  = 1;
int                  g_form_entry_mult  = 1;
int                  g_form_delay_sec   = 5;
bool                 g_form_delay_close = false;
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

//+------------------------------------------------------------------+
//| REALTIME STRONG BULLISH ENGULFING BREAK DETECTION                |
//+------------------------------------------------------------------+
bool IsStrongBullishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf,
                                   double &out_atr_50, double &out_broken_low, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, 0, 3, rates) < 3) return false;
   
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
   {
      out_atr_50 = CalculateATR50(sym, tf, InpATRPeriod);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| REALTIME STRONG BEARISH ENGULFING BREAK DETECTION                |
//+------------------------------------------------------------------+
bool IsStrongBearishEngulfingBreak(const string sym, const ENUM_TIMEFRAMES tf,
                                   double &out_atr_50, double &out_broken_high, double &out_cur_price)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, 0, 3, rates) < 3) return false;
   
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
   bool is_stronger_body   = ((prev_close - prev_open) < (cur_open - cur_close) * InpBodyRatioMult);
   
   if(is_bearish_running && is_breaking_low && is_covering_high && is_stronger_body)
   {
      out_atr_50 = CalculateATR50(sym, tf, InpATRPeriod);
      return true;
   }
   return false;
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
      
      double trigger_ratio = g_tracking_list[i].trail_trigger_pct / 100.0;
      if(trigger_ratio <= 0) trigger_ratio = 0.05;
      
      double current_atr100 = CalculateATR100(sym, g_tracking_list[i].timeframe, InpATRPeriod);
      double required_atr   = g_tracking_list[i].initial_atr100 * g_tracking_list[i].atr_multiplier;
      bool atr_exploding    = (current_atr100 >= required_atr);
      
      if(ptype == POSITION_TYPE_BUY)
      {
         double total_dist = cur_tp - open_p;
         if(total_dist <= 0) continue;
         
         double remaining_dist = cur_tp - bid;
         if(remaining_dist <= total_dist * trigger_ratio && bid > open_p)
         {
            if(g_tracking_list[i].trail_cycle == 0)
            {
               double be_sl = NormalizeDouble(open_p + spread, digits);
               if(be_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL moved to BE\nNew SL: %.5f", sym, tkt, be_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, be_sl > cur_sl ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: TP Extended\nNew TP: %.5f", sym, tkt, new_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
            else if(g_tracking_list[i].trail_cycle >= 1)
            {
               double prev_tp = g_tracking_list[i].prev_tp_level;
               double new_sl  = NormalizeDouble(prev_tp, digits);
               if(new_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, new_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL locked to Prev TP\nNew SL: %.5f", sym, tkt, new_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, new_sl > cur_sl ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f", sym, tkt, g_tracking_list[i].trail_cycle, new_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
         }
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double total_dist = open_p - cur_tp;
         if(total_dist <= 0) continue;
         
         double remaining_dist = ask - cur_tp;
         if(remaining_dist <= total_dist * trigger_ratio && ask < open_p)
         {
            if(g_tracking_list[i].trail_cycle == 0)
            {
               double be_sl = NormalizeDouble(open_p - spread, digits);
               if(cur_sl == 0 || be_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL moved to BE\nNew SL: %.5f", sym, tkt, be_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || be_sl < cur_sl) ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: TP Extended\nNew TP: %.5f", sym, tkt, new_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
            }
            else if(g_tracking_list[i].trail_cycle >= 1)
            {
               double prev_tp = g_tracking_list[i].prev_tp_level;
               double new_sl  = NormalizeDouble(prev_tp, digits);
               if(cur_sl == 0 || new_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, new_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL locked to Prev TP\nNew SL: %.5f", sym, tkt, new_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                  }
               }
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || new_sl < cur_sl) ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f", sym, tkt, g_tracking_list[i].trail_cycle, new_tp);
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
   if(SymbolInfoInteger(input_sym, SYMBOL_SELECT)) return input_sym;
   if(SymbolSelect(input_sym, true)) return input_sym;
   
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
   int win_w  = 840;
   int win_h  = 540;
   
   CreateRect("WIN_BG", root_x, root_y, win_w, win_h, CLR_PANEL_BG, CLR_BORDER_HARD);
   CreateRect("WIN_TOP", root_x, root_y, win_w, 36, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("WIN_TITLE", root_x + 14, root_y + 9, "ENGULFING AUTO TRADER", CLR_TEXT_PURE, 10, true);
   CreateLabel("WIN_TAG", root_x + 220, root_y + 10, "[MULTI-RULE REALTIME TICK ENGINE]", CLR_CYAN_NEON, 8, true);
   
   string status_txt = g_master_power_enabled ? "ALL ACTIVE" : "ALL PAUSED";
   color status_bg  = g_master_power_enabled ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
   color status_clr = g_master_power_enabled ? CLR_BULL_NEON : CLR_BEAR_NEON;
   CreateButton("BTN_TOGGLE_MASTER", root_x + win_w - 115, root_y + 6, 100, 24, status_txt, status_bg, status_clr, status_clr);
   
   int upper_y = root_y + 44;
   int form_w  = 410;
   int prev_w  = win_w - form_w - 36;
   int prev_x  = root_x + form_w + 22;
   
   // 1A. Form Deck (Kiri)
   CreateRect("CARD_FORM_DECK", root_x + 14, upper_y, form_w, 232, CLR_CARD_BG, CLR_BORDER_HARD);
   
   string form_header_txt = (g_editing_rule_idx >= 0) ? StringFormat("EDIT RULE #%d CONFIGURATION", g_editing_rule_idx + 1) : "ADD AUTO TRADER RULE";
   color form_header_clr = (g_editing_rule_idx >= 0) ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateLabel("LBL_FORM_HEADER", root_x + 22, upper_y + 6, form_header_txt, form_header_clr, 9, true);
   
   // Row A: Symbol & Direction Toggle Buttons (y = upper_y + 24)
   int row_a_y = upper_y + 24;
   CreateLabel("LBL_SYM", root_x + 22, row_a_y + 3, "SYMBOL:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_SYM", root_x + 95, row_a_y, 75, 20, g_form_sym, CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   color btn_both_bg = (g_form_direction == TRADE_DIR_BOTH) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color btn_both_cl = (g_form_direction == TRADE_DIR_BOTH) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   color btn_buy_bg  = (g_form_direction == TRADE_DIR_BUY) ? CLR_POWER_ON_BG : CLR_PANEL_BG;
   color btn_buy_cl  = (g_form_direction == TRADE_DIR_BUY) ? CLR_BULL_NEON : CLR_TEXT_MED;
   color btn_sell_bg = (g_form_direction == TRADE_DIR_SELL) ? CLR_POWER_OFF_BG : CLR_PANEL_BG;
   color btn_sell_cl = (g_form_direction == TRADE_DIR_SELL) ? CLR_BEAR_NEON : CLR_TEXT_MED;
   
   CreateButton("BTN_DIR_BOTH", root_x + 178, row_a_y, 78, 20, "BUY & SELL", btn_both_bg, btn_both_cl, btn_both_cl);
   CreateButton("BTN_DIR_BUY",  root_x + 260, row_a_y, 74, 20, "BUY ONLY",  btn_buy_bg,  btn_buy_cl,  btn_buy_cl);
   CreateButton("BTN_DIR_SELL", root_x + 338, row_a_y, 76, 20, "SELL ONLY", btn_sell_bg, btn_sell_cl, btn_sell_cl);
   
   // Row B: Risk Reward & Timeframe (y = upper_y + 48)
   int row_b_y = upper_y + 48;
   CreateLabel("LBL_RR", root_x + 22, row_b_y + 3, "RR RATIO:", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_RR", root_x + 95, row_b_y, 85, 20, DoubleToString(g_form_rr, 2), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_TF", root_x + 195, row_b_y + 3, "TF (MIN):", CLR_TEXT_PURE, 8, true);
   int tf_min = 5;
   if(g_form_tf == PERIOD_M1) tf_min = 1;
   else if(g_form_tf == PERIOD_M5) tf_min = 5;
   else if(g_form_tf == PERIOD_M15) tf_min = 15;
   else if(g_form_tf == PERIOD_M30) tf_min = 30;
   else if(g_form_tf == PERIOD_H1) tf_min = 60;
   else if(g_form_tf == PERIOD_H4) tf_min = 240;
   else if(g_form_tf == PERIOD_D1) tf_min = 1440;
   CreateEdit("INP_TF", root_x + 260, row_b_y, 154, 20, IntegerToString(tf_min), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   // Row C: Lot Mode, Value & Max Orders (y = upper_y + 72)
   int row_c_y = upper_y + 72;
   CreateLabel("LBL_LOT_MODE", root_x + 22, row_c_y + 3, "LOT MODE:", CLR_TEXT_PURE, 8, true);
   string lot_mode_str = (g_form_lot_mode == LOT_FIXED) ? "FIXED LOT" : "% RISK";
   color lot_mode_clr = (g_form_lot_mode == LOT_FIXED) ? CLR_CYAN_NEON : CLR_GOLD_NEON;
   CreateButton("BTN_TOGGLE_LOT_MODE", root_x + 95, row_c_y, 75, 20, lot_mode_str, CLR_CANVAS_BG, lot_mode_clr, CLR_BORDER_HARD);
   
   CreateEdit("INP_LOT", root_x + 174, row_c_y, 55, 20, DoubleToString(g_form_lot_val, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   CreateLabel("LBL_MAX_ORD", root_x + 235, row_c_y + 3, "MAX ORD:", CLR_TEXT_MED, 7, true);
   string max_ord_str = (g_form_max_orders <= 0) ? "UNL" : IntegerToString(g_form_max_orders);
   CreateEdit("INP_MAX_ORD", root_x + 295, row_c_y, 45, 20, max_ord_str, CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   string max_btn_lbl = (g_form_max_orders <= 0) ? "UNL" : IntegerToString(g_form_max_orders) + "x PAUSE";
   CreateButton("BTN_TOGGLE_MAX_ORD", root_x + 344, row_c_y, 70, 20, max_btn_lbl, CLR_PANEL_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
   
   // Row D: Auto Trail Toggle & Parameters (y = upper_y + 96)
   int row_d_y = upper_y + 96;
   CreateLabel("LBL_TRAIL", root_x + 22, row_d_y + 3, "TRAIL:", CLR_TEXT_PURE, 8, true);
   string trail_mode_str = g_form_trail_on ? "ON" : "OFF";
   color trail_mode_clr = g_form_trail_on ? CLR_GOLD_NEON : CLR_TEXT_MED;
   CreateButton("BTN_TOGGLE_TRAIL", root_x + 65, row_d_y, 38, 20, trail_mode_str, CLR_CANVAS_BG, trail_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_TRAIL_PCT", root_x + 108, row_d_y + 3, "TP%:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_TRAIL_PCT", root_x + 138, row_d_y, 40, 20, DoubleToString(g_form_trail_pct, 1), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   CreateLabel("LBL_ATR_MULT_LBL", root_x + 183, row_d_y + 3, "ATR:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_ATR_MULT", root_x + 215, row_d_y, 40, 20, DoubleToString(g_form_atr_mult, 1), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_MULT", root_x + 260, row_d_y + 3, "MULT:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_MULT", root_x + 300, row_d_y, 35, 20, IntegerToString(g_form_entry_mult), CLR_CANVAS_BG, CLR_GOLD_NEON);
   CreateLabel("LBL_X", root_x + 340, row_d_y + 3, "x", CLR_CYAN_NEON, 8, true);
   
   // Row G: Entry Delay & Mode (y = upper_y + 120)
   int row_g_y = upper_y + 120;
   CreateLabel("LBL_DELAY_MODE", root_x + 22, row_g_y + 3, "DELAY MODE:", CLR_TEXT_PURE, 8, true);
   string delay_mode_str = g_form_delay_close ? "TF CLOSE" : "SECONDS";
   color delay_mode_clr = g_form_delay_close ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateButton("BTN_TOGGLE_DELAY_MODE", root_x + 105, row_g_y, 85, 20, delay_mode_str, CLR_CANVAS_BG, delay_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_DELAY_SEC", root_x + 205, row_g_y + 3, "SEC:", CLR_TEXT_MED, 7, true);
   CreateEdit("INP_DELAY_SEC", root_x + 238, row_g_y, 45, 20, IntegerToString(g_form_delay_sec), CLR_CANVAS_BG, CLR_GOLD_NEON);
   CreateLabel("LBL_SEC_UNIT", root_x + 288, row_g_y + 3, "s (0=Inst)", CLR_TEXT_MED, 7, false);
   
   // Row E: Dynamic Price Bounds based on Direction (y = upper_y + 146)
   int row_e_y = upper_y + 146;
   if(g_form_direction == TRADE_DIR_BOTH)
   {
      CreateLabel("LBL_BULL_MAX", root_x + 22, row_e_y + 3, "BUY BD:", CLR_BULL_NEON, 8, true);
      CreateEdit("INP_BULL_MAX", root_x + 75, row_e_y, 140, 20, g_form_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
      
      CreateLabel("LBL_BEAR_MIN", root_x + 225, row_e_y + 3, "SELL BD:", CLR_BEAR_NEON, 8, true);
      CreateEdit("INP_BEAR_MIN", root_x + 278, row_e_y, 136, 20, g_form_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   else if(g_form_direction == TRADE_DIR_BUY)
   {
      CreateLabel("LBL_BULL_MAX", root_x + 22, row_e_y + 3, "BUY BOUND (cth: <1.0850 atau 4040-4078):", CLR_BULL_NEON, 8, true);
      CreateEdit("INP_BULL_MAX", root_x + 265, row_e_y, 149, 20, g_form_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   else if(g_form_direction == TRADE_DIR_SELL)
   {
      CreateLabel("LBL_BEAR_MIN", root_x + 22, root_x + 22, row_e_y + 3, "SELL BOUND (cth: >1.0900 atau 4040-4078):", CLR_BEAR_NEON, 8, true);
      CreateEdit("INP_BEAR_MIN", root_x + 265, row_e_y, 149, 20, g_form_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   }
   
   // Row F: Form Action Buttons (y = upper_y + 176)
   int row_f_y = upper_y + 176;
   if(g_editing_rule_idx >= 0)
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_f_y, 215, 26, "UPDATE RULE #" + IntegerToString(g_editing_rule_idx + 1), CLR_TAB_ACTIVE_BG, CLR_GOLD_NEON, CLR_GOLD_NEON);
      CreateButton("BTN_DEFAULT_RULE", root_x + 242, row_f_y, 80, 26, "DEFAULT", CLR_CARD_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
      CreateButton("BTN_CANCEL_EDIT", root_x + 327, row_f_y, 87, 26, "CANCEL", CLR_CARD_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
   }
   else
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_f_y, 310, 26, "+ ADD AUTO TRADER RULE", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
      CreateButton("BTN_DEFAULT_RULE", root_x + 337, row_f_y, 77, 26, "DEFAULT", CLR_CARD_BG, CLR_CYAN_NEON, CLR_BORDER_HARD);
   }
   
   // 1B. Live Simulation & Active Settings Box (Kanan)
   CreateRect("CARD_SIM_BOX", prev_x, upper_y, prev_w, 205, CLR_CANVAS_BG, CLR_BORDER_HARD);
   CreateRect("SIM_BOX_TOP", prev_x, upper_y, prev_w, 24, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("SIM_BOX_TITLE", prev_x + 10, upper_y + 5, "ACTIVE SETTINGS & TRAIL SIMULATION", CLR_CYAN_NEON, 8, true);
   CreateLabel("SIM_BOX_TAG", prev_x + prev_w - 95, upper_y + 5, "[LIVE ENGINE]", CLR_GOLD_NEON, 8, true);
   
   // ================= SECTION 2: RULES TABLE (BOTTOM) =================
   int table_y = upper_y + 215;
   CreateRect("CARD_TABLE", root_x + 14, table_y, win_w - 28, 260, CLR_CANVAS_BG, CLR_BORDER_HARD);
   
   // Table Header Bar
   CreateRect("TH_BG", root_x + 14, table_y, win_w - 28, 24, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("TH_NO",     root_x + 24,  table_y + 6, "NO",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_SYM",    root_x + 55,  table_y + 6, "SYMBOL",    CLR_TEXT_MED, 8, true);
   CreateLabel("TH_DIR",    root_x + 130, table_y + 6, "DIRECTION", CLR_TEXT_MED, 8, true);
   CreateLabel("TH_LOT",    root_x + 210, table_y + 6, "LOT/RISK",  CLR_TEXT_MED, 8, true);
   CreateLabel("TH_RR",     root_x + 285, table_y + 6, "RR",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_TF",     root_x + 340, table_y + 6, "TF",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_MAX",    root_x + 375,  table_y + 6, "MAX",       CLR_TEXT_MED, 8, true);
   CreateLabel("TH_MULT",   root_x + 412,  table_y + 6, "MULT",      CLR_GOLD_NEON, 8, true);
   CreateLabel("TH_DELAY",  root_x + 450,  table_y + 6, "DELAY",     CLR_CYAN_NEON, 8, true);
   CreateLabel("TH_FILTER", root_x + 495,  table_y + 6, "PRICE BOUNDS", CLR_TEXT_MED, 8, true);
   CreateLabel("TH_TRAIL",  root_x + 575, table_y + 6, "AUTO TRAIL",CLR_TEXT_MED, 8, true);
   CreateLabel("TH_STATUS", root_x + 680, table_y + 6, "STATUS",    CLR_TEXT_MED, 8, true);
   CreateLabel("TH_ACT",    root_x + 750, table_y + 6, "ACTIONS",   CLR_TEXT_MED, 8, true);
   
   UpdatePreviewTerminalBox();
   UpdateDashboardUI();
   ChartRedraw();
}

void UpdatePreviewTerminalBox()
{
   int root_x  = 20;
   int root_y  = 20;
   int win_w   = 840;
   int upper_y = root_y + 44;
   int form_w  = 410;
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
      if(g_rules[idx].direction == TRADE_DIR_BUY)  prev_dir = "BUY ONLY";
      else if(g_rules[idx].direction == TRADE_DIR_SELL) prev_dir = "SELL ONLY";
      prev_rule_tag = StringFormat("[RULE #%d PREVIEW]", idx + 1);
   }
   
   string l1 = StringFormat("Target: %s (%s) | %s | %s", prev_sym, prev_tf, prev_dir, prev_rule_tag);
   string l2 = StringFormat("Rasio RR: 1:%.2f | Mode Lot: %s | SL Buffer: 50%% ATR(14)", prev_rr, prev_lot);
   string l3 = "-------------------------------------------------------------";
   
   CreateLabel("SIM_L1", prev_x + 10, line_y, l1, CLR_TEXT_PURE, 8, true);
   CreateLabel("SIM_L2", prev_x + 10, line_y + 18, l2, CLR_CYAN_NEON, 8, false);
   CreateLabel("SIM_L3", prev_x + 10, line_y + 32, l3, CLR_BORDER_HARD, 7, false);
   
   if(prev_trail)
   {
      string l4 = StringFormat("Auto Trail SL (BE): Sisa %.1f%% ke TP -> Kunci BE (Open +- Spread)", prev_pct);
      string l5 = StringFormat("Volatility Trail TP: ATR >= %.1fx Entry -> TP +1x Target", prev_atr_m);
      string l6 = StringFormat("Profit Lock (Cycle 2+): Sisa %.1f%% ke TP baru -> SL dikunci di Prev TP", prev_pct);
      
      CreateLabel("SIM_L4", prev_x + 10, line_y + 46, l4, CLR_GOLD_NEON, 8, true);
      CreateLabel("SIM_L5", prev_x + 10, line_y + 68, l5, CLR_CYAN_NEON, 8, false);
      CreateLabel("SIM_L6", prev_x + 10, line_y + 90, l6, CLR_BULL_NEON, 8, true);
      CreateLabel("SIM_L7", prev_x + 10, line_y + 112, "Klik baris rule di tabel bawah untuk mengganti preview", CLR_TEXT_MED, 7, false);
   }
   else
   {
      CreateLabel("SIM_L4", prev_x + 10, line_y + 50, "Auto Trail Engine: OFF", CLR_BEAR_NEON, 8, true);
      CreateLabel("SIM_L5", prev_x + 10, line_y + 72, "Take Profit & Stop Loss tetap di level awal tanpa trailing.", CLR_TEXT_MED, 8, false);
      CreateLabel("SIM_L6", prev_x + 10, line_y + 112, "Klik baris rule di tabel bawah untuk mengganti preview", CLR_TEXT_MED, 7, false);
   }
}

void UpdateDashboardUI()
{
   int root_x  = 20;
   int root_y  = 20;
   int win_w   = 840;
   int table_y = root_y + 44 + 215;
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
      CreateLabel("ROW_EMPTY", root_x + 300, start_y + 20, "Belum ada aturan Auto Trader. Tambahkan rule di atas!", CLR_TEXT_MED, 9, false);
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
      
      string lot_str = (g_rules[i].lot_mode == LOT_FIXED) ? DoubleToString(g_rules[i].lot_value, 2) + "L" : DoubleToString(g_rules[i].lot_value, 1) + "%R";
      CreateLabel(r_pfx + "LOT", root_x + 210, cur_y + 9, lot_str, CLR_TEXT_PURE, 8, false);
      
      CreateLabel(r_pfx + "RR", root_x + 285, cur_y + 9, StringFormat("1:%.1f", g_rules[i].risk_reward_ratio), CLR_CYAN_NEON, 8, true);
      
      string str_tf = StringSubstr(EnumToString(g_rules[i].timeframe), 7);
      CreateLabel(r_pfx + "TF", root_x + 340, cur_y + 9, "[" + str_tf + "]", CLR_GOLD_NEON, 8, true);
      
      string max_ord_disp = (g_rules[i].max_orders <= 0) ? "UNL" : IntegerToString(g_rules[i].max_orders);
      CreateLabel(r_pfx + "MAX", root_x + 375, cur_y + 9, max_ord_disp, CLR_TEXT_PURE, 8, true);
      
      int mult_disp = (g_rules[i].entry_multiplier <= 0) ? 1 : g_rules[i].entry_multiplier;
      CreateLabel(r_pfx + "MULT", root_x + 412, cur_y + 9, IntegerToString(mult_disp) + "x", CLR_GOLD_NEON, 8, true);
      
      string delay_disp = g_rules[i].delay_is_tf_close ? "TF Close" : (IntegerToString(g_rules[i].delay_seconds) + "s");
      CreateLabel(r_pfx + "DELAY", root_x + 450, cur_y + 9, delay_disp, CLR_CYAN_NEON, 8, false);
      
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
      CreateLabel(r_pfx + "FLT", root_x + 495, cur_y + 9, f_str, CLR_TEXT_MED, 7, false);
      
      string trail_str = g_rules[i].enable_trail ? StringFormat("ON (%.1f%%, %.1fx)", g_rules[i].trail_trigger_pct, g_rules[i].atr_multiplier) : "OFF";
      CreateLabel(r_pfx + "TRL", root_x + 575, cur_y + 9, trail_str, g_rules[i].enable_trail ? CLR_GOLD_NEON : CLR_TEXT_MED, 8, false);
      
      string r_status_txt = g_rules[i].active ? "ACTIVE" : "PAUSED";
      color  r_status_bg  = g_rules[i].active ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
      color  r_status_clr = g_rules[i].active ? CLR_BULL_NEON : CLR_BEAR_NEON;
      CreateButton("BTN_TOGGLE_RULE_" + IntegerToString(i), root_x + 675, cur_y + 5, 58, 22, r_status_txt, r_status_bg, r_status_clr, r_status_clr);
      
      CreateButton("BTN_EDIT_RULE_" + IntegerToString(i), root_x + 740, cur_y + 5, 42, 22, "EDIT", is_selected ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_selected ? CLR_GOLD_NEON : CLR_CYAN_NEON, is_selected ? CLR_GOLD_NEON : CLR_BORDER_HARD);
      CreateButton("BTN_DEL_RULE_"  + IntegerToString(i), root_x + 786, cur_y + 5, 38, 22, "DEL",  C'34,8,18', CLR_BEAR_NEON, CLR_BEAR_NEON);
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
//| PERSISTENCE (SAVE / LOAD STATE TO FILE)                          |
//+------------------------------------------------------------------+
void SaveStateToFile()
{
   string filename = "EAT_MultiRules_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   int handle = FileOpen(filename, FILE_WRITE|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      FileWriteInteger(handle, g_master_power_enabled ? 1 : 0);
      
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
         FileWriteInteger(handle, g_rules[i].delay_seconds);
         FileWriteInteger(handle, g_rules[i].delay_is_tf_close ? 1 : 0);
         FileWriteInteger(handle, g_rules[i].orders_opened_count);
         FileWriteInteger(handle, g_rules[i].active ? 1 : 0);
      }
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
      g_rules[0].atr_multiplier    = InpATRMultiplier;
      g_rules[0].bull_price_filter = "ALL";
      g_rules[0].bear_price_filter = "ALL";
      g_rules[0].max_orders        = InpMaxOrders;
      g_rules[0].entry_multiplier  = InpEntryMultiplier;
      g_rules[0].delay_seconds     = InpDelaySeconds;
      g_rules[0].delay_is_tf_close = InpDelayIsTfClose;
      g_rules[0].orders_opened_count = 0;
      g_rules[0].active            = true;
      g_rules[0].last_bull_bar     = 0;
      g_rules[0].last_bear_bar     = 0;
      g_rules[0].bull_cond_start_time = 0;
      g_rules[0].bear_cond_start_time = 0;
      g_rules[0].bull_last_checked_bar = 0;
      g_rules[0].bear_last_checked_bar = 0;
      return;
   }
   
   int handle = FileOpen(filename, FILE_READ|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      g_master_power_enabled = (FileReadInteger(handle) == 1);
      int total_rules = FileReadInteger(handle);
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
         g_rules[i].delay_seconds     = FileReadInteger(handle);
         g_rules[i].delay_is_tf_close = (FileReadInteger(handle) == 1);
         g_rules[i].orders_opened_count = FileReadInteger(handle);
         g_rules[i].active            = (FileReadInteger(handle) == 1);
         g_rules[i].last_bull_bar     = 0;
         g_rules[i].last_bear_bar     = 0;
         g_rules[i].bull_cond_start_time = 0;
         g_rules[i].bear_cond_start_time = 0;
         g_rules[i].bull_last_checked_bar = 0;
         g_rules[i].bear_last_checked_bar = 0;
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
   
   PrintFormat("EngulfingAutoTrader Initialized | Multi-Rules Active: %d rules loaded", ArraySize(g_rules));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveStateToFile();
   DestroyDashboardUI();
   Print("EngulfingAutoTrader Deinitialized.");
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
         
         int cur_mult = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MULT", OBJPROP_TEXT));
         if(cur_mult > 0) g_form_entry_mult = cur_mult;
         
         int cur_sec = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
         if(cur_sec >= 0) g_form_delay_sec = cur_sec;
         
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
         int cur_sec = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
         if(cur_sec >= 0) g_form_delay_sec = cur_sec;
         
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
         g_form_atr_mult   = InpATRMultiplier;
         g_form_max_orders = InpMaxOrders;
         g_form_entry_mult = InpEntryMultiplier;
         g_form_delay_sec  = InpDelaySeconds;
         g_form_delay_close= InpDelayIsTfClose;
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
         if(atr_mult <= 0) atr_mult = 2.0;
         
         int max_ord_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MAX_ORD", OBJPROP_TEXT));
         
         int mult_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_MULT", OBJPROP_TEXT));
         if(mult_val <= 0) mult_val = 1;
         
         int delay_sec_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_DELAY_SEC", OBJPROP_TEXT));
         if(delay_sec_val < 0) delay_sec_val = 0;
         
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
         g_form_delay_sec = delay_sec_val;
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
         g_rules[target_idx].delay_seconds       = delay_sec_val;
         g_rules[target_idx].delay_is_tf_close   = g_form_delay_close;
         g_rules[target_idx].last_bull_bar       = 0;
         g_rules[target_idx].last_bear_bar       = 0;
         g_rules[target_idx].bull_cond_start_time = 0;
         g_rules[target_idx].bear_cond_start_time = 0;
         g_rules[target_idx].bull_last_checked_bar = 0;
         g_rules[target_idx].bear_last_checked_bar = 0;
         
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
            sparam == g_prefix + r_pfx + "TRL")
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
            g_form_delay_sec    = g_rules[i].delay_seconds;
            g_form_delay_close  = g_rules[i].delay_is_tf_close;
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
      
      string sym = g_rules[r].symbol;
      ENUM_TIMEFRAMES tf = g_rules[r].timeframe;
      
      if(!m_symbol_info.Name(sym)) continue;
      m_symbol_info.RefreshRates();
      
      double ask = m_symbol_info.Ask();
      double bid = m_symbol_info.Bid();
      double spread = ask - bid;
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      
      datetime cur_bar_time = (datetime)SeriesInfoInteger(sym, tf, SERIES_LASTBAR_DATE);
      
      double atr_50 = 0.0;
      double broken_level = 0.0;
      double cur_price = 0.0;
      
      // A. CHECK BUY (Strong Bullish Break)
      if(g_rules[r].direction == TRADE_DIR_BOTH || g_rules[r].direction == TRADE_DIR_BUY)
      {
         bool is_bull_valid = IsStrongBullishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price) && EvaluatePriceFilter(cur_price, g_rules[r].bull_price_filter);
         
         if(is_bull_valid)
         {
            datetime cur_bar_open_time = (datetime)SeriesInfoInteger(sym, tf, SERIES_LASTBAR_DATE);
            
            // Check if already traded this bar
            if(g_rules[r].last_bull_bar != cur_bar_open_time)
            {
               bool trigger_buy = false;
               
               if(g_rules[r].delay_is_tf_close)
               {
                  // Mode TF Close: Check if candle closed and condition was met during the candle
                  if(g_rules[r].bull_last_checked_bar != cur_bar_open_time)
                  {
                     g_rules[r].bull_last_checked_bar = cur_bar_open_time;
                     // We check if the completed candle (rates[1] or rates[2]) satisfied engulfing
                     // Actually, if we are at a new bar, candle [1] just closed. Let's verify if candle [1] was a strong engulfing break!
                     // Let's check completed candle [1] vs [2]
                     MqlRates r_check[];
                     ArraySetAsSeries(r_check, true);
                     if(CopyRates(sym, tf, 1, 2, r_check) >= 2)
                     {
                        bool c_bull = (r_check[0].close > r_check[0].open);
                        bool c_break = (r_check[0].close >= r_check[1].high || r_check[0].high >= r_check[1].high);
                        bool c_cover = (r_check[0].low <= r_check[1].low);
                        bool c_body  = ((r_check[0].close - r_check[0].open) > (r_check[1].open - r_check[1].close) * InpBodyRatioMult);
                        
                        if(c_bull && c_break && c_cover && c_body && EvaluatePriceFilter(r_check[0].close, g_rules[r].bull_price_filter))
                        {
                           trigger_buy = true;
                           g_rules[r].last_bull_bar = cur_bar_open_time;
                        }
                     }
                  }
               }
               else
               {
                  // Mode Seconds Delay
                  int d_sec = g_rules[r].delay_seconds;
                  if(d_sec <= 0)
                  {
                     // Instant entry
                     trigger_buy = true;
                     g_rules[r].last_bull_bar = cur_bar_open_time;
                  }
                  else
                  {
                     datetime now_time = TimeCurrent();
                     if(g_rules[r].bull_cond_start_time == 0)
                     {
                        g_rules[r].bull_cond_start_time = now_time;
                     }
                     else if((int)(now_time - g_rules[r].bull_cond_start_time) >= d_sec)
                     {
                        trigger_buy = true;
                        g_rules[r].last_bull_bar = cur_bar_open_time;
                        g_rules[r].bull_cond_start_time = 0;
                     }
                  }
               }
               
               if(trigger_buy)
               {
                  double sl_price = broken_level - atr_50;
                  double sl_dist  = ask - sl_price;
                  
                  if(sl_dist > 0)
                  {
                     double tp_price = ask + (sl_dist * g_rules[r].risk_reward_ratio);
                     sl_price = NormalizeDouble(sl_price, digits);
                     tp_price = NormalizeDouble(tp_price, digits);
                     double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, ask, sl_price);
                     
                     int mult = g_rules[r].entry_multiplier;
                     if(mult <= 0) mult = 1;
                     
                     for(int m = 0; m < mult; m++)
                     {
                        if(m_trade.Buy(lots, sym, ask, sl_price, tp_price, StringFormat("Engulfing Buy #%d (RR 1:%.1f)", m + 1, g_rules[r].risk_reward_ratio)))
                        {
                           ulong deal_tkt = m_trade.ResultOrder();
                           g_rules[r].orders_opened_count++;
                           SaveStateToFile();
                           
                           double atr100 = atr_50 * 2.0;
                           if(g_rules[r].enable_trail)
                           {
                              RegisterPositionTracking(deal_tkt, sym, tf, atr100, ask, tp_price, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                           }
                           
                           string msg = StringFormat("[AUTO TRADER - ORDER OPENED (%d/%d)]\nSymbol: %s (%s)\nTicket: #%d (BUY)\nLot: %.2f | Ask: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)",
                                                     m + 1, mult, sym, EnumToString(tf), deal_tkt, lots, ask, sl_price, tp_price, g_rules[r].risk_reward_ratio);
                           if(InpEnableSoundAlerts) Alert(msg);
                           if(InpEnablePushAlerts)  SendNotification(msg);
                        }
                     }
                  }
               }
            }
         }
         else
         {
            // Condition broken: reset seconds timer
            g_rules[r].bull_cond_start_time = 0;
         }
      }
      
      // B. CHECK SELL (Strong Bearish Break)
      if(g_rules[r].direction == TRADE_DIR_BOTH || g_rules[r].direction == TRADE_DIR_SELL)
      {
         bool is_bear_valid = IsStrongBearishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price) && EvaluatePriceFilter(cur_price, g_rules[r].bear_price_filter);
         
         if(is_bear_valid)
         {
            datetime cur_bar_open_time = (datetime)SeriesInfoInteger(sym, tf, SERIES_LASTBAR_DATE);
            
            if(g_rules[r].last_bear_bar != cur_bar_open_time)
            {
               bool trigger_sell = false;
               
               if(g_rules[r].delay_is_tf_close)
               {
                  if(g_rules[r].bear_last_checked_bar != cur_bar_open_time)
                  {
                     g_rules[r].bear_last_checked_bar = cur_bar_open_time;
                     MqlRates r_check[];
                     ArraySetAsSeries(r_check, true);
                     if(CopyRates(sym, tf, 1, 2, r_check) >= 2)
                     {
                        bool c_bear = (r_check[0].close < r_check[0].open);
                        bool c_break = (r_check[0].close <= r_check[1].low || r_check[0].low <= r_check[1].low);
                        bool c_cover = (r_check[0].high >= r_check[1].high);
                        bool c_body  = ((r_check[0].open - r_check[0].close) > (r_check[1].close - r_check[1].open) * InpBodyRatioMult);
                        
                        if(c_bear && c_break && c_cover && c_body && EvaluatePriceFilter(r_check[0].close, g_rules[r].bear_price_filter))
                        {
                           trigger_sell = true;
                           g_rules[r].last_bear_bar = cur_bar_open_time;
                        }
                     }
                  }
               }
               else
               {
                  int d_sec = g_rules[r].delay_seconds;
                  if(d_sec <= 0)
                  {
                     trigger_sell = true;
                     g_rules[r].last_bear_bar = cur_bar_open_time;
                  }
                  else
                  {
                     datetime now_time = TimeCurrent();
                     if(g_rules[r].bear_cond_start_time == 0)
                     {
                        g_rules[r].bear_cond_start_time = now_time;
                     }
                     else if((int)(now_time - g_rules[r].bear_cond_start_time) >= d_sec)
                     {
                        trigger_sell = true;
                        g_rules[r].last_bear_bar = cur_bar_open_time;
                        g_rules[r].bear_cond_start_time = 0;
                     }
                  }
               }
               
               if(trigger_sell)
               {
                  double sl_price = broken_level + atr_50 + spread;
                  double sl_dist  = sl_price - bid;
                  
                  if(sl_dist > 0)
                  {
                     double tp_price = bid - (sl_dist * g_rules[r].risk_reward_ratio);
                     sl_price = NormalizeDouble(sl_price, digits);
                     tp_price = NormalizeDouble(tp_price, digits);
                     double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, bid, sl_price);
                     
                     int mult_s = g_rules[r].entry_multiplier;
                     if(mult_s <= 0) mult_s = 1;
                     
                     for(int m = 0; m < mult_s; m++)
                     {
                        if(m_trade.Sell(lots, sym, bid, sl_price, tp_price, StringFormat("Engulfing Sell #%d (RR 1:%.1f)", m + 1, g_rules[r].risk_reward_ratio)))
                        {
                           ulong deal_tkt = m_trade.ResultOrder();
                           g_rules[r].orders_opened_count++;
                           SaveStateToFile();
                           
                           double atr100 = atr_50 * 2.0;
                           if(g_rules[r].enable_trail)
                           {
                              RegisterPositionTracking(deal_tkt, sym, tf, atr100, bid, tp_price, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                           }
                           
                           string msg = StringFormat("[AUTO TRADER - ORDER OPENED (%d/%d)]\nSymbol: %s (%s)\nTicket: #%d (SELL)\nLot: %.2f | Bid: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)",
                                                     m + 1, mult_s, sym, EnumToString(tf), deal_tkt, lots, bid, sl_price, tp_price, g_rules[r].risk_reward_ratio);
                           if(InpEnableSoundAlerts) Alert(msg);
                           if(InpEnablePushAlerts)  SendNotification(msg);
                        }
                     }
                  }
               }
            }
         }
         else
         {
            g_rules[r].bear_cond_start_time = 0;
         }
      }
   }
}
//+------------------------------------------------------------------+
