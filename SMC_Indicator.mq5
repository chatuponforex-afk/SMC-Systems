//+------------------------------------------------------------------+
//|                                              SMC_Indicator.mq5     |
//|  อินดิเคเตอร์ Smart Money Concepts (SMC) สำหรับ MetaTrader 5        |
//|  ประกอบด้วย: Market Structure (BOS/CHoCH), Inducement (IDM),       |
//|              Fair Value Gap (FVG), Order Block / Fresh Zone,       |
//|              Premium/Discount Zone, Liquidity Sweep (EQH/EQL),     |
//|              และ POI Confluence Engine                             |
//|                                                                    |
//|  หมายเหตุสำคัญ: ไฟล์นี้คือ SMC_Indicator ตัวเดียวที่ EA เรียกใช้ผ่าน  |
//|  iCustom() มี "Indicator Buffers" 5 ช่องสำหรับส่งค่ากล่อง POI       |
//|  ให้ EA อ่านผ่าน CopyBuffer() โดยตรง (ต้อง Compile ไฟล์นี้ไฟล์เดียว   |
//|  ในชื่อ "SMC_Indicator" ให้ตรงกับ Input "Indicator_Name" ใน EA)     |
//+------------------------------------------------------------------+
#property copyright "SMC Indicator (Smart Money Concepts)"
#property link      ""
#property version   "3.00"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   0

//====================================================================
// BUFFER INDEX MAP (สำหรับ EA ใช้ CopyBuffer อ้างอิง)
//   Buffer 0 : POI_Signal  -> 0 = ไม่มีสัญญาณ, 1 = Buy POI (Discount), 2 = Sell POI (Premium)
//   Buffer 1 : POI_Top     -> ขอบบนของกล่อง POI
//   Buffer 2 : POI_Bottom  -> ขอบล่างของกล่อง POI
//   Buffer 3 : POI_TP      -> เป้าหมาย Take Profit (แนวสภาพคล่องฝั่งตรงข้าม / Swing เดิม)
//   Buffer 4 : POI_OriginTime -> เวลาของแท่ง Origin ของกล่อง POI (cast เป็น double)
//                                ใช้เป็น "รหัสกล่อง POI" ให้ EA แยกกล่องใหม่ vs กล่องเดิม
//   Buffer 5 : POI_Trend   -> ทิศทางเทรนด์โครงสร้างราคา (1 = ขาขึ้น Bullish, -1 = ขาลง Bearish, 0 = ไม่มีเทรนด์)
//====================================================================
#define BUF_SIGNAL   0
#define BUF_TOP      1
#define BUF_BOTTOM   2
#define BUF_TP       3
#define BUF_ORIGIN   4
#define BUF_TREND    5

double BufSignal[];
double BufTop[];
double BufBottom[];
double BufTP[];
double BufOrigin[];
double BufTrend[];

//====================================================================
// INPUT PARAMETERS (พารามิเตอร์ที่ผู้ใช้ปรับแต่งได้)
//====================================================================
// input group "== Market Structure =="
input int    InpSwingPeriod        = 5;      // จำนวนแท่งซ้าย-ขวาที่ใช้ยืนยัน Swing High/Low
input int    InpMaxBars            = 500;    // จำนวนแท่งย้อนหลังสูงสุดที่นำมาวิเคราะห์
input bool   InpShowStructure      = true;   // แสดง BOS / CHoCH

// input group "== Fair Value Gap (FVG) =="
input bool   InpShowFVG            = true;   // แสดงกล่อง Fair Value Gap

// input group "== Order Block / Fresh Zone =="
input bool   InpShowOrderBlock     = true;   // แสดงกล่อง Demand / Supply Zone
input int    InpOBSearchBars       = 6;      // จำนวนแท่งย้อนหลังสูงสุดที่ค้นหาแท่ง Order Block

// input group "== Premium / Discount Zone =="
input bool   InpShowPremiumDiscount= true;   // แสดงโซน Premium / Discount
input int    InpRangeBars          = 100;    // จำนวนแท่งที่ใช้คำนวณกรอบราคาปัจจุบัน (Trading Range)

// input group "== Liquidity (EQH/EQL) =="
input bool   InpShowLiquidity      = true;   // แสดงจุด Equal High / Equal Low
input int    InpEqualTolerancePts  = 15;     // ระยะเผื่อ (Points) สำหรับตรวจ Equal High/Low
input int    InpLiquidityLookback  = 30;     // จำนวน Swing ล่าสุดที่นำมาตรวจ EQH/EQL

// input group "== POI Confluence Engine =="
input int    InpConfluenceTolPts   = 50;     // ระยะเผื่อ (Points) สำหรับตรวจ FVG/Liquidity ใกล้กล่อง OB

// input group "== สีและรูปแบบการแสดงผล =="
input color  InpBullColor          = clrDodgerBlue;    // สีโครงสร้างขาขึ้น (BOS/CHoCH)
input color  InpBearColor          = clrRed;            // สีโครงสร้างขาลง (BOS/CHoCH)
input color  InpBullFVGColor       = C'204,255,204';    // สี FVG ขาขึ้น (เขียวอ่อน)
input color  InpBearFVGColor       = C'255,204,204';    // สี FVG ขาลง (แดงอ่อน)
input color  InpDemandColor        = C'173,216,230';    // สี Demand Zone (ฟ้า)
input color  InpSupplyColor        = C'255,218,185';    // สี Supply Zone (ส้ม)
input color  InpPOIDemandColor     = clrLime;            // สีกล่อง POI ฝั่ง Buy (เข้มกว่า Demand ปกติ)
input color  InpPOISupplyColor     = clrMagenta;         // สีกล่อง POI ฝั่ง Sell (เข้มกว่า Supply ปกติ)
input color  InpPremiumColor       = C'255,228,225';    // สีโซน Premium (แดงจาง - โซนน่าขาย)
input color  InpDiscountColor      = C'224,255,255';    // สีโซน Discount (ฟ้าจาง - โซนน่าซื้อ)
input color  InpLiquidityColor     = clrGoldenrod;      // สีเส้น Liquidity (EQH/EQL)
input int    InpFontSize           = 8;                 // ขนาดตัวอักษร

//====================================================================
// GLOBAL VARIABLES / STRUCTS
//====================================================================
#define PFX "SMC_"   // Prefix ของ Object ทั้งหมด ใช้สำหรับลบทิ้งได้ง่าย

datetime g_lastBarTime = 0;   // เก็บเวลาแท่งล่าสุดที่คำนวณไปแล้ว เพื่อไม่ต้องคำนวณซ้ำทุก Tick

// โครงสร้างเก็บข้อมูลจุด Swing High / Swing Low
struct SwingPoint
{
   int    barIndex;    // ตำแหน่งแท่งเทียนที่เป็นจุด Swing
   int    confirmBar;  // ตำแหน่งแท่งที่ Swing นี้ "ยืนยัน" แล้ว (barIndex + SwingPeriod)
   double price;        // ราคาของจุด Swing
};

// โครงสร้างเก็บโซน FVG (ใช้ตรวจ Confluence กับกล่อง OB)
struct FVGZone
{
   double top;
   double bottom;
   bool   isBull;
   bool   mitigated;
};

// โครงสร้างเก็บกล่อง Order Block / Fresh Zone (ใช้ประกอบเป็น POI)
struct OBZone
{
   int    barIndex;
   double top;
   double bottom;
   bool   isDemand;
   bool   mitigated;
};

FVGZone g_fvgZones[];     // เก็บโซน FVG ทั้งหมดที่พบในรอบคำนวณล่าสุด
OBZone  g_demandZones[];  // เก็บกล่อง Demand (OB ขาขึ้น) ทั้งหมด
OBZone  g_supplyZones[];  // เก็บกล่อง Supply (OB ขาลง) ทั้งหมด
double  g_liqHighLevels[]; // ราคาระดับ Liquidity ฝั่งบน (EQH)
double  g_liqLowLevels[];  // ราคาระดับ Liquidity ฝั่งล่าง (EQL)

double  g_rangeHigh = 0, g_rangeLow = 0, g_rangeMid = 0; // กรอบราคา Premium/Discount ล่าสุด

//====================================================================
// OnInit / OnDeinit
//====================================================================
int OnInit()
{
   SetIndexBuffer(BUF_SIGNAL, BufSignal, INDICATOR_CALCULATIONS);
   SetIndexBuffer(BUF_TOP,    BufTop,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(BUF_BOTTOM, BufBottom, INDICATOR_CALCULATIONS);
   SetIndexBuffer(BUF_TP,     BufTP,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(BUF_ORIGIN, BufOrigin, INDICATOR_CALCULATIONS);
   SetIndexBuffer(BUF_TREND,  BufTrend,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufSignal, false);
   ArraySetAsSeries(BufTop,    false);
   ArraySetAsSeries(BufBottom, false);
   ArraySetAsSeries(BufTP,     false);
   ArraySetAsSeries(BufOrigin, false);
   ArraySetAsSeries(BufTrend,  false);

   // ล้าง Object เก่าทั้งหมดตอนเริ่มต้น กันกรณีโหลดอินดิเคเตอร์ซ้ำ
   ObjectsDeleteAll(0, PFX);
   g_lastBarTime = 0;
   IndicatorSetString(INDICATOR_SHORTNAME, "SMC Master Indicator (BOS/CHoCH, FVG, OB, Premium-Discount, Liquidity, POI)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // ล้าง Object ทั้งหมดทุกครั้งที่ถอดอินดิเคเตอร์ เปลี่ยน Timeframe หรือเปลี่ยนสัญลักษณ์
   // เพื่อไม่ให้ Object เก่าค้างอยู่บนกราฟและทำให้เครื่องหนัก
   ObjectsDeleteAll(0, PFX);
}

//====================================================================
// HELPER FUNCTIONS สำหรับวาด Object บนกราฟ
//====================================================================

void DrawLine(string name, datetime t1, double p1, datetime t2, double p2,
              color clr, int width=1, ENUM_LINE_STYLE style=STYLE_SOLID)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DrawText(string name, datetime t, double p, string text, color clr, int size,
              ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT_LOWER)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//====================================================================
// 1) MARKET STRUCTURE : ตรวจจับ Swing High / Swing Low
//====================================================================
void DetectSwings(const int startIdx, const int endIdx,
                   const double &high[], const double &low[],
                   SwingPoint &highsArr[], SwingPoint &lowsArr[])
{
   ArrayResize(highsArr, 0);
   ArrayResize(lowsArr, 0);

   for(int i = startIdx + InpSwingPeriod; i <= endIdx - InpSwingPeriod; i++)
   {
      bool isHigh = true;
      bool isLow  = true;
      for(int k = i - InpSwingPeriod; k <= i + InpSwingPeriod; k++)
      {
         if(k == i) continue;
         if(high[k] >= high[i]) isHigh = false;
         if(low[k]  <= low[i])  isLow  = false;
      }
      if(isHigh)
      {
         int n = ArraySize(highsArr);
         ArrayResize(highsArr, n + 1);
         highsArr[n].barIndex   = i;
         highsArr[n].confirmBar = MathMin(i + InpSwingPeriod, endIdx);
         highsArr[n].price      = high[i];
      }
      if(isLow)
      {
         int n = ArraySize(lowsArr);
         ArrayResize(lowsArr, n + 1);
         lowsArr[n].barIndex   = i;
         lowsArr[n].confirmBar = MathMin(i + InpSwingPeriod, endIdx);
         lowsArr[n].price      = low[i];
      }
   }
}

void DrawStructureEvent(const datetime &time[], int swingBar, double price, int breakBar,
                         bool isBullBreak, bool isCHoCH)
{
   static int counter = 0;
   counter++;
   string tag  = isCHoCH ? "CHoCH" : "BOS";
   color  clr  = isBullBreak ? InpBullColor : InpBearColor;
   string lineName = PFX + "STRUCT_L_" + IntegerToString(counter);
   string textName = PFX + "STRUCT_T_" + IntegerToString(counter);

   DrawLine(lineName, time[swingBar], price, time[breakBar], price, clr, 1, STYLE_DASH);
   DrawText(textName, time[breakBar], price, tag, clr, InpFontSize,
            isBullBreak ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
}

int DetectStructure(const int startIdx, const int endIdx,
                      const datetime &time[], const double &close[],
                      const SwingPoint &highsArr[], const SwingPoint &lowsArr[],
                      bool draw)
{
   int    trend = 0;
   double refHigh = 0;  int refHighBar = -1;  bool refHighBroken = true;
   double refLow  = 0;  int refLowBar  = -1;  bool refLowBroken  = true;
   int hPtr = 0, lPtr = 0;
   int nH = ArraySize(highsArr), nL = ArraySize(lowsArr);

   for(int i = startIdx; i <= endIdx; i++)
   {
      while(hPtr < nH && highsArr[hPtr].confirmBar == i)
      {
         refHigh = highsArr[hPtr].price;
         refHighBar = highsArr[hPtr].barIndex;
         refHighBroken = false;
         hPtr++;
      }
      while(lPtr < nL && lowsArr[lPtr].confirmBar == i)
      {
         refLow = lowsArr[lPtr].price;
         refLowBar = lowsArr[lPtr].barIndex;
         refLowBroken = false;
         lPtr++;
      }

      if(!refHighBroken && refHighBar >= 0 && close[i] > refHigh)
      {
         bool isCHoCH = (trend <= 0);
         if(draw && InpShowStructure)
            DrawStructureEvent(time, refHighBar, refHigh, i, true, isCHoCH);
         trend = 1;
         refHighBroken = true;
      }
      if(!refLowBroken && refLowBar >= 0 && close[i] < refLow)
      {
         bool isCHoCH = (trend >= 0);
         if(draw && InpShowStructure)
            DrawStructureEvent(time, refLowBar, refLow, i, false, isCHoCH);
         trend = -1;
         refLowBroken = true;
      }
   }
   return(trend);
}

//====================================================================
// 2) FAIR VALUE GAP (FVG)  +  3) ORDER BLOCK / FRESH ZONE
//====================================================================

void DrawFVGBox(const datetime &time[], int barA, int barC, double top, double bottom, bool isBull)
{
   static int counter = 0;
   counter++;
   string name = PFX + "FVG_" + IntegerToString(counter);
   color  clr  = isBull ? InpBullFVGColor : InpBearFVGColor;
   datetime t2 = time[barC] + (datetime)(PeriodSeconds() * 15);
   DrawRect(name, time[barA], top, t2, bottom, clr);
}

void DrawOBBox(const datetime &time[], int obBar, int endIdx, double top, double bottom, bool isDemand)
{
   static int counter = 0;
   counter++;
   string name  = PFX + (isDemand ? "DEMAND_" : "SUPPLY_") + IntegerToString(counter);
   color  clr   = isDemand ? InpDemandColor : InpSupplyColor;
   DrawRect(name, time[obBar], top, time[endIdx], bottom, clr);

   string labelName = PFX + (isDemand ? "DEMAND_L_" : "SUPPLY_L_") + IntegerToString(counter);
   DrawText(labelName, time[obBar], isDemand ? bottom : top, isDemand ? "Demand" : "Supply",
            clr, InpFontSize, isDemand ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
}

// ค้นหาแท่ง Order Block และเก็บผลลง g_demandZones / g_supplyZones เพื่อใช้ตรวจ POI ภายหลัง
void DetectOrderBlock(int startIdx, int impulseBar, int fvgFormBar,
                       const double &open[], const double &high[], const double &low[], const double &close[],
                       const datetime &time[], bool isBull, int endIdx, bool draw)
{
   int obBar = -1;
   int lowerLimit = MathMax(startIdx, impulseBar - InpOBSearchBars);
   for(int k = impulseBar; k >= lowerLimit; k--)
   {
      if(isBull  && close[k] < open[k]) { obBar = k; break; }
      if(!isBull && close[k] > open[k]) { obBar = k; break; }
   }
   if(obBar == -1)
      obBar = MathMax(startIdx, impulseBar - 1);

   double top = high[obBar], bottom = low[obBar];

    bool mitigated = false;
    for(int j = fvgFormBar + 1; j <= endIdx; j++)
    {
       if(isBull  && low[j]  < bottom)  { mitigated = true; break; }
       if(!isBull && high[j] > top)     { mitigated = true; break; }
    }

   // เก็บลง Array กลาง เพื่อใช้ในขั้นตอน POI Confluence (เก็บทุกกล่อง ไม่ใช่แค่ที่ Fresh
   // เพราะฟังก์ชัน POI จะเป็นผู้ตัดสินใจอีกครั้งว่ากล่องไหน Fresh จริง ณ endIdx)
   if(isBull)
   {
      int n = ArraySize(g_demandZones);
      ArrayResize(g_demandZones, n + 1);
      g_demandZones[n].barIndex  = obBar;
      g_demandZones[n].top       = top;
      g_demandZones[n].bottom    = bottom;
      g_demandZones[n].isDemand  = true;
      g_demandZones[n].mitigated = mitigated;
   }
   else
   {
      int n = ArraySize(g_supplyZones);
      ArrayResize(g_supplyZones, n + 1);
      g_supplyZones[n].barIndex  = obBar;
      g_supplyZones[n].top       = top;
      g_supplyZones[n].bottom    = bottom;
      g_supplyZones[n].isDemand  = false;
      g_supplyZones[n].mitigated = mitigated;
   }

   if(draw && !mitigated && InpShowOrderBlock)
      DrawOBBox(time, obBar, endIdx, top, bottom, isBull);
}

// ตรวจจับ FVG ทั้งขาขึ้นและขาลง พร้อมเก็บลง g_fvgZones สำหรับตรวจ Confluence
void DetectFVG(const int startIdx, const int endIdx,
                const double &open[], const double &high[], const double &low[], const double &close[],
                const datetime &time[], bool draw)
{
   for(int i = startIdx + 2; i <= endIdx; i++)
   {
      if(low[i] > high[i - 2])
      {
         double top = low[i], bottom = high[i - 2];
         bool mitigated = false;
         for(int j = i + 1; j <= endIdx; j++)
         {
            if(low[j] <= top) { mitigated = true; break; }
         }

         int n = ArraySize(g_fvgZones);
         ArrayResize(g_fvgZones, n + 1);
         g_fvgZones[n].top = top;
         g_fvgZones[n].bottom = bottom;
         g_fvgZones[n].isBull = true;
         g_fvgZones[n].mitigated = mitigated;

         if(draw && InpShowFVG && !mitigated)
            DrawFVGBox(time, i - 2, i, top, bottom, true);

         DetectOrderBlock(startIdx, i - 1, i, open, high, low, close, time, true, endIdx, draw);
      }

      if(high[i] < low[i - 2])
      {
         double top = low[i - 2], bottom = high[i];
         bool mitigated = false;
         for(int j = i + 1; j <= endIdx; j++)
         {
            if(high[j] >= bottom) { mitigated = true; break; }
         }

         int n = ArraySize(g_fvgZones);
         ArrayResize(g_fvgZones, n + 1);
         g_fvgZones[n].top = top;
         g_fvgZones[n].bottom = bottom;
         g_fvgZones[n].isBull = false;
         g_fvgZones[n].mitigated = mitigated;

         if(draw && InpShowFVG && !mitigated)
            DrawFVGBox(time, i - 2, i, top, bottom, false);

         DetectOrderBlock(startIdx, i - 1, i, open, high, low, close, time, false, endIdx, draw);
      }
   }
}

//====================================================================
// 4) PREMIUM / DISCOUNT ZONE
//====================================================================
void DrawPremiumDiscount(const int startIdx, const int endIdx,
                          const double &high[], const double &low[], const datetime &time[],
                          bool draw)
{
   int rangeStart = MathMax(startIdx, endIdx - InpRangeBars);
   double rangeHigh = -DBL_MAX, rangeLow = DBL_MAX;

   for(int i = rangeStart; i <= endIdx; i++)
   {
      if(high[i] > rangeHigh) rangeHigh = high[i];
      if(low[i]  < rangeLow)  rangeLow  = low[i];
   }

   double mid = (rangeHigh + rangeLow) / 2.0;
   g_rangeHigh = rangeHigh;
   g_rangeLow  = rangeLow;
   g_rangeMid  = mid;

   datetime t1 = time[rangeStart];
   datetime t2 = time[endIdx] + (datetime)(PeriodSeconds() * 10);

   if(draw && InpShowPremiumDiscount)
   {
      DrawRect(PFX + "PREMIUM",  t1, rangeHigh, t2, mid, InpPremiumColor);
      DrawRect(PFX + "DISCOUNT", t1, mid, t2, rangeLow, InpDiscountColor);
      DrawLine(PFX + "EQUILIBRIUM", t1, mid, t2, mid, clrGray, 1, STYLE_DASH);

      DrawText(PFX + "EQ_LABEL",       t2, mid,       "Equilibrium 50%", clrGray, InpFontSize, ANCHOR_RIGHT_LOWER);
      DrawText(PFX + "PREMIUM_LABEL",  t2, rangeHigh, "Premium (โซนน่าขาย)",   clrFireBrick, InpFontSize, ANCHOR_RIGHT_LOWER);
      DrawText(PFX + "DISCOUNT_LABEL", t2, rangeLow,  "Discount (โซนน่าซื้อ)", clrTeal,      InpFontSize, ANCHOR_RIGHT_UPPER);
   }
}

//====================================================================
// 5) LIQUIDITY POINTS (Equal Highs / Equal Lows)
//====================================================================
void DrawLiquidityLine(const datetime &time[], int bar1, double p1, int bar2, double p2, bool isHigh)
{
   static int counter = 0;
   counter++;
   string name      = PFX + "LIQ_"   + IntegerToString(counter);
   string labelName = PFX + "LIQ_L_" + IntegerToString(counter);
   double avgPrice  = (p1 + p2) / 2.0;

   DrawLine(name, time[bar1], avgPrice, time[bar2], avgPrice, InpLiquidityColor, 1, STYLE_DASH);
   string tag = isHigh ? "EQH $" : "EQL $";
   DrawText(labelName, time[bar2], avgPrice, tag, InpLiquidityColor, InpFontSize,
            isHigh ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
}

void DetectLiquidity(const SwingPoint &highsArr[], const SwingPoint &lowsArr[], const datetime &time[],
                     bool draw)
{
   ArrayResize(g_liqHighLevels, 0);
   ArrayResize(g_liqLowLevels, 0);
   double tol = InpEqualTolerancePts * _Point;

   int nH = ArraySize(highsArr);
   int startH = MathMax(0, nH - InpLiquidityLookback);
   for(int i = startH; i < nH; i++)
   {
      for(int j = i + 1; j < nH; j++)
      {
         if(MathAbs(highsArr[i].price - highsArr[j].price) <= tol)
         {
            double avg = (highsArr[i].price + highsArr[j].price) / 2.0;
            int n = ArraySize(g_liqHighLevels);
            ArrayResize(g_liqHighLevels, n + 1);
            g_liqHighLevels[n] = avg;
            if(draw && InpShowLiquidity)
               DrawLiquidityLine(time, highsArr[i].barIndex, highsArr[i].price,
                                  highsArr[j].barIndex, highsArr[j].price, true);
            break;
         }
      }
   }

   int nL = ArraySize(lowsArr);
   int startL = MathMax(0, nL - InpLiquidityLookback);
   for(int i = startL; i < nL; i++)
   {
      for(int j = i + 1; j < nL; j++)
      {
         if(MathAbs(lowsArr[i].price - lowsArr[j].price) <= tol)
         {
            double avg = (lowsArr[i].price + lowsArr[j].price) / 2.0;
            int n = ArraySize(g_liqLowLevels);
            ArrayResize(g_liqLowLevels, n + 1);
            g_liqLowLevels[n] = avg;
            if(draw && InpShowLiquidity)
               DrawLiquidityLine(time, lowsArr[i].barIndex, lowsArr[i].price,
                                  lowsArr[j].barIndex, lowsArr[j].price, false);
            break;
         }
      }
   }
}

//====================================================================
// 6) POI CONFLUENCE ENGINE (ส่วนที่เพิ่มใหม่)
//    รวมเงื่อนไข Fresh OB + Premium/Discount + FVG/Liquidity ใกล้เคียง
//    แล้วเขียนผลลัพธ์ลง Buffer เพื่อให้ EA อ่านผ่าน iCustom
//====================================================================

// ตรวจว่ากล่อง OB (top/bottom) มี FVG หรือ Liquidity อยู่ใกล้เคียงหรือไม่ (Confluence)
bool HasConfluence(double top, double bottom, bool isDemand)
{
   double tol = InpConfluenceTolPts * _Point;

   // เช็ค FVG ที่ยังไม่ถูก Mitigate และซ้อนทับ/อยู่ใกล้กล่อง OB
   for(int i = 0; i < ArraySize(g_fvgZones); i++)
   {
      if(g_fvgZones[i].mitigated) continue;
      if(isDemand && !g_fvgZones[i].isBull) continue;
      if(!isDemand && g_fvgZones[i].isBull) continue;

      bool overlap = (g_fvgZones[i].top + tol >= bottom) && (g_fvgZones[i].bottom - tol <= top);
      if(overlap) return(true);
   }

   // เช็คระดับ Liquidity ที่อยู่ใกล้กล่อง OB (ใช้ Liquidity ฝั่งตรงข้ามเป็นเป้าดึงราคาเข้ากล่อง)
   if(isDemand)
   {
      for(int i = 0; i < ArraySize(g_liqLowLevels); i++)
      {
         if(g_liqLowLevels[i] >= bottom - tol && g_liqLowLevels[i] <= top + tol)
            return(true);
      }
   }
   else
   {
      for(int i = 0; i < ArraySize(g_liqHighLevels); i++)
      {
         if(g_liqHighLevels[i] >= bottom - tol && g_liqHighLevels[i] <= top + tol)
            return(true);
      }
   }
   return(false);
}

// หาเป้าหมาย TP: ใช้ Liquidity ฝั่งตรงข้ามที่ใกล้ที่สุด หากไม่มีใช้ขอบสุดของกรอบราคา (rangeHigh/rangeLow)
double FindOppositeTarget(bool isDemand, double entryRefPrice)
{
   double best = 0;
   bool   found = false;

   if(isDemand) // ฝั่ง Buy -> เป้าหมายคือ Liquidity High ที่ใกล้ที่สุดซึ่งอยู่เหนือราคาปัจจุบัน
   {
      for(int i = 0; i < ArraySize(g_liqHighLevels); i++)
      {
         if(g_liqHighLevels[i] > entryRefPrice)
         {
            if(!found || g_liqHighLevels[i] < best) { best = g_liqHighLevels[i]; found = true; }
         }
      }
      if(!found) best = g_rangeHigh;
   }
   else // ฝั่ง Sell -> เป้าหมายคือ Liquidity Low ที่ใกล้ที่สุดซึ่งอยู่ใต้ราคาปัจจุบัน
   {
      for(int i = 0; i < ArraySize(g_liqLowLevels); i++)
      {
         if(g_liqLowLevels[i] < entryRefPrice)
         {
            if(!found || g_liqLowLevels[i] > best) { best = g_liqLowLevels[i]; found = true; }
         }
      }
      if(!found) best = g_rangeLow;
   }
   return(best);
}

// ประเมินกล่อง POI ที่ดีที่สุด ณ แท่ง endIdx แล้วเขียนผลลง Buffer
void EvaluatePOI(const int endIdx, const datetime &time[], const SwingPoint &highsArr[], const SwingPoint &lowsArr[], bool draw)
{
   BufSignal[endIdx] = 0;
   BufTop[endIdx]     = 0;
   BufBottom[endIdx]  = 0;
   BufTP[endIdx]      = 0;
   BufOrigin[endIdx]  = 0;

   // ---- ฝั่ง Buy: หา Fresh Demand Zone ที่อยู่ใน Discount Zone และมี Confluence ----
   int bestDemandIdx = -1;
   for(int i = ArraySize(g_demandZones) - 1; i >= 0; i--) // ไล่จากล่าสุดไปเก่าสุด
   {
      if(g_demandZones[i].mitigated) continue;
      double zoneMid = (g_demandZones[i].top + g_demandZones[i].bottom) / 2.0;
      if(zoneMid >= g_rangeMid) continue; // ต้องอยู่ใน Discount (ต่ำกว่า Equilibrium)
      if(!HasConfluence(g_demandZones[i].top, g_demandZones[i].bottom, true)) continue;
      bestDemandIdx = i; // เจอกล่องล่าสุดที่ผ่านเงื่อนไข ใช้กล่องนี้
      break;
   }

   // ---- ฝั่ง Sell: หา Fresh Supply Zone ที่อยู่ใน Premium Zone และมี Confluence ----
   int bestSupplyIdx = -1;
   for(int i = ArraySize(g_supplyZones) - 1; i >= 0; i--)
   {
      if(g_supplyZones[i].mitigated) continue;
      double zoneMid = (g_supplyZones[i].top + g_supplyZones[i].bottom) / 2.0;
      if(zoneMid <= g_rangeMid) continue; // ต้องอยู่ใน Premium (สูงกว่า Equilibrium)
      if(!HasConfluence(g_supplyZones[i].top, g_supplyZones[i].bottom, false)) continue;
      bestSupplyIdx = i;
      break;
   }

   // ถ้าเจอทั้งสองฝั่งพร้อมกัน (กรณีหายาก) ให้เลือกกล่องที่เกิดหลังสุด (barIndex มากกว่า)
   if(bestDemandIdx >= 0 && bestSupplyIdx >= 0)
   {
      if(g_demandZones[bestDemandIdx].barIndex >= g_supplyZones[bestSupplyIdx].barIndex)
         bestSupplyIdx = -1;
      else
         bestDemandIdx = -1;
   }

   if(bestDemandIdx >= 0)
   {
      double top = g_demandZones[bestDemandIdx].top;
      double bottom = g_demandZones[bestDemandIdx].bottom;
      
      // ยอด High ล่าสุดก่อนหน้า
      double tpPrice = 0;
      int nH = ArraySize(highsArr);
      if(nH > 0) tpPrice = highsArr[nH - 1].price;
      else tpPrice = g_rangeHigh;

      BufSignal[endIdx] = 1;
      BufTop[endIdx]     = top;
      BufBottom[endIdx]  = bottom;
      BufTP[endIdx]      = tpPrice;
      BufOrigin[endIdx]  = (double)time[g_demandZones[bestDemandIdx].barIndex];

      if(draw && InpShowOrderBlock)
      {
         string name = PFX + "POI_BUY_" + IntegerToString((int)time[g_demandZones[bestDemandIdx].barIndex]);
         DrawRect(name, time[g_demandZones[bestDemandIdx].barIndex], top, time[endIdx], bottom, InpPOIDemandColor);
         DrawText(name + "_L", time[endIdx], top, "POI BUY", InpPOIDemandColor, InpFontSize, ANCHOR_RIGHT_LOWER);
      }
   }
   else if(bestSupplyIdx >= 0)
   {
      double top = g_supplyZones[bestSupplyIdx].top;
      double bottom = g_supplyZones[bestSupplyIdx].bottom;
      
      // ยอด Low ล่าสุดก่อนหน้า
      double tpPrice = 0;
      int nL = ArraySize(lowsArr);
      if(nL > 0) tpPrice = lowsArr[nL - 1].price;
      else tpPrice = g_rangeLow;

      BufSignal[endIdx] = 2;
      BufTop[endIdx]     = top;
      BufBottom[endIdx]  = bottom;
      BufTP[endIdx]      = tpPrice;
      BufOrigin[endIdx]  = (double)time[g_supplyZones[bestSupplyIdx].barIndex];

      if(draw && InpShowOrderBlock)
      {
         string name = PFX + "POI_SELL_" + IntegerToString((int)time[g_supplyZones[bestSupplyIdx].barIndex]);
         DrawRect(name, time[g_supplyZones[bestSupplyIdx].barIndex], top, time[endIdx], bottom, InpPOISupplyColor);
         DrawText(name + "_L", time[endIdx], bottom, "POI SELL", InpPOISupplyColor, InpFontSize, ANCHOR_RIGHT_UPPER);
      }
   }
}

//====================================================================
// OnCalculate : ฟังก์ชันหลักที่ MT5 เรียกทุกครั้งที่มีข้อมูลราคาใหม่
//====================================================================
int OnCalculate(const int rates_total,
                 const int prev_calculated,
                 const datetime &time[],
                 const double &open[],
                 const double &high[],
                 const double &low[],
                 const double &close[],
                 const long &tick_volume[],
                 const long &volume[],
                 const int &spread[])
{
   if(rates_total < InpSwingPeriod * 2 + 10)
      return(rates_total);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   // กำหนดตำแหน่งเริ่มต้นในการคำนวณ โดยคำนวณย้อนหลังจำกัดไม่เกิน InpMaxBars เสมอเพื่อประสิทธิภาพสูงสุด
   int start = prev_calculated - 1;
   int minStart = rates_total - InpMaxBars;
   if(minStart < 0) minStart = 0;
   if(start < minStart)
      start = minStart;

   // ลบออบเจกต์เก่าออกเพื่อเตรียมวาดใหม่ตามข้อมูลล่าสุด
   ObjectsDeleteAll(0, PFX);

   for(int barIdx = start; barIdx < rates_total; barIdx++)
   {
      // วาดออบเจกต์ลงบนกราฟเฉพาะที่แท่งเทียนปัจจุบันเท่านั้น (เพื่อป้องกันการวาดซ้ำซ้อนของแท่งในอดีต)
      bool draw = (barIdx == rates_total - 1);
      int startIdx = MathMax(0, barIdx - InpMaxBars);

      // ล้าง Array กลางที่ใช้เก็บ FVG / OB / Liquidity ก่อนคำนวณรอบใหม่ของแต่ละแท่ง
      ArrayResize(g_fvgZones, 0);
      ArrayResize(g_demandZones, 0);
      ArrayResize(g_supplyZones, 0);
      ArrayResize(g_liqHighLevels, 0);
      ArrayResize(g_liqLowLevels, 0);

      // ---- 1) Market Structure ----
      SwingPoint highsArr[], lowsArr[];
      DetectSwings(startIdx, barIdx, high, low, highsArr, lowsArr);
      int trend = DetectStructure(startIdx, barIdx, time, close, highsArr, lowsArr, draw);
      BufTrend[barIdx] = (double)trend;

      // ---- 2) & 3) Fair Value Gap + Order Block ----
      DetectFVG(startIdx, barIdx, open, high, low, close, time, draw);

      // ---- 4) Premium / Discount Zone ----
      DrawPremiumDiscount(startIdx, barIdx, high, low, time, draw);

      // ---- 5) Liquidity Points (EQH/EQL) ----
      DetectLiquidity(highsArr, lowsArr, time, draw);

      // ---- 6) POI Confluence Engine -> เขียนผลลง Buffer ให้ EA อ่าน ----
      EvaluatePOI(barIdx, time, highsArr, lowsArr, draw);
   }

   // ---- Diagnostic Log (เปิดดูได้ที่แท็บ Journal/Experts ใน Strategy Tester) ----
   static int s_logCounter = 0;
   s_logCounter++;
   if(s_logCounter % 200 == 0) // Log ทุก 200 แท่ง กันข้อความรก
   {
      int endIdx = rates_total - 1;
      PrintFormat("SMC_Indicator: bar=%s | FVG=%d Demand=%d Supply=%d LiqHigh=%d LiqLow=%d | Signal=%.0f",
                  TimeToString(time[endIdx]), ArraySize(g_fvgZones), ArraySize(g_demandZones),
                  ArraySize(g_supplyZones), ArraySize(g_liqHighLevels), ArraySize(g_liqLowLevels),
                  BufSignal[endIdx]);
   }

   ChartRedraw(0);
   return(rates_total);
}
//+------------------------------------------------------------------+
