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
   
   //--- Auto-detect supported filling mode
   long fillFlags = SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   
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
   
   //--- Execute pending signals from the previous candle FIRST
   //    (Must happen before spread check — signal was validated on prior candle)
   if(!HasOpenPosition())
   {
      if(g_bullZone.SignalPending && g_bullZone.IsActive)
      {
         if(OpenBuyTrade())
            g_bullZone.TradeAlreadyTaken = true;
      }
      else if(g_bearZone.SignalPending && g_bearZone.IsActive)
      {
         if(OpenSellTrade())
            g_bearZone.TradeAlreadyTaken = true;
      }
   }
   //--- Always clear pending signals after processing (prevent stale signals)
   g_bullZone.SignalPending = false;
   g_bearZone.SignalPending = false;
   
   //--- Check spread — skip new signal detection if spread too wide
   long spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(spread > (long)InpMaxSpreadPoints)
   {
      // Spread too wide — skip new signal detection but still manage zones
      ManageZones();
      return;
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
   //--- Need at least InpSwingLookback bars on both sides
   //    Right side must not go below shift 1 (no peeking at unclosed bar 0)
   if(shift < InpSwingLookback + 1)
      return false;
   
   double high = iHigh(Symbol(), Period(), shift);
   
   //--- Check N candles on the left (older bars, higher index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(iHigh(Symbol(), Period(), shift + i) >= high)
         return false;
   }
   
   //--- Check N candles on the right (newer bars, lower index)
   //    Never go below shift 1 to avoid using unclosed bar 0
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(shift - i < 1)
         return false;  // Would peek at unclosed bar — reject
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
   //--- Need at least InpSwingLookback bars on both sides
   //    Right side must not go below shift 1 (no peeking at unclosed bar 0)
   if(shift < InpSwingLookback + 1)
      return false;
   
   double low = iLow(Symbol(), Period(), shift);
   
   //--- Check N candles on the left (older bars, higher index)
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(iLow(Symbol(), Period(), shift + i) <= low)
         return false;
   }
   
   //--- Check N candles on the right (newer bars, lower index)
   //    Never go below shift 1 to avoid using unclosed bar 0
   for(int i = 1; i <= InpSwingLookback; i++)
   {
      if(shift - i < 1)
         return false;  // Would peek at unclosed bar — reject
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
   //--- Minimum shift for valid swing detection is InpSwingLookback + 1
   //    Search from there through a reasonable range around the engulfing candle
   int minShift = InpSwingLookback + 1;
   int maxShift = shift + InpSwingLookback + 2;
   
   for(int i = MathMax(shift, minShift); i <= maxShift; i++)
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
   //--- Minimum shift for valid swing detection is InpSwingLookback + 1
   //    Search from there through a reasonable range around the engulfing candle
   int minShift = InpSwingLookback + 1;
   int maxShift = shift + InpSwingLookback + 2;
   
   for(int i = MathMax(shift, minShift); i <= maxShift; i++)
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
   
   //--- Check we have enough historical data
   if(Bars(Symbol(), Period()) < maxBarsToScan + InpSwingLookback)
      return TREND_NONE;
   
   //--- We start from shift = InpSwingLookback + 1 to ensure we have
   //    enough bars on both sides for swing detection (no bar 0 peeking)
   int startShift = InpSwingLookback + 1;
   
   //--- Scan the full range to collect swing points over a consistent window
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
   
   //--- Need at least the requested swing count to determine trend reliably
   if(ArraySize(swingHighs) < requiredSwings || ArraySize(swingLows) < requiredSwings)
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
   
   //--- Current candle must be bullish (strict — reject doji)
   if(close1 < open1 || close1 == open1)
      return false;
   
   //--- Previous candle must be bearish (strict — reject doji)
   if(close2 > open2 || close2 == open2)
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
   
   //--- Current candle must be bearish (strict — reject doji)
   if(close1 > open1 || close1 == open1)
      return false;
   
   //--- Previous candle must be bullish (strict — reject doji)
   if(close2 < open2 || close2 == open2)
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
   
   //--- The engulfing candle should be substantially inside the zone
   //    Both the candle's low and high must be within zone boundaries
   //    This ensures the candle is truly "inside" and not just touching
   if(zone.ZoneType == ZONE_BULLISH)
   {
      //--- For bullish zone: candle must be fully contained within zone
      //    Low >= ZoneLow AND High <= ZoneHigh
      return (candleLow >= zone.ZoneLow && candleHigh <= zone.ZoneHigh);
   }
   else
   {
      //--- For bearish zone: candle must be fully contained within zone
      //    High <= ZoneHigh AND Low >= ZoneLow
      return (candleHigh <= zone.ZoneHigh && candleLow >= zone.ZoneLow);
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
   
   //--- Dynamic normalization based on step size
   int lotDigits = 2;
   if(stepSize > 0)
   {
      lotDigits = (int)MathMax(0, -MathLog10(stepSize));
   }
   
   return NormalizeDouble(lot, lotDigits);
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
//| Returns true on successful execution, false otherwise              |
//+------------------------------------------------------------------+
bool OpenBuyTrade()
{
   if(!g_bullZone.IsActive)
   {
      Print("⚠️ Cannot open BUY: Bullish zone is not active");
      return false;
   }
   
   //--- Re-check spread at actual trade time
   long currentSpread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(currentSpread > (long)InpMaxSpreadPoints)
   {
      Print("⚠️ BUY aborted: Spread widened to ", currentSpread, " points");
      return false;
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
      return false;
   }
   
   //--- Check broker minimum stop level
   long stopLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopLevel * point;
   if(riskDist < minStopDist)
   {
      Print("⚠️ Cannot open BUY: SL too close. Risk=", DoubleToString(riskDist, digits),
            " MinRequired=", DoubleToString(minStopDist, digits));
      return false;
   }
   
   //--- TP = Entry + risk distance (1:1 RR)
   double tp = NormalizeDouble(ask + riskDist, digits);
   
   //--- Lot size
   double lot = CalculateLotSize();
   
   //--- Execute (pass actual ask price so SL/TP match the entry)
   string comment = "EZ_BUY_" + IntegerToString(InpMagicNumber);
   
   if(g_trade.Buy(lot, Symbol(), ask, sl, tp, comment))
   {
      Print("✅ BUY OPENED: Lot=", DoubleToString(lot, 2),
            " Entry=", DoubleToString(ask, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits),
            " RR=1:1");
      return true;
   }
   else
   {
      Print("❌ BUY FAILED: Error ", GetLastError(),
            " Lot=", DoubleToString(lot, 2),
            " Ask=", DoubleToString(ask, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits));
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open a SELL trade with SL above bearish zone and 1:1 TP           |
//| Returns true on successful execution, false otherwise              |
//+------------------------------------------------------------------+
bool OpenSellTrade()
{
   if(!g_bearZone.IsActive)
   {
      Print("⚠️ Cannot open SELL: Bearish zone is not active");
      return false;
   }
   
   //--- Re-check spread at actual trade time
   long currentSpread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(currentSpread > (long)InpMaxSpreadPoints)
   {
      Print("⚠️ SELL aborted: Spread widened to ", currentSpread, " points");
      return false;
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
      return false;
   }
   
   //--- Check broker minimum stop level
   long stopLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopLevel * point;
   if(riskDist < minStopDist)
   {
      Print("⚠️ Cannot open SELL: SL too close. Risk=", DoubleToString(riskDist, digits),
            " MinRequired=", DoubleToString(minStopDist, digits));
      return false;
   }
   
   //--- TP = Entry - risk distance (1:1 RR)
   double tp = NormalizeDouble(bid - riskDist, digits);
   
   //--- Lot size
   double lot = CalculateLotSize();
   
   //--- Execute (pass actual bid price so SL/TP match the entry)
   string comment = "EZ_SELL_" + IntegerToString(InpMagicNumber);
   
   if(g_trade.Sell(lot, Symbol(), bid, sl, tp, comment))
   {
      Print("✅ SELL OPENED: Lot=", DoubleToString(lot, 2),
            " Entry=", DoubleToString(bid, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits),
            " RR=1:1");
      return true;
   }
   else
   {
      Print("❌ SELL FAILED: Error ", GetLastError(),
            " Lot=", DoubleToString(lot, 2),
            " Bid=", DoubleToString(bid, digits),
            " SL=", DoubleToString(sl, digits),
            " TP=", DoubleToString(tp, digits));
      return false;
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
