# XAUUSD SMC Trading System (EA Upgrade Specifications)

This repository contains the ongoing development of an automated Expert Advisor (EA) for MetaTrader 5 (MT5) designed specifically for trading Gold (XAUUSD) using Smart Money Concepts (SMC).

## 🚀 Objective
Upgrade and complete the existing MQL5 code to implement strict Multi-Timeframe (MTF) alignment, ensure deep historical data learning during backtests, and enforce Price Action (PA) candlestick confirmations before execution.

---

## 📐 System Specifications & Logic

### 1. Multi-Timeframe (MTF) Architecture
* **Analysis Timeframe (H4):** Used to scan the macro market structure. The system must automatically identify the primary trend (Bullish BOS / Bearish BOS) and map out major Fair Value Gaps (FVG) and Order Blocks (OB).
* **Execution Timeframe (M15):** The system must remain passive until the live XAUUSD price retraces deep into the H4 FVG or H4 OB zone (Points of Interest - POI).

### 2. Historical Learning & Backtest Synchronization
* To eliminate "Waiting for Update" bugs and indicators failing to load during Strategy Tester sessions, a data synchronization module must reside inside `OnInit()`.
* **Execution:** Implement a `CheckAndDownloadHistory()` function to force MT5 to download full M15 and H4 bar history from the broker server before launching trading routines.
* Ensure all indicator buffers extracted via `iCustom()` correctly parse `EMPTY_VALUE` to learn from past structural shifts.

### 3. Price Action (PA) Confirmation Entry
Even if the M15 Indicator buffer sends an immediate signal, **do not enter blindly**. The EA must wait for the current M15 bar (Bar 1) to close inside the H4 POI with a valid candlestick pattern:
* **🟢 BUY Entry Conditions:**
  * M15 Indicator Buy Signal is active.
  * Price is inside H4 Bullish OB/FVG.
  * Candlestick Confirmation: Bullish Engulfing, Hammer, or Pinbar (Bar 1 Close > Bar 1 Open WITH a long lower wick).
* **🔴 SELL Entry Conditions:**
  * M15 Indicator Sell Signal is active.
  * Price is inside H4 Bearish OB/FVG.
  * Candlestick Confirmation: Bearish Engulfing, Shooting Star, or Pinbar (Bar 1 Close < Bar 1 Open WITH a long upper wick).

### 4. Risk Management & Execution Specs
* **Lot Sizing:** Enforce Fixed Lot size configuration through `InpFixLot`.
* **Stop Loss (SL):** Placed strictly beyond the high of the Bearish PA candle (for Sells) or below the low of the Bullish PA candle (for Buys), accounting for the live XAUUSD spread buffer.
* **Take Profit (TP):** Target the major opposing H4 liquidity pools (Next H4 High/Low) maintaining a minimum Risk-to-Reward (RR) ratio of 1:3.
* **Gold Precision:** All internal points, pips, and price calculations must be compatible with 2-decimal/3-decimal Gold quoting mechanisms.

---

## 🛠️ Instructions for AI Developer
1. Read the current source code provided below.
2. Maintain the established indicator connection handles for `"SmartMoneyConcepts 3.00"`.
3. Implement the missing M15 Price Action scanning functions.
4. Refactor `OnInit()` to support the historical data pre-loading logic.
5. Return the finalized, compiled-ready `.mq5` source code with detailed structural comments.
