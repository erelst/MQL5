# Engulfing Auto Trader (MQL5)

Expert Advisor (EA) otomatis untuk MetaTrader 5 yang mengeksekusi order **Buy / Sell** secara instan saat terjadi pola **Strong Engulfing Break** realtime (tick-level), dengan kalkulasi Stop Loss berbasis **50% ATR** dan Take Profit otomatis berdasarkan rasio **Risk-to-Reward (RR)** dinamis.

---

## Fitur Utama

1. **Arah Trading Fleksibel (`InpTradeDirection`)**:
   - `Buy and Sell`: Mengeksekusi order Buy maupun Sell saat pola terdeteksi.
   - `Buy Only`: Hanya mengeksekusi order Buy (mengabaikan Bearish Engulfing).
   - `Sell Only`: Hanya mengeksekusi order Sell (mengabaikan Bullish Engulfing).

2. **Rasio Risk-to-Reward Dinamis (`InpRiskRewardRatio`)**:
   - Menerima input desimal (contoh: `1.5`, `2.0`, `2.5`, `3.0`).
   - Formula Take Profit:
     - **Buy TP**: `Ask + (Jarak SL * RR)`
     - **Sell TP**: `Bid - (Jarak SL * RR)`

3. **Stop Loss Presisi (50% ATR)**:
   - **Buy SL**: `Low Candle Sebelumnya - 50% ATR(14)`
   - **Sell SL**: `High Candle Sebelumnya + 50% ATR(14) + Spread`

4. **Realtime Tick Execution**:
   - Order dieksekusi seketika saat tick harga menembus High/Low candle sebelumnya tanpa menunggu bar selesai (*close*).
   - Dilengkapi proteksi anti multi-order dalam 1 candle yang sama (*one trade per bar*).

5. **Money Management**:
   - Pilihan Fixed Lot (contoh `0.01`) atau Risk Percentage (% Balance per trade yang otomatis menghitung ukuran lot berdasarkan jarak SL).

---

## Parameter Input

| Parameter | Default | Keterangan |
|---|---|---|
| `InpTradeDirection` | `Buy and Sell` | Pilihan arah order (`Buy and Sell`, `Buy Only`, `Sell Only`) |
| `InpRiskRewardRatio` | `2.0` | Target rasio Risk to Reward (1:RR) |
| `InpMaxOpenTrades` | `1` | Maksimal posisi terbuka per simbol (0 = tanpa batas) |
| `InpLotMode` | `LOT_FIXED` | Mode lot: `LOT_FIXED` atau `LOT_RISK_PCT` |
| `InpFixedLot` | `0.01` | Ukuran lot jika mode Fixed Lot |
| `InpRiskPercent` | `1.0` | Risiko % saldo jika mode Risk Percentage |
| `InpTimeframe` | `PERIOD_M5` | Timeframe deteksi pola Engulfing |
| `InpATRPeriod` | `14` | Periode ATR untuk kalkulasi 50% buffer SL |
| `InpBullishPriceMax` | `0.0` | Filter batas harga Buy `< X` (`0` = Bebas / Any Price) |
| `InpBearishPriceMin` | `0.0` | Filter batas harga Sell `> Y` (`0` = Bebas / Any Price) |
| `InpMagicNumber` | `882201` | ID unik transaksi EA |
| `InpSlippage` | `10` | Toleransi slippage (Points) |
