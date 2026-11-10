//+------------------------------------------------------------------+
//|                                   EngulfingAutoTrader.mq5        |
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "2.10"
#property description "Multi-Rule Auto Execution EA on Realtime Strong Engulfing Break with Auto Trail SL (BE) & Volatility Trail TP Engine"

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

// ponytail: single struct for auto trader rules
struct AutoTraderRule
{
   string               symbol;
   ENUM_TRADE_DIRECTION direction;
   double               risk_reward_ratio;
   ENUM_TIMEFRAMES      timeframe;
   ENUM_LOT_MODE        lot_mode;
   double               lot_value;         // Fixed lot or Risk %
   bool                 enable_trail;
   double               trail_trigger_pct;
   double               atr_multiplier;
   double               bull_price_max;    // 0 = Any price
   double               bear_price_min;    // 0 = Any price
   int                  max_trades;        // 0 = Unlimited
   bool                 active;
   datetime             last_bull_bar;
   datetime             last_bear_bar;
};

struct SPositionTracking
{
   ulong    ticket;
   string   symbol;
   ENUM_TIMEFRAMES timeframe;
   double   initial_atr100;    // 100% ATR of the entry candle
   double   initial_tp_dist;   // Initial distance between Open Price and initial TP
   double   prev_tp_level;     // Level of previous TP target (0.0 for initial)
   int      trail_cycle;       // Cycle count (0 = before BE, 1 = BE active, 2+ = trailing SL to prev TP)
   double   trail_trigger_pct; // Trigger percentage
   double   atr_multiplier;    // ATR multiplier
   bool     active;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== DEFAULT NEW RULE SETTINGS ==="
input ENUM_TRADE_DIRECTION InpTradeDirection   = TRADE_DIR_BOTH; // Default Direction
input double               InpRiskRewardRatio  = 2.0;            // Default RR Ratio (1:RR)
input int                  InpMaxOpenTrades    = 1;              // Default Max Trades (0 = Unlimited)
input int                  InpSlippage         = 10;             // Max Slippage (Points)
input ulong                InpMagicNumber      = 882201;         // Magic Number

input group "=== AUTO TRAIL SL & TP ENGINE ==="
input bool                 InpEnableTrail      = true;           // Default Enable Trail SL & TP
input double               InpTrailTriggerPct  = 5.0;            // Sisa Jarak Menuju TP Trigger (%)
input double               InpATRMultiplier    = 2.0;            // Min ATR Multiplier for Trail TP (>= 2.0x)

input group "=== NOTIFICATIONS & ALERTS ==="
input bool                 InpEnablePushAlerts = true;           // Send Mobile Push Notifications
input bool                 InpEnableSoundAlerts= true;           // Enable Terminal / Sound Alerts

input group "=== MONEY MANAGEMENT ==="
input ENUM_LOT_MODE        InpLotMode          = LOT_FIXED;      // Default Lot Mode
input double               InpFixedLot         = 0.01;           // Default Fixed Lot Size
input double               InpRiskPercent      = 1.0;            // Default Risk Percent (% Balance)

input group "=== ENGULFING & ATR SETTINGS ==="
input ENUM_TIMEFRAMES      InpTimeframe        = PERIOD_M5;      // Default Timeframe
input int                  InpATRPeriod        = 14;             // ATR Period for 50% calculation
input double               InpBodyRatioMult    = 1.0;            // Min Body Ratio vs Previous Candle

// UI Coordinates & Colors (Cyberpunk Pitch-Black Palette)
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
#define CLR_GOLD_NEON       C'255,179,0'   // Luminous Gold
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

// Active Form & Preview States
ENUM_TRADE_DIRECTION g_form_direction   = TRADE_DIR_BOTH;
ENUM_LOT_MODE        g_form_lot_mode    = LOT_FIXED;
bool                 g_form_trail_on    = true;
int                  g_selected_rule_idx = 0;  // Index of rule currently previewed (>=0)
int                  g_editing_rule_idx  = -1; // -1 = Add mode, >=0 = Edit mode

// Rules Storage
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
   bool is_stronger_body   = ((cur_open - cur_close) > (prev_close - prev_open) * InpBodyRatioMult);
   
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
      
      double trigger_ratio = g_tracking_list[i].trail_trigger_pct / 100.0;
      if(trigger_ratio <= 0) trigger_ratio = 0.05;
      
      double current_atr100 = CalculateATR100(sym, g_tracking_list[i].timeframe, InpATRPeriod);
      double required_atr   = g_tracking_list[i].initial_atr100 * g_tracking_list[i].atr_multiplier;
      bool atr_exploding    = (current_atr100 >= required_atr);
      
      // ================= BUY POSITION =================
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
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL moved to Break-Even\nNew SL: %.5f\nEntry: %.5f",
                                               sym, tkt, be_sl, open_p);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL (BE) for BUY #%d | New SL: %.5f", tkt, be_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, be_sl > cur_sl ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: TP Extended (+1x Target)\nNew TP: %.5f\nATR: %.5f (>= %.1fx ATR Awal)",
                                               sym, tkt, new_tp, current_atr100, g_tracking_list[i].atr_multiplier);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP for BUY #%d | New TP: %.5f", tkt, new_tp);
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
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: SL locked to Prev TP\nNew SL: %.5f",
                                               sym, tkt, new_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL locked to Prev TP for BUY #%d | New SL: %.5f", tkt, new_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, new_sl > cur_sl ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (BUY)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f",
                                               sym, tkt, g_tracking_list[i].trail_cycle, new_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Extended for BUY #%d | New TP: %.5f", tkt, new_tp);
                  }
               }
            }
         }
      }
      // ================= SELL POSITION =================
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
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL moved to Break-Even\nNew SL: %.5f\nEntry: %.5f",
                                               sym, tkt, be_sl, open_p);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL (BE) for SELL #%d | New SL: %.5f", tkt, be_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || be_sl < cur_sl) ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: TP Extended (+1x Target)\nNew TP: %.5f\nATR: %.5f (>= %.1fx ATR Awal)",
                                               sym, tkt, new_tp, current_atr100, g_tracking_list[i].atr_multiplier);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP for SELL #%d | New TP: %.5f", tkt, new_tp);
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
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: SL locked to Prev TP\nNew SL: %.5f",
                                               sym, tkt, new_sl);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL locked to Prev TP for SELL #%d | New SL: %.5f", tkt, new_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || new_sl < cur_sl) ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s\nTicket: #%d (SELL)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f",
                                               sym, tkt, g_tracking_list[i].trail_cycle, new_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Extended for SELL #%d | New TP: %.5f", tkt, new_tp);
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
   
   // Outer Pitch-black window
   CreateRect("WIN_BG", root_x, root_y, win_w, win_h, CLR_PANEL_BG, CLR_BORDER_HARD);
   
   // Top header
   CreateRect("WIN_TOP", root_x, root_y, win_w, 36, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("WIN_TITLE", root_x + 14, root_y + 9, "ENGULFING AUTO TRADER", CLR_TEXT_PURE, 10, true);
   CreateLabel("WIN_TAG", root_x + 220, root_y + 10, "[MULTI-RULE REALTIME TICK ENGINE]", CLR_CYAN_NEON, 8, true);
   
   // Master Status Badge
   string status_txt = g_master_power_enabled ? "ALL ACTIVE" : "ALL PAUSED";
   color status_bg  = g_master_power_enabled ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
   color status_clr = g_master_power_enabled ? CLR_BULL_NEON : CLR_BEAR_NEON;
   CreateButton("BTN_TOGGLE_MASTER", root_x + win_w - 115, root_y + 6, 100, 24, status_txt, status_bg, status_clr, status_clr);
   
   // ================= SECTION 1: SIDE-BY-SIDE UPPER DECK =================
   int upper_y = root_y + 44;
   int form_w  = 410;
   int prev_w  = win_w - form_w - 36;
   int prev_x  = root_x + form_w + 22;
   
   // 1A. Form Deck (Kiri)
   CreateRect("CARD_FORM_DECK", root_x + 14, upper_y, form_w, 205, CLR_CARD_BG, CLR_BORDER_HARD);
   
   string form_header_txt = (g_editing_rule_idx >= 0) ? StringFormat("EDIT RULE #%d CONFIGURATION", g_editing_rule_idx + 1) : "ADD AUTO TRADER RULE";
   color form_header_clr = (g_editing_rule_idx >= 0) ? CLR_GOLD_NEON : CLR_CYAN_NEON;
   CreateLabel("LBL_FORM_HEADER", root_x + 22, upper_y + 8, form_header_txt, form_header_clr, 9, true);
   
   // Row A: Symbol & Direction Toggle Buttons (y = upper_y + 28)
   int row_a_y = upper_y + 28;
   CreateLabel("LBL_SYM", root_x + 22, row_a_y + 3, "SYMBOL:", CLR_TEXT_PURE, 8, true);
   string default_sym = (g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules)) ? g_rules[g_editing_rule_idx].symbol : _Symbol;
   CreateEdit("INP_SYM", root_x + 95, row_a_y, 75, 20, default_sym, CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   color btn_both_bg = (g_form_direction == TRADE_DIR_BOTH) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color btn_both_cl = (g_form_direction == TRADE_DIR_BOTH) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   color btn_buy_bg  = (g_form_direction == TRADE_DIR_BUY) ? CLR_POWER_ON_BG : CLR_PANEL_BG;
   color btn_buy_cl  = (g_form_direction == TRADE_DIR_BUY) ? CLR_BULL_NEON : CLR_TEXT_MED;
   color btn_sell_bg = (g_form_direction == TRADE_DIR_SELL) ? CLR_POWER_OFF_BG : CLR_PANEL_BG;
   color btn_sell_cl = (g_form_direction == TRADE_DIR_SELL) ? CLR_BEAR_NEON : CLR_TEXT_MED;
   
   CreateButton("BTN_DIR_BOTH", root_x + 178, row_a_y, 78, 20, "BUY & SELL", btn_both_bg, btn_both_cl, btn_both_cl);
   CreateButton("BTN_DIR_BUY",  root_x + 260, row_a_y, 74, 20, "BUY ONLY",  btn_buy_bg,  btn_buy_cl,  btn_buy_cl);
   CreateButton("BTN_DIR_SELL", root_x + 338, row_a_y, 76, 20, "SELL ONLY", btn_sell_bg, btn_sell_cl, btn_sell_cl);
   
   // Row B: Risk Reward & Timeframe (y = upper_y + 54)
   int row_b_y = upper_y + 54;
   CreateLabel("LBL_RR", root_x + 22, row_b_y + 3, "RR RATIO:", CLR_TEXT_PURE, 8, true);
   double default_rr = (g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules)) ? g_rules[g_editing_rule_idx].risk_reward_ratio : InpRiskRewardRatio;
   CreateEdit("INP_RR", root_x + 95, row_b_y, 85, 20, DoubleToString(default_rr, 2), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_TF", root_x + 195, row_b_y + 3, "TF (MIN):", CLR_TEXT_PURE, 8, true);
   int tf_min = 5;
   if(g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules))
   {
      ENUM_TIMEFRAMES tf_val = g_rules[g_editing_rule_idx].timeframe;
      if(tf_val == PERIOD_M1) tf_min = 1;
      else if(tf_val == PERIOD_M5) tf_min = 5;
      else if(tf_val == PERIOD_M15) tf_min = 15;
      else if(tf_val == PERIOD_M30) tf_min = 30;
      else if(tf_val == PERIOD_H1) tf_min = 60;
      else if(tf_val == PERIOD_H4) tf_min = 240;
      else if(tf_val == PERIOD_D1) tf_min = 1440;
   }
   CreateEdit("INP_TF", root_x + 260, row_b_y, 154, 20, IntegerToString(tf_min), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   // Row C: Lot Mode & Lot Value (y = upper_y + 80)
   int row_c_y = upper_y + 80;
   CreateLabel("LBL_LOT_MODE", root_x + 22, row_c_y + 3, "LOT MODE:", CLR_TEXT_PURE, 8, true);
   string lot_mode_str = (g_form_lot_mode == LOT_FIXED) ? "FIXED LOT" : "% RISK / SL";
   color lot_mode_clr = (g_form_lot_mode == LOT_FIXED) ? CLR_CYAN_NEON : CLR_GOLD_NEON;
   CreateButton("BTN_TOGGLE_LOT_MODE", root_x + 95, row_c_y, 85, 20, lot_mode_str, CLR_CANVAS_BG, lot_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_LOT_VAL", root_x + 195, row_c_y + 3, "VALUE:", CLR_TEXT_PURE, 8, true);
   double default_lot = (g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules)) ? g_rules[g_editing_rule_idx].lot_value : ((g_form_lot_mode == LOT_FIXED) ? InpFixedLot : InpRiskPercent);
   CreateEdit("INP_LOT", root_x + 260, row_c_y, 154, 20, DoubleToString(default_lot, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   // Row D: Auto Trail Toggle & Parameters (y = upper_y + 106)
   int row_d_y = upper_y + 106;
   CreateLabel("LBL_TRAIL", root_x + 22, row_d_y + 3, "AUTO TRAIL:", CLR_TEXT_PURE, 8, true);
   string trail_mode_str = g_form_trail_on ? "ON" : "OFF";
   color trail_mode_clr = g_form_trail_on ? CLR_GOLD_NEON : CLR_TEXT_MED;
   CreateButton("BTN_TOGGLE_TRAIL", root_x + 95, row_d_y, 42, 20, trail_mode_str, CLR_CANVAS_BG, trail_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_TRAIL_PCT", root_x + 145, row_d_y + 3, "SISA%:", CLR_TEXT_MED, 7, true);
   double default_trail_pct = (g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules)) ? g_rules[g_editing_rule_idx].trail_trigger_pct : InpTrailTriggerPct;
   CreateEdit("INP_TRAIL_PCT", root_x + 185, row_d_y, 45, 20, DoubleToString(default_trail_pct, 1), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   CreateLabel("LBL_ATR_MULT_LBL", root_x + 240, row_d_y + 3, "MIN ATR:", CLR_TEXT_MED, 7, true);
   double default_atr_mult = (g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules)) ? g_rules[g_editing_rule_idx].atr_multiplier : InpATRMultiplier;
   CreateEdit("INP_ATR_MULT", root_x + 295, row_d_y, 45, 20, DoubleToString(default_atr_mult, 1), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   // Row E: Filter Harga Buy & Filter Harga Sell (y = upper_y + 132)
   int row_e_y = upper_y + 132;
   CreateLabel("LBL_BULL_MAX", root_x + 22, row_e_y + 3, "BUY < :", CLR_BULL_NEON, 8, true);
   string default_bmax = "ALL";
   if(g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules) && g_rules[g_editing_rule_idx].bull_price_max > 0)
      default_bmax = DoubleToString(g_rules[g_editing_rule_idx].bull_price_max, 5);
   CreateEdit("INP_BULL_MAX", root_x + 72, row_e_y, 108, 20, default_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   CreateLabel("LBL_BEAR_MIN", root_x + 195, row_e_y + 3, "SELL > :", CLR_BEAR_NEON, 8, true);
   string default_smin = "ALL";
   if(g_editing_rule_idx >= 0 && g_editing_rule_idx < ArraySize(g_rules) && g_rules[g_editing_rule_idx].bear_price_min > 0)
      default_smin = DoubleToString(g_rules[g_editing_rule_idx].bear_price_min, 5);
   CreateEdit("INP_BEAR_MIN", root_x + 260, row_e_y, 154, 20, default_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   // Row F: Form Action Buttons (y = upper_y + 162)
   int row_f_y = upper_y + 162;
   if(g_editing_rule_idx >= 0)
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_f_y, 240, 26, "UPDATE RULE #" + IntegerToString(g_editing_rule_idx + 1), CLR_TAB_ACTIVE_BG, CLR_GOLD_NEON, CLR_GOLD_NEON);
      CreateButton("BTN_CANCEL_EDIT", root_x + 270, row_f_y, 144, 26, "CANCEL EDIT", CLR_CARD_BG, CLR_TEXT_MED, CLR_BORDER_HARD);
   }
   else
   {
      CreateButton("BTN_SUBMIT_RULE", root_x + 22, row_f_y, form_w - 18, 26, "+ ADD AUTO TRADER RULE", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
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
   CreateLabel("TH_SYM",    root_x + 60,  table_y + 6, "SYMBOL",    CLR_TEXT_MED, 8, true);
   CreateLabel("TH_DIR",    root_x + 140, table_y + 6, "DIRECTION", CLR_TEXT_MED, 8, true);
   CreateLabel("TH_LOT",    root_x + 230, table_y + 6, "LOT/RISK",  CLR_TEXT_MED, 8, true);
   CreateLabel("TH_RR",     root_x + 310, table_y + 6, "RR RATIO",  CLR_TEXT_MED, 8, true);
   CreateLabel("TH_TF",     root_x + 380, table_y + 6, "TF",        CLR_TEXT_MED, 8, true);
   CreateLabel("TH_FILTER", root_x + 425, table_y + 6, "PRICE BOUNDS", CLR_TEXT_MED, 8, true);
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
   
   // Clean previous preview labels
   ObjectsDeleteAll(0, g_prefix + "SIM_L");
   
   string prev_sym   = _Symbol;
   string prev_dir   = "BUY & SELL";
   string prev_tf    = "M5";
   double prev_rr    = 2.0;
   string prev_lot   = "0.01 Lot";
   bool   prev_trail = true;
   double prev_pct   = 5.0;
   double prev_atr_m = 2.0;
   string prev_rule_tag = "[FORM INPUT]";
   
   int total_rules = ArraySize(g_rules);
   if(g_editing_rule_idx >= 0 && g_editing_rule_idx < total_rules)
   {
      int idx = g_editing_rule_idx;
      prev_sym   = g_rules[idx].symbol;
      prev_tf    = StringSubstr(EnumToString(g_rules[idx].timeframe), 7);
      prev_rr    = g_rules[idx].risk_reward_ratio;
      prev_lot   = (g_rules[idx].lot_mode == LOT_FIXED) ? DoubleToString(g_rules[idx].lot_value, 2) + " Lot" : DoubleToString(g_rules[idx].lot_value, 1) + "% Risk";
      prev_trail = g_rules[idx].enable_trail;
      prev_pct   = g_rules[idx].trail_trigger_pct;
      prev_atr_m = g_rules[idx].atr_multiplier;
      if(g_rules[idx].direction == TRADE_DIR_BUY)  prev_dir = "BUY ONLY";
      else if(g_rules[idx].direction == TRADE_DIR_SELL) prev_dir = "SELL ONLY";
      prev_rule_tag = StringFormat("[RULE #%d EDIT]", idx + 1);
   }
   else if(g_selected_rule_idx >= 0 && g_selected_rule_idx < total_rules)
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
      string l6 = StringFormat("Profit Lock (Cycle 2+): Sisa %.1f%% ke TP baru -> Kunci SL di Prev TP", prev_pct);
      
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
   
   // Clean previous rows
   ObjectsDeleteAll(0, g_prefix + "ROW_");
   ObjectsDeleteAll(0, g_prefix + "BTN_EDIT_RULE_");
   ObjectsDeleteAll(0, g_prefix + "BTN_DEL_RULE_");
   ObjectsDeleteAll(0, g_prefix + "BTN_TOGGLE_RULE_");
   
   int total_rules = ArraySize(g_rules);
   
   if(total_rules == 0)
   {
      CreateLabel("ROW_EMPTY", root_x + 300, start_y + 20, "Belum ada aturan Auto Trader. Tambahkan rule di atas!", CLR_TEXT_MED, 9, false);
      ChartRedraw();
      return;
   }
   
   for(int i = 0; i < total_rules && i < 5; i++)
   {
      int cur_y = start_y + (i * 38);
      string r_pfx = StringFormat("ROW_%d_", i);
      bool is_selected = (g_selected_rule_idx == i || g_editing_rule_idx == i);
      
      color row_bg = is_selected ? CLR_ROW_SELECTED : ((i % 2 == 0) ? CLR_CARD_BG : CLR_PANEL_BG);
      CreateRect(r_pfx + "BG", root_x + 20, cur_y, win_w - 40, 32, row_bg, is_selected ? CLR_GOLD_NEON : CLR_BORDER_SOFT);
      
      // No
      CreateLabel(r_pfx + "NO", root_x + 24, cur_y + 9, StringFormat("#%d", i + 1), CLR_TEXT_PURE, 8, true);
      
      // Symbol
      CreateLabel(r_pfx + "SYM", root_x + 60, cur_y + 9, g_rules[i].symbol, CLR_TEXT_PURE, 8, true);
      
      // Direction
      string dir_str = "BUY & SELL";
      color  dir_clr = CLR_CYAN_NEON;
      if(g_rules[i].direction == TRADE_DIR_BUY)  { dir_str = "BUY ONLY";  dir_clr = CLR_BULL_NEON; }
      if(g_rules[i].direction == TRADE_DIR_SELL) { dir_str = "SELL ONLY"; dir_clr = CLR_BEAR_NEON; }
      CreateLabel(r_pfx + "DIR", root_x + 140, cur_y + 9, dir_str, dir_clr, 8, true);
      
      // Lot
      string lot_str = (g_rules[i].lot_mode == LOT_FIXED) ? DoubleToString(g_rules[i].lot_value, 2) + " Lot" : DoubleToString(g_rules[i].lot_value, 1) + "% Risk";
      CreateLabel(r_pfx + "LOT", root_x + 230, cur_y + 9, lot_str, CLR_TEXT_PURE, 8, false);
      
      // RR
      CreateLabel(r_pfx + "RR", root_x + 310, cur_y + 9, StringFormat("1:%.2f", g_rules[i].risk_reward_ratio), CLR_CYAN_NEON, 8, true);
      
      // TF
      string str_tf = StringSubstr(EnumToString(g_rules[i].timeframe), 7);
      CreateLabel(r_pfx + "TF", root_x + 380, cur_y + 9, "[" + str_tf + "]", CLR_GOLD_NEON, 8, true);
      
      // Filter Bounds
      string b_str = (g_rules[i].bull_price_max > 0) ? StringFormat("B<%.5f", g_rules[i].bull_price_max) : "B:ALL";
      string s_str = (g_rules[i].bear_price_min > 0) ? StringFormat("S>%.5f", g_rules[i].bear_price_min) : "S:ALL";
      CreateLabel(r_pfx + "FLT", root_x + 425, cur_y + 9, b_str + " | " + s_str, CLR_TEXT_MED, 7, false);
      
      // Auto Trail
      string trail_str = g_rules[i].enable_trail ? StringFormat("ON (%.1f%%, %.1fx)", g_rules[i].trail_trigger_pct, g_rules[i].atr_multiplier) : "OFF";
      CreateLabel(r_pfx + "TRL", root_x + 575, cur_y + 9, trail_str, g_rules[i].enable_trail ? CLR_GOLD_NEON : CLR_TEXT_MED, 8, false);
      
      // Status Toggle Button
      string r_status_txt = g_rules[i].active ? "ACTIVE" : "PAUSED";
      color  r_status_bg  = g_rules[i].active ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
      color  r_status_clr = g_rules[i].active ? CLR_BULL_NEON : CLR_BEAR_NEON;
      CreateButton("BTN_TOGGLE_RULE_" + IntegerToString(i), root_x + 675, cur_y + 5, 58, 22, r_status_txt, r_status_bg, r_status_clr, r_status_clr);
      
      // Actions: Edit and Delete
      CreateButton("BTN_EDIT_RULE_" + IntegerToString(i), root_x + 740, cur_y + 5, 42, 22, "EDIT", is_selected ? CLR_TAB_ACTIVE_BG : CLR_CARD_BG, is_selected ? CLR_GOLD_NEON : CLR_CYAN_NEON, is_selected ? CLR_GOLD_NEON : CLR_BORDER_HARD);
      CreateButton("BTN_DEL_RULE_"  + IntegerToString(i), root_x + 786, cur_y + 5, 38, 22, "DEL",  C'34,8,18', CLR_BEAR_NEON, CLR_BEAR_NEON);
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
         if(sym_len > 0)
            FileWriteString(handle, g_rules[i].symbol, sym_len);
            
         FileWriteInteger(handle, (int)g_rules[i].direction);
         FileWriteDouble(handle, g_rules[i].risk_reward_ratio);
         FileWriteInteger(handle, (int)g_rules[i].timeframe);
         FileWriteInteger(handle, (int)g_rules[i].lot_mode);
         FileWriteDouble(handle, g_rules[i].lot_value);
         FileWriteInteger(handle, g_rules[i].enable_trail ? 1 : 0);
         FileWriteDouble(handle, g_rules[i].trail_trigger_pct);
         FileWriteDouble(handle, g_rules[i].atr_multiplier);
         FileWriteDouble(handle, g_rules[i].bull_price_max);
         FileWriteDouble(handle, g_rules[i].bear_price_min);
         FileWriteInteger(handle, g_rules[i].max_trades);
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
      g_rules[0].bull_price_max    = 0.0;
      g_rules[0].bear_price_min    = 0.0;
      g_rules[0].max_trades        = InpMaxOpenTrades;
      g_rules[0].active            = true;
      g_rules[0].last_bull_bar     = 0;
      g_rules[0].last_bear_bar     = 0;
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
         if(sym_len > 0)
            g_rules[i].symbol = FileReadString(handle, sym_len);
         else
            g_rules[i].symbol = "";
            
         g_rules[i].direction         = (ENUM_TRADE_DIRECTION)FileReadInteger(handle);
         g_rules[i].risk_reward_ratio = FileReadDouble(handle);
         g_rules[i].timeframe         = (ENUM_TIMEFRAMES)FileReadInteger(handle);
         g_rules[i].lot_mode          = (ENUM_LOT_MODE)FileReadInteger(handle);
         g_rules[i].lot_value         = FileReadDouble(handle);
         g_rules[i].enable_trail      = (FileReadInteger(handle) == 1);
         g_rules[i].trail_trigger_pct = FileReadDouble(handle);
         g_rules[i].atr_multiplier    = FileReadDouble(handle);
         g_rules[i].bull_price_max    = FileReadDouble(handle);
         g_rules[i].bear_price_min    = FileReadDouble(handle);
         g_rules[i].max_trades        = FileReadInteger(handle);
         g_rules[i].active            = (FileReadInteger(handle) == 1);
         g_rules[i].last_bull_bar     = 0;
         g_rules[i].last_bear_bar     = 0;
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
      // Toggle Master Power
      if(sparam == g_prefix + "BTN_TOGGLE_MASTER")
      {
         g_master_power_enabled = !g_master_power_enabled;
         CreateDashboardUI();
         return;
      }
      // Form Direction buttons
      else if(sparam == g_prefix + "BTN_DIR_BOTH")
      {
         g_form_direction = TRADE_DIR_BOTH;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DIR_BUY")
      {
         g_form_direction = TRADE_DIR_BUY;
         CreateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DIR_SELL")
      {
         g_form_direction = TRADE_DIR_SELL;
         CreateDashboardUI();
         return;
      }
      // Form Toggle Lot Mode
      else if(sparam == g_prefix + "BTN_TOGGLE_LOT_MODE")
      {
         if(g_form_lot_mode == LOT_FIXED)
            g_form_lot_mode = LOT_RISK_PCT;
         else
            g_form_lot_mode = LOT_FIXED;
            
         CreateDashboardUI();
         return;
      }
      // Form Toggle Auto Trail
      else if(sparam == g_prefix + "BTN_TOGGLE_TRAIL")
      {
         g_form_trail_on = !g_form_trail_on;
         CreateDashboardUI();
         return;
      }
      // Form Cancel Edit
      else if(sparam == g_prefix + "BTN_CANCEL_EDIT")
      {
         g_editing_rule_idx = -1;
         CreateDashboardUI();
         return;
      }
      // Form Add or Update Rule
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
         if(lot_val <= 0) lot_val = (g_form_lot_mode == LOT_FIXED) ? 0.01 : 1.0;
         
         double trail_pct = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_PCT", OBJPROP_TEXT));
         if(trail_pct <= 0) trail_pct = 5.0;
         
         double atr_mult = StringToDouble(ObjectGetString(0, g_prefix + "INP_ATR_MULT", OBJPROP_TEXT));
         if(atr_mult <= 0) atr_mult = 2.0;
         
         string str_bmax = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
         StringTrimLeft(str_bmax); StringTrimRight(str_bmax); StringToUpper(str_bmax);
         double bmax_val = (str_bmax == "" || str_bmax == "ALL" || str_bmax == "BEBAS") ? 0.0 : StringToDouble(str_bmax);
         
         string str_smin = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
         StringTrimLeft(str_smin); StringTrimRight(str_smin); StringToUpper(str_smin);
         double smin_val = (str_smin == "" || str_smin == "ALL" || str_smin == "BEBAS") ? 0.0 : StringToDouble(str_smin);
         
         int target_idx = g_editing_rule_idx;
         if(target_idx < 0)
         {
            target_idx = ArraySize(g_rules);
            ArrayResize(g_rules, target_idx + 1);
            g_rules[target_idx].active = true;
         }
         
         g_rules[target_idx].symbol            = valid_sym;
         g_rules[target_idx].direction         = g_form_direction;
         g_rules[target_idx].risk_reward_ratio = rr_val;
         g_rules[target_idx].timeframe         = tf_val;
         g_rules[target_idx].lot_mode          = g_form_lot_mode;
         g_rules[target_idx].lot_value         = lot_val;
         g_rules[target_idx].enable_trail      = g_form_trail_on;
         g_rules[target_idx].trail_trigger_pct = trail_pct;
         g_rules[target_idx].atr_multiplier    = atr_mult;
         g_rules[target_idx].bull_price_max    = bmax_val;
         g_rules[target_idx].bear_price_min    = smin_val;
         g_rules[target_idx].max_trades        = InpMaxOpenTrades;
         g_rules[target_idx].last_bull_bar     = 0;
         g_rules[target_idx].last_bear_bar     = 0;
         
         g_selected_rule_idx = target_idx;
         g_editing_rule_idx  = -1;
         SaveStateToFile();
         CreateDashboardUI();
         Alert(StringFormat("Auto Trader Rule untuk %s berhasil disimpan!", valid_sym));
         return;
      }
      
      // Dynamic Table Action Buttons (Edit, Delete, Toggle Active, Select Row for Preview)
      int total_rules = ArraySize(g_rules);
      for(int i = 0; i < total_rules; i++)
      {
         string r_pfx = StringFormat("ROW_%d_", i);
         // Click anywhere on row background or labels to preview
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
         // Edit button
         else if(sparam == g_prefix + "BTN_EDIT_RULE_" + IntegerToString(i))
         {
            g_editing_rule_idx  = i;
            g_selected_rule_idx = i;
            g_form_direction    = g_rules[i].direction;
            g_form_lot_mode     = g_rules[i].lot_mode;
            g_form_trail_on     = g_rules[i].enable_trail;
            CreateDashboardUI();
            return;
         }
         // Delete button
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
         // Toggle Active/Paused button
         else if(sparam == g_prefix + "BTN_TOGGLE_RULE_" + IntegerToString(i))
         {
            g_rules[i].active = !g_rules[i].active;
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
   
   // 1. Process active position trailing SL & TP
   ProcessAutoTrailSLTP();
   
   int total_rules = ArraySize(g_rules);
   if(total_rules == 0) return;
   
   for(int r = 0; r < total_rules; r++)
   {
      if(!g_rules[r].active) continue;
      
      string sym = g_rules[r].symbol;
      ENUM_TIMEFRAMES tf = g_rules[r].timeframe;
      
      if(g_rules[r].max_trades > 0 && CountOpenPositions(sym) >= g_rules[r].max_trades)
         continue;
         
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
         if(IsStrongBullishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
         {
            if(g_rules[r].bull_price_max <= 0.0 || cur_price < g_rules[r].bull_price_max)
            {
               if(g_rules[r].last_bull_bar != cur_bar_time)
               {
                  g_rules[r].last_bull_bar = cur_bar_time;
                  
                  double sl_price = broken_level - atr_50;
                  double sl_dist  = ask - sl_price;
                  
                  if(sl_dist > 0)
                  {
                     double tp_price = ask + (sl_dist * g_rules[r].risk_reward_ratio);
                     sl_price = NormalizeDouble(sl_price, digits);
                     tp_price = NormalizeDouble(tp_price, digits);
                     double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, ask, sl_price);
                     
                     if(m_trade.Buy(lots, sym, ask, sl_price, tp_price, "Engulfing Buy (RR 1:" + DoubleToString(g_rules[r].risk_reward_ratio, 1) + ")"))
                     {
                        ulong deal_tkt = m_trade.ResultOrder();
                        double atr100 = atr_50 * 2.0;
                        if(g_rules[r].enable_trail)
                        {
                           RegisterPositionTracking(deal_tkt, sym, tf, atr100, ask, tp_price, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                        }
                        
                        string msg = StringFormat("[AUTO TRADER - ORDER OPENED]\nSymbol: %s (%s)\nTicket: #%d (BUY)\nLot: %.2f | Ask: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)\n100%% ATR Awal: %.5f",
                                                  sym, EnumToString(tf), deal_tkt, lots, ask, sl_price, tp_price, g_rules[r].risk_reward_ratio, atr100);
                        if(InpEnableSoundAlerts) Alert(msg);
                        if(InpEnablePushAlerts)  SendNotification(msg);
                        
                        PrintFormat("BUY Executed: #%d | %s | Lot: %.2f | Ask: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f)",
                                    deal_tkt, sym, lots, ask, sl_price, tp_price, g_rules[r].risk_reward_ratio);
                     }
                  }
               }
            }
         }
      }
      
      // B. CHECK SELL (Strong Bearish Break)
      if(g_rules[r].direction == TRADE_DIR_BOTH || g_rules[r].direction == TRADE_DIR_SELL)
      {
         if(IsStrongBearishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
         {
            if(g_rules[r].bear_price_min <= 0.0 || cur_price > g_rules[r].bear_price_min)
            {
               if(g_rules[r].last_bear_bar != cur_bar_time)
               {
                  g_rules[r].last_bear_bar = cur_bar_time;
                  
                  double sl_price = broken_level + atr_50 + spread;
                  double sl_dist  = sl_price - bid;
                  
                  if(sl_dist > 0)
                  {
                     double tp_price = bid - (sl_dist * g_rules[r].risk_reward_ratio);
                     sl_price = NormalizeDouble(sl_price, digits);
                     tp_price = NormalizeDouble(tp_price, digits);
                     double lots = CalculateLotSize(sym, g_rules[r].lot_mode, g_rules[r].lot_value, bid, sl_price);
                     
                     if(m_trade.Sell(lots, sym, bid, sl_price, tp_price, "Engulfing Sell (RR 1:" + DoubleToString(g_rules[r].risk_reward_ratio, 1) + ")"))
                     {
                        ulong deal_tkt = m_trade.ResultOrder();
                        double atr100 = atr_50 * 2.0;
                        if(g_rules[r].enable_trail)
                        {
                           RegisterPositionTracking(deal_tkt, sym, tf, atr100, bid, tp_price, g_rules[r].trail_trigger_pct, g_rules[r].atr_multiplier);
                        }
                        
                        string msg = StringFormat("[AUTO TRADER - ORDER OPENED]\nSymbol: %s (%s)\nTicket: #%d (SELL)\nLot: %.2f | Bid: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)\n100%% ATR Awal: %.5f",
                                                  sym, EnumToString(tf), deal_tkt, lots, bid, sl_price, tp_price, g_rules[r].risk_reward_ratio, atr100);
                        if(InpEnableSoundAlerts) Alert(msg);
                        if(InpEnablePushAlerts)  SendNotification(msg);
                        
                        PrintFormat("SELL Executed: #%d | %s | Lot: %.2f | Bid: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f)",
                                    deal_tkt, sym, lots, bid, sl_price, tp_price, g_rules[r].risk_reward_ratio);
                     }
                  }
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
