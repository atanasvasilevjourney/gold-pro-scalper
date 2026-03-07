//+------------------------------------------------------------------+
//|                                      gold-quant-m5-scalper.mq5   |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "3.00"
#property description "Gold Quant M5 Scalper - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   TradeSymbol    = "GOLD";
input double   InpEntryZ      = 2.0;      // Z-Score entry threshold (1.8–2.5)
input int      InpADXFilter   = 20;       // ADX range filter (below = ranging)
input double   InpRiskPct     = 10.0;     // Risk % per trade
input double   InpATRStop     = 2.0;      // ATR multiplier for SL (1.5–2.5)
input double   InpTrailingATR = 1.5;      // ATR multiplier for trailing
input int      InpStartHour   = 10;       // Trade window start hour
input int      InpEndHour     = 20;       // Trade window end hour (exclusive)
input int      InpMagic       = 777333;   // Magic number

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period
input int      InpATRPeriod   = 14;       // ATR period
input int      InpADXPeriod   = 14;       // ADX period

//--- Inputs: Execution
input int      InpSlippage    = 30;       // Max slippage in points
input double   InpMaxSpreadPts = 50.0;    // Max allowed spread in points

//--- Inputs: News Filter
input bool     InpUseNewsFilter   = true;  // Enable news time filter
input int      InpNewsMinsBefore  = 15;    // Minutes to pause BEFORE news
input int      InpNewsMinsAfter   = 15;    // Minutes to pause AFTER news

//--- Inputs: Volatility Filter
input bool     InpUseVolFilter    = true;  // Enable volatility-adjusted entry
input double   InpATRMaxMultiple  = 2.0;   // Max ATR vs 50-period avg (skip if exceeded)
input double   InpATRMinMultiple  = 0.5;   // Min ATR vs 50-period avg (skip if too quiet)

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleATR50;
string partialTag = "_P1";

//--- News schedule (up to 20 events per day, stored as server timestamps)
datetime newsEvents[20];
int newsCount = 0;
datetime lastNewsLoad = 0;

//+------------------------------------------------------------------+
int OnInit() {
   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);
   handleADX   = iADX(TradeSymbol, _Period, InpADXPeriod);
   handleATR50 = iATR(TradeSymbol, _Period, 50);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleATR50 == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleATR50 != INVALID_HANDLE) IndicatorRelease(handleATR50);
}

//+------------------------------------------------------------------+
//  News Filter — uses MQL5 economic calendar
//+------------------------------------------------------------------+
void LoadNewsEvents() {
   newsCount = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Build start/end of today in server time
   datetime dayStart = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   datetime dayEnd   = dayStart + 86400;

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, dayStart, dayEnd);

   for(int i = 0; i < total && newsCount < 20; i++) {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;

      // Only high-impact events for USD (gold-correlated)
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(country.currency != "USD") continue;

      newsEvents[newsCount] = values[i].time;
      newsCount++;
   }

   lastNewsLoad = TimeCurrent();
   Print("News filter loaded: ", newsCount, " high-impact USD events today");
}

//+------------------------------------------------------------------+
bool IsNearNews() {
   if(!InpUseNewsFilter) return false;

   // Reload news once per day
   MqlDateTime dtNow, dtLast;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(lastNewsLoad, dtLast);
   if(dtNow.day != dtLast.day) LoadNewsEvents();

   datetime now = TimeCurrent();
   for(int i = 0; i < newsCount; i++) {
      long diff = (long)(newsEvents[i] - now);
      // Within the blackout window around the event
      if(diff > -(InpNewsMinsAfter * 60) && diff < (InpNewsMinsBefore * 60))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  Volatility Filter — skip abnormal ATR conditions
//+------------------------------------------------------------------+
bool IsVolatilityOk(double atrFast) {
   if(!InpUseVolFilter) return true;

   double atrSlow[1];
   if(CopyBuffer(handleATR50, 0, 0, 1, atrSlow) < 1) return true;
   if(atrSlow[0] <= 0) return true;

   double ratio = atrFast / atrSlow[0];

   // Too volatile (news spike, flash crash) or too quiet (no movement)
   if(ratio > InpATRMaxMultiple || ratio < InpATRMinMultiple) return false;

   return true;
}

//+------------------------------------------------------------------+
bool SelectOwnPosition() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsPartialClosed() {
   string comment = PositionGetString(POSITION_COMMENT);
   return (StringFind(comment, partialTag) >= 0);
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot) {
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
void OnTick() {
   double ma[1], sd[1], atr[1], adx[1];
   if(CopyBuffer(handleMA,0,0,1,ma)<1 || CopyBuffer(handleSD,0,0,1,sd)<1 ||
      CopyBuffer(handleATR,0,0,1,atr)<1 || CopyBuffer(handleADX,0,0,1,adx)<1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

   if(sd[0] <= 0.0) return;

   double zScore = (bid - ma[0]) / sd[0];
   bool nearNews = IsNearNews();

   // --- POSITION MANAGEMENT ---
   if(SelectOwnPosition()) {
      bool alreadyPartial = IsPartialClosed();

      // 1. SCALING OUT: Close 50% at Mean (Z-Score near 0)
      if(!alreadyPartial && MathAbs(zScore) < 0.2) {
         ScaleOutHalf();
         Print("TP1 Hit: 50% Closed. SL moved to Breakeven.");
      }

      // 2. TRAILING
      HandleTrailingStop(atr[0]);
   } else {
      // --- ENTRY LOGIC ---
      bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      bool isRanging = (adx[0] < InpADXFilter);
      double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      bool spreadOk  = (spreadPts <= InpMaxSpreadPts);
      bool volOk     = IsVolatilityOk(atr[0]);

      if(inWindow && isRanging && spreadOk && volOk && !nearNews && MathAbs(zScore) > InpEntryZ) {
         if(zScore < 0) ExecuteTrade(ORDER_TYPE_BUY, ask, atr[0]);
         else           ExecuteTrade(ORDER_TYPE_SELL, bid, atr[0]);
      }
   }

   Comment("--- GOLD QUANT M5 SCALPER v3 ---\n",
           "Z-Score: ", DoubleToString(zScore, 2), "\n",
           "ADX: ", DoubleToString(adx[0], 1), "\n",
           "ATR: ", DoubleToString(atr[0], 2), "\n",
           "Spread: ", DoubleToString((ask-bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT), 1), " pts\n",
           "News Block: ", (nearNews ? "YES" : "no"), "\n",
           "Vol Filter: ", (IsVolatilityOk(atr[0]) ? "OK" : "BLOCKED"));
}

//+------------------------------------------------------------------+
void ScaleOutHalf() {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double vol = PositionGetDouble(POSITION_VOLUME);
   double halfVol = NormalizeLot(vol * 0.5);

   if(halfVol >= vol) {
      Print("Cannot scale out: volume too small to split");
      return;
   }

   req.action = TRADE_ACTION_DEAL;
   req.position = PositionGetInteger(POSITION_TICKET);
   req.symbol = TradeSymbol;
   req.volume = halfVol;
   req.type = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_SELL)?SymbolInfoDouble(TradeSymbol, SYMBOL_BID):SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   req.deviation = InpSlippage;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("ScaleOut failed: retcode=", res.retcode, " comment=", res.comment);
      return;
   }

   // Move SL to breakeven (entry + spread cost)
   if(!SelectOwnPosition()) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentTP  = PositionGetDouble(POSITION_TP);
   long   posType    = PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   double beSL;
   if(posType == POSITION_TYPE_BUY)
      beSL = NormalizeDouble(entryPrice + spread, digits);
   else
      beSL = NormalizeDouble(entryPrice - spread, digits);

   MqlTradeRequest beReq = {}; MqlTradeResult beRes = {};
   beReq.action   = TRADE_ACTION_SLTP;
   beReq.position = PositionGetInteger(POSITION_TICKET);
   beReq.symbol   = TradeSymbol;
   beReq.sl       = beSL;
   beReq.tp       = currentTP;

   if(!OrderSend(beReq, beRes) || beRes.retcode != TRADE_RETCODE_DONE) {
      Print("Breakeven modify failed: retcode=", beRes.retcode);
   }
}

//+------------------------------------------------------------------+
void HandleTrailingStop(double atrVal) {
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   double trailDist = atrVal * InpTrailingATR;
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   if(type == POSITION_TYPE_BUY) {
      double newSL = NormalizeDouble(bid - trailDist, digits);
      if(newSL > currentSL + (atrVal * 0.2)) ModifySL(newSL, currentTP);
   } else {
      double newSL = NormalizeDouble(ask + trailDist, digits);
      if(newSL < currentSL - (atrVal * 0.2) || currentSL == 0) ModifySL(newSL, currentTP);
   }
}

//+------------------------------------------------------------------+
void ModifySL(double nSL, double currentTP) {
   MqlTradeRequest r = {}; MqlTradeResult rs = {};
   r.action   = TRADE_ACTION_SLTP;
   r.position = PositionGetInteger(POSITION_TICKET);
   r.symbol   = TradeSymbol;
   r.sl       = nSL;
   r.tp       = currentTP;
   if(!OrderSend(r, rs) || rs.retcode != TRADE_RETCODE_DONE) {
      Print("TrailSL modify failed: retcode=", rs.retcode);
   }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double p, double a) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double slD = a * InpATRStop;
   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPct / 100.0);
   double tickV = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickV <= 0 || tickS <= 0) {
      Print("Invalid tick value/size, skipping trade");
      return;
   }

   double lot = risk / (slD * (1.0 / tickS) * tickV);
   lot = NormalizeLot(lot);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = InpMagic;
   req.sl           = NormalizeDouble(sl, digits);
   req.deviation    = InpSlippage;
   req.comment      = "GQS";
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      Print("Trade opened: ", EnumToString(type), " ", lot, " lots, SL=", sl);
   }
}
//+------------------------------------------------------------------+
