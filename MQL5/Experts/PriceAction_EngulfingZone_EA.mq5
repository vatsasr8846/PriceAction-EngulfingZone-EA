//+------------------------------------------------------------------+
//|                              PriceAction_EngulfingZone_EA.mq5    |
//|                              XAUUSD M5 Engulfing Zone Retest EA  |
//|                                                                  |
//|  STRATEGY:                                                       |
//|    Pure price-action EA that trades XAUUSD on M5.                |
//|    1. Detects trend via swing-point structure (HH/HL or LH/LL). |
//|    2. Identifies Engulfing patterns at swing points.             |
//|    3. Creates supply/demand zones from the engulfing candle.     |
//|    4. Waits for price to leave the zone and later retest it.     |
//|    5. If a NEW engulfing pattern forms inside the zone during    |
//|       the retest, a trade is opened on the next candle.          |
//|    6. SL beyond the zone, TP at 1:1 risk-to-reward.             |
//|                                                                  |
//|  No indicators. No repainting. No Martingale/Grid/Hedging.      |
//+------------------------------------------------------------------+
#property copyright "PriceAction Engulfing Zone EA"
#property link      ""
#property version   "1.00"
#property description "XAUUSD M5 — Engulfing Zone Retest Strategy"
#property description "Pure price action. No indicators. No repainting."
#property strict

#include <Trade\Trade.mqh>

//================================================================
// ENUMERATIONS
//================================================================
enum ENUM_TREND_DIR
{
   TREND_UP   = 1,    // Uptrend
   TREND_DOWN = -1,   // Downtrend
   TREND_NONE = 0     // No clear trend
};

enum ENUM_ZONE_TYPE
{
   ZONE_BULLISH = 1,  // Bullish (demand) zone
   ZONE_BEARISH = -1  // Bearish (supply) zone
};

//================================================================
// DATA STRUCTURES
//================================================================
struct EngulfingZone
{
   double         ZoneHigh;           // High of the engulfing candle
   double         ZoneLow;            // Low of the engulfing candle
   datetime       CreationTime;       // Bar time when zone was created
   bool           PriceHasLeft;       // Has price closed outside the zone?
   int            CandlesOutside;     // Consecutive candles closed outside
   bool           IsActive;           // Is zone still valid?
   bool           TradeAlreadyTaken;  // Has a trade been fired from this zone?
   bool           SignalPending;      // Signal fired, waiting for next candle to open trade
   ENUM_ZONE_TYPE ZoneType;           // Bullish or Bearish zone
   string         ObjName;            // Chart object name for visual rectangle
};

struct SwingPoint
{
   double   price;     // Swing high or swing low price
   datetime time;      // Bar time of the swing point
   int      barIndex;  // Bar index (shift) where detected
};

//================================================================
// INPUT PARAMETERS
//================================================================
input group "=== 💰 LOT SIZE SETTINGS ==="
input double InpManualLotSize   = 0.0;    // Manual Lot Size (0 = Auto)
input double InpLotPer1000      = 0.04;   // Lot Size per $1,000 Balance (Auto mode)
input double InpMaxLotSize      = 2.0;    // Maximum Lot Size
input double InpMinLotSize      = 0.01;   // Minimum Lot Size

input group "=== 🛡️ STOP LOSS & TAKE PROFIT ==="
input int    InpSLBufferPoints  = 50;     // SL Buffer Beyond Zone (Points)

input group "=== 📊 SWING & TREND DETECTION ==="
input int    InpSwingLookback   = 3;      // Swing Point Lookback (candles each side)
input int    InpTrendSwingCount = 4;      // Swing Points for Trend Evaluation (minimum 3)

input group "=== 🔄 ZONE MANAGEMENT ==="
input int    InpZoneExitCandles = 3;      // Min Candles Outside Zone Before Retest
input bool   InpInvalidateZone  = true;   // Invalidate Zone on Opposite Close-Through

input group "=== ⚙️ EXECUTION SETTINGS ==="
input int    InpMagicNumber     = 202507; // Magic Number
input int    InpMaxSlippage     = 30;     // Maximum Slippage (Points)
input int    InpMaxSpreadPoints = 50;     // Maximum Spread (Points)

input group "=== 🎨 VISUAL SETTINGS ==="
input bool   InpShowZones       = true;   // Draw Zone Rectangles on Chart
input color  InpBullZoneColor   = clrDodgerBlue;   // Bullish Zone Color
input color  InpBearZoneColor   = clrOrangeRed;    // Bearish Zone Color

//================================================================
// GLOBAL VARIABLES
//================================================================
CTrade         g_trade;              // Trade execution object
EngulfingZone  g_bullZone;           // Current active bullish zone
EngulfingZone  g_bearZone;           // Current active bearish zone
datetime       g_lastBarTime;        // For new candle detection
int            g_zoneCounter;        // Unique zone object name counter

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   string sym = Symbol();
   if(StringFind(sym, "XAUUSD") < 0 && StringFind(sym, "GOLD") < 0 && StringFind(sym, "XAU") < 0)
   {
      Print("❌ ERROR: This EA is designed for XAUUSD only. Current symbol: ", sym);
      return(INIT_FAILED);
   }
   
   //--- Validate timeframe
   if(Period() != PERIOD_M5)
   {
      Print("❌ ERROR: This EA is designed for M5 timeframe only. Current: ", EnumToString(Period()));
      return(INIT_FAILED);
   }
   
   //--- Validate inputs
   if(InpSwingLookback < 1)
   {
      Print("❌ ERROR: SwingLookback must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpTrendSwingCount < 3)
   {
      Print("❌ ERROR: TrendSwingCount must be >= 3");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   //--- Initialize trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Initialize zones as inactive
   ResetZone(g_bullZone, ZONE_BULLISH);
   ResetZone(g_bearZone, ZONE_BEARISH);
   
   //--- Initialize tracking variables
   g_lastBarTime = 0;
   g_zoneCounter = 0;
   
   Print("✅ PriceAction Engulfing Zone EA initialized on ", sym, " ", EnumToString(Period()));
   Print("   Lot Mode: ", (InpManualLotSize > 0 ? "Manual (" + DoubleToString(InpManualLotSize, 2) + ")" : "Auto (" + DoubleToString(InpLotPer1000, 2) + " per $1000)"));
   Print("   SL Buffer: ", InpSLBufferPoints, " points | Magic: ", InpMagicNumber);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Remove chart objects created by this EA
   RemoveAllZoneObjects();
   Print("🔴 PriceAction Engulfing Zone EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new candle close
   if(!IsNewCandle())
      return;
   
   //--- Check spread
   double spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
   {
      // Spread too wide — skip this bar but still manage zones
      ManageZones();
      return;
   }
   
   //--- Execute pending signals from the previous candle
   //    (We open on the NEXT candle after signal, so check pending flags first)
   if(!HasOpenPosition())
   {
      if(g_bullZone.SignalPending && g_bullZone.IsActive)
      {
         OpenBuyTrade();
         g_bullZone.SignalPending = false;
         g_bullZone.TradeAlreadyTaken = true;
      }
      else if(g_bearZone.SignalPending && g_bearZone.IsActive)
      {
         OpenSellTrade();
         g_bearZone.SignalPending = false;
         g_bearZone.TradeAlreadyTaken = true;
      }
   }
   else
   {
      //--- If we had a pending signal but already have a position, clear it
      g_bullZone.SignalPending = false;
      g_bearZone.SignalPending = false;
   }
   
   //--- Update zone states (price left, retest, invalidation)
   ManageZones();
   
   //--- Detect trend
   ENUM_TREND_DIR trend = GetTrend();
   
   //--- Check for new engulfing patterns and signals
   //    All analysis is done on closed candles (shift >= 1) — no repainting
   
   //--- BULLISH LOGIC (Uptrend)
   if(trend == TREND_UP)
   {
      //--- Check if a Bullish Engulfing formed at a Swing Low on the last closed candle
      if(IsBullishEngulfing(1) && IsAtSwingLow(1))
      {
         //--- Is there already an active bullish zone?
         if(g_bullZone.IsActive)
         {
            //--- Is this new engulfing INSIDE the existing zone during a retest?
            if(g_bullZone.PriceHasLeft && !g_bullZone.TradeAlreadyTaken && IsEngulfingInsideZone(1, g_bullZone))
            {
               //--- SIGNAL: Open BUY on next candle
               g_bullZone.SignalPending = true;
               Print("🟢 BUY SIGNAL: New Bullish Engulfing inside zone during retest at ", TimeToString(iTime(Symbol(), Period(), 1)));
            }
         }
         else
         {
            //--- No active bullish zone — create one (first engulfing, do NOT trade)
            CreateZone(g_bullZone, ZONE_BULLISH, 1);
            Print("📦 BULLISH ZONE CREATED [No Trade]: High=", DoubleToString(g_bullZone.ZoneHigh, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
                  " Low=", DoubleToString(g_bullZone.ZoneLow, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
                  " at ", TimeToString(g_bullZone.CreationTime));
         }
      }
   }
   
   //--- BEARISH LOGIC (Downtrend)
   if(trend == TREND_DOWN)
   {
      //--- Check if a Bearish Engulfing formed at a Swing High on the last closed candle
      if(IsBearishEngulfing(1) && IsAtSwingHigh(1))
      {
         //--- Is there already an active bearish zone?
         if(g_bearZone.IsActive)
         {
            //--- Is this new engulfing INSIDE the existing zone during a retest?
            if(g_bearZone.PriceHasLeft && !g_bearZone.TradeAlreadyTaken && IsEngulfingInsideZone(1, g_bearZone))
            {
               //--- SIGNAL: Open SELL on next candle
               g_bearZone.SignalPending = true;
               Print("🔴 SELL SIGNAL: New Bearish Engulfing inside zone during retest at ", TimeToString(iTime(Symbol(), Period(), 1)));
            }
         }
         else
         {
            //--- No active bearish zone — create one (first engulfing, do NOT trade)
            CreateZone(g_bearZone, ZONE_BEARISH, 1);
            Print("📦 BEARISH ZONE CREATED [No Trade]: High=", DoubleToString(g_bearZone.ZoneHigh, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
                  " Low=", DoubleToString(g_bearZone.ZoneLow, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
                  " at ", TimeToString(g_bearZone.CreationTime));
         }
      }
   }
}

//================================================================
// HELPER FUNCTIONS
//================================================================

//+------------------------------------------------------------------+
//| Detect new M5 candle                                               |
//+------------------------------------------------------------------+
bool IsNewCandle()
{
   datetime currentBarTime = iTime(Symbol(), Period(), 0);
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reset a zone to inactive defaults                                  |
//+------------------------------------------------------------------+
void ResetZone(EngulfingZone &zone, ENUM_ZONE_TYPE type)
{
   zone.ZoneHigh          = 0;
   zone.ZoneLow           = 0;
   zone.CreationTime      = 0;
   zone.PriceHasLeft      = false;
   zone.CandlesOutside    = 0;
   zone.IsActive          = false;
   zone.TradeAlreadyTaken = false;
   zone.SignalPending     = false;
   zone.ZoneType          = type;
   zone.ObjName           = "";
}

//+------------------------------------------------------------------+
//| Create a new engulfing zone from the candle at shift               |
//+------------------------------------------------------------------+
void CreateZone(EngulfingZone &zone, ENUM_ZONE_TYPE type, int shift)
{
   //--- Remove old zone visual if it exists
   if(zone.ObjName != "" && InpShowZones)
      ObjectDelete(0, zone.ObjName);
   
   zone.ZoneHigh          = iHigh(Symbol(), Period(), shift);
   zone.ZoneLow           = iLow(Symbol(), Period(), shift);
   zone.CreationTime      = iTime(Symbol(), Period(), shift);
   zone.PriceHasLeft      = false;
   zone.CandlesOutside    = 0;
   zone.IsActive          = true;
   zone.TradeAlreadyTaken = false;
   zone.SignalPending     = false;
   zone.ZoneType          = type;
   
   //--- Draw zone on chart
   if(InpShowZones)
   {
      g_zoneCounter++;
      zone.ObjName = "EZ_" + (type == ZONE_BULLISH ? "BULL_" : "BEAR_") + IntegerToString(g_zoneCounter);
      DrawZoneRectangle(zone);
   }
}

//+------------------------------------------------------------------+
//| Manage zone lifecycle — update states on each new candle           |
//+------------------------------------------------------------------+
void ManageZones()
{
   ManageSingleZone(g_bullZone);
   ManageSingleZone(g_bearZone);
}

//+------------------------------------------------------------------+
//| Manage a single zone's lifecycle                                   |
//+------------------------------------------------------------------+
void ManageSingleZone(EngulfingZone &zone)
{
   if(!zone.IsActive)
      return;
   
   //--- Get the last closed candle's data (shift 1)
   double closePrice = iClose(Symbol(), Period(), 1);
   
   //--- Check for zone invalidation (price closes through zone in wrong direction)
   if(InpInvalidateZone)
   {
      if(zone.ZoneType == ZONE_BULLISH && closePrice < zone.ZoneLow)
      {
         Print("❌ BULLISH ZONE INVALIDATED: Price closed below zone at ", DoubleToString(closePrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
         InvalidateZone(zone);
         return;
      }
      if(zone.ZoneType == ZONE_BEARISH && closePrice > zone.ZoneHigh)
      {
         Print("❌ BEARISH ZONE INVALIDATED: Price closed above zone at ", DoubleToString(closePrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
         InvalidateZone(zone);
         return;
      }
   }
   
   //--- Check if price has left the zone
   if(!zone.PriceHasLeft)
   {
      bool priceOutside = false;
      
      if(zone.ZoneType == ZONE_BULLISH)
         priceOutside = (closePrice > zone.ZoneHigh);  // Price must close above the bullish zone
      else
         priceOutside = (closePrice < zone.ZoneLow);   // Price must close below the bearish zone
      
      if(priceOutside)
      {
         zone.CandlesOutside++;
         if(zone.CandlesOutside >= InpZoneExitCandles)
         {
            zone.PriceHasLeft = true;
            Print("📤 ", (zone.ZoneType == ZONE_BULLISH ? "BULLISH" : "BEARISH"),
                  " ZONE: Price has left after ", zone.CandlesOutside, " candles outside");
         }
      }
      else
      {
         zone.CandlesOutside = 0;  // Reset counter if price returns to zone
      }
   }
   
   //--- Update zone rectangle if visible
   if(InpShowZones && zone.ObjName != "")
      UpdateZoneRectangle(zone);
}

//+------------------------------------------------------------------+
//| Invalidate and deactivate a zone                                   |
//+------------------------------------------------------------------+
void InvalidateZone(EngulfingZone &zone)
{
   if(InpShowZones && zone.ObjName != "")
   {
      //--- Change color to indicate invalidation then remove after a few bars
      ObjectSetInteger(0, zone.ObjName, OBJPROP_COLOR, clrGray);
   }
   zone.IsActive = false;
   zone.SignalPending = false;
}

//================================================================
// SWING POINT DETECTION
//================================================================

//+------------------------------------------------------------------+
//| Check if candle at shift is a Swing High                           |
//+------------------------------------------------------------------+
bool DetectSwingHigh(int shift)
{
   double high = iHigh(Symbol(), Period(), shift);
   
   //--- Check N candles on the left (older bars, higher index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(iHigh(Symbol(), Period(), shift + i) >= high)
         return false;
   }
   
   //--- Check N candles on the right (newer bars, lower index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(shift - i < 0)
         return false;  // Not enough bars on the right
      if(iHigh(Symbol(), Period(), shift - i) >= high)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if candle at shift is a Swing Low                            |
//+------------------------------------------------------------------+
bool DetectSwingLow(int shift)
{
   double low = iLow(Symbol(), Period(), shift);
   
   //--- Check N candles on the left (older bars, higher index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(iLow(Symbol(), Period(), shift + i) <= low)
         return false;
   }
   
   //--- Check N candles on the right (newer bars, lower index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(shift - i < 0)
         return false;
      if(iLow(Symbol(), Period(), shift - i) <= low)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if candle at shift is AT a Swing Low (nearby)                |
//|  The engulfing candle itself or the candle it engulfs              |
//|  should be at or near a swing low area                             |
//+------------------------------------------------------------------+
bool IsAtSwingLow(int shift)
{
   //--- Check if the engulfing candle or the candle before it is at a swing area
   //    We look back a few candles to see if there's a swing low nearby
   int lookRange = InpSwingLookback + 2;
   
   for(int i = shift; i <= shift + lookRange; i++)
   {
      if(DetectSwingLow(i))
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if candle at shift is AT a Swing High (nearby)               |
//+------------------------------------------------------------------+
bool IsAtSwingHigh(int shift)
{
   int lookRange = InpSwingLookback + 2;
   
   for(int i = shift; i <= shift + lookRange; i++)
   {
      if(DetectSwingHigh(i))
         return true;
   }
   
   return false;
}

//================================================================
// TREND DETECTION (Pure Price Action)
//================================================================

//+------------------------------------------------------------------+
//| Detect trend using swing point structure                           |
//| Higher Highs + Higher Lows = UPTREND                              |
//| Lower Highs  + Lower Lows  = DOWNTREND                           |
//+------------------------------------------------------------------+
ENUM_TREND_DIR GetTrend()
{
   //--- Collect recent swing highs and swing lows
   SwingPoint swingHighs[];
   SwingPoint swingLows[];
   ArrayResize(swingHighs, 0);
   ArrayResize(swingLows, 0);
   
   int requiredSwings = InpTrendSwingCount;
   int maxBarsToScan  = 200;  // Scan up to 200 bars back
   
   //--- We start from shift = InpSwingLookback + 1 to ensure we have
   //    enough bars on both sides for swing detection
   int startShift = InpSwingLookback + 1;
   
   for(int i = startShift; i < maxBarsToScan; i++)
   {
      //--- Collect swing highs
      if(ArraySize(swingHighs) < requiredSwings && DetectSwingHigh(i))
      {
         int idx = ArraySize(swingHighs);
         ArrayResize(swingHighs, idx + 1);
         swingHighs[idx].price    = iHigh(Symbol(), Period(), i);
         swingHighs[idx].time     = iTime(Symbol(), Period(), i);
         swingHighs[idx].barIndex = i;
      }
      
      //--- Collect swing lows
      if(ArraySize(swingLows) < requiredSwings && DetectSwingLow(i))
      {
         int idx = ArraySize(swingLows);
         ArrayResize(swingLows, idx + 1);
         swingLows[idx].price    = iLow(Symbol(), Period(), i);
         swingLows[idx].time     = iTime(Symbol(), Period(), i);
         swingLows[idx].barIndex = i;
      }
      
      //--- Stop early if we have enough
      if(ArraySize(swingHighs) >= requiredSwings && ArraySize(swingLows) >= requiredSwings)
         break;
   }
   
   //--- Need at least 2 swing highs and 2 swing lows to determine trend
   if(ArraySize(swingHighs) < 2 || ArraySize(swingLows) < 2)
      return TREND_NONE;
   
   //--- Check for Higher Highs (most recent swings are at index 0, oldest at end)
   //    swingHighs[0] is most recent, swingHighs[1] is older
   bool higherHighs = true;
   bool lowerHighs  = true;
   int shCount = MathMin(ArraySize(swingHighs), requiredSwings);
   
   for(int i = 0; i < shCount - 1; i++)
   {
      //--- swingHighs[i] is more recent than swingHighs[i+1]
      if(swingHighs[i].price <= swingHighs[i + 1].price)
         higherHighs = false;
      if(swingHighs[i].price >= swingHighs[i + 1].price)
         lowerHighs = false;
   }
   
   //--- Check for Higher Lows / Lower Lows
   bool higherLows = true;
   bool lowerLows  = true;
   int slCount = MathMin(ArraySize(swingLows), requiredSwings);
   
   for(int i = 0; i < slCount - 1; i++)
   {
      if(swingLows[i].price <= swingLows[i + 1].price)
         higherLows = false;
      if(swingLows[i].price >= swingLows[i + 1].price)
         lowerLows = false;
   }
   
   //--- Determine trend
   if(higherHighs && higherLows)
      return TREND_UP;
   if(lowerHighs && lowerLows)
      return TREND_DOWN;
   
   return TREND_NONE;
}

//================================================================
// ENGULFING PATTERN DETECTION
//================================================================

//+------------------------------------------------------------------+
//| Check for Bullish Engulfing at shift                               |
//| Prev candle (shift+1) is bearish, current (shift) is bullish      |
//| Current body fully engulfs previous body                           |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int shift)
{
   double open1  = iOpen(Symbol(), Period(), shift);
   double close1 = iClose(Symbol(), Period(), shift);
   double open2  = iOpen(Symbol(), Period(), shift + 1);
   double close2 = iClose(Symbol(), Period(), shift + 1);
   
   //--- Current candle must be bullish
   if(close1 <= open1)
      return false;
   
   //--- Previous candle must be bearish
   if(close2 >= open2)
      return false;
   
   //--- Current body must engulf previous body
   //    For bullish engulfing: current open <= prev close AND current close >= prev open
   if(open1 <= close2 && close1 >= open2)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check for Bearish Engulfing at shift                               |
//| Prev candle (shift+1) is bullish, current (shift) is bearish      |
//| Current body fully engulfs previous body                           |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(int shift)
{
   double open1  = iOpen(Symbol(), Period(), shift);
   double close1 = iClose(Symbol(), Period(), shift);
   double open2  = iOpen(Symbol(), Period(), shift + 1);
   double close2 = iClose(Symbol(), Period(), shift + 1);
   
   //--- Current candle must be bearish
   if(close1 >= open1)
      return false;
   
   //--- Previous candle must be bullish
   if(close2 <= open2)
      return false;
   
   //--- Current body must engulf previous body
   //    For bearish engulfing: current open >= prev close AND current close <= prev open
   if(open1 >= close2 && close1 <= open2)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if an engulfing candle at shift is INSIDE a zone             |
//+------------------------------------------------------------------+
bool IsEngulfingInsideZone(int shift, const EngulfingZone &zone)
{
   double candleLow  = iLow(Symbol(), Period(), shift);
   double candleHigh = iHigh(Symbol(), Period(), shift);
   
   //--- The engulfing candle should have significant overlap with the zone
   //    At minimum, the candle's body or wicks must touch the zone
   if(zone.ZoneType == ZONE_BULLISH)
   {
      //--- For bullish zone: candle low should be >= zone low and some part within zone
      return (candleLow >= zone.ZoneLow && candleLow <= zone.ZoneHigh);
   }
   else
   {
      //--- For bearish zone: candle high should be <= zone high and some part within zone
      return (candleHigh <= zone.ZoneHigh && candleHigh >= zone.ZoneLow);
   }
}

//================================================================
// LOT SIZE CALCULATION
//================================================================

//+------------------------------------------------------------------+
//| Calculate lot size based on account balance or manual input        |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double lot;
   
   //--- Manual override
   if(InpManualLotSize > 0)
   {
      lot = InpManualLotSize;
   }
   else
   {
      //--- Auto calculation: balance / 1000 * lotPer1000
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      lot = (balance / 1000.0) * InpLotPer1000;
   }
   
   //--- Clamp to limits
   lot = MathMax(lot, InpMinLotSize);
   lot = MathMin(lot, InpMaxLotSize);
   
   //--- Normalize to broker step size
   double stepSize = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if(stepSize > 0)
      lot = MathFloor(lot / stepSize) * stepSize;
   
   //--- Final clamp to broker limits
   double brokerMin = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double brokerMax = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lot = MathMax(lot, brokerMin);
   lot = MathMin(lot, brokerMax);
   
   return NormalizeDouble(lot, 2);
}

//================================================================
// TRADE EXECUTION
//================================================================

//+------------------------------------------------------------------+
//| Check if the EA already has an open position                       |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == Symbol())
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open a BUY trade with SL below bullish zone and 1:1 TP            |
//+------------------------------------------------------------------+
void OpenBuyTrade()
{
   if(!g_bullZone.IsActive)
   {
      Print("⚠️ Cannot open BUY: Bullish zone is not active");
      return;
   }
   
   double ask   = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   //--- SL = Zone Low - buffer
   double sl = NormalizeDouble(g_bullZone.ZoneLow - InpSLBufferPoints * point, digits);
   
   //--- Risk distance
   double riskDist = ask - sl;
   
   if(riskDist <= 0)
   {
      Print("⚠️ Cannot open BUY: Invalid risk distance. Ask=", DoubleToString(ask, digits),
            " SL=", DoubleToString(sl, digits));
      return;
   }
   
   //--- TP = Entry + risk distance (1:1 RR)
   double tp = NormalizeDouble(ask + riskDist, digits);
   
   //--- Lot size
   double lot = CalculateLotSize();
   
   //--- Execute
   string comment = "EZ_BUY_" + IntegerToString(InpMagicNumber);
   
   if(g_trade.Buy(lot, Symbol(), ask, sl, tp, comment))
   {
      Print("✅ BUY OPENED: Lot=", DoubleToString(lot, 2),
            " Entry=", DoubleToString(ask, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits),
            " RR=1:1");
   }
   else
   {
      Print("❌ BUY FAILED: Error ", GetLastError(),
            " Lot=", DoubleToString(lot, 2),
            " Ask=", DoubleToString(ask, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits));
   }
}

//+------------------------------------------------------------------+
//| Open a SELL trade with SL above bearish zone and 1:1 TP           |
//+------------------------------------------------------------------+
void OpenSellTrade()
{
   if(!g_bearZone.IsActive)
   {
      Print("⚠️ Cannot open SELL: Bearish zone is not active");
      return;
   }
   
   double bid   = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   //--- SL = Zone High + buffer
   double sl = NormalizeDouble(g_bearZone.ZoneHigh + InpSLBufferPoints * point, digits);
   
   //--- Risk distance
   double riskDist = sl - bid;
   
   if(riskDist <= 0)
   {
      Print("⚠️ Cannot open SELL: Invalid risk distance. Bid=", DoubleToString(bid, digits),
            " SL=", DoubleToString(sl, digits));
      return;
   }
   
   //--- TP = Entry - risk distance (1:1 RR)
   double tp = NormalizeDouble(bid - riskDist, digits);
   
   //--- Lot size
   double lot = CalculateLotSize();
   
   //--- Execute
   string comment = "EZ_SELL_" + IntegerToString(InpMagicNumber);
   
   if(g_trade.Sell(lot, Symbol(), bid, sl, tp, comment))
   {
      Print("✅ SELL OPENED: Lot=", DoubleToString(lot, 2),
            " Entry=", DoubleToString(bid, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits),
            " RR=1:1");
   }
   else
   {
      Print("❌ SELL FAILED: Error ", GetLastError(),
            " Lot=", DoubleToString(lot, 2),
            " Bid=", DoubleToString(bid, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits));
   }
}

//================================================================
// VISUAL ZONE DRAWING
//================================================================

//+------------------------------------------------------------------+
//| Draw a zone rectangle on the chart                                 |
//+------------------------------------------------------------------+
void DrawZoneRectangle(const EngulfingZone &zone)
{
   if(!InpShowZones || zone.ObjName == "")
      return;
   
   datetime timeStart = zone.CreationTime;
   datetime timeEnd   = iTime(Symbol(), Period(), 0) + PeriodSeconds(Period()) * 20;  // Extend forward
   
   color zoneColor = (zone.ZoneType == ZONE_BULLISH) ? InpBullZoneColor : InpBearZoneColor;
   
   if(ObjectCreate(0, zone.ObjName, OBJ_RECTANGLE, 0, timeStart, zone.ZoneHigh, timeEnd, zone.ZoneLow))
   {
      ObjectSetInteger(0, zone.ObjName, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, zone.ObjName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, zone.ObjName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zone.ObjName, OBJPROP_FILL, true);
      ObjectSetInteger(0, zone.ObjName, OBJPROP_BACK, true);
      ObjectSetInteger(0, zone.ObjName, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, zone.ObjName, OBJPROP_TOOLTIP, 
                      (zone.ZoneType == ZONE_BULLISH ? "Bullish" : "Bearish") + " Engulfing Zone\n" +
                      "High: " + DoubleToString(zone.ZoneHigh, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\n" +
                      "Low: " + DoubleToString(zone.ZoneLow, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
   }
}

//+------------------------------------------------------------------+
//| Update zone rectangle to extend to current time                    |
//+------------------------------------------------------------------+
void UpdateZoneRectangle(const EngulfingZone &zone)
{
   if(!InpShowZones || zone.ObjName == "")
      return;
   
   datetime timeEnd = iTime(Symbol(), Period(), 0) + PeriodSeconds(Period()) * 20;
   ObjectSetInteger(0, zone.ObjName, OBJPROP_TIME, 1, timeEnd);
   
   //--- Update color based on zone state
   color zoneColor;
   if(!zone.IsActive)
      zoneColor = clrGray;
   else if(zone.TradeAlreadyTaken)
      zoneColor = clrDarkGray;
   else if(zone.PriceHasLeft)
      zoneColor = (zone.ZoneType == ZONE_BULLISH) ? clrLimeGreen : clrCrimson;  // Brighter when ready for retest
   else
      zoneColor = (zone.ZoneType == ZONE_BULLISH) ? InpBullZoneColor : InpBearZoneColor;
   
   ObjectSetInteger(0, zone.ObjName, OBJPROP_COLOR, zoneColor);
}

//+------------------------------------------------------------------+
//| Remove all zone objects from chart                                 |
//+------------------------------------------------------------------+
void RemoveAllZoneObjects()
{
   int total = ObjectsTotal(0, 0, OBJ_RECTANGLE);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_RECTANGLE);
      if(StringFind(name, "EZ_") == 0)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+
