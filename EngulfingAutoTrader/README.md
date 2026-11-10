# Engulfing Auto Trader (EA 2) - Multi-Rule Realtime Tick Engine

Expert Advisor MetaTrader 5 (MQL5) untuk eksekusi otomatis pola **Strong Engulfing Breakout** pada level tick realtime, dilengkapi **Sistem Multi-Rule Auto Trader**, manajemen resiko dinamis (Risk-to-Reward), serta mesin **Auto Trail SL (BE)** dan **Volatility Trail TP**.

---

## Fitur Utama

### 1. Multi-Rule Auto Trader List (Kombinasi Bebas Tanpa Batas)
Berbeda dengan EA konvensional yang hanya memiliki satu pasang pengaturan, Engulfing Auto Trader memungkinkan Anda menambahkan **banyak aturan (*rules*) independen** langsung di chart:
- **Aturan Berbeda per Simbol**: Pasang strategi di EURUSD, GBPUSD, XAUUSD, dsb. dalam satu EA.
- **Kombinasi Skenario pada Simbol yang Sama**:
  - *Skenario A*: Buy EURUSD dengan lot kecil (0.01) saat harga murah `< 1.0820` (RR 1:2.0).
  - *Skenario B*: Sell EURUSD dengan lot besar (0.05) saat harga jenuh `> 1.0950` (RR 1:3.0).
- **Tabel Daftar Aturan**: Menampilkan simbol, arah, lot/risk %, rasio RR, timeframe, filter harga, status trailing, status aktif (`ACTIVE` / `PAUSED`), serta tombol **`EDIT`** dan **`DEL`**.
- **Mode Edit Cepat**: Mengklik `EDIT` pada baris tertentu akan memuat nilai rule ke form atas, mengubah tombol menjadi `UPDATE RULE #N` dan menyediakan tombol `CANCEL EDIT`.

---

### 2. Deteksi Strong Engulfing Realtime Tick
- **Tanpa Menunggu Bar Close**: Eksekusi instan seketika candle live menembus High candle sebelumnya (Bullish Break) atau menembus Low candle sebelumnya (Bearish Break).
- **Syarat Validitas Pola**:
  - *Bullish Break*: Candle sebelumnya Bearish, candle saat ini Bullish & menembus High candle lalu, Low candle saat ini $\le$ Low candle lalu, dan rasio body candle saat ini lebih dominan.
  - *Bearish Break*: Candle sebelumnya Bullish, candle saat ini Bearish & menembus Low candle lalu, High candle saat ini $\ge$ High candle lalu, dan rasio body candle saat ini lebih dominan.
- **Buffer Stop Loss Otomatis**:
  - Buy SL = `Low Candle Sebelumnya - 50% ATR(14)`
  - Sell SL = `High Candle Sebelumnya + 50% ATR(14) + Spread Realtime`
- **Target Take Profit**:
  - $\text{TP} = \text{Entry Price} \pm (\text{Jarak SL} \times \text{Risk Reward Ratio})$

---

### 3. Auto Trail SL (BE) & Volatility Trail TP Engine
1. **Auto Trail SL ke BE (Break-Even)**:
   - Saat profit posisi telah menempuh perjalanan hingga sisa persentase menuju TP (default sisa 5% TP), Stop Loss otomatis dipindahkan ke harga `Open ± Spread`.
2. **Volatility Trail TP Extension**:
   - Jika ATR Realtime saat mendekati target mencapai $\ge 2\times$ ATR acuan saat open, TP otomatis diperpanjang sejauh $+1\times$ target awal.
3. **Penguncian Profit Bertingkat (Cycle 2+)**:
   - Saat harga mendekati target TP baru yang diperpanjang, SL otomatis dikunci di level harga TP sebelumnya.

---

### 4. Notifikasi Realtime Spesifik Auto Trader
EA mengirimkan alert pop-up dan push notifikasi ke HP Anda pada momen penting eksekusi:
- **`[AUTO TRADER - ORDER OPENED]`**: Muncul saat posisi Buy/Sell berhasil dieksekusi dengan info lot, harga ask/bid, SL awal, TP awal, rasio RR, dan nilai 100% ATR acuan.
- **`[AUTO TRADER - TRAIL SL BE]`**: Muncul saat harga mencapai sisa persentase target dan Stop Loss berhasil dipindahkan ke Break-Even (bebas risiko).
- **`[AUTO TRADER - TRAIL TP EXTENDED]`**: Muncul saat volatilitas pasar meledak ($\ge$ Multiplier ATR) dan target Take Profit berhasil diperpanjang +1x target.
- **`[AUTO TRADER - TRAIL SL LOCKED]`**: Muncul saat harga mendekati target baru dan Stop Loss berhasil dikunci di harga Take Profit sebelumnya.

---

### 5. State Persistence (Pengaturan & List Rule Tidak Hilang)
Sistem penyimpanan persisten otomatis (`.bin`) menjaga data Multi-Rule Auto Trader Anda tetap utuh:
- **Tahan Ganti Timeframe & Restart MT5**: Seluruh aturan Multi-Rule di tabel, status aktif/paused tiap rule, saklar master power, dan posisi trailing otomatis tersimpan.
- **Auto-Restore saat Re-Attach**: Saat EA ditutup atau dipasang ulang (*re-attach*), EA otomatis membaca data penyimpanan dan mengembalikan seluruh daftar aturan persis seperti sebelum ditutup.

---

## Parameter Input Dasar

| Parameter | Default | Keterangan |
|---|---|---|
| `InpTradeDirection` | `Buy and Sell` | Default arah order saat menambah rule baru |
| `InpRiskRewardRatio` | `2.0` | Default rasio Risk to Reward (1:RR) |
| `InpEnableTrail` | `true` | Default aktifkan Auto Trail SL & TP |
| `InpTrailTriggerPct` | `5.0` | Sisa jarak menuju TP untuk memicu trailing (%) |
| `InpATRMultiplier` | `2.0` | Syarat lonjakan ATR realtime untuk perpanjangan TP ($\ge$ 2.0x) |
| `InpMaxOpenTrades` | `1` | Maksimal posisi terbuka per simbol (0 = tanpa batas) |
| `InpLotMode` | `LOT_FIXED` | Mode lot: `LOT_FIXED` atau `LOT_RISK_PCT` |
| `InpFixedLot` | `0.01` | Ukuran lot jika mode Fixed Lot |
| `InpRiskPercent` | `1.0` | Risiko % saldo jika mode Risk Percentage |
| `InpTimeframe` | `PERIOD_M5` | Default timeframe deteksi pola Engulfing |
| `InpATRPeriod` | `14` | Periode ATR untuk kalkulasi buffer SL |
| `InpEnablePushAlerts` | `true` | Kirim notifikasi push ke aplikasi MT5 mobile di HP |
| `InpEnableSoundAlerts` | `true` | Bunyikan suara / pop-up alert di terminal MT5 |
| `InpMagicNumber` | `882201` | ID unik transaksi EA |
| `InpSlippage` | `10` | Toleransi slippage (Points) |

---

## Preview Visual Dashboard
Buka file `EngulfingAutoTrader_preview.html` di browser Anda untuk melihat simulasi visual cyberpunk neon pitch-black dan interaksi penambahan/pengeditan rule.
