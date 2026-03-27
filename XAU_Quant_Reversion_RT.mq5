//+------------------------------------------------------------------+
//|                                    XAU_Quant_Reversion_RT.mq5    |
//|                                     Copyright 2026, n30dyn4m1c  |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, n30dyn4m1c"
#property link      ""
#property version   "6.00"
#property description "N30 Gold Reversion - Real Tick Refactored"
#property description "Mean Reversion Z-Score EA - Every Tick / Real Ticks Ready"

//--- Inputs: Strategy
input string   InpTradeSymbol    = "GOLD";        // Trade symbol (GOLD, XAUUSD, etc.)
string         TradeSymbol;
input double   InpEntryZ         = 2.4;           // Z-Score entry threshold (1.8-2.5)
input int      InpADXFilter      = 20;            // ADX range filter (below = ranging)
input bool     InpUseDynamicRisk = true;           // Enable equity-based risk tiers
input double   InpRiskPct        = 10.0;           // Risk % per trade (when dynamic risk off)
input double   InpSLPoints       = 800;            // Fixed SL in points
input double   InpHardTPPoints   = 1500;           // Hard TP in points (server-side)
input double   InpExitZ          = 0.3;            // Z-Score exit threshold
input double   InpTrailingATR    = 2.0;            // ATR multiplier for trailing
input int      InpStartHour      = 10;             // Trade window start hour
input int      InpEndHour        = 20;             // Trade window end hour (exclusive)
input int      InpMagic          = 777333;         // Magic number

//--- Inputs: Indicators
input int      InpMAPeriod       = 20;             // MA / StdDev period
input int      InpATRPeriod      = 14;             // ATR period
input int      InpADXPeriod      = 14;             // ADX period

//--- Inputs: Execution
input int      InpSlippage       = 30;             // Max slippage in points
input double   InpMaxSpreadPts   = 50.0;           // Max allowed spread in points
input int      InpMaxPositions   = 1;              // Max open positions allowed
input int      InpOrderRetries   = 3;              // Order send retry attempts
input int      InpRetryDelayMs   = 500;            // Delay between retries (ms)

//--- Inputs: News Filter
input bool     InpUseNewsFilter      = true;
input int      InpNewsMinsBefore     = 60;
input int      InpNewsMinsAfter      = 60;
input bool     InpCloseBeforeNews    = true;

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit  = true;
input double   InpMaxDailyLossPct    = 20.0;

//--- Inputs: Volatility Filter
input bool     InpUseVolFilter       = true;
input double   InpATRMaxMultiple     = 2.0;
input double   InpATRMinMultiple     = 0.5;

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleATR50;

//--- News schedule
#define MAX_NEWS 40
datetime newsRed[MAX_NEWS];
int      newsRedCount = 0;
datetime lastNewsLoad = 0;

//--- Daily loss tracking
double   dailyStartBalance = 0;
int      dailyStartDay     = -1;
bool     dailyLossHit      = false;

//--- New-bar detection (static per function)
datetime g_lastBarTime     = 0;       // for entry logic new-bar gate
datetime g_lastTrailBar    = 0;       // for trailing stop new-bar gate
datetime g_lastExitBar     = 0;       // for Z-score exit new-bar gate

//--- Cooldown after trade to prevent rapid re-entry on same signal
datetime g_lastTradeTime   = 0;
input int InpCooldownSecs  = 60;      // Seconds to wait after a trade before new entry

//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize and validate symbol
   TradeSymbol = InpTradeSymbol;
   if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST))
   {
      Print("Symbol ", TradeSymbol, " not found - trying XAUUSD");
      TradeSymbol = "XAUUSD";
      if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST))
      {
         Print("Neither GOLD nor XAUUSD found. Please set TradeSymbol manually.");
         return(INIT_FAILED);
      }
   }

   // Ensure symbol is selected in MarketWatch (required for real-time data)
   if(!SymbolInfoInteger(TradeSymbol, SYMBOL_SELECT))
      SymbolSelect(TradeSymbol, true);

   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);
   handleADX   = iADX(TradeSymbol, _Period, InpADXPeriod);
   handleATR50 = iATR(TradeSymbol, _Period, 50);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleATR50 == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter)
      LoadNewsEvents();

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dailyStartDay = dt.day_of_year;
   dailyLossHit  = false;

   // Initialize bar tracking to current bar so we don't trigger on first tick
   g_lastBarTime  = iTime(TradeSymbol, _Period, 0);
   g_lastTrailBar = g_lastBarTime;
   g_lastExitBar  = g_lastBarTime;

   Print("N30 Gold Reversion RT v6.00 initialized on ", TradeSymbol,
         " | Period=", EnumToString(_Period),
         " | Mode=Real Tick Ready");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleATR50 != INVALID_HANDLE) IndicatorRelease(handleATR50);
   Comment("");
}

//+------------------------------------------------------------------+
//  New Bar Detection — reliable under real ticks
//  Each subsystem (entry, trail, exit) tracks its own bar time
//+------------------------------------------------------------------+
bool IsNewBar(datetime &lastBar)
{
   datetime curBar = iTime(TradeSymbol, _Period, 0);
   if(curBar == 0) return false;           // data not ready
   if(curBar == lastBar) return false;     // same bar
   lastBar = curBar;
   return true;
}

//+------------------------------------------------------------------+
//  Get completed bar indicator values — always bar index 1
//  This is the KEY fix: bar 0 is forming and unstable under real ticks.
//  Bar 1 is the last fully completed bar = stable signal source.
//+------------------------------------------------------------------+
bool GetIndicators(double &ma, double &sd, double &atr, double &adx)
{
   double bufMA[1], bufSD[1], bufATR[1], bufADX[1];

   // Copy from bar index 1 (completed bar), NOT bar 0
   if(CopyBuffer(handleMA,  0, 1, 1, bufMA)  < 1) return false;
   if(CopyBuffer(handleSD,  0, 1, 1, bufSD)  < 1) return false;
   if(CopyBuffer(handleATR, 0, 1, 1, bufATR) < 1) return false;
   if(CopyBuffer(handleADX, 0, 1, 1, bufADX) < 1) return false;

   ma  = bufMA[0];
   sd  = bufSD[0];
   atr = bufATR[0];
   adx = bufADX[0];
   return true;
}

//+------------------------------------------------------------------+
//  Get previous bar close — matches indicator calculation basis
//+------------------------------------------------------------------+
double GetPrevClose()
{
   double close[1];
   if(CopyClose(TradeSymbol, _Period, 1, 1, close) < 1) return 0;
   return close[0];
}

//+------------------------------------------------------------------+
//  Daily Loss Limit
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != dailyStartDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartDay = dt.day_of_year;
      dailyLossHit  = false;
      Print("Daily loss tracker reset. Starting balance: ", dailyStartBalance);
   }
}

bool IsDailyLossLimitHit()
{
   if(!InpUseDailyLossLimit) return false;
   if(dailyLossHit) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dailyStartBalance <= 0) return false;

   double lossPercent = ((dailyStartBalance - equity) / dailyStartBalance) * 100.0;
   double dailyLimit  = GetDailyLossLimitPct();

   if(lossPercent >= dailyLimit)
   {
      dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2),
            "% lost (limit ", DoubleToString(dailyLimit, 1), "%). Trading stopped for today.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  News Filter
//+------------------------------------------------------------------+
void LoadNewsEvents()
{
   newsRedCount = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   datetime dayEnd   = dayStart + 86400;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, dayStart, dayEnd)) return;

   int total = ArraySize(values);
   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(country.currency != "USD") continue;

      if(newsRedCount < MAX_NEWS)
      {
         newsRed[newsRedCount] = values[i].time;
         newsRedCount++;
      }
   }
   lastNewsLoad = TimeCurrent();
   Print("News loaded: ", newsRedCount, " red-folder high-impact USD events today");
}

bool IsNearNews()
{
   if(!InpUseNewsFilter) return false;

   MqlDateTime dtNow, dtLast;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(lastNewsLoad, dtLast);
   if(dtNow.day_of_year != dtLast.day_of_year) LoadNewsEvents();

   datetime now = TimeCurrent();
   for(int i = 0; i < newsRedCount; i++)
   {
      long diff = (long)(newsRed[i] - now);
      if(diff > -(InpNewsMinsAfter * 60) && diff < (InpNewsMinsBefore * 60))
         return true;
   }
   return false;
}

bool IsRedNewsImminent()
{
   if(!InpUseNewsFilter || !InpCloseBeforeNews) return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < newsRedCount; i++)
   {
      long diff = (long)(newsRed[i] - now);
      if(diff > 0 && diff < (InpNewsMinsBefore * 60))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  Volatility Filter — uses bar 1 data
//+------------------------------------------------------------------+
bool IsVolatilityOk(double atrFast)
{
   if(!InpUseVolFilter) return true;

   double atrSlow[1];
   // Bar 1 for consistency
   if(CopyBuffer(handleATR50, 0, 1, 1, atrSlow) < 1) return true;
   if(atrSlow[0] <= 0) return true;

   double ratio = atrFast / atrSlow[0];
   if(ratio > InpATRMaxMultiple || ratio < InpATRMinMultiple) return false;
   return true;
}

//+------------------------------------------------------------------+
//  Dynamic Risk Tiers
//+------------------------------------------------------------------+
double GetRiskPct()
{
   if(!InpUseDynamicRisk) return InpRiskPct;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity < 500)   return 10.0;
   if(equity < 2000)  return 7.0;
   if(equity < 5000)  return 5.0;
   if(equity < 20000) return 3.0;
   return 1.5;
}

double GetDailyLossLimitPct()
{
   if(!InpUseDynamicRisk) return InpMaxDailyLossPct;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity < 500)   return 25.0;
   if(equity < 2000)  return 20.0;
   if(equity < 5000)  return 15.0;
   if(equity < 20000) return 10.0;
   return 7.0;
}

//+------------------------------------------------------------------+
//  Position helpers
//+------------------------------------------------------------------+
bool SelectOwnPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return true;
   }
   return false;
}

int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//  Utility
//+------------------------------------------------------------------+
string TruncateComment(string comment, int maxLen = 31)
{
   if(StringLen(comment) <= maxLen) return comment;
   return StringSubstr(comment, 0, maxLen);
}

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = NormalizeDouble(lot, 2);
   return lot;
}

//+------------------------------------------------------------------+
//  Get fresh tick — always call immediately before order operations
//+------------------------------------------------------------------+
bool GetFreshTick(MqlTick &tick)
{
   if(!SymbolInfoTick(TradeSymbol, tick))
   {
      Print("Failed to get fresh tick for ", TradeSymbol);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//  Fill mode detection
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillMode()
{
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if(fill & SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if(fill & SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//  Close All — with fresh price and retry
//+------------------------------------------------------------------+
void CloseAllOwnPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY)
                                  ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      for(int attempt = 0; attempt < InpOrderRetries; attempt++)
      {
         // Fresh price on every attempt
         MqlTick tick;
         if(!GetFreshTick(tick)) break;

         double price = (closeType == ORDER_TYPE_SELL) ? tick.bid : tick.ask;

         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action       = TRADE_ACTION_DEAL;
         req.position     = ticket;
         req.symbol       = TradeSymbol;
         req.volume       = volume;
         req.type         = closeType;
         req.price        = price;
         req.deviation    = InpSlippage;
         req.comment      = TruncateComment("N30 " + reason);
         req.type_filling = GetFillMode();

         if(OrderSend(req, res))
         {
            if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL)
            {
               Print("Position closed (", reason, "): ticket=", ticket);
               break;
            }
         }

         Print("Close attempt ", attempt + 1, " failed: ticket=", ticket,
               " retcode=", res.retcode, " comment=", res.comment);

         if(attempt < InpOrderRetries - 1)
            Sleep(InpRetryDelayMs);
      }
   }
}

//+------------------------------------------------------------------+
//  Main Tick Handler
//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyReset();

   //--- Get stable indicators from completed bar (bar 1)
   double ma, sd, atr, adx;
   if(!GetIndicators(ma, sd, atr, adx)) return;

   //--- Time check
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   //--- Z-Score from previous bar close (matches MA/SD calculation basis)
   double prevClose = GetPrevClose();
   if(prevClose == 0 || sd <= 0.0) return;
   double zScore = (prevClose - ma) / sd;

   //--- Current tick for display only
   MqlTick curTick;
   if(!GetFreshTick(curTick)) return;
   double bid = curTick.bid;
   double ask = curTick.ask;

   //--- Filter states
   bool nearNews       = IsNearNews();
   bool lossLimitHit   = IsDailyLossLimitHit();
   bool redNewsImminent = IsRedNewsImminent();
   bool volOk          = IsVolatilityOk(atr);

   //--- DAILY LOSS: close everything and stop
   if(lossLimitHit)
   {
      if(SelectOwnPosition())
         CloseAllOwnPositions("daily loss limit");

      Comment("--- N30 GOLD REVERSION RT v6 ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY))
                        / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   //--- CLOSE BEFORE RED-FOLDER NEWS (can happen on any tick)
   if(redNewsImminent && SelectOwnPosition())
      CloseAllOwnPositions("red-folder news imminent");

   //--- POSITION MANAGEMENT
   if(SelectOwnPosition())
   {
      //--- Z-Score exit: only evaluate on NEW BAR to avoid tick noise
      bool newExitBar = IsNewBar(g_lastExitBar);
      if(newExitBar)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         bool zRevert = false;

         if(posType == POSITION_TYPE_BUY  && zScore >= -InpExitZ) zRevert = true;
         if(posType == POSITION_TYPE_SELL && zScore <=  InpExitZ) zRevert = true;

         if(zRevert)
         {
            CloseAllOwnPositions("Z-TP (Z=" + DoubleToString(zScore, 2) + ")");
            g_lastTradeTime = TimeCurrent();  // cooldown after exit too
         }
      }

      //--- Trailing stop: only on new bar
      if(!newExitBar || SelectOwnPosition())  // re-check, position may have been closed above
      {
         if(SelectOwnPosition() && IsNewBar(g_lastTrailBar))
            HandleTrailingStop(atr);
      }
   }
   else
   {
      //--- ENTRY LOGIC — only on confirmed new bar
      bool newEntryBar = IsNewBar(g_lastBarTime);
      if(!newEntryBar) goto DISPLAY;  // skip entry evaluation between bars

      //--- Cooldown check
      if(TimeCurrent() - g_lastTradeTime < InpCooldownSecs) goto DISPLAY;

      //--- Position limit
      if(CountOwnPositions() >= InpMaxPositions) goto DISPLAY;

      //--- Entry filters
      bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      bool isRanging = (adx < InpADXFilter);

      //--- Spread check uses live tick
      double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      bool spreadOk = (spreadPts <= InpMaxSpreadPts);

      if(inWindow && isRanging && spreadOk && volOk && !nearNews &&
         MathAbs(zScore) > InpEntryZ)
      {
         // Use fresh tick prices for the order, not the earlier snapshot
         if(zScore < 0)
            ExecuteTrade(ORDER_TYPE_BUY, atr, zScore, adx);
         else
            ExecuteTrade(ORDER_TYPE_SELL, atr, zScore, adx);
      }
   }

   //--- HUD Display
   DISPLAY:
   double dailyLossPct = (dailyStartBalance > 0)
      ? ((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0
      : 0;

   Comment("--- N30 GOLD REVERSION RT v6 ---\n",
           "Mode: Real Tick Ready | Bar-1 Signals\n",
           "Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
           "Risk: ", DoubleToString(GetRiskPct(), 1), "% | DLL: ",
                     DoubleToString(GetDailyLossLimitPct(), 1), "%\n",
           "Z-Score(bar1): ", DoubleToString(zScore, 2), "\n",
           "ADX: ", DoubleToString(adx, 1), "\n",
           "ATR: ", DoubleToString(atr, 2), "\n",
           "Spread: ", DoubleToString((ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT), 1),
                       " pts\n",
           "News Block: ", (nearNews ? "YES" : "no"),
           (redNewsImminent ? " [RED CLOSE]" : ""), "\n",
           "Vol Filter: ", (volOk ? "OK" : "BLOCKED"), "\n",
           "Daily P/L: ", DoubleToString(-dailyLossPct, 2),
                          "% / -", DoubleToString(GetDailyLossLimitPct(), 1), "% limit");
}

//+------------------------------------------------------------------+
//  Trailing Stop — bar-1 ATR, fresh tick price, with buffer
//+------------------------------------------------------------------+
void HandleTrailingStop(double atrVal)
{
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   long type = PositionGetInteger(POSITION_TYPE);
   double trailDist = atrVal * InpTrailingATR;
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   // Fresh price for trail calculation
   MqlTick tick;
   if(!GetFreshTick(tick)) return;

   // Minimum SL movement threshold to avoid excessive modifications
   double minMove = atrVal * 0.2;
   double stopLevel = SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                      * SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   if(type == POSITION_TYPE_BUY)
   {
      double newSL = NormalizeDouble(tick.bid - trailDist, digits);
      // Only trail upward, and only if meaningful movement
      if(newSL > currentSL + minMove)
      {
         // Respect broker minimum stop distance
         if(tick.bid - newSL >= stopLevel)
            ModifySL(newSL, currentTP);
      }
   }
   else // SELL
   {
      double newSL = NormalizeDouble(tick.ask + trailDist, digits);
      // Only trail downward (lower SL for sells), or set initial
      if(currentSL == 0 || newSL < currentSL - minMove)
      {
         if(newSL - tick.ask >= stopLevel)
            ModifySL(newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//  Modify SL — with retry
//+------------------------------------------------------------------+
void ModifySL(double nSL, double currentTP)
{
   for(int attempt = 0; attempt < InpOrderRetries; attempt++)
   {
      MqlTradeRequest r = {};
      MqlTradeResult rs = {};
      r.action   = TRADE_ACTION_SLTP;
      r.position = (ulong)PositionGetInteger(POSITION_TICKET);
      r.symbol   = TradeSymbol;
      r.sl       = nSL;
      r.tp       = currentTP;

      if(OrderSend(r, rs))
      {
         if(rs.retcode == TRADE_RETCODE_DONE)
            return;
      }

      Print("TrailSL modify attempt ", attempt + 1, " failed: retcode=", rs.retcode);
      if(attempt < InpOrderRetries - 1)
         Sleep(InpRetryDelayMs);
   }
}

//+------------------------------------------------------------------+
//  Execute Trade — fresh tick price, spread recheck, retry loop
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double atrVal, double zScore, double adxVal)
{
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   if(point <= 0) return;

   double slD = InpSLPoints * point;
   double tpD = InpHardTPPoints * point;
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   // Calculate lot size
   double riskPct = GetRiskPct();
   double risk    = AccountInfoDouble(ACCOUNT_BALANCE) * (riskPct / 100.0);
   double tickV   = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS   = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickV <= 0 || tickS <= 0)
   {
      Print("Invalid tick value/size, skipping trade");
      return;
   }
   double lot = risk / (slD * (1.0 / tickS) * tickV);
   lot = NormalizeLot(lot);

   // Pre-check margin with approximate price
   MqlTick tick;
   if(!GetFreshTick(tick)) return;
   double approxPrice = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

   double marginRequired;
   if(!OrderCalcMargin(type, TradeSymbol, lot, approxPrice, marginRequired))
   {
      Print("Failed to calculate margin, skipping trade");
      return;
   }
   if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("Insufficient margin: required=", marginRequired,
            " free=", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   // Build comment
   string dir = (type == ORDER_TYPE_BUY) ? "B" : "S";
   string comment = TruncateComment("N30 " + dir
                    + "|Z" + DoubleToString(zScore, 2)
                    + "|A" + DoubleToString(adxVal, 0)
                    + "|R" + DoubleToString(atrVal, 2));

   //--- Retry loop with fresh price each attempt
   for(int attempt = 0; attempt < InpOrderRetries; attempt++)
   {
      // Get FRESH tick on every attempt (price may have moved)
      if(!GetFreshTick(tick))
      {
         Print("No fresh tick on attempt ", attempt + 1);
         break;
      }

      double price = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

      // Re-check spread on every attempt (critical under real ticks)
      double currentSpread = (tick.ask - tick.bid) / point;
      if(currentSpread > InpMaxSpreadPts)
      {
         Print("Spread widened to ", DoubleToString(currentSpread, 1),
               " pts on attempt ", attempt + 1, ", aborting entry");
         return;
      }

      double sl = (type == ORDER_TYPE_BUY) ? (price - slD) : (price + slD);
      double tp = (type == ORDER_TYPE_BUY) ? (price + tpD) : (price - tpD);

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = TradeSymbol;
      req.volume       = lot;
      req.type         = type;
      req.price        = NormalizeDouble(price, digits);
      req.magic        = InpMagic;
      req.sl           = NormalizeDouble(sl, digits);
      req.tp           = NormalizeDouble(tp, digits);
      req.deviation    = InpSlippage;
      req.comment      = comment;
      req.type_filling = GetFillMode();

      if(OrderSend(req, res))
      {
         if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL)
         {
            Print("Trade opened: ", EnumToString(type), " ", lot, " lots @ ",
                  NormalizeDouble(price, digits),
                  " SL=", NormalizeDouble(sl, digits),
                  " TP=", NormalizeDouble(tp, digits),
                  " exitZ=", InpExitZ);
            g_lastTradeTime = TimeCurrent();
            return;
         }
      }

      Print("Entry attempt ", attempt + 1, " failed: retcode=", res.retcode,
            " comment=", res.comment);

      // Don't retry on fatal errors
      if(res.retcode == TRADE_RETCODE_INVALID_STOPS ||
         res.retcode == TRADE_RETCODE_NO_MONEY ||
         res.retcode == TRADE_RETCODE_MARKET_CLOSED ||
         res.retcode == TRADE_RETCODE_TRADE_DISABLED ||
         res.retcode == TRADE_RETCODE_INVALID_VOLUME)
      {
         Print("Fatal order error, not retrying");
         return;
      }

      if(attempt < InpOrderRetries - 1)
         Sleep(InpRetryDelayMs);
   }
}
//+------------------------------------------------------------------+
// This work is my worship unto GOD
