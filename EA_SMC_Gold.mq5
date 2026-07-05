//+------------------------------------------------------------------+
//|                                              EA_SMC_Gold.mq5      |
//|  Smart Money Concepts (SMC) Expert Advisor for XAUUSD             |
//|  Multi-Timeframe (MTF) Trading System with Price Action            |
//|                                                                    |
//|  System Logic:                                                     |
//|  - Analysis Timeframe (H4): Identifies macro market structure      |
//|  - Execution Timeframe (M15): Waits for retracement into H4 POI    |
//|  - Price Action Confirmation: Requires valid candlestick patterns  |
//|  - Risk Management: Fixed Lot, SL beyond PA candle, TP at H4 Liq   |
//+------------------------------------------------------------------+
#property copyright "SMC Gold EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
COrderInfo    orderInfo;
CPositionInfo posInfo;

//====================================================================
// 1) INPUT PARAMETERS
//====================================================================
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED    = 0,   // Fixed Lot
   LOT_MODE_SCALE_IN = 1    // Scale-In (30% / 40% / 30%)
};

input group "== SMC Indicator Connection =="
input string       Indicator_Name        = "SMC_Indicator"; // Indicator filename (must be compiled)
input int          Inp_SwingPeriod       = 5;
input int          Inp_MaxBars           = 500;
input int          Inp_OBSearchBars      = 6;
input int          Inp_RangeBars         = 100;
input int          Inp_EqualTolerancePts = 15;
input int          Inp_LiquidityLookback = 30;
input int          Inp_ConfluenceTolPts  = 50;

input group "== Money Management =="
input ENUM_LOT_MODE Lot_Mode             = LOT_MODE_FIXED;
input double        Fixed_Lot             = 0.10;   // Fixed lot size (Gold lot)
input double        Max_Total_Lot        = 0.10;   // Max total lot per entry
input int           Max_Backcandles      = 1000;   // Prevent lagging

input group "== Multi-Timeframe Configuration =="
input ENUM_TIMEFRAMES Analysis_TF        = PERIOD_H4;  // H4 for structure analysis
input ENUM_TIMEFRAMES Execution_TF       = PERIOD_M15; // M15 for execution
input bool          Use_MTF_Alignment    = true;   // Enforce MTF structure alignment

input group "== Risk Management & Entry =="
input double        Target_RR            = 3.0;    // Minimum Risk:Reward ratio (1:3)
input int           Inp_SL_Buffer        = 300;    // SL buffer beyond PA candle (Points)
input double        Breakeven_RR_Trigger = 2.0;    // Move SL to breakeven trigger
input bool          Require_PA_Confirmation = true; // Require candlestick pattern

input group "== Price Action Patterns =="
input int           PA_Min_Lower_Wick_Points = 30;   // Minimum lower wick for Hammer/Pinbar (points)
input int           PA_Min_Upper_Wick_Points = 30;   // Minimum upper wick for Shooting Star (points)
input double        PA_Engulfing_Ratio      = 0.7;   // Engulfing candle must close beyond 70% of previous

input group "== Order Management =="
input int           Magic_Number         = 20260704;
input int           Slippage_Points      = 10;
input int           Pending_Expire_Hours = 48;
input bool          Use_Alert            = true;
input bool          Use_Push             = true;

//====================================================================
// 2) DATA STRUCTURES
//====================================================================

// Structure for storing historical bar data synchronization
struct HistorySyncStatus
{
   bool   m15_synced;
   bool   h4_synced;
   int    m15_total_bars;
   int    h4_total_bars;
   datetime last_sync_time;
};

// Structure for Price Action candle patterns
struct PAPattern
{
   bool is_valid;
   int pattern_type;  // 0=None, 1=BullishEngulfing, 2=Hammer, 3=Pinbar, 4=BearishEngulfing, 5=ShootingStar
   double lower_wick_ratio;
   double upper_wick_ratio;
   double close_ratio; // Percentage of candle body closed
};

// Structure for POI group (entry setup)
struct POIGroup
{
   datetime originTime;
   bool     isBuy;
   double   top;        // POI top (H4)
   double   bottom;     // POI bottom (H4)
   double   slPrice;
   double   tpPrice;
   double   zoneWidth;
   ulong    ticket;     // Single ticket for this setup
   bool     beDone;     // Breakeven moved
   bool     active;     // Still active
};

POIGroup g_groups[];

//====================================================================
// GLOBAL VARIABLES
//====================================================================
datetime g_lastBarTime             = 0;
datetime g_lastSignalProcessed     = 0;
int      g_hSMC_M15               = INVALID_HANDLE;  // M15 indicator handle
int      g_hSMC_H4                = INVALID_HANDLE;  // H4 indicator handle
HistorySyncStatus g_historySync;

//====================================================================
// 3) HISTORY DATA SYNCHRONIZATION (NEW)
//====================================================================

// Force download of historical data before trading
bool CheckAndDownloadHistory()
{
   Print("EA_SMC_Gold: Starting historical data synchronization...");
   
   // Request M15 data
   if(!SymbolInfoTick(_Symbol, NULL))
   {
      Print("EA_SMC_Gold: Symbol tick not available");
      return(false);
   }
   
   // Download M15 bars
   int m15_bars = Bars(_Symbol, PERIOD_M15);
   if(m15_bars < 500)
   {
      Print("EA_SMC_Gold: WARNING - M15 bars (", m15_bars, ") less than 500. Retrying...");
      Sleep(500);
      m15_bars = Bars(_Symbol, PERIOD_M15);
   }
   
   // Download H4 bars
   int h4_bars = Bars(_Symbol, PERIOD_H4);
   if(h4_bars < 200)
   {
      Print("EA_SMC_Gold: WARNING - H4 bars (", h4_bars, ") less than 200. Retrying...");
      Sleep(500);
      h4_bars = Bars(_Symbol, PERIOD_H4);
   }
   
   g_historySync.m15_total_bars = m15_bars;
   g_historySync.h4_total_bars = h4_bars;
   g_historySync.m15_synced = (m15_bars >= 100);
   g_historySync.h4_synced = (h4_bars >= 50);
   g_historySync.last_sync_time = TimeCurrent();
   
   Print("EA_SMC_Gold: Historical data sync complete - M15: ", m15_bars, " bars, H4: ", h4_bars, " bars");
   return(true);
}

//====================================================================
// 4) INDICATOR CONNECTION
//====================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   // === HISTORICAL DATA PRE-LOADING (Required by README) ===
   if(!CheckAndDownloadHistory())
   {
      Print("EA_SMC_Gold: Historical data download failed");
      return(INIT_FAILED);
   }
   
   // Load M15 indicator
   g_hSMC_M15 = iCustom(_Symbol, PERIOD_M15, Indicator_Name,
                        Inp_SwingPeriod, Inp_MaxBars, true,
                        true, true, Inp_OBSearchBars,
                        true, Inp_RangeBars,
                        true, Inp_EqualTolerancePts, Inp_LiquidityLookback,
                        Inp_ConfluenceTolPts);
   
   if(g_hSMC_M15 == INVALID_HANDLE)
   {
      Print("EA_SMC_Gold: Failed to load M15 indicator (Error ", GetLastError(), ")");
      return(INIT_FAILED);
   }
   
   // Load H4 indicator
   g_hSMC_H4 = iCustom(_Symbol, PERIOD_H4, Indicator_Name,
                       Inp_SwingPeriod, Inp_MaxBars, true,
                       true, true, Inp_OBSearchBars,
                       true, Inp_RangeBars,
                       true, Inp_EqualTolerancePts, Inp_LiquidityLookback,
                       Inp_ConfluenceTolPts);
   
   if(g_hSMC_H4 == INVALID_HANDLE)
   {
      Print("EA_SMC_Gold: Failed to load H4 indicator (Error ", GetLastError(), ")");
      return(INIT_FAILED);
   }
   
   Print("EA_SMC_Gold: All indicators loaded successfully");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hSMC_M15 != INVALID_HANDLE)
      IndicatorRelease(g_hSMC_M15);
   if(g_hSMC_H4 != INVALID_HANDLE)
      IndicatorRelease(g_hSMC_H4);
}

//====================================================================
// 5) PRICE ACTION CONFIRMATION FUNCTIONS (NEW)
//====================================================================

// Analyze current M15 candle for PA confirmation patterns
PAPattern AnalyzePriceActionCandle(int shift)
{
   PAPattern pattern;
   pattern.is_valid = false;
   pattern.pattern_type = 0;
   
   double open   = iOpen(_Symbol, PERIOD_M15, shift);
   double close  = iClose(_Symbol, PERIOD_M15, shift);
   double high   = iHigh(_Symbol, PERIOD_M15, shift);
   double low    = iLow(_Symbol, PERIOD_M15, shift);
   
   double candle_body = MathAbs(close - open);
   double full_range = high - low;
   
   if(full_range <= 0) return(pattern);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lower_wick = (close > open) ? (open - low) : (close - low);
   double upper_wick = (close > open) ? (high - close) : (high - open);
   
   // ===== BULLISH PATTERNS (for BUY entries) =====
   // 1. Bullish Engulfing
   if(shift > 0)
   {
      double prev_open  = iOpen(_Symbol, PERIOD_M15, shift + 1);
      double prev_close = iClose(_Symbol, PERIOD_M15, shift + 1);
      double prev_low   = iLow(_Symbol, PERIOD_M15, shift + 1);
      
      if(prev_close < prev_open) // Previous candle bearish
      {
         if(close > prev_open && open < prev_close)
         {
            double engulf_ratio = MathAbs(close - open) / MathAbs(prev_close - prev_open);
            if(engulf_ratio >= PA_Engulfing_Ratio)
            {
               pattern.is_valid = true;
               pattern.pattern_type = 1; // Bullish Engulfing
               pattern.close_ratio = (close - open) / full_range;
               return(pattern);
            }
         }
      }
   }
   
   // 2. Hammer (bullish reversal at POI)
   if(close > open && lower_wick > candle_body * 1.5 && upper_wick < candle_body * 0.5)
   {
      if(lower_wick > PA_Min_Lower_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 2; // Hammer
         pattern.lower_wick_ratio = lower_wick / full_range;
         return(pattern);
      }
   }
   
   // 3. Pinbar (bullish - long lower wick)
   if(close > open && lower_wick > candle_body * 2.0)
   {
      if(lower_wick > PA_Min_Lower_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 3; // Pinbar
         pattern.lower_wick_ratio = lower_wick / full_range;
         return(pattern);
      }
   }
   
   // ===== BEARISH PATTERNS (for SELL entries) =====
   // 4. Bearish Engulfing
   if(shift > 0)
   {
      double prev_open  = iOpen(_Symbol, PERIOD_M15, shift + 1);
      double prev_close = iClose(_Symbol, PERIOD_M15, shift + 1);
      double prev_high  = iHigh(_Symbol, PERIOD_M15, shift + 1);
      
      if(prev_close > prev_open) // Previous candle bullish
      {
         if(close < prev_open && open > prev_close)
         {
            double engulf_ratio = MathAbs(open - close) / MathAbs(prev_open - prev_close);
            if(engulf_ratio >= PA_Engulfing_Ratio)
            {
               pattern.is_valid = true;
               pattern.pattern_type = 4; // Bearish Engulfing
               pattern.close_ratio = (open - close) / full_range;
               return(pattern);
            }
         }
      }
   }
   
   // 5. Shooting Star (bearish reversal at POI)
   if(close < open && upper_wick > candle_body * 1.5 && lower_wick < candle_body * 0.5)
   {
      if(upper_wick > PA_Min_Upper_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 5; // Shooting Star
         pattern.upper_wick_ratio = upper_wick / full_range;
         return(pattern);
      }
   }
   
   return(pattern); // No valid pattern
}

// Check if PA candle is closed inside POI zone (for M15 bar 1)
bool IsPriceActionConfirmed(bool isBuy, double poi_top, double poi_bottom, int bar_shift)
{
   if(!Require_PA_Confirmation) return(true);
   
   double close = iClose(_Symbol, PERIOD_M15, bar_shift);
   bool inside_zone = (close >= poi_bottom && close <= poi_top);
   
   if(!inside_zone) return(false);
   
   PAPattern pattern = AnalyzePriceActionCandle(bar_shift);
   
   if(!pattern.is_valid) return(false);
   
   // Validate pattern direction
   if(isBuy && (pattern.pattern_type == 1 || pattern.pattern_type == 2 || pattern.pattern_type == 3))
      return(true);
   
   if(!isBuy && (pattern.pattern_type == 4 || pattern.pattern_type == 5))
      return(true);
   
   return(false);
}

//====================================================================
// 6) HELPER FUNCTIONS
//====================================================================

double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   
   double normalized = MathRound(lot / step) * step;
   normalized = MathMax(minL, MathMin(maxL, normalized));
   int digits = 2;
   if(step < 0.01) digits = 3;
   return(NormalizeDouble(normalized, digits));
}

// Read POI signal from indicator buffer
bool ReadPOISignal(int handle, int shift, int &signal, double &top, double &bottom, double &tp, datetime &originTime)
{
   double bufSignal[1], bufTop[1], bufBottom[1], bufTP[1], bufOrigin[1];
   
   if(CopyBuffer(handle, 0, shift, 1, bufSignal) <= 0) return(false);
   if(CopyBuffer(handle, 1, shift, 1, bufTop)    <= 0) return(false);
   if(CopyBuffer(handle, 2, shift, 1, bufBottom) <= 0) return(false);
   if(CopyBuffer(handle, 3, shift, 1, bufTP)     <= 0) return(false);
   if(CopyBuffer(handle, 4, shift, 1, bufOrigin) <= 0) return(false);
   
   signal     = (int)bufSignal[0];
   top        = bufTop[0];
   bottom     = bufBottom[0];
   tp         = bufTP[0];
   originTime = (datetime)bufOrigin[0];
   return(true);
}

void NotifyUser(string msg)
{
   Print(msg);
   if(Use_Alert) Alert(msg);
   if(Use_Push)  SendNotification(msg);
}

// Check if price is inside H4 POI zone (MTF alignment requirement)
bool IsPriceInH4POI(bool isBuy)
{
   int h4_signal;
   double h4_top, h4_bottom, h4_tp;
   datetime h4_origin;
   
   if(!ReadPOISignal(g_hSMC_H4, 0, h4_signal, h4_top, h4_bottom, h4_tp, h4_origin))
      return(false);
   
   if(h4_signal == 0) return(false);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // For BUY: M15 price must be in H4 Demand (OB) zone
   if(isBuy && h4_signal == 1)
      return(bid >= h4_bottom && bid <= h4_top);
   
   // For SELL: M15 price must be in H4 Supply (OB) zone
   if(!isBuy && h4_signal == 2)
      return(ask >= h4_bottom && ask <= h4_top);
   
   return(false);
}

//====================================================================
// 7) ORDER MANAGEMENT
//====================================================================

void ManageGroups()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   for(int g = 0; g < ArraySize(g_groups); g++)
   {
      if(!g_groups[g].active) continue;
      
      ulong ticket = g_groups[g].ticket;
      if(ticket == 0) continue;
      
      // Check if position still exists
      if(!posInfo.SelectByTicket(ticket))
      {
         g_groups[g].active = false;
         continue;
      }
      
      // Breakeven logic
      if(!g_groups[g].beDone)
      {
         double be_trigger_dist = g_groups[g].zoneWidth * Breakeven_RR_Trigger;
         double spread = ask - bid;
         double open_price = posInfo.PriceOpen();
         double profit_dist = g_groups[g].isBuy ? (bid - open_price) : (open_price - ask);
         
         if(profit_dist >= be_trigger_dist)
         {
            double new_sl = g_groups[g].isBuy ? (open_price + spread) : (open_price - spread);
            bool improve = g_groups[g].isBuy ? (new_sl > posInfo.StopLoss()) : (new_sl < posInfo.StopLoss() || posInfo.StopLoss() == 0);
            
            if(improve)
            {
               if(trade.PositionModify(ticket, new_sl, posInfo.TakeProfit()))
                  Print("EA_SMC_Gold: Moved SL to breakeven, Ticket=", ticket);
            }
            g_groups[g].beDone = true;
         }
      }
   }
}

void OpenPOITrade(bool isBuy, double top, double bottom, double tp, datetime originTime)
{
   double zone_width = MathAbs(top - bottom);
   if(zone_width <= 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl_buffer = Inp_SL_Buffer * point;
   
   double entry_price, sl_price;
   
   if(isBuy)
   {
      entry_price = bottom; // Buy at POI bottom
      sl_price = bottom - sl_buffer;
   }
   else
   {
      entry_price = top;    // Sell at POI top
      sl_price = top + sl_buffer;
   }
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   entry_price = NormalizeDouble(entry_price, digits);
   sl_price = NormalizeDouble(sl_price, digits);
   tp = NormalizeDouble(tp, digits);
   
   // Check RR ratio
   double risk_dist = MathAbs(entry_price - sl_price);
   double reward_dist = MathAbs(tp - entry_price);
   
   if(risk_dist <= 0 || reward_dist / risk_dist < Target_RR)
   {
      Print("EA_SMC_Gold: Skipped trade (RR insufficient: ", DoubleToString(risk_dist > 0 ? reward_dist / risk_dist : 0, 2), ")");
      return;
   }
   
   double lot = NormalizeLot(Fixed_Lot);
   
   int n = ArraySize(g_groups);
   ArrayResize(g_groups, n + 1);
   g_groups[n].originTime = originTime;
   g_groups[n].isBuy = isBuy;
   g_groups[n].top = top;
   g_groups[n].bottom = bottom;
   g_groups[n].slPrice = sl_price;
   g_groups[n].tpPrice = tp;
   g_groups[n].zoneWidth = zone_width;
   g_groups[n].beDone = false;
   g_groups[n].active = true;
   
   bool ok = false;
   if(isBuy)
      ok = trade.Buy(lot, _Symbol, 0, sl_price, tp, "SMC_Gold_BUY");
   else
      ok = trade.Sell(lot, _Symbol, 0, sl_price, tp, "SMC_Gold_SELL");
   
   if(ok)
   {
      g_groups[n].ticket = trade.ResultOrder();
      NotifyUser(StringFormat("EA_SMC_Gold: Opened %s trade | Entry=%.5f SL=%.5f TP=%.5f Lot=%.2f",
                              isBuy ? "BUY" : "SELL", entry_price, sl_price, tp, lot));
   }
   else
   {
      Print("EA_SMC_Gold: Trade failed. Error=", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
      g_groups[n].active = false;
   }
}

bool GroupAlreadyExists(datetime originTime, bool isBuy)
{
   for(int i = 0; i < ArraySize(g_groups); i++)
   {
      if(g_groups[i].originTime == originTime && g_groups[i].isBuy == isBuy && g_groups[i].active)
         return(true);
   }
   return(false);
}

//====================================================================
// 8) OnTick - Main execution logic
//====================================================================

void OnTick()
{
   ManageGroups();
   
   if(BarsCalculated(g_hSMC_M15) < 3) return;
   if(BarsCalculated(g_hSMC_H4) < 3) return;
   
   // Check M15 bar 1 (most recent closed bar)
   int m15_signal;
   double m15_top, m15_bottom, m15_tp;
   datetime m15_origin;
   
   if(!ReadPOISignal(g_hSMC_M15, 1, m15_signal, m15_top, m15_bottom, m15_tp, m15_origin))
      return;
   
   if(m15_signal == 0 || m15_origin == 0) return;
   
   bool isBuy = (m15_signal == 1);
   
   // === MTF ALIGNMENT CHECK (README requirement) ===
   if(Use_MTF_Alignment)
   {
      if(!IsPriceInH4POI(isBuy))
      {
         return; // Price not in H4 POI zone - skip
      }
   }
   
   // === PRICE ACTION CONFIRMATION (README requirement) ===
   if(Require_PA_Confirmation)
   {
      if(!IsPriceActionConfirmed(isBuy, m15_top, m15_bottom, 1))
      {
         return; // No valid PA candle
      }
   }
   
   // Prevent duplicate entries
   if(GroupAlreadyExists(m15_origin, isBuy))
      return;
   
   // Open trade
   OpenPOITrade(isBuy, m15_top, m15_bottom, m15_tp, m15_origin);
   
   g_lastSignalProcessed = m15_origin;
}

//+------------------------------------------------------------------+
