//+------------------------------------------------------------------+
//|                                   EngulfingAutoTrader.mq5        |
//|                             Copyright 2026, Multi-Symbol Manager |
//|                                  https://github.com/1jehuang/jcode|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Symbol Manager"
#property link      "https://github.com/1jehuang/jcode"
#property version   "1.00"
#property description "Auto Execution EA on Realtime Strong Engulfing Break with Dynamic Risk-to-Reward (RR)"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                            |
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

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== TRADE EXECUTION SETTINGS ==="
input ENUM_TRADE_DIRECTION InpTradeDirection   = TRADE_DIR_BOTH; // Trading Direction
input double               InpRiskRewardRatio  = 2.0;            // Risk Reward Ratio (1:RR, e.g. 1.5, 2.0, 2.5)
input int                  InpMaxOpenTrades    = 1;              // Max Open Trades per Symbol (0 = Unlimited)
input int                  InpSlippage         = 10;             // Max Slippage (Points)
input ulong                InpMagicNumber      = 882201;         // Magic Number

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

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol_info;

datetime       g_last_bull_trade_bar = 0;
datetime       g_last_bear_trade_bar = 0;

//+------------------------------------------------------------------+
//| FAST DIRECT ATR CALCULATION (ponytail: No indicator handles)     |
//+------------------------------------------------------------------+
double CalculateATR50(const string sym, const ENUM_TIMEFRAMES tf, int period)
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
   double atr = tr_sum / (double)period;
   return (atr * 0.5); // 50% ATR
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
   if(InpLotMode == LOT_FIXED) return InpFixedLot;
   
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double sl_distance = MathAbs(entry_price - sl_price);
   if(sl_distance <= 0) return InpFixedLot;
   
   double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0 || tick_value <= 0) return InpFixedLot;
   
   double point_loss_per_lot = (sl_distance / tick_size) * tick_value;
   if(point_loss_per_lot <= 0) return InpFixedLot;
   
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
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   PrintFormat("EngulfingAutoTrader Initialized | Direction: %s | RR 1:%.2f | TF: %s",
               EnumToString(InpTradeDirection), InpRiskRewardRatio, EnumToString(InpTimeframe));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EngulfingAutoTrader Deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function (Instant Execution on Engulfing Break)      |
//+------------------------------------------------------------------+
void OnTick()
{
   string sym = _Symbol;
   ENUM_TIMEFRAMES tf = InpTimeframe;
   
   if(InpMaxOpenTrades > 0 && CountOpenPositions(sym) >= InpMaxOpenTrades)
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
   if(InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_BUY)
   {
      if(IsStrongBullishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
      {
         // Price boundary filter
         if(InpBullishPriceMax <= 0.0 || cur_price < InpBullishPriceMax)
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
                  double tp_price = ask + (sl_dist * InpRiskRewardRatio);
                  
                  sl_price = NormalizeDouble(sl_price, digits);
                  tp_price = NormalizeDouble(tp_price, digits);
                  double lots = CalculateLotSize(sym, ask, sl_price);
                  
                  if(m_trade.Buy(lots, sym, ask, sl_price, tp_price, "Engulfing Buy (RR 1:" + DoubleToString(InpRiskRewardRatio, 1) + ")"))
                  {
                     PrintFormat("BUY Executed: #%d | Lot: %.2f | Ask: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f)",
                                 m_trade.ResultOrder(), lots, ask, sl_price, tp_price, InpRiskRewardRatio);
                  }
               }
            }
         }
      }
   }
   
   // 2. CHECK SELL (Strong Bearish Break)
   if(InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_SELL)
   {
      if(IsStrongBearishEngulfingBreak(sym, tf, atr_50, broken_level, cur_price))
      {
         // Price boundary filter
         if(InpBearishPriceMin <= 0.0 || cur_price > InpBearishPriceMin)
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
                  double tp_price = bid - (sl_dist * InpRiskRewardRatio);
                  
                  sl_price = NormalizeDouble(sl_price, digits);
                  tp_price = NormalizeDouble(tp_price, digits);
                  double lots = CalculateLotSize(sym, bid, sl_price);
                  
                  if(m_trade.Sell(lots, sym, bid, sl_price, tp_price, "Engulfing Sell (RR 1:" + DoubleToString(InpRiskRewardRatio, 1) + ")"))
                  {
                     PrintFormat("SELL Executed: #%d | Lot: %.2f | Bid: %.5f | SL: %.5f | TP: %.5f (RR 1:%.2f)",
                                 m_trade.ResultOrder(), lots, bid, sl_price, tp_price, InpRiskRewardRatio);
                  }
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
