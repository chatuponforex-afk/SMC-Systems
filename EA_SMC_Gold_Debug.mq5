//+------------------------------------------------------------------+
//|                                      EA_SMC_Gold_Debug.mq5       |
//|  Smart Money Concepts (SMC) Expert Advisor - DEBUG VERSION 2      |
//|  Multi-Timeframe (MTF) Trading System with Dashboard              |
//|  RELAXED PA PATTERNS + CURRENT BAR + DEBUG LOGS                   |
//+------------------------------------------------------------------+
#property copyright "SMC Gold EA - Debug v2"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
COrderInfo    orderInfo;
CPositionInfo posInfo;

//====================================================================
// INPUT PARAMETERS
//====================================================================
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED    = 0,
   LOT_MODE_SCALE_IN = 1
};

input group "== SMC Indicator Connection =="
input string       Indicator_Name        = "SMC_Indicator";
input int          Inp_SwingPeriod       = 5;
input int          Inp_MaxBars           = 500;
input int          Inp_OBSearchBars      = 6;
input int          Inp_RangeBars         = 100;
input int          Inp_EqualTolerancePts = 15;
input int          Inp_LiquidityLookback = 30;
input int          Inp_ConfluenceTolPts  = 50;

input group "== Money Management =="
input ENUM_LOT_MODE Lot_Mode             = LOT_MODE_FIXED;
input double        Fixed_Lot             = 0.10;
input double        Max_Total_Lot        = 0.10;
input int           Max_Backcandles      = 1000;

input group "== Multi-Timeframe Configuration =="
input ENUM_TIMEFRAMES Analysis_TF        = PERIOD_H4;
input ENUM_TIMEFRAMES Execution_TF       = PERIOD_M15;
input bool          Use_MTF_Alignment    = true;

input group "== Risk Management & Entry =="
input double        Target_RR            = 2.5;  // RELAXED from 3.0
input int           Inp_SL_Buffer        = 300;
input double        Breakeven_RR_Trigger = 2.0;
input bool          Require_PA_Confirmation = true;

input group "== Price Action Patterns (RELAXED) =="
input int           PA_Min_Lower_Wick_Points = 20;   // RELAXED from 30
input int           PA_Min_Upper_Wick_Points = 20;   // RELAXED from 30
input double        PA_Engulfing_Ratio      = 0.6;   // RELAXED from 0.7
input bool          Allow_Inside_Bar        = false; // Allow bar inside zone

input group "== Order Management =="
input int           Magic_Number         = 20260704;
input int           Slippage_Points      = 10;
input int           Pending_Expire_Hours = 48;
input bool          Use_Alert            = true;
input bool          Use_Push             = true;

input group "== DEBUG Dashboard =="
input bool          Show_Dashboard       = true;
input bool          Show_Debug_Logs      = true;

//====================================================================
// DATA STRUCTURES
//====================================================================

struct HistorySyncStatus
{
   bool   m15_synced;
   bool   h4_synced;
   int    m15_total_bars;
   int    h4_total_bars;
   datetime last_sync_time;
};

struct PAPattern
{
   bool is_valid;
   int pattern_type;
   string pattern_name;
   double lower_wick_ratio;
   double upper_wick_ratio;
   double close_ratio;
};

struct POIGroup
{
   datetime originTime;
   bool     isBuy;
   double   top;
   double   bottom;
   double   slPrice;
   double   tpPrice;
   double   zoneWidth;
   ulong    ticket;
   bool     beDone;
   bool     active;
};

//====================================================================
// GLOBAL VARIABLES
//====================================================================
POIGroup g_groups[];
datetime g_lastBarTime             = 0;
datetime g_lastSignalProcessed     = 0;
int      g_hSMC_M15               = INVALID_HANDLE;
int      g_hSMC_H4                = INVALID_HANDLE;
HistorySyncStatus g_historySync;

int g_tick_counter = 0;
int g_check_counter = 0;

//====================================================================
// DASHBOARD FUNCTIONS - Using Comment()
//====================================================================

void UpdateDashboard(string m15_signal_text, string h4_signal_text, string pa_pattern_text, 
                     string rr_ratio_text, string mtf_check_text, string entry_reason_text)
{
   if(!Show_Dashboard) return;
   
   g_tick_counter++;
   
   string dashboard_text = "";
   dashboard_text += "TIME: " + TimeToString(TimeCurrent()) + " | TICK: " + IntegerToString(g_tick_counter) + "\n";
   dashboard_text += "\n";
   dashboard_text += "M15 SIGNAL: " + m15_signal_text + "\n";
   dashboard_text += "H4 SIGNAL:  " + h4_signal_text + "\n";
   dashboard_text += "\n";
   dashboard_text += "PA PATTERN: " + pa_pattern_text + "\n";
   dashboard_text += "RR RATIO:   " + rr_ratio_text + "\n";
   dashboard_text += "\n";
   dashboard_text += "MTF CHECK:  " + mtf_check_text + "\n";
   dashboard_text += "ENTRY:      " + entry_reason_text + "\n";
   
   Comment(dashboard_text);
}

void DebugLog(string msg)
{
   if(Show_Debug_Logs)
   {
      g_check_counter++;
      Print("[CHECK #", g_check_counter, "] ", msg);
   }
}

//====================================================================
// ALERT FUNCTIONS
//====================================================================

void AlertSignal(bool isBuy, string pa_pattern, double rr_ratio)
{
   string alert_msg = StringFormat(
      "[SMC GOLD EA] SIGNAL DETECTED!\n"
      "Direction: %s\n"
      "PA Pattern: %s\n"
      "RR Ratio: %.2f:1\n"
      "Status: READY TO ENTER",
      isBuy ? "BUY" : "SELL",
      pa_pattern,
      rr_ratio
   );
   
   DebugLog("ALERT TRIGGERED: " + alert_msg);
   if(Use_Alert) Alert(alert_msg);
   if(Use_Push) SendNotification(alert_msg);
}

void AlertEntry(bool isBuy, double entry_price, double sl_price, double tp_price, double lot)
{
   string entry_msg = StringFormat(
      "[SMC GOLD EA] TRADE ENTRY EXECUTED!\n"
      "Direction: %s\n"
      "Entry: %.5f\n"
      "SL: %.5f\n"
      "TP: %.5f\n"
      "Lot: %.2f",
      isBuy ? "BUY" : "SELL",
      entry_price,
      sl_price,
      tp_price,
      lot
   );
   
   if(Use_Alert) Alert(entry_msg);
   if(Use_Push) SendNotification(entry_msg);
}

//====================================================================
// HISTORY DATA SYNCHRONIZATION
//====================================================================

bool CheckAndDownloadHistory()
{
   Print("=== EA_SMC_Gold: Starting historical data synchronization ===");
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("ERROR: Symbol tick not available");
      return(false);
   }
   
   int m15_bars = Bars(_Symbol, PERIOD_M15);
   if(m15_bars < 500)
   {
      Print("WARNING: M15 bars (", m15_bars, ") < 500, retrying...");
      Sleep(500);
      m15_bars = Bars(_Symbol, PERIOD_M15);
   }
   
   int h4_bars = Bars(_Symbol, PERIOD_H4);
   if(h4_bars < 200)
   {
      Print("WARNING: H4 bars (", h4_bars, ") < 200, retrying...");
      Sleep(500);
      h4_bars = Bars(_Symbol, PERIOD_H4);
   }
   
   g_historySync.m15_total_bars = m15_bars;
   g_historySync.h4_total_bars = h4_bars;
   g_historySync.m15_synced = (m15_bars >= 100);
   g_historySync.h4_synced = (h4_bars >= 50);
   g_historySync.last_sync_time = TimeCurrent();
   
   Print("OK: Historical data sync complete:");
   Print("   M15: ", m15_bars, " bars (Synced: ", (g_historySync.m15_synced ? "Yes" : "No"), ")");
   Print("   H4: ", h4_bars, " bars (Synced: ", (g_historySync.h4_synced ? "Yes" : "No"), ")");
   Print("===================================================================");
   
   return(true);
}

//====================================================================
// INDICATOR CONNECTION
//====================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   Print("\n\n");
   Print("================== EA_SMC_Gold DEBUG v2 STARTING ==================");
   Print("VERSION: 2.00 - RELAXED PA + CURRENT BAR + DEBUG");
   
   if(!CheckAndDownloadHistory())
   {
      Print("FAILED: Historical data download failed");
      return(INIT_FAILED);
   }
   
   g_hSMC_M15 = iCustom(_Symbol, PERIOD_M15, Indicator_Name,
                        Inp_SwingPeriod, Inp_MaxBars, true,
                        true, true, Inp_OBSearchBars,
                        true, Inp_RangeBars,
                        true, Inp_EqualTolerancePts, Inp_LiquidityLookback,
                        Inp_ConfluenceTolPts);
   
   if(g_hSMC_M15 == INVALID_HANDLE)
   {
      Print("FAILED: M15 Indicator Load (Error ", GetLastError(), ")");
      return(INIT_FAILED);
   }
   Print("OK: M15 Indicator Loaded");
   
   g_hSMC_H4 = iCustom(_Symbol, PERIOD_H4, Indicator_Name,
                       Inp_SwingPeriod, Inp_MaxBars, true,
                       true, true, Inp_OBSearchBars,
                       true, Inp_RangeBars,
                       true, Inp_EqualTolerancePts, Inp_LiquidityLookback,
                       Inp_ConfluenceTolPts);
   
   if(g_hSMC_H4 == INVALID_HANDLE)
   {
      Print("FAILED: H4 Indicator Load (Error ", GetLastError(), ")");
      return(INIT_FAILED);
   }
   Print("OK: H4 Indicator Loaded");
   
   Print("OK: All Indicators Loaded Successfully");
   Print("=====================================================================\n");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hSMC_M15 != INVALID_HANDLE)
      IndicatorRelease(g_hSMC_M15);
   if(g_hSMC_H4 != INVALID_HANDLE)
      IndicatorRelease(g_hSMC_H4);
   
   Comment("");
   Print("EA_SMC_Gold Stopped");
}

//====================================================================
// PRICE ACTION ANALYSIS (RELAXED VERSION)
//====================================================================

PAPattern AnalyzePriceActionCandle(int shift)
{
   PAPattern pattern;
   pattern.is_valid = false;
   pattern.pattern_type = 0;
   pattern.pattern_name = "NONE";
   
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
   
   DebugLog(StringFormat("PA Check [Shift %d]: Body=%.0f Range=%.0f LowerWick=%.0f UpperWick=%.0f",
            shift, candle_body, full_range, lower_wick, upper_wick));
   
   // BULLISH PATTERNS
   // 1. Bullish Engulfing (RELAXED)
   if(shift > 0)
   {
      double prev_open  = iOpen(_Symbol, PERIOD_M15, shift + 1);
      double prev_close = iClose(_Symbol, PERIOD_M15, shift + 1);
      
      if(prev_close < prev_open && close > prev_open && open < prev_close)
      {
         double engulf_ratio = MathAbs(close - open) / MathAbs(prev_close - prev_open);
         if(engulf_ratio >= PA_Engulfing_Ratio)
         {
            pattern.is_valid = true;
            pattern.pattern_type = 1;
            pattern.pattern_name = "BULLISH ENGULFING";
            pattern.close_ratio = (close - open) / full_range;
            DebugLog("PA MATCH: Bullish Engulfing (Ratio=" + DoubleToString(engulf_ratio, 2) + ")");
            return(pattern);
         }
      }
   }
   
   // 2. Hammer (RELAXED)
   if(close > open && lower_wick > candle_body * 1.5 && upper_wick < candle_body * 0.5)
   {
      if(lower_wick > PA_Min_Lower_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 2;
         pattern.pattern_name = "HAMMER";
         pattern.lower_wick_ratio = lower_wick / full_range;
         DebugLog("PA MATCH: Hammer (LowerWick=" + DoubleToString(pattern.lower_wick_ratio * 100, 1) + "%)");
         return(pattern);
      }
   }
   
   // 3. Pinbar (RELAXED)
   if(close > open && lower_wick > candle_body * 1.5)
   {
      if(lower_wick > PA_Min_Lower_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 3;
         pattern.pattern_name = "PINBAR (Lower Wick)";
         pattern.lower_wick_ratio = lower_wick / full_range;
         DebugLog("PA MATCH: Pinbar LowerWick (Ratio=" + DoubleToString(pattern.lower_wick_ratio * 100, 1) + "%)");
         return(pattern);
      }
   }
   
   // BEARISH PATTERNS
   // 4. Bearish Engulfing (RELAXED)
   if(shift > 0)
   {
      double prev_open  = iOpen(_Symbol, PERIOD_M15, shift + 1);
      double prev_close = iClose(_Symbol, PERIOD_M15, shift + 1);
      
      if(prev_close > prev_open && close < prev_open && open > prev_close)
      {
         double engulf_ratio = MathAbs(open - close) / MathAbs(prev_open - prev_close);
         if(engulf_ratio >= PA_Engulfing_Ratio)
         {
            pattern.is_valid = true;
            pattern.pattern_type = 4;
            pattern.pattern_name = "BEARISH ENGULFING";
            pattern.close_ratio = (open - close) / full_range;
            DebugLog("PA MATCH: Bearish Engulfing (Ratio=" + DoubleToString(engulf_ratio, 2) + ")");
            return(pattern);
         }
      }
   }
   
   // 5. Shooting Star (RELAXED)
   if(close < open && upper_wick > candle_body * 1.5 && lower_wick < candle_body * 0.5)
   {
      if(upper_wick > PA_Min_Upper_Wick_Points * point)
      {
         pattern.is_valid = true;
         pattern.pattern_type = 5;
         pattern.pattern_name = "SHOOTING STAR";
         pattern.upper_wick_ratio = upper_wick / full_range;
         DebugLog("PA MATCH: Shooting Star (UpperWick=" + DoubleToString(pattern.upper_wick_ratio * 100, 1) + "%)");
         return(pattern);
      }
   }
   
   return(pattern);
}

bool IsPriceActionConfirmed(bool isBuy, double poi_top, double poi_bottom, int bar_shift)
{
   if(!Require_PA_Confirmation) 
   {
      DebugLog("PA Confirmation: DISABLED");
      return(true);
   }
   
   double close = iClose(_Symbol, PERIOD_M15, bar_shift);
   bool inside_zone = (close >= poi_bottom && close <= poi_top);
   
   DebugLog(StringFormat("Price Inside Zone Check: Close=%.2f POI[%.2f-%.2f] = %s",
            close, poi_bottom, poi_top, inside_zone ? "YES" : "NO"));
   
   if(!inside_zone) 
   {
      DebugLog("PA FAIL: Price not inside POI zone");
      return(false);
   }
   
   PAPattern pattern = AnalyzePriceActionCandle(bar_shift);
   
   if(!pattern.is_valid) 
   {
      DebugLog("PA FAIL: No valid pattern detected");
      return(false);
   }
   
   if(isBuy && (pattern.pattern_type == 1 || pattern.pattern_type == 2 || pattern.pattern_type == 3))
      return(true);
   
   if(!isBuy && (pattern.pattern_type == 4 || pattern.pattern_type == 5))
      return(true);
   
   DebugLog("PA FAIL: Pattern type mismatch (isBuy=" + (isBuy ? "YES" : "NO") + " type=" + IntegerToString(pattern.pattern_type) + ")");
   return(false);
}

//====================================================================
// HELPER FUNCTIONS
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

bool IsPriceInH4POI(bool isBuy, double &h4_top, double &h4_bottom)
{
   int h4_signal;
   double h4_tp;
   datetime h4_origin;
   
   if(!ReadPOISignal(g_hSMC_H4, 0, h4_signal, h4_top, h4_bottom, h4_tp, h4_origin))
      return(false);
   
   if(h4_signal == 0) return(false);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(isBuy && h4_signal == 1)
      return(bid >= h4_bottom && bid <= h4_top);
   
   if(!isBuy && h4_signal == 2)
      return(ask >= h4_bottom && ask <= h4_top);
   
   return(false);
}

//====================================================================
// ORDER MANAGEMENT
//====================================================================

void ManageGroups()
{
   for(int g = 0; g < ArraySize(g_groups); g++)
   {
      if(!g_groups[g].active) continue;
      if(g_groups[g].ticket == 0) continue;
      
      if(!posInfo.SelectByTicket(g_groups[g].ticket))
      {
         g_groups[g].active = false;
         continue;
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
      entry_price = bottom;
      sl_price = bottom - sl_buffer;
   }
   else
   {
      entry_price = top;
      sl_price = top + sl_buffer;
   }
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   entry_price = NormalizeDouble(entry_price, digits);
   sl_price = NormalizeDouble(sl_price, digits);
   tp = NormalizeDouble(tp, digits);
   
   double risk_dist = MathAbs(entry_price - sl_price);
   double reward_dist = MathAbs(tp - entry_price);
   
   if(risk_dist <= 0 || reward_dist / risk_dist < Target_RR)
   {
      DebugLog(StringFormat("SKIP: RR Insufficient (%.2f:1 < %.1f:1)", 
               risk_dist > 0 ? reward_dist / risk_dist : 0, Target_RR));
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
      AlertEntry(isBuy, entry_price, sl_price, tp, lot);
      DebugLog(StringFormat("ENTRY: %s | Entry=%.5f SL=%.5f TP=%.5f Lot=%.2f", 
               isBuy ? "BUY" : "SELL", entry_price, sl_price, tp, lot));
   }
   else
   {
      DebugLog("FAILED: Trade Error=" + IntegerToString(trade.ResultRetcode()));
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
// OnTick - MAIN LOGIC WITH DEBUG (CURRENT BAR = SHIFT 0)
//====================================================================

void OnTick()
{
   ManageGroups();
   
   if(BarsCalculated(g_hSMC_M15) < 3 || BarsCalculated(g_hSMC_H4) < 3)
   {
      UpdateDashboard("LOADING", "LOADING", "LOADING", "LOADING", "LOADING", "LOADING DATA");
      return;
   }
   
   // ===== CHECK CURRENT M15 BAR (SHIFT 0) =====
   DebugLog("--- OnTick Cycle Start ---");
   
   int m15_signal = 0;
   double m15_top = 0, m15_bottom = 0, m15_tp = 0;
   datetime m15_origin = 0;
   
   string m15_text = "NONE";
   if(ReadPOISignal(g_hSMC_M15, 0, m15_signal, m15_top, m15_bottom, m15_tp, m15_origin))  // SHIFT 0 = CURRENT
   {
      if(m15_signal == 1)
      {
         m15_text = StringFormat("BUY | T:%.2f B:%.2f", m15_top, m15_bottom);
         DebugLog("M15 Signal: BUY detected");
      }
      else if(m15_signal == 2)
      {
         m15_text = StringFormat("SELL | T:%.2f B:%.2f", m15_top, m15_bottom);
         DebugLog("M15 Signal: SELL detected");
      }
      else
      {
         m15_text = "NONE";
         DebugLog("M15 Signal: NONE (signal=0)");
      }
   }
   else
   {
      m15_text = "ERROR";
      DebugLog("M15 Signal: ERROR reading buffer");
   }
   
   // ===== CHECK CURRENT H4 BAR (SHIFT 0) =====
   int h4_signal = 0;
   double h4_top = 0, h4_bottom = 0, h4_tp = 0;
   datetime h4_origin = 0;
   
   string h4_text = "NONE";
   if(ReadPOISignal(g_hSMC_H4, 0, h4_signal, h4_top, h4_bottom, h4_tp, h4_origin))  // SHIFT 0 = CURRENT
   {
      if(h4_signal == 1)
      {
         h4_text = StringFormat("BUY | T:%.2f B:%.2f", h4_top, h4_bottom);
         DebugLog("H4 Signal: BUY detected");
      }
      else if(h4_signal == 2)
      {
         h4_text = StringFormat("SELL | T:%.2f B:%.2f", h4_top, h4_bottom);
         DebugLog("H4 Signal: SELL detected");
      }
      else
      {
         h4_text = "NONE";
         DebugLog("H4 Signal: NONE (signal=0)");
      }
   }
   else
   {
      h4_text = "ERROR";
      DebugLog("H4 Signal: ERROR reading buffer");
   }
   
   // ===== PRICE ACTION ANALYSIS =====
   string pa_text = "WAITING";
   if(m15_signal != 0)
   {
      PAPattern pattern = AnalyzePriceActionCandle(0);  // SHIFT 0 = CURRENT BAR
      if(pattern.is_valid)
         pa_text = pattern.pattern_name;
      else
         pa_text = "NO PATTERN";
   }
   
   // ===== RR RATIO CALCULATION =====
   string rr_text = "WAITING";
   double rr_ratio = 0;
   if(m15_signal != 0 && m15_bottom > 0 && m15_top > 0)
   {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double sl_buffer = Inp_SL_Buffer * point;
      double entry_price = (m15_signal == 1) ? m15_bottom : m15_top;
      double sl_price = (m15_signal == 1) ? (m15_bottom - sl_buffer) : (m15_top + sl_buffer);
      double risk_dist = MathAbs(entry_price - sl_price);
      double reward_dist = MathAbs(m15_tp - entry_price);
      rr_ratio = (risk_dist > 0) ? (reward_dist / risk_dist) : 0;
      
      string rr_status = (rr_ratio >= Target_RR) ? "OK" : "LOW";
      rr_text = StringFormat("%s %.2f:1 (Need: %.1f:1)", rr_status, rr_ratio, Target_RR);
      DebugLog(StringFormat("RR Ratio: %.2f:1 (Status: %s)", rr_ratio, rr_status));
   }
   
   // ===== MTF ALIGNMENT CHECK =====
   string mtf_text = "NOT CHECKED";
   bool mtf_ok = true;
   if(Use_MTF_Alignment)
   {
      double h4_chk_top = 0, h4_chk_bottom = 0;
      bool isBuy = (m15_signal == 1);
      if(IsPriceInH4POI(isBuy, h4_chk_top, h4_chk_bottom))
      {
         mtf_text = "OK - ALIGNED";
         DebugLog("MTF Check: ALIGNED");
      }
      else
      {
         mtf_text = "FAIL - NOT ALIGNED";
         mtf_ok = false;
         DebugLog("MTF Check: NOT ALIGNED");
      }
   }
   else
   {
      mtf_text = "DISABLED";
      mtf_ok = true;
      DebugLog("MTF Check: DISABLED");
   }
   
   // ===== ENTRY DECISION =====
   string entry_reason = "NONE";
   if(m15_signal == 0)
   {
      entry_reason = "NO SIGNAL";
      DebugLog("Entry Decision: NO M15 SIGNAL");
   }
   else if(!mtf_ok)
   {
      entry_reason = "MTF FAIL";
      DebugLog("Entry Decision: MTF NOT ALIGNED");
   }
   else if(!IsPriceActionConfirmed((m15_signal == 1), m15_top, m15_bottom, 0))  // SHIFT 0 = CURRENT
   {
      entry_reason = "PA FAIL";
      DebugLog("Entry Decision: PA NOT CONFIRMED");
   }
   else if(GroupAlreadyExists(m15_origin, (m15_signal == 1)))
   {
      entry_reason = "ALREADY IN";
      DebugLog("Entry Decision: ALREADY ENTERED");
   }
   else
   {
      entry_reason = "READY";
      DebugLog("Entry Decision: READY TO ENTER");
   }
   
   // Update Dashboard
   UpdateDashboard(m15_text, h4_text, pa_text, rr_text, mtf_text, entry_reason);
   
   // ===== EXECUTE TRADE =====
   if(m15_signal != 0 && m15_origin != 0 && entry_reason == "READY")
   {
      bool isBuy = (m15_signal == 1);
      PAPattern pattern = AnalyzePriceActionCandle(0);  // SHIFT 0 = CURRENT BAR
      AlertSignal(isBuy, pattern.pattern_name, rr_ratio);
      OpenPOITrade(isBuy, m15_top, m15_bottom, m15_tp, m15_origin);
      g_lastSignalProcessed = m15_origin;
      Print("=== TRADE ENTRY EXECUTED ===");
   }
}

//+------------------------------------------------------------------+
