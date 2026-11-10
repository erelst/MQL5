//+------------------------------------------------------------------+
//|                                   EngulfingAutoTrader.mq5        |
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "1.10"
#property description "Auto Execution EA on Realtime Strong Engulfing Break with Auto Trail SL (BE) & Volatility Trail TP Engine"

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

struct SPositionTracking
{
   ulong    ticket;
   double   initial_atr100;    // 100% ATR of the entry candle
   double   initial_tp_dist;   // Initial distance between Open Price and initial TP
   double   prev_tp_level;     // Level of previous TP target (0.0 for initial)
   int      trail_cycle;       // Cycle count (0 = before BE, 1 = BE active, 2+ = trailing SL to prev TP)
   bool     active;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== TRADE EXECUTION SETTINGS ==="
input ENUM_TRADE_DIRECTION InpTradeDirection   = TRADE_DIR_BOTH; // Trading Direction
input double               InpRiskRewardRatio  = 2.0;            // Risk Reward Ratio (1:RR, e.g. 1.5, 2.0, 2.5)
input int                  InpMaxOpenTrades    = 1;              // Max Open Trades per Symbol (0 = Unlimited)
input int                  InpSlippage         = 10;             // Max Slippage (Points)
input ulong                InpMagicNumber      = 882201;         // Magic Number

input group "=== AUTO TRAIL SL & TP ENGINE ==="
input bool                 InpEnableTrail      = true;           // Enable Auto Trail SL & Volatility Trail TP
input double               InpTrailTriggerPct  = 5.0;            // Sisa Jarak Menuju TP untuk Trigger (%)
input double               InpATRMultiplier    = 2.0;            // Minimum ATR Multiplier for Trail TP (>= 2.0x)

input group "=== NOTIFICATIONS & ALERTS ==="
input bool                 InpEnablePushAlerts = true;           // Send Mobile Push Notifications
input bool                 InpEnableSoundAlerts= true;           // Enable Terminal / Sound Alerts

input group "=== MONEY MANAGEMENT ==="
input ENUM_LOT_MODE        InpLotMode          = LOT_FIXED;      // Lot Size Mode
input double               InpFixedLot         = 0.01;           // Fixed Lot Size
input double               InpRiskPercent      = 1.0;            // Risk Percent (% Balance per Trade)

input group "=== ENGULFING & ATR SETTINGS ==="
input ENUM_TIMEFRAMES      InpTimeframe        = PERIOD_M5;      // Timeframe for Engulfing Break
input int                  InpATRPeriod        = 14;             // ATR Period for 50% calculation
input double               InpBodyRatioMult    = 1.0;            // Min Body Ratio vs Previous Candle

input group "=== PRICE BOUNDARY FILTERS ==="
input double               InpBullishPriceMax  = 0.0;            // Buy only if Price < X (0 = Any Price)
input double               InpBearishPriceMin  = 0.0;            // Sell only if Price > Y (0 = Any Price)

// UI Coordinates & Colors (Pure High-Contrast Palette)
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

//+------------------------------------------------------------------+
//| GLOBALS & DYNAMIC STATE                                          |
//+------------------------------------------------------------------+
CTrade               m_trade;
CPositionInfo        m_position;
CSymbolInfo          m_symbol_info;

string               g_prefix = "EAT_";
bool                 g_auto_trading_enabled = true;
ENUM_TRADE_DIRECTION g_trade_direction;
double               g_risk_reward_ratio;
ENUM_TIMEFRAMES      g_timeframe;
ENUM_LOT_MODE        g_lot_mode;
double               g_fixed_lot;
double               g_risk_pct;
double               g_bull_price_max;
double               g_bear_price_min;
int                  g_max_open_trades;
bool                 g_enable_trail;
double               g_trail_trigger_pct;
double               g_atr_multiplier;

SPositionTracking    g_tracking_list[];

datetime             g_last_bull_trade_bar = 0;
datetime             g_last_bear_trade_bar = 0;

// Forward declarations
void CreateDashboardUI();
void UpdateDashboardUI();
void DestroyDashboardUI();
void SaveStateToFile();
void LoadStateFromFile();
void ProcessAutoTrailSLTP();
void RegisterPositionTracking(ulong ticket, double atr100, double open_p, double tp_p);

//+------------------------------------------------------------------+
//| FAST DIRECT 100% ATR CALCULATION                                 |
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
   double cur_close = rates[0].close; // live realtime tick price
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price   = cur_close;
   out_broken_low  = prev_low;
   
   // 1. Previous candle must be Bearish
   if(prev_close >= prev_open) return false;
   
   // 2. Realtime Breakout & Strong Engulfing:
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
   double cur_close = rates[0].close; // live realtime tick price
   double cur_high  = rates[0].high;
   double cur_low   = rates[0].low;
   double prev_open = rates[1].open;
   double prev_close= rates[1].close;
   double prev_high = rates[1].high;
   double prev_low  = rates[1].low;
   
   out_cur_price    = cur_close;
   out_broken_high  = prev_high;
   
   // 1. Previous candle must be Bullish
   if(prev_close <= prev_open) return false;
   
   // 2. Realtime Breakout & Strong Engulfing:
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
double CalculateLotSize(const string sym, double entry_price, double sl_price)
{
   if(g_lot_mode == LOT_FIXED) return g_fixed_lot;
   
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (g_risk_pct / 100.0);
   double sl_distance = MathAbs(entry_price - sl_price);
   if(sl_distance <= 0) return g_fixed_lot;
   
   double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0 || tick_value <= 0) return g_fixed_lot;
   
   double point_loss_per_lot = (sl_distance / tick_size) * tick_value;
   if(point_loss_per_lot <= 0) return g_fixed_lot;
   
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
void RegisterPositionTracking(ulong ticket, double atr100, double open_p, double tp_p)
{
   int size = ArraySize(g_tracking_list);
   for(int i = 0; i < size; i++)
   {
      if(g_tracking_list[i].ticket == ticket)
      {
         g_tracking_list[i].initial_atr100  = atr100;
         g_tracking_list[i].initial_tp_dist = MathAbs(tp_p - open_p);
         g_tracking_list[i].prev_tp_level   = 0.0;
         g_tracking_list[i].trail_cycle     = 0;
         g_tracking_list[i].active          = true;
         return;
      }
   }
   
   ArrayResize(g_tracking_list, size + 1);
   g_tracking_list[size].ticket          = ticket;
   g_tracking_list[size].initial_atr100  = atr100;
   g_tracking_list[size].initial_tp_dist = MathAbs(tp_p - open_p);
   g_tracking_list[size].prev_tp_level   = 0.0;
   g_tracking_list[size].trail_cycle     = 0;
   g_tracking_list[size].active          = true;
}

void ProcessAutoTrailSLTP()
{
   if(!g_enable_trail) return;
   
   int size = ArraySize(g_tracking_list);
   if(size == 0) return;
   
   double trigger_ratio = g_trail_trigger_pct / 100.0; // default 0.05 (sisa 5%)
   if(trigger_ratio <= 0) return;
   
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
      
      if(cur_tp <= 0) continue; // No TP defined
      
      double current_atr100 = CalculateATR100(sym, g_timeframe, InpATRPeriod);
      double required_atr   = g_tracking_list[i].initial_atr100 * InpATRMultiplier;
      bool atr_exploding    = (current_atr100 >= required_atr);
      
      // ================= BUY POSITION =================
      if(ptype == POSITION_TYPE_BUY)
      {
         double total_dist = cur_tp - open_p;
         if(total_dist <= 0) continue;
         
         double remaining_dist = cur_tp - bid;
         // Trigger condition: Sisa jarak <= trigger_pct% of total_dist
         if(remaining_dist <= total_dist * trigger_ratio && bid > open_p)
         {
            // SIKLUS 1: Auto Trail SL ke BE (Mandiri, selalu aktif)
            if(g_tracking_list[i].trail_cycle == 0)
            {
               double be_sl = NormalizeDouble(open_p + spread, digits);
               if(be_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s (M%d)\nTicket: #%d (BUY)\nAction: SL moved to Break-Even\nNew SL: %.5f\nEntry: %.5f",
                                               sym, (int)g_timeframe, tkt, be_sl, open_p);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL (BE) Executed for BUY #%d | New SL: %.5f", tkt, be_sl);
                  }
               }
               
               // Evaluasi Trail TP: Jika ATR Realtime >= g_atr_multiplier x ATR Awal
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, be_sl > cur_sl ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s (M%d)\nTicket: #%d (BUY)\nAction: TP Extended (+1x Target)\nNew TP: %.5f\nATR Realtime: %.5f (>= %.1fx ATR Awal)",
                                               sym, (int)g_timeframe, tkt, new_tp, current_atr100, g_atr_multiplier);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Executed for BUY #%d | ATR: %.5f >= %.5f | New TP: %.5f",
                                 tkt, current_atr100, required_atr, new_tp);
                  }
               }
            }
            // SIKLUS 2+: Auto Trail SL ke TP Sebelumnya & Perpanjang TP lagi jika ATR tetap >= g_atr_multiplier
            else if(g_tracking_list[i].trail_cycle >= 1)
            {
               double prev_tp = g_tracking_list[i].prev_tp_level;
               double new_sl  = NormalizeDouble(prev_tp, digits);
               
               if(new_sl > cur_sl)
               {
                  if(m_trade.PositionModify(tkt, new_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s (M%d)\nTicket: #%d (BUY)\nAction: SL locked to Prev TP\nNew SL: %.5f (Locked Profit: %.5f)",
                                               sym, (int)g_timeframe, tkt, new_sl, prev_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL to Prev TP Executed for BUY #%d | New SL: %.5f", tkt, new_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp + g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, new_sl > cur_sl ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s (M%d)\nTicket: #%d (BUY)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f\nATR Realtime: %.5f",
                                               sym, (int)g_timeframe, tkt, g_tracking_list[i].trail_cycle, new_tp, current_atr100);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Extended (Cycle %d) for BUY #%d | New TP: %.5f",
                                 g_tracking_list[i].trail_cycle, tkt, new_tp);
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
         // Trigger condition: Sisa jarak <= trigger_pct% of total_dist
         if(remaining_dist <= total_dist * trigger_ratio && ask < open_p)
         {
            // SIKLUS 1: Auto Trail SL ke BE (Mandiri, selalu aktif)
            if(g_tracking_list[i].trail_cycle == 0)
            {
               double be_sl = NormalizeDouble(open_p - spread, digits);
               if(cur_sl == 0 || be_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, be_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL BE]\nSymbol: %s (M%d)\nTicket: #%d (SELL)\nAction: SL moved to Break-Even\nNew SL: %.5f\nEntry: %.5f",
                                               sym, (int)g_timeframe, tkt, be_sl, open_p);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL (BE) Executed for SELL #%d | New SL: %.5f", tkt, be_sl);
                  }
               }
               
               // Evaluasi Trail TP: Jika ATR Realtime >= g_atr_multiplier x ATR Awal
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || be_sl < cur_sl) ? be_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle   = 1;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s (M%d)\nTicket: #%d (SELL)\nAction: TP Extended (+1x Target)\nNew TP: %.5f\nATR Realtime: %.5f (>= %.1fx ATR Awal)",
                                               sym, (int)g_timeframe, tkt, new_tp, current_atr100, g_atr_multiplier);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Executed for SELL #%d | ATR: %.5f >= %.5f | New TP: %.5f",
                                 tkt, current_atr100, required_atr, new_tp);
                  }
               }
            }
            // SIKLUS 2+: Auto Trail SL ke TP Sebelumnya & Perpanjang TP lagi jika ATR tetap >= g_atr_multiplier
            else if(g_tracking_list[i].trail_cycle >= 1)
            {
               double prev_tp = g_tracking_list[i].prev_tp_level;
               double new_sl  = NormalizeDouble(prev_tp, digits);
               
               if(cur_sl == 0 || new_sl < cur_sl)
               {
                  if(m_trade.PositionModify(tkt, new_sl, cur_tp))
                  {
                     string msg = StringFormat("[AUTO TRADER - TRAIL SL LOCKED]\nSymbol: %s (M%d)\nTicket: #%d (SELL)\nAction: SL locked to Prev TP\nNew SL: %.5f (Locked Profit: %.5f)",
                                               sym, (int)g_timeframe, tkt, new_sl, prev_tp);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail SL to Prev TP Executed for SELL #%d | New SL: %.5f", tkt, new_sl);
                  }
               }
               
               if(atr_exploding)
               {
                  double new_tp = NormalizeDouble(cur_tp - g_tracking_list[i].initial_tp_dist, digits);
                  if(m_trade.PositionModify(tkt, (cur_sl == 0 || new_sl < cur_sl) ? new_sl : cur_sl, new_tp))
                  {
                     g_tracking_list[i].prev_tp_level = cur_tp;
                     g_tracking_list[i].trail_cycle++;
                     string msg = StringFormat("[AUTO TRADER - TRAIL TP EXTENDED]\nSymbol: %s (M%d)\nTicket: #%d (SELL)\nAction: TP Extended (Cycle %d)\nNew TP: %.5f\nATR Realtime: %.5f",
                                               sym, (int)g_timeframe, tkt, g_tracking_list[i].trail_cycle, new_tp, current_atr100);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     PrintFormat("Auto Trail TP Extended (Cycle %d) for SELL #%d | New TP: %.5f",
                                 g_tracking_list[i].trail_cycle, tkt, new_tp);
                  }
               }
            }
         }
      }
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
   int win_w  = 540;
   int win_h  = 430;
   
   // Outer Pitch-black window
   CreateRect("WIN_BG", root_x, root_y, win_w, win_h, CLR_PANEL_BG, CLR_BORDER_HARD);
   
   // Top header
   CreateRect("WIN_TOP", root_x, root_y, win_w, 36, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("WIN_TITLE", root_x + 14, root_y + 9, "ENGULFING AUTO TRADER", CLR_TEXT_PURE, 10, true);
   CreateLabel("WIN_TAG", root_x + 220, root_y + 10, "[REALTIME TICK & TRAIL ENGINE]", CLR_CYAN_NEON, 8, true);
   
   // Status Badge
   string status_txt = g_auto_trading_enabled ? "ACTIVE" : "PAUSED";
   color status_bg  = g_auto_trading_enabled ? CLR_POWER_ON_BG : CLR_POWER_OFF_BG;
   color status_clr = g_auto_trading_enabled ? CLR_BULL_NEON : CLR_BEAR_NEON;
   CreateButton("BTN_TOGGLE_POWER", root_x + win_w - 95, root_y + 6, 82, 24, status_txt, status_bg, status_clr, status_clr);
   
   // Row 1: Direction Toggle Buttons
   int row1_y = root_y + 48;
   CreateRect("CARD_DIR", root_x + 14, row1_y, win_w - 28, 48, CLR_CARD_BG, CLR_BORDER_HARD);
   CreateLabel("LBL_DIR", root_x + 24, row1_y + 16, "DIRECTION:", CLR_TEXT_MED, 8, true);
   
   color btn_both_bg = (g_trade_direction == TRADE_DIR_BOTH) ? CLR_TAB_ACTIVE_BG : CLR_PANEL_BG;
   color btn_both_cl = (g_trade_direction == TRADE_DIR_BOTH) ? CLR_CYAN_NEON : CLR_TEXT_MED;
   color btn_buy_bg  = (g_trade_direction == TRADE_DIR_BUY) ? CLR_POWER_ON_BG : CLR_PANEL_BG;
   color btn_buy_cl  = (g_trade_direction == TRADE_DIR_BUY) ? CLR_BULL_NEON : CLR_TEXT_MED;
   color btn_sell_bg = (g_trade_direction == TRADE_DIR_SELL) ? CLR_POWER_OFF_BG : CLR_PANEL_BG;
   color btn_sell_cl = (g_trade_direction == TRADE_DIR_SELL) ? CLR_BEAR_NEON : CLR_TEXT_MED;
   
   CreateButton("BTN_DIR_BOTH", root_x + 120, row1_y + 11, 120, 26, "BUY & SELL", btn_both_bg, btn_both_cl, btn_both_cl);
   CreateButton("BTN_DIR_BUY",  root_x + 248, row1_y + 11, 120, 26, "BUY ONLY",  btn_buy_bg,  btn_buy_cl,  btn_buy_cl);
   CreateButton("BTN_DIR_SELL", root_x + 376, row1_y + 11, 120, 26, "SELL ONLY", btn_sell_bg, btn_sell_cl, btn_sell_cl);
   
   // Row 2: Strategy Inputs (RR Ratio, TF, Lot, Auto Trail)
   int row2_y = row1_y + 58;
   CreateRect("CARD_INPUTS", root_x + 14, row2_y, win_w - 28, 160, CLR_CARD_BG, CLR_BORDER_HARD);
   
   CreateLabel("LBL_RR", root_x + 24, row2_y + 14, "RISK REWARD (1:X):", CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_RR", root_x + 160, row2_y + 10, 80, 22, DoubleToString(g_risk_reward_ratio, 2), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_TF", root_x + 265, row2_y + 14, "TIMEFRAME (MIN):", CLR_TEXT_PURE, 8, true);
   int tf_min = (int)g_timeframe;
   if(g_timeframe == PERIOD_M1) tf_min = 1;
   else if(g_timeframe == PERIOD_M5) tf_min = 5;
   else if(g_timeframe == PERIOD_M15) tf_min = 15;
   else if(g_timeframe == PERIOD_M30) tf_min = 30;
   else if(g_timeframe == PERIOD_H1) tf_min = 60;
   else if(g_timeframe == PERIOD_H4) tf_min = 240;
   else if(g_timeframe == PERIOD_D1) tf_min = 1440;
   CreateEdit("INP_TF", root_x + 400, row2_y + 10, 80, 22, IntegerToString(tf_min), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_LOT_MODE", root_x + 24, row2_y + 42, "LOT MODE:", CLR_TEXT_PURE, 8, true);
   string lot_mode_str = (g_lot_mode == LOT_FIXED) ? "FIXED LOT" : "% RISK / SL";
   color lot_mode_clr = (g_lot_mode == LOT_FIXED) ? CLR_CYAN_NEON : CLR_GOLD_NEON;
   CreateButton("BTN_TOGGLE_LOT_MODE", root_x + 120, row2_y + 38, 110, 22, lot_mode_str, CLR_CANVAS_BG, lot_mode_clr, CLR_BORDER_HARD);
   
   string lot_lbl_str = (g_lot_mode == LOT_FIXED) ? "LOT VALUE:" : "% RISK:";
   double lot_val_disp = (g_lot_mode == LOT_FIXED) ? g_fixed_lot : g_risk_pct;
   CreateLabel("LBL_LOT_VAL", root_x + 245, row2_y + 42, lot_lbl_str, CLR_TEXT_PURE, 8, true);
   CreateEdit("INP_LOT", root_x + 340, row2_y + 38, 140, 22, DoubleToString(lot_val_disp, 2), CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   // Auto Trail SL/TP Settings Row (Trigger % & Multiplier editable)
   CreateLabel("LBL_TRAIL", root_x + 24, row2_y + 70, "AUTO TRAIL:", CLR_TEXT_PURE, 8, true);
   string trail_mode_str = g_enable_trail ? "ON" : "OFF";
   color trail_mode_clr = g_enable_trail ? CLR_GOLD_NEON : CLR_TEXT_MED;
   CreateButton("BTN_TOGGLE_TRAIL", root_x + 105, row2_y + 66, 50, 22, trail_mode_str, CLR_CANVAS_BG, trail_mode_clr, CLR_BORDER_HARD);
   
   CreateLabel("LBL_TRAIL_PCT", root_x + 165, row2_y + 70, "SISA TP (%):", CLR_TEXT_MED, 8, true);
   CreateEdit("INP_TRAIL_PCT", root_x + 250, row2_y + 66, 55, 22, DoubleToString(g_trail_trigger_pct, 1), CLR_CANVAS_BG, CLR_GOLD_NEON);
   
   CreateLabel("LBL_ATR_MULT_LBL", root_x + 315, row2_y + 70, "MIN ATR (X):", CLR_TEXT_MED, 8, true);
   CreateEdit("INP_ATR_MULT", root_x + 400, row2_y + 66, 80, 22, DoubleToString(g_atr_multiplier, 1), CLR_CANVAS_BG, CLR_CYAN_NEON);
   
   CreateLabel("LBL_BULL_MAX", root_x + 24, row2_y + 100, "BUY HARGA < :", CLR_BULL_NEON, 8, true);
   string str_bmax = (g_bull_price_max > 0) ? DoubleToString(g_bull_price_max, _Digits) : "ALL";
   CreateEdit("INP_BULL_MAX", root_x + 160, row2_y + 96, 110, 22, str_bmax, CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   CreateLabel("LBL_BEAR_MIN", root_x + 290, row2_y + 100, "SELL HARGA > :", CLR_BEAR_NEON, 8, true);
   string str_smin = (g_bear_price_min > 0) ? DoubleToString(g_bear_price_min, _Digits) : "ALL";
   CreateEdit("INP_BEAR_MIN", root_x + 400, row2_y + 96, 110, 22, str_smin, CLR_CANVAS_BG, CLR_TEXT_PURE);
   
   // Row 3: Action Buttons
   int row3_y = row2_y + 170;
   CreateButton("BTN_SAVE_CONFIG", root_x + 14, row3_y, win_w - 28, 28, "APPLY & SAVE SETTINGS", CLR_TAB_ACTIVE_BG, CLR_CYAN_NEON, CLR_CYAN_NEON);
   
   // Row 4: Live Info Terminal Preview
   int row4_y = row3_y + 36;
   CreateRect("CARD_INFO", root_x + 14, row4_y, win_w - 28, 80, CLR_CANVAS_BG, CLR_BORDER_HARD);
   
   string live_dir_str = (g_trade_direction == TRADE_DIR_BOTH) ? "BUY & SELL" : ((g_trade_direction == TRADE_DIR_BUY) ? "BUY ONLY" : "SELL ONLY");
   string info_line1 = StringFormat("Engine: %s | Ratio: 1:%.2f RR | Timeframe: %s", live_dir_str, g_risk_reward_ratio, EnumToString(g_timeframe));
   string info_line2 = StringFormat("Auto Trail: %s (Sisa %.1f%% TP, Min %.1fx ATR) | Open: %d trade(s)", g_enable_trail ? "ON" : "OFF", g_trail_trigger_pct, g_atr_multiplier, CountOpenPositions(_Symbol));
   
   CreateLabel("INFO_L1", root_x + 24, row4_y + 14, info_line1, CLR_TEXT_PURE, 8, false);
   CreateLabel("INFO_L2", root_x + 24, row4_y + 36, info_line2, CLR_GOLD_NEON, 8, true);
   CreateLabel("INFO_L3", root_x + 24, row4_y + 56, "*Auto executes per tick; Trails SL to BE and extends TP when ATR >= multiplier", CLR_TEXT_MED, 7, false);
   
   ChartRedraw();
}

void UpdateDashboardUI()
{
   CreateDashboardUI();
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
   string filename = "EAT_State_" + _Symbol + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   int handle = FileOpen(filename, FILE_WRITE|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      FileWriteInteger(handle, g_auto_trading_enabled ? 1 : 0);
      FileWriteInteger(handle, (int)g_trade_direction);
      FileWriteDouble(handle, g_risk_reward_ratio);
      FileWriteInteger(handle, (int)g_timeframe);
      FileWriteInteger(handle, (int)g_lot_mode);
      FileWriteDouble(handle, g_fixed_lot);
      FileWriteDouble(handle, g_risk_pct);
      FileWriteDouble(handle, g_bull_price_max);
      FileWriteDouble(handle, g_bear_price_min);
      FileWriteInteger(handle, g_enable_trail ? 1 : 0);
      FileWriteDouble(handle, g_trail_trigger_pct);
      FileWriteDouble(handle, g_atr_multiplier);
      FileClose(handle);
   }
}

void LoadStateFromFile()
{
   string filename = "EAT_State_" + _Symbol + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".bin";
   if(!FileIsExist(filename))
   {
      // Default from Inputs
      g_auto_trading_enabled = true;
      g_trade_direction      = InpTradeDirection;
      g_risk_reward_ratio    = InpRiskRewardRatio;
      g_timeframe            = InpTimeframe;
      g_lot_mode             = InpLotMode;
      g_fixed_lot            = InpFixedLot;
      g_risk_pct             = InpRiskPercent;
      g_bull_price_max       = InpBullishPriceMax;
      g_bear_price_min       = InpBearishPriceMin;
      g_max_open_trades      = InpMaxOpenTrades;
      g_enable_trail         = InpEnableTrail;
      g_trail_trigger_pct    = InpTrailTriggerPct;
      g_atr_multiplier       = InpATRMultiplier;
      return;
   }
   
   int handle = FileOpen(filename, FILE_READ|FILE_BIN);
   if(handle != INVALID_HANDLE)
   {
      g_auto_trading_enabled = (FileReadInteger(handle) == 1);
      g_trade_direction      = (ENUM_TRADE_DIRECTION)FileReadInteger(handle);
      g_risk_reward_ratio    = FileReadDouble(handle);
      g_timeframe            = (ENUM_TIMEFRAMES)FileReadInteger(handle);
      g_lot_mode             = (ENUM_LOT_MODE)FileReadInteger(handle);
      g_fixed_lot            = FileReadDouble(handle);
      g_risk_pct             = FileReadDouble(handle);
      g_bull_price_max       = FileReadDouble(handle);
      g_bear_price_min       = FileReadDouble(handle);
      g_max_open_trades      = InpMaxOpenTrades;
      g_enable_trail         = (FileReadInteger(handle) == 1);
      g_trail_trigger_pct    = FileReadDouble(handle);
      g_atr_multiplier       = FileReadDouble(handle);
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
   
   PrintFormat("EngulfingAutoTrader Initialized | Direction: %s | RR 1:%.2f | TF: %s | Trail: %s",
               EnumToString(g_trade_direction), g_risk_reward_ratio, EnumToString(g_timeframe), g_enable_trail ? "ON" : "OFF");
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
      // Toggle Power
      if(sparam == g_prefix + "BTN_TOGGLE_POWER")
      {
         g_auto_trading_enabled = !g_auto_trading_enabled;
         UpdateDashboardUI();
         return;
      }
      // Direction buttons
      else if(sparam == g_prefix + "BTN_DIR_BOTH")
      {
         g_trade_direction = TRADE_DIR_BOTH;
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DIR_BUY")
      {
         g_trade_direction = TRADE_DIR_BUY;
         UpdateDashboardUI();
         return;
      }
      else if(sparam == g_prefix + "BTN_DIR_SELL")
      {
         g_trade_direction = TRADE_DIR_SELL;
         UpdateDashboardUI();
         return;
      }
      // Toggle Lot Mode
      else if(sparam == g_prefix + "BTN_TOGGLE_LOT_MODE")
      {
         if(g_lot_mode == LOT_FIXED)
            g_lot_mode = LOT_RISK_PCT;
         else
            g_lot_mode = LOT_FIXED;
            
         CreateDashboardUI();
         return;
      }
      // Toggle Auto Trail SL & TP
      else if(sparam == g_prefix + "BTN_TOGGLE_TRAIL")
      {
         g_enable_trail = !g_enable_trail;
         CreateDashboardUI();
         return;
      }
      // Apply & Save Config
      else if(sparam == g_prefix + "BTN_SAVE_CONFIG")
      {
         double new_rr = StringToDouble(ObjectGetString(0, g_prefix + "INP_RR", OBJPROP_TEXT));
         if(new_rr > 0) g_risk_reward_ratio = new_rr;
         
         int new_tf_val = (int)StringToInteger(ObjectGetString(0, g_prefix + "INP_TF", OBJPROP_TEXT));
         if(new_tf_val == 1) g_timeframe = PERIOD_M1;
         else if(new_tf_val == 5) g_timeframe = PERIOD_M5;
         else if(new_tf_val == 15) g_timeframe = PERIOD_M15;
         else if(new_tf_val == 30) g_timeframe = PERIOD_M30;
         else if(new_tf_val == 60) g_timeframe = PERIOD_H1;
         else if(new_tf_val == 240) g_timeframe = PERIOD_H4;
         else if(new_tf_val == 1440) g_timeframe = PERIOD_D1;
         
         double new_lot_val = StringToDouble(ObjectGetString(0, g_prefix + "INP_LOT", OBJPROP_TEXT));
         if(new_lot_val > 0)
         {
            if(g_lot_mode == LOT_FIXED) g_fixed_lot = new_lot_val;
            else g_risk_pct = new_lot_val;
         }
         
         double new_trail_pct = StringToDouble(ObjectGetString(0, g_prefix + "INP_TRAIL_PCT", OBJPROP_TEXT));
         if(new_trail_pct > 0) g_trail_trigger_pct = new_trail_pct;
         
         double new_atr_mult = StringToDouble(ObjectGetString(0, g_prefix + "INP_ATR_MULT", OBJPROP_TEXT));
         if(new_atr_mult > 0) g_atr_multiplier = new_atr_mult;
         
         string str_bmax = ObjectGetString(0, g_prefix + "INP_BULL_MAX", OBJPROP_TEXT);
         StringTrimLeft(str_bmax); StringTrimRight(str_bmax); StringToUpper(str_bmax);
         if(str_bmax == "" || str_bmax == "ALL" || str_bmax == "BEBAS" || str_bmax == "FREE") g_bull_price_max = 0.0;
         else g_bull_price_max = StringToDouble(str_bmax);
         
         string str_smin = ObjectGetString(0, g_prefix + "INP_BEAR_MIN", OBJPROP_TEXT);
         StringTrimLeft(str_smin); StringTrimRight(str_smin); StringToUpper(str_smin);
         if(str_smin == "" || str_smin == "ALL" || str_smin == "BEBAS" || str_smin == "FREE") g_bear_price_min = 0.0;
         else g_bear_price_min = StringToDouble(str_smin);
         
         SaveStateToFile();
         UpdateDashboardUI();
         Alert("Pengaturan Engulfing Auto Trader berhasil disimpan & diterapkan!");
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function (Instant Execution on Engulfing Break)      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_auto_trading_enabled) return;
   
   string sym = _Symbol;
   ENUM_TIMEFRAMES tf = g_timeframe;
   
   // 1. Process active position trailing SL & TP
   ProcessAutoTrailSLTP();
   
   if(g_max_open_trades > 0 && CountOpenPositions(sym) >= g_max_open_trades)
      return;
      
   if(!m_symbol_info.Name(sym)) return;
   m_symbol_info.RefreshRates();
   
   double ask = m_symbol_info.Ask();
   double bid = m_symbol_info.Bid();
   double spread = ask - bid;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   datetime cur_bar_time = (datetime)SeriesInfoInteger(sym, tf, SERIES_LASTBAR_DATE);
   
   double atr_50 = 0.0;
   double broken_level = 0.0;
   double cur_price = 0.0;
   
   // 1. CHECK BUY (Strong Bullish Break)
   if(g_trade_direction == TRADE_DIR_BOTH || g_trade_direction == TRADE_DIR_BUY)
   {
      if(IsStrongBullishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
      {
         // Price boundary filter
         if(g_bull_price_max <= 0.0 || cur_price < g_bull_price_max)
         {
            if(g_last_bull_trade_bar != cur_bar_time)
            {
               g_last_bull_trade_bar = cur_bar_time;
               
               // SL = Low Candle Sebelumnya - 50% ATR
               double sl_price = broken_level - atr_50;
               double sl_dist  = ask - sl_price;
               
               if(sl_dist > 0)
               {
                  // TP = Ask + (SL Distance * RR)
                  double tp_price = ask + (sl_dist * g_risk_reward_ratio);
                  
                  sl_price = NormalizeDouble(sl_price, digits);
                  tp_price = NormalizeDouble(tp_price, digits);
                  double lots = CalculateLotSize(sym, ask, sl_price);
                  
                  if(m_trade.Buy(lots, sym, ask, sl_price, tp_price, "Engulfing Buy (RR 1:" + DoubleToString(g_risk_reward_ratio, 1) + ")"))
                  {
                     ulong deal_tkt = m_trade.ResultOrder();
                     double atr100 = atr_50 * 2.0; // 100% ATR of entry
                     RegisterPositionTracking(deal_tkt, atr100, ask, tp_price);
                     
                     string msg = StringFormat("[AUTO TRADER - ORDER OPENED]\nSymbol: %s (M%d)\nTicket: #%d (BUY)\nLot: %.2f | Ask: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)\n100%% ATR Awal: %.5f",
                                               sym, (int)g_timeframe, deal_tkt, lots, ask, sl_price, tp_price, g_risk_reward_ratio, atr100);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     
                     PrintFormat("BUY Executed: #%d | Lot: %.2f | Ask: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f) | ATR100: %.5f",
                                 deal_tkt, lots, ask, sl_price, tp_price, g_risk_reward_ratio, atr100);
                  }
               }
            }
         }
      }
   }
   
   // 2. CHECK SELL (Strong Bearish Break)
   if(g_trade_direction == TRADE_DIR_BOTH || g_trade_direction == TRADE_DIR_SELL)
   {
      if(IsStrongBearishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
      {
         // Price boundary filter
         if(g_bear_price_min <= 0.0 || cur_price > g_bear_price_min)
         {
            if(g_last_bear_trade_bar != cur_bar_time)
            {
               g_last_bear_trade_bar = cur_bar_time;
               
               // SL = High Candle Sebelumnya + 50% ATR + Spread
               double sl_price = broken_level + atr_50 + spread;
               double sl_dist  = sl_price - bid;
               
               if(sl_dist > 0)
               {
                  // TP = Bid - (SL Distance * RR)
                  double tp_price = bid - (sl_dist * g_risk_reward_ratio);
                  
                  sl_price = NormalizeDouble(sl_price, digits);
                  tp_price = NormalizeDouble(tp_price, digits);
                  double lots = CalculateLotSize(sym, bid, sl_price);
                  
                  if(m_trade.Sell(lots, sym, bid, sl_price, tp_price, "Engulfing Sell (RR 1:" + DoubleToString(g_risk_reward_ratio, 1) + ")"))
                  {
                     ulong deal_tkt = m_trade.ResultOrder();
                     double atr100 = atr_50 * 2.0; // 100% ATR of entry
                     RegisterPositionTracking(deal_tkt, atr100, bid, tp_price);
                     
                     string msg = StringFormat("[AUTO TRADER - ORDER OPENED]\nSymbol: %s (M%d)\nTicket: #%d (SELL)\nLot: %.2f | Bid: %.5f\nSL: %.5f | TP: %.5f (1:%.2f RR)\n100%% ATR Awal: %.5f",
                                               sym, (int)g_timeframe, deal_tkt, lots, bid, sl_price, tp_price, g_risk_reward_ratio, atr100);
                     if(InpEnableSoundAlerts) Alert(msg);
                     if(InpEnablePushAlerts)  SendNotification(msg);
                     
                     PrintFormat("SELL Executed: #%d | Lot: %.2f | Bid: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f) | ATR100: %.5f",
                                 deal_tkt, lots, bid, sl_price, tp_price, g_risk_reward_ratio, atr100);
                  }
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
