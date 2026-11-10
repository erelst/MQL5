# Engulfing Auto Trader (MQL5)

Expert Advisor (EA) otomatis untuk MetaTrader 5 yang mengeksekusi order **Buy / Sell** secara instan saat terjadi pola **Strong Engulfing Break** realtime (tick-level), lengkap dengan proteksi otomatis **Auto Trail SL (BE / Lock TP Sebelumnya)** dan **Volatility Trail TP Engine (>= 2x ATR)** serta dashboard interaktif on-chart.

---

## Fitur Utama

### 1. Eksekusi Realtime & Rasio Risk-to-Reward (RR) Dinamis
- **Realtime Tick Execution**: Order dieksekusi seketika saat tick harga menembus High/Low candle sebelumnya tanpa menunggu bar selesai (*close*), dengan proteksi *one trade per bar*.
- **Rasio Risk-to-Reward Fleksibel**: Menerima input desimal (contoh: `1.5`, `2.0`, `2.5`, `3.0`). Target Take Profit awal dihitung otomatis dari jarak Stop Loss dikali rasio RR.
- **Arah Trading**: Pilihan `Buy and Sell`, `Buy Only`, atau `Sell Only` yang dapat diubah langsung dari tombol di chart.

---

### 2. Auto Trail SL (BE) & Volatility Trail TP Engine
Fitur cerdas untuk memproteksi modal sekaligus membiarkan profit berlari (*let profits run*) ketika terjadi lonjakan volatilitas pasar:

1. **Pemicu (Trigger Zona Sisa 5% TP)**:
   - Terpicu saat harga profit sudah menempuh 95% perjalanan target (sisa jarak tinggal $\le$ 5% menuju Take Profit aktif).
2. **Auto Trail SL Tahap 1 (Break-Even Otomatis)**:
   - Seketika di zona sisa 5% tersebut, SL **pasti digeser ke Break-Even (BE)** (`Harga Open ± Spread`), menjadikan posisi bebas risiko rugi (*risk-free*).
3. **Auto Trail TP (Perpanjangan Target saat Volatilitas Meledak)**:
   - Di detik yang sama, EA mengecek kondisi pasar:
     $$\text{ATR Realtime Saat Ini} \ge 2 \times (\text{100% ATR Acuan Awal saat Entry})$$
   - **Jika ATR $\ge$ 2x**: Target TP **otomatis diperpanjang sejauh +1x jarak target awal**, memberi ruang posisi untuk memaksimalkan profit tren besar.
   - **Jika ATR < 2x**: Target TP tetap di posisi awal untuk take profit normal.
4. **Auto Trail SL Tahap 2 & Seterusnya (Penguncian Profit Bertingkat)**:
   - Jika target TP sebelumnya berhasil diperpanjang dan harga kembali mendekati sisa 5% dari TP baru tersebut, SL otomatis **dikerek naik/turun dan dikunci tepat di harga TP sebelumnya**. Anda mengamankan profit penuh dari target sebelumnya secara berulang.

---

### 3. Dashboard Interaktif On-Chart
Panel visual di chart memudahkan Anda memantau dan mengubah strategi tanpa perlu membuka jendela properties:
- **Direction Toggle**: Tombol visual `BUY & SELL`, `BUY ONLY`, dan `SELL ONLY`.
- **Lot Mode Switch**: Tombol instan beralih antara `FIXED LOT` (lot tetap) dan `% RISK / SL` (kalkulasi lot otomatis berdasarkan % resiko saldo terhadap jarak SL).
- **Auto Trail Toggle**: Tombol cepat untuk menyalakan/mematikan fitur Auto Trail SL & TP.
- **Master Power Button**: Saklar `ACTIVE` / `PAUSED` untuk mengontrol eksekusi auto-trading secara instan.
- **Auto Persistence**: Setiap perubahan setting di panel chart otomatis disimpan ke file lokal dan tidak akan ter-reset saat chart berganti timeframe atau terminal MT5 di-restart.

---

## Parameter Input Dasar

| Parameter | Default | Keterangan |
|---|---|---|
| `InpTradeDirection` | `Buy and Sell` | Pilihan arah order (`Buy and Sell`, `Buy Only`, `Sell Only`) |
| `InpRiskRewardRatio` | `2.0` | Target rasio Risk to Reward (1:RR) |
| `InpEnableTrail` | `true` | Mengaktifkan Auto Trail SL (BE) & Volatility Trail TP |
| `InpTrailTriggerPct` | `5.0` | Sisa jarak menuju TP untuk memicu trailing (%) |
| `InpATRMultiplier` | `2.0` | Syarat lonjakan ATR realtime untuk perpanjangan TP ($\ge$ 2.0x) |
| `InpMaxOpenTrades` | `1` | Maksimal posisi terbuka per simbol (0 = tanpa batas) |
| `InpLotMode` | `LOT_FIXED` | Mode lot: `LOT_FIXED` atau `LOT_RISK_PCT` |
| `InpFixedLot` | `0.01` | Ukuran lot jika mode Fixed Lot |
| `InpRiskPercent` | `1.0` | Risiko % saldo jika mode Risk Percentage |
| `InpTimeframe` | `PERIOD_M5` | Timeframe deteksi pola Engulfing |
| `InpATRPeriod` | `14` | Periode ATR untuk kalkulasi buffer SL |
| `InpBullishPriceMax` | `0.0` | Filter batas harga Buy `< X` (`0` / `ALL` = Bebas) |
| `InpBearishPriceMin` | `0.0` | Filter batas harga Sell `> Y` (`0` / `ALL` = Bebas) |
| `InpMagicNumber` | `882201` | ID unik transaksi EA |
| `InpSlippage` | `10` | Toleransi slippage (Points) |
