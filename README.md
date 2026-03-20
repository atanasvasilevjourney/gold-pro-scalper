# N30 Gold Reversion

A **mean-reversion scalping EA** for MetaTrader 5, designed for aggressive small-account growth on XM Global micro accounts. Uses Z-Score deviations from a moving average to identify statistically extreme price levels, then trades the snap-back.

## Primary EA

| EA | File | Symbol | Timeframe | SL | TP |
|----|------|--------|-----------|----|----|
| **N30 Gold Reversion** | `XAU_Quant_Reversion.mq5` | GOLD (XAUUSD) | M1 | Fixed 800 pts | Z-Score return to 0 |

## How It Works

### Entry

The EA calculates a **Z-Score** — how many standard deviations price is from its SMA. When price is stretched and filters agree, it enters:

- **Z-Score < -2.4** -> BUY (price is abnormally low)
- **Z-Score > +2.4** -> SELL (price is abnormally high)

**Filters that must pass before entry:**

| Filter | Value | Purpose |
|--------|-------|---------|
| Z-Score | > 2.4 | Price is statistically extreme |
| ADX | < 20 | Market is ranging, not trending |
| Spread | < 50 pts | Avoids bad fills during illiquid conditions |
| Volatility | ATR ratio 0.5–2.0x | Skips abnormally quiet or volatile periods |
| Session | 10:00–20:00 broker time | London+NY overlap session |
| News | No red-folder USD events | Avoids high-impact news spikes |

### Exit

Four possible exits, in priority order:

1. **Z-Score TP** — EA closes when Z-Score reverts to ±0.3 (price returned to mean)
2. **Trailing stop** — ATR-based trail tightens on new bar closes
3. **Hard SL** — fixed 800 points, server-side (survives gold spikes and disconnects)
4. **Hard TP** — fixed 1500 points, server-side safety net

### Dynamic Risk Tiers

Risk automatically scales down as your account grows:

| Equity | Risk/Trade | Daily Loss Limit |
|--------|-----------|-----------------|
| < $500 | 10% | 25% |
| $500 – $2,000 | 7% | 20% |
| $2,000 – $5,000 | 5% | 15% |
| $5,000 – $20,000 | 3% | 10% |
| $20,000+ | 1.5% | 7% |

Lot size is calculated from the SL distance and risk %. On a $50 account this produces 0.01 lots (minimum on XM micro). Dynamic risk can be toggled off via `InpUseDynamicRisk` to use fixed values.

### News Filter

The EA uses the MQL5 built-in economic calendar to avoid trading around high-impact USD news events (`CALENDAR_IMPORTANCE_HIGH` — equivalent to Forex Factory red folder news).

- **60 minutes before** a red-folder event: new entries blocked
- **60 minutes after** a red-folder event: new entries blocked
- **Pre-news close**: optionally closes all open trades before red-folder news hits

Note: MQL5's `CALENDAR_IMPORTANCE_MODERATE` does not match Forex Factory's orange folder — it includes CFTC positioning and Baker Hughes rig counts which don't move gold. Only `CALENDAR_IMPORTANCE_HIGH` is filtered.

## Input Parameters

### Strategy
| Parameter | Default | Description |
|-----------|---------|-------------|
| `TradeSymbol` | GOLD | Symbol to trade |
| `InpEntryZ` | 2.4 | Z-Score threshold for entry |
| `InpADXFilter` | 20 | ADX must be below this (ranging market) |
| `InpUseDynamicRisk` | true | Enable equity-based risk tiers |
| `InpRiskPct` | 10.0 | Risk % per trade (when dynamic risk is off) |
| `InpSLPoints` | 800 | Fixed SL in points |
| `InpHardTPPoints` | 1500 | Hard TP in points (server-side safety net) |
| `InpExitZ` | 0.3 | Z-Score exit threshold (close when Z returns near 0) |
| `InpTrailingATR` | 2.0 | ATR multiplier for trailing stop |
| `InpStartHour` | 10 | Trading window start (broker time) |
| `InpEndHour` | 20 | Trading window end (broker time) |
| `InpMagic` | 777333 | Magic number for position ID |

### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAPeriod` | 20 | SMA and StdDev period |
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |

### Execution
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpSlippage` | 30 | Max slippage in points |
| `InpMaxSpreadPts` | 50 | Max spread in points |

### News Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseNewsFilter` | true | Enable red-folder news filter |
| `InpNewsMinsBefore` | 60 | Minutes to pause before red-folder news |
| `InpNewsMinsAfter` | 60 | Minutes to pause after red-folder news |
| `InpCloseBeforeNews` | true | Close open trades before red-folder news |

### Volatility Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseVolFilter` | true | Enable volatility-adjusted entry |
| `InpATRMaxMultiple` | 2.0 | Max ATR vs 50-period avg (skip if exceeded) |
| `InpATRMinMultiple` | 0.5 | Min ATR vs 50-period avg (skip if too quiet) |

### Daily Loss Limit
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable daily loss stop |
| `InpMaxDailyLossPct` | 20.0 | Max daily loss % (when dynamic risk is off) |

## Installation

1. Copy `XAU_Quant_Reversion.mq5` to your MetaTrader 5 `MQL5/Experts/` folder
2. Compile in MetaEditor
3. Drag onto a **GOLD / XAUUSD M1** chart
4. Enable **AutoTrading**

## Chart Display

Real-time status overlay:

```
--- N30 GOLD REVERSION v5 ---
Equity: $52.30
Risk: 10.0% | DLL: 25.0%
Z-Score: -1.45
ADX: 16.3
ATR: 4.82
Spread: 25.0 pts
News Block: no
Vol Filter: OK
Daily P/L: +4.60% / -25.0% limit
```

## Design Rationale

- **Fixed-point SL** — ATR-based stops get clipped by gold spikes. Fixed 800-point SL survives volatility.
- **Z-Score TP** — mean reversion naturally targets Z=0. Closing at ±0.3 captures the snap-back without waiting for an arbitrary pip target.
- **Hard TP as safety net** — 1500-point server-side TP protects against VPS disconnects. The Z-Score exit usually triggers first.
- **Dynamic risk tiers** — aggressive at micro level (10% risk), conservative as capital grows. Prevents giving back gains.
- **New-bar trailing** — trails only on bar close, not every tick. Reduces broker modify requests and avoids noise-triggered exits.

## Risk Warning

This EA is for **educational and research purposes**. Trading leveraged instruments carries significant risk. 10% risk per trade is aggressive and can blow a small account. Always test on demo first. Past performance does not guarantee future results.

## License

Copyright 2026, n30dyn4m1c
