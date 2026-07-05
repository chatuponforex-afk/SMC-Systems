//+------------------------------------------------------------------+
//|                                            EA_SMC_ScaleIn.mq5      |
//|  Expert Advisor: Smart Money Concepts (SMC) แบบเข้าไม้ Scale-In 3   |
//|  ไม้ สำหรับพอร์ต Cent (แนะนำใช้กับ XAUUSD)                          |
//|                                                                    |
//|  หลักการทำงาน:                                                     |
//|  - EA นี้ "ไม่คำนวณ" BOS/CHoCH/FVG/OB/POI เองเลย                    |
//|  - ดึงค่าทั้งหมดผ่าน iCustom() จากอินดิเคเตอร์ SMC_Master_Indicator  |
//|    โดยอ่านค่าจาก Indicator Buffer ด้วย CopyBuffer()                 |
//|  - เมื่อพบสัญญาณ POI ใหม่ (Buy หรือ Sell) จะวางคำสั่ง Pending Order  |
//|    แบบแบ่ง 3 ไม้ (0.03 / 0.04 / 0.03) ทันที                         |
//+------------------------------------------------------------------+
#property copyright "SMC Scale-In EA"
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
// 1) INPUT PARAMETERS (พารามิเตอร์ตั้งค่าเริ่มต้น)
//====================================================================
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED    = 0,   // Fixed Lot (ใช้ล็อตคงที่ตามที่กำหนดในแต่ละไม้)
   LOT_MODE_SCALE_IN = 1    // Scale-In Lot (แบ่งสัดส่วน 30% / 40% / 30% ของ Max_Total_Lot)
};

input group "== การเชื่อมต่ออินดิเคเตอร์ SMC =="
input string       Indicator_Name        = "SMC_Indicator"; // ชื่อไฟล์อินดิเคเตอร์ (ต้อง Compile ไว้แล้ว ชื่อไฟล์ต้องตรงกันเป๊ะ)
input int          Inp_SwingPeriod       = 5;
input int          Inp_MaxBars           = 500;
input int          Inp_OBSearchBars      = 6;
input int          Inp_RangeBars         = 100;
input int          Inp_EqualTolerancePts = 15;
input int          Inp_LiquidityLookback = 30;
input int          Inp_ConfluenceTolPts  = 50;

input group "== การบริหารเงินทุน (Money Management) =="
input ENUM_LOT_MODE Lot_Mode             = LOT_MODE_SCALE_IN; // โหมดคำนวณ Lot
input double        Max_Total_Lot        = 0.10;   // จำกัดหลอดรวมกันต่อ 1 ชุด POI ห้ามเกิน (Cent Lot)
input double        Fixed_Lot_Each       = 0.03;   // ใช้เมื่อ Lot_Mode = Fixed (ทุกไม้ใช้ค่านี้)
input int           Max_Backcandles      = 1000;   // จำกัดแท่งเทียนคำนวณ ป้องกันเครื่องหน่วง (สำรองใช้กับ Inp_MaxBars)

input group "== เป้าหมายกำไร / ความเสี่ยง =="
input double        Target_RR            = 3.0;    // อัตราส่วน Risk:Reward ขั้นต่ำที่ยอมรับ (1:3)
input int           Inp_SL_Buffer        = 300;     // ระยะเผื่อ SL เลยขอบกล่อง POI (Points)
input double        Breakeven_RR_Trigger = 2.0;     // เลื่อน SL เข้าทุนเมื่อกำไร >= N เท่าของความกว้างกล่อง POI

input group "== ระบบกรองหลายไทม์เฟรม (MTF Confluence) =="
input bool          Use_MTF_Zone_Filter  = false;   // กรองราคาตามกล่อง POI ไทม์เฟรมใหญ่ (HTF POI)
input bool          Use_MTF_Trend_Filter = false;   // กรองทิศทางการเทรดตามเทรนด์ไทม์เฟรมใหญ่ (HTF Trend)
input ENUM_TIMEFRAMES HTF_Timeframe      = PERIOD_H1;// ไทม์เฟรมใหญ่ที่ใช้กรอง

input group "== การจัดการออเดอร์ =="
input int           Magic_Number         = 20260703;
input int           Slippage_Points      = 10;
input int           Pending_Expire_Hours = 48;      // อายุ Pending Order (ชั่วโมง) 0 = ไม่หมดอายุ

input group "== การแจ้งเตือน =="
input bool          Use_Alert            = true;
input bool          Use_Push             = true;

//====================================================================
// 2) โครงสร้างเก็บข้อมูลชุด POI (1 ชุด = 3 ไม้ + SL/TP ร่วม)
//====================================================================
struct POIGroup
{
   datetime originTime;   // เวลาแท่ง Origin ของกล่อง POI (ใช้เป็นรหัสกันซ้ำ)
   bool     isBuy;
   double   top;
   double   bottom;
   double   slPrice;
   double   tpPrice;
   double   zoneWidth;
   ulong    tickets[3];   // Ticket ของ Pending Order / Position ทั้ง 3 ไม้ (0 = ไม่มี/ถูกลบแล้ว)
   bool     beDone;       // เลื่อนทุนแล้วหรือยัง
   bool     active;       // ชุดนี้ยังใช้งานอยู่หรือไม่ (false = ปิด/ยกเลิกครบแล้ว)
};

POIGroup g_groups[];               // เก็บทุกชุด POI ที่เคยเปิด (ระหว่างรัน EA ครั้งนี้)
datetime g_lastBuyOriginProcessed  = 0;
datetime g_lastSellOriginProcessed = 0;
datetime g_lastBarTime             = 0;
int      g_hSMC                    = INVALID_HANDLE;
int      g_hSMC_HTF                = INVALID_HANDLE;

//====================================================================
// OnInit / OnDeinit
//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);

   // เรียกอินดิเคเตอร์ SMC_Master_Indicator ผ่าน iCustom โดยส่ง Input ให้ตรงกัน
   g_hSMC = iCustom(_Symbol, PERIOD_CURRENT, Indicator_Name,
                     Inp_SwingPeriod, Inp_MaxBars, true,   // SwingPeriod, MaxBars, ShowStructure
                     true,                                  // ShowFVG
                     true, Inp_OBSearchBars,                // ShowOrderBlock, OBSearchBars
                     true, Inp_RangeBars,                    // ShowPremiumDiscount, RangeBars
                     true, Inp_EqualTolerancePts, Inp_LiquidityLookback, // ShowLiquidity, Tol, Lookback
                     Inp_ConfluenceTolPts);

   if(g_hSMC == INVALID_HANDLE)
   {
      Print("EA_SMC_ScaleIn: ไม่สามารถโหลดอินดิเคเตอร์ '", Indicator_Name,
            "' ได้ (Error ", GetLastError(), ")");
      return(INIT_FAILED);
   }

   // โหลดอินดิเคเตอร์สำหรับไทม์เฟรมใหญ่ (HTF) หากเปิดใช้งานระบบกรองหลายไทม์เฟรม
   if(Use_MTF_Zone_Filter || Use_MTF_Trend_Filter)
   {
      g_hSMC_HTF = iCustom(_Symbol, HTF_Timeframe, Indicator_Name,
                           Inp_SwingPeriod, Inp_MaxBars, true,
                           true,
                           true, Inp_OBSearchBars,
                           true, Inp_RangeBars,
                           true, Inp_EqualTolerancePts, Inp_LiquidityLookback,
                           Inp_ConfluenceTolPts);

      if(g_hSMC_HTF == INVALID_HANDLE)
      {
         Print("EA_SMC_ScaleIn: ไม่สามารถโหลดอินดิเคเตอร์ HTF (", EnumToString(HTF_Timeframe), ") ได้ (Error ", GetLastError(), ")");
         return(INIT_FAILED);
      }
      Print("EA_SMC_ScaleIn: เชื่อมต่ออินดิเคเตอร์ HTF สำเร็จ Handle=", g_hSMC_HTF);
   }

   Print("EA_SMC_ScaleIn: เชื่อมต่ออินดิเคเตอร์ LTF สำเร็จ Handle=", g_hSMC);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hSMC != INVALID_HANDLE)
      IndicatorRelease(g_hSMC);
   if(g_hSMC_HTF != INVALID_HANDLE)
      IndicatorRelease(g_hSMC_HTF);
}

//====================================================================
// HELPER: ปรับ Lot ให้ตรงกับ Step / Min / Max ของโบรกเกอร์
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

// คำนวณ Lot ทั้ง 3 ไม้ ตามโหมดที่เลือก โดยรวมกันต้องไม่เกิน Max_Total_Lot
void CalcLots(double &lot1, double &lot2, double &lot3)
{
   if(Lot_Mode == LOT_MODE_FIXED)
   {
      lot1 = NormalizeLot(Fixed_Lot_Each);
      lot2 = NormalizeLot(Fixed_Lot_Each);
      lot3 = NormalizeLot(Fixed_Lot_Each);
      double sum = lot1 + lot2 + lot3;
      if(sum > Max_Total_Lot)
      {
         double scale = Max_Total_Lot / sum;
         lot1 = NormalizeLot(lot1 * scale);
         lot2 = NormalizeLot(lot2 * scale);
         lot3 = NormalizeLot(lot3 * scale);
      }
   }
   else // Scale-In: 30% / 40% / 30%
   {
      lot1 = NormalizeLot(Max_Total_Lot * 0.30);
      lot2 = NormalizeLot(Max_Total_Lot * 0.40);
      lot3 = NormalizeLot(Max_Total_Lot - lot1 - lot2); // ไม้ 3 รับส่วนต่างจากการปัดเศษ
      if(lot3 <= 0) lot3 = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }
}

//====================================================================
// อ่านค่าจาก Buffer ของอินดิเคเตอร์ SMC_Master_Indicator ผ่าน iCustom
//====================================================================
bool ReadPOISignal(int shift, int &signal, double &top, double &bottom, double &tp, datetime &originTime)
{
   double bufSignal[1], bufTop[1], bufBottom[1], bufTP[1], bufOrigin[1];

   if(CopyBuffer(g_hSMC, 0, shift, 1, bufSignal) <= 0) return(false);
   if(CopyBuffer(g_hSMC, 1, shift, 1, bufTop)    <= 0) return(false);
   if(CopyBuffer(g_hSMC, 2, shift, 1, bufBottom) <= 0) return(false);
   if(CopyBuffer(g_hSMC, 3, shift, 1, bufTP)     <= 0) return(false);
   if(CopyBuffer(g_hSMC, 4, shift, 1, bufOrigin) <= 0) return(false);

   signal     = (int)bufSignal[0];
   top        = bufTop[0];
   bottom     = bufBottom[0];
   tp         = bufTP[0];
   originTime = (datetime)bufOrigin[0];
   return(true);
}

// อ่านสัญญาณ POI จากอินดิเคเตอร์ไทม์เฟรมใหญ่ (HTF)
bool ReadPOISignalHTF(int shift, int &signal, double &top, double &bottom, double &tp, datetime &originTime)
{
   if(g_hSMC_HTF == INVALID_HANDLE) return(false);
   double bufSignal[1], bufTop[1], bufBottom[1], bufTP[1], bufOrigin[1];

   if(CopyBuffer(g_hSMC_HTF, 0, shift, 1, bufSignal) <= 0) return(false);
   if(CopyBuffer(g_hSMC_HTF, 1, shift, 1, bufTop)    <= 0) return(false);
   if(CopyBuffer(g_hSMC_HTF, 2, shift, 1, bufBottom) <= 0) return(false);
   if(CopyBuffer(g_hSMC_HTF, 3, shift, 1, bufTP)     <= 0) return(false);
   if(CopyBuffer(g_hSMC_HTF, 4, shift, 1, bufOrigin) <= 0) return(false);

   signal     = (int)bufSignal[0];
   top        = bufTop[0];
   bottom     = bufBottom[0];
   tp         = bufTP[0];
   originTime = (datetime)bufOrigin[0];
   return(true);
}

// อ่านทิศทางเทรนด์จากอินดิเคเตอร์ไทม์เฟรมใหญ่ (HTF)
int ReadHTFTrend(int shift)
{
   if(g_hSMC_HTF == INVALID_HANDLE) return(0);
   double bufTrend[1];
   if(CopyBuffer(g_hSMC_HTF, 5, shift, 1, bufTrend) <= 0) return(0);
   return((int)bufTrend[0]);
}

// ตรวจสอบว่าชุดออเดอร์ (Group) โดนชน SL หรือไม่
bool IsGroupStoppedOut(int groupIdx)
{
   if(groupIdx < 0 || groupIdx >= ArraySize(g_groups)) return(false);
   
   bool anyFilled = false;
   bool anyLoss = false;

   for(int i = 0; i < 3; i++)
   {
      ulong ticket = g_groups[groupIdx].tickets[i];
      if(ticket == 0) continue;

      // หากยังมีออเดอร์ค้าง (Pending) หรือยังมี Position เปิดอยู่ ถือว่ายังไม่หยุดขาดทุนทั้งหมด
      if(orderInfo.Select(ticket) || posInfo.SelectByTicket(ticket))
         return(false);

      // ดึงประวัติ Deal เพื่อเช็คผลกำไร/ขาดทุน
      if(HistorySelect(0, TimeCurrent()))
      {
         int total = HistoryDealsTotal();
         for(int d = total - 1; d >= 0; d--)
         {
            ulong dealTicket = HistoryDealGetTicket(d);
            if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == ticket)
            {
               anyFilled = true;
               double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               if(profit < 0)
               {
                  anyLoss = true;
                  break;
               }
            }
         }
      }
   }

   // ถือว่าเป็น Stop Out ถ้ามีการแมตช์เข้าออเดอร์จริง (Filled) และผลลัพธ์คือขาดทุน (Loss)
   return(anyFilled && anyLoss);
}

//====================================================================
// แจ้งเตือน
//====================================================================
void NotifyUser(string msg)
{
   Print(msg);
   if(Use_Alert) Alert(msg);
   if(Use_Push)  SendNotification(msg);
}

//====================================================================
// เปิดชุด POI ใหม่ (วาง Pending Order 3 ไม้)
//====================================================================
void OpenPOIGroup(bool isBuy, double top, double bottom, double tp, datetime originTime)
{
   double zoneWidth = MathAbs(top - bottom);
   if(zoneWidth <= 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slBuffer = Inp_SL_Buffer * point;

   double price1, price2, price3, slPrice;
   
   // ดึง Stop Level ของโบรกเกอร์เพื่อป้องกันปัญหาราคาวางออเดอร์ใกล้เคียงราคาปัจจุบันเกินไป
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      price1 = top;                 // ไม้ 1: ขอบบนสุด (ดักตกรถ)
      price2 = (top + bottom) / 2.0; // ไม้ 2: กึ่งกลาง (ไม้หลัก)
      price3 = bottom;               // ไม้ 3: ขอบล่างสุด (ไม้ต้นน้ำ)
      slPrice = bottom - slBuffer;
      
      // ป้องกันราคาวาง Buy Limit เกินราคาตลาดปัจจุบัน (Ask)
      double maxBuyLimitPrice = ask - stopsLevel * point;
      price1 = MathMin(price1, maxBuyLimitPrice);
      price2 = MathMin(price2, maxBuyLimitPrice);
      price3 = MathMin(price3, maxBuyLimitPrice);
   }
   else
   {
      price1 = bottom;               // ไม้ 1: ขอบล่างสุด
      price2 = (top + bottom) / 2.0; // ไม้ 2: กึ่งกลาง
      price3 = top;                  // ไม้ 3: ขอบบนสุด
      slPrice = top + slBuffer;
      
      // ป้องกันราคาวาง Sell Limit ต่ำกว่าราคาตลาดปัจจุบัน (Bid)
      double minSellLimitPrice = bid + stopsLevel * point;
      price1 = MathMax(price1, minSellLimitPrice);
      price2 = MathMax(price2, minSellLimitPrice);
      price3 = MathMax(price3, minSellLimitPrice);
   }

   // Normalize ราคาออเดอร์ทั้งหมดให้ตรงกับจำนวนทศนิยมของโบรกเกอร์
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price1 = NormalizeDouble(price1, digits);
   price2 = NormalizeDouble(price2, digits);
   price3 = NormalizeDouble(price3, digits);
   slPrice = NormalizeDouble(slPrice, digits);
   tp = NormalizeDouble(tp, digits);

   // ตรวจสอบระยะ SL เทียบ TP ให้ได้ RR ขั้นต่ำตามที่กำหนด (Target_RR) โดยอิงจากไม้ 2 (ราคาเฉลี่ยหลัก)
   double riskDist   = MathAbs(price2 - slPrice);
   double rewardDist = MathAbs(tp - price2);
   if(riskDist <= 0 || rewardDist / riskDist < Target_RR)
   {
      Print("EA_SMC_ScaleIn: ข้ามกล่อง POI (Origin=", TimeToString(originTime),
            ") เพราะ RR ไม่ถึงเป้าหมาย (RR=", DoubleToString(riskDist>0 ? rewardDist/riskDist : 0, 2), ")");
      return;
   }

   double lot1, lot2, lot3;
   CalcLots(lot1, lot2, lot3);

   datetime expiration = 0;
   if(Pending_Expire_Hours > 0)
      expiration = TimeCurrent() + Pending_Expire_Hours * 3600;

   int n = ArraySize(g_groups);
   ArrayResize(g_groups, n + 1);
   g_groups[n].originTime = originTime;
   g_groups[n].isBuy      = isBuy;
   g_groups[n].top        = top;
   g_groups[n].bottom     = bottom;
   g_groups[n].slPrice    = slPrice;
   g_groups[n].tpPrice    = tp;
   g_groups[n].zoneWidth  = zoneWidth;
   g_groups[n].beDone     = false;
   g_groups[n].active     = true;
   g_groups[n].tickets[0] = 0;
   g_groups[n].tickets[1] = 0;
   g_groups[n].tickets[2] = 0;

   string groupTag = (isBuy ? "SMC_B_" : "SMC_S_") + IntegerToString((int)originTime);

   double prices[3]; prices[0] = price1; prices[1] = price2; prices[2] = price3;
   double lots[3];   lots[0]   = lot1;   lots[1]   = lot2;   lots[2]   = lot3;

   int filled = 0;
   for(int i = 0; i < 3; i++)
   {
      bool ok;
      string cmt = groupTag + "_" + IntegerToString(i + 1);
      if(isBuy)
         ok = trade.BuyLimit(lots[i], prices[i], _Symbol, slPrice, tp, ORDER_TIME_SPECIFIED, expiration, cmt);
      else
         ok = trade.SellLimit(lots[i], prices[i], _Symbol, slPrice, tp, ORDER_TIME_SPECIFIED, expiration, cmt);

      if(ok)
      {
         g_groups[n].tickets[i] = trade.ResultOrder();
         filled++;
      }
      else
      {
         Print("EA_SMC_ScaleIn: วางออเดอร์ไม้ที่ ", i + 1, " ไม่สำเร็จ Error=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ")");
      }
   }

   if(filled > 0)
   {
      NotifyUser(StringFormat("SMC EA: เปิดชุด POI %s | %s | Top=%.5f Bottom=%.5f SL=%.5f TP=%.5f | Lots=%.2f/%.2f/%.2f",
                               groupTag, isBuy ? "BUY" : "SELL", top, bottom, slPrice, tp, lot1, lot2, lot3));
   }
   else
   {
      g_groups[n].active = false; // ไม่มีไม้ไหนวางสำเร็จเลย ปิดชุดนี้ทิ้ง
   }
}

//====================================================================
// จัดการชุด POI ที่เปิดอยู่: ลบ Pending ค้างเมื่อ TP โดนแตะ + เลื่อน Breakeven
//====================================================================
void ManageGroups()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int g = 0; g < ArraySize(g_groups); g++)
   {
      if(!g_groups[g].active) continue;

      bool anyPendingLeft = false;
      bool anyPositionOpen = false;

      for(int i = 0; i < 3; i++)
      {
         ulong ticket = g_groups[g].tickets[i];
         if(ticket == 0) continue;

         if(orderInfo.Select(ticket))
         {
            anyPendingLeft = true; // ยังเป็น Pending Order อยู่
         }
         else if(posInfo.SelectByTicket(ticket))
         {
            anyPositionOpen = true; // กลายเป็น Position ที่เปิดอยู่แล้ว (Filled)
         }
         else
         {
            g_groups[g].tickets[i] = 0; // ปิดไปแล้ว / ถูกลบไปแล้ว
         }
      }

      // --- ฟังก์ชันลบออเดอร์ค้าง: ถ้าราคาวิ่งไปถึง TP แล้วแต่ยังมี Pending ค้างอยู่ ให้ลบทิ้งทันที ---
      bool tpReached = g_groups[g].isBuy ? (bid >= g_groups[g].tpPrice) : (ask <= g_groups[g].tpPrice);
      if(tpReached && anyPendingLeft)
      {
         for(int i = 0; i < 3; i++)
         {
            ulong ticket = g_groups[g].tickets[i];
            if(ticket == 0) continue;
            if(orderInfo.Select(ticket))
            {
               if(trade.OrderDelete(ticket))
               {
                  Print("EA_SMC_ScaleIn: ลบ Pending Order ค้าง Ticket=", ticket,
                        " (ราคาถึงเป้าหมาย TP แล้ว, ป้องกันความเสี่ยงส่วนเกิน)");
                  g_groups[g].tickets[i] = 0;
               }
            }
         }
      }

      // --- ฟังก์ชันเลื่อนหน้าทุน (Breakeven) ---
      if(!g_groups[g].beDone && anyPositionOpen)
      {
         double beTriggerDist = g_groups[g].zoneWidth * Breakeven_RR_Trigger;
         double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

         for(int i = 0; i < 3; i++)
         {
            ulong ticket = g_groups[g].tickets[i];
            if(ticket == 0) continue;
            if(!posInfo.SelectByTicket(ticket)) continue;

            double openPrice = posInfo.PriceOpen();
            double curProfitDist = g_groups[g].isBuy ? (bid - openPrice) : (openPrice - ask);

            if(curProfitDist >= beTriggerDist)
            {
               double newSL = g_groups[g].isBuy ? (openPrice + spread) : (openPrice - spread);
               // เลื่อน SL เฉพาะกรณีที่ทำให้ความเสี่ยงลดลงเท่านั้น (กันเลื่อนย้อนกลับ)
               bool improve = g_groups[g].isBuy ? (newSL > posInfo.StopLoss()) : (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0);
               if(improve)
               {
                  if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit()))
                     Print("EA_SMC_ScaleIn: เลื่อน SL เข้าทุน (Breakeven) Ticket=", ticket, " SL ใหม่=", newSL);
               }
            }
         }
         // ถือว่าเลื่อนทุนของทั้งชุดแล้วเมื่อไม้ใดไม้หนึ่งเข้าเงื่อนไข (กันประมวลผลซ้ำทุก Tick)
         g_groups[g].beDone = true;
      }

      // --- ปิดชุดถ้าไม่มีทั้ง Pending และ Position เหลือแล้ว ---
      bool anyLeft = false;
      for(int i = 0; i < 3; i++)
         if(g_groups[g].tickets[i] != 0) anyLeft = true;
      if(!anyLeft) g_groups[g].active = false;
   }
}

//====================================================================
// ตรวจสอบว่ามีชุด POI ที่ origin เดียวกันเปิดอยู่แล้วหรือไม่ (กันเปิดซ้ำ)
//====================================================================
bool GroupAlreadyExists(datetime originTime, bool isBuy)
{
   for(int i = 0; i < ArraySize(g_groups); i++)
   {
      if(g_groups[i].originTime == originTime && g_groups[i].isBuy == isBuy)
         return(true);
   }
   return(false);
}

// ตรวจนับจำนวนชุดออเดอร์ของรหัสกล่องเดียวกัน
int GetGroupCount(datetime originTime, bool isBuy, bool &anyActive, int &lastGroupIdx)
{
   int count = 0;
   anyActive = false;
   lastGroupIdx = -1;
   for(int i = 0; i < ArraySize(g_groups); i++)
   {
      if(g_groups[i].originTime == originTime && g_groups[i].isBuy == isBuy)
      {
         count++;
         lastGroupIdx = i;
         if(g_groups[i].active)
            anyActive = true;
      }
   }
   return(count);
}

//====================================================================
// OnTick : จุดเริ่มทำงานหลักของ EA
//====================================================================
void OnTick()
{
   // จัดการชุด POI ที่เปิดอยู่ทุก Tick (Breakeven / ลบ Pending ค้าง)
   ManageGroups();

   if(BarsCalculated(g_hSMC) < 3) return; // อินดิเคเตอร์ยังคำนวณไม่เสร็จ

   int      signal;
   double   top, bottom, tp;
   datetime originTime;

   // อ่านค่าสัญญาณ POI จากแท่งปัจจุบัน (shift = 0) เพื่อเช็คราคาเข้าโซนเรียลไทม์ทุก Tick
   if(!ReadPOISignal(0, signal, top, bottom, tp, originTime)) return;
   if(signal == 0 || originTime == 0) return;

   bool isBuy = (signal == 1);

   // --- 1. กรองเทรนด์ตามโครงสร้างราคาไทม์เฟรมใหญ่ (HTF Trend Filter) ---
   if(Use_MTF_Trend_Filter && g_hSMC_HTF != INVALID_HANDLE)
   {
      int htfTrend = ReadHTFTrend(0);
      if(isBuy && htfTrend == -1) return; // HTF เป็นขาลง ห้าม Buy
      if(!isBuy && htfTrend == 1) return; // HTF เป็นขาขึ้น ห้าม Sell
   }

   // --- 2. กรองว่าราคาปัจจุบันอยู่ในพื้นที่กล่อง POI ไทม์เฟรมใหญ่ (HTF POI Zone Filter) ---
   if(Use_MTF_Zone_Filter && g_hSMC_HTF != INVALID_HANDLE)
   {
      int htfSignal;
      double htfTop, htfBottom, htfTP;
      datetime htfOrigin;
      if(ReadPOISignalHTF(0, htfSignal, htfTop, htfBottom, htfTP, htfOrigin))
      {
         double curPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(isBuy)
         {
            // ต้องมีกล่อง Demand H1 Active และราคาปัจจุบันต้องอยู่ร่วมในกล่อง Demand H1 ด้วย
            if(htfSignal != 1 || curPrice > htfTop || curPrice < htfBottom) return;
         }
         else
         {
            // ต้องมีกล่อง Supply H1 Active และราคาปัจจุบันต้องอยู่ร่วมในกล่อง Supply H1 ด้วย
            if(htfSignal != 2 || curPrice < htfBottom || curPrice > htfTop) return;
         }
      }
      else
      {
         return; // ไม่พบสัญญาณหรือกล่องจาก HTF ข้ามการเทรด
      }
   }

   // ตรวจนับจำนวนชุดออเดอร์สำหรับกล่องนี้
   bool anyActive = false;
   int lastGroupIdx = -1;
   int groupCount = GetGroupCount(originTime, isBuy, anyActive, lastGroupIdx);

   if(anyActive) return; // หากยังมีออเดอร์ในชุดปัจจุบันทำงานอยู่ ห้ามวางซ้ำ
   if(groupCount >= 2) return; // จำกัดสูงสุดไม่เกิน 2 ชุดต่อหนึ่งโซน POI

   // เช็คว่าราคาปัจจุบันวิ่งเข้ากล่องหรือไม่
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isInsideZone = false;

   if(isBuy)
   {
      if(bid <= top && bid >= bottom)
         isInsideZone = true;
   }
   else
   {
      if(ask >= bottom && ask <= top)
         isInsideZone = true;
   }

   if(!isInsideZone) return; // ราคายังไม่เข้าโซน

   // --- ตรวจสอบเงื่อนไขเข้าออเดอร์ชุดที่ 2 (Re-Entry) ---
   if(groupCount == 1)
   {
      // ตรวจสอบว่าชุดแรกโดนชน SL หรือไม่
      if(!IsGroupStoppedOut(lastGroupIdx))
         return; // ถ้าชุดแรกไม่ได้ปิดขาดทุนด้วย SL จะไม่อนุญาตให้ Re-Entry
      
      Print("EA_SMC_ScaleIn: สัญญาณ Re-Entry สำหรับกล่อง Origin=", TimeToString(originTime), " (ชุดแรกชน SL และราคากลับเข้าโซน)");
   }

   // ทำการเข้าชุดออเดอร์
   OpenPOIGroup(isBuy, top, bottom, tp, originTime);

   if(isBuy) g_lastBuyOriginProcessed = originTime;
   else      g_lastSellOriginProcessed = originTime;
}
//+------------------------------------------------------------------+
