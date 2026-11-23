# MultiRule Auto Trader (EA 2) - Multi-Rule Realtime Reversal Engine

Expert Advisor MetaTrader 5 (MQL5) untuk eksekusi otomatis pola pembalikan arah (*reversal*) pada level tick realtime, dilengkapi **Sistem Multi-Rule Auto Trader**, multi-sinyal (*Engulfing, Hammer, Shooting Star, Stoch+HA*), **Combo Mode (OR/AND)**, toleransi *Price Bound Grace Period* (1.5x TF), persentase umur lilin (*% TF Delay*), manajemen resiko dinamis, Multi Take Profit (Multi TP), serta mesin **EWMA True Range Auto Trail BE & Volatility TP Extend**.

---

## Fitur Utama

### 1. Multi-Rule Auto Trader List (Kombinasi Bebas Tanpa Batas)
Berbeda dengan EA konvensional yang hanya memiliki satu pasang pengaturan, MultiRule Auto Trader memungkinkan Anda menambahkan **banyak aturan (*rules*) independen** langsung di chart:
- **Aturan Berbeda per Simbol**: Pasang strategi di EURUSD, GBPUSD, XAUUSD, dsb. dalam satu EA.
- **Kombinasi Skenario pada Simbol yang Sama**:
  - *Skenario A*: Buy EURUSD dengan lot kecil (0.01) saat harga murah `< 1.0820` (RR 1:2.0).
  - *Skenario B*: Sell EURUSD dengan lot besar (0.05) saat harga jenuh `> 1.0950` (RR 1:3.0).
- **Tabel Daftar Aturan**: Menampilkan simbol, arah, kombinasi sinyal `[ENG] [HMR/SS] [ST+HA] [OR/AND]`, lot/risk %, rasio RR, timeframe, Max Orders, filter harga, status trailing EWMA, status aktif (`ACTIVE` / `PAUSED`), serta tombol **`EDIT`** dan **`DEL`**.
- **Mode Edit Cepat & Persistent Form**: Mengklik `EDIT` memuat nilai rule ke form atas. Setelah menekan Add/Update, form **tidak ter-reset** sehingga memudahkan input beruntun. Tombol **`DEFAULT`** disediakan untuk mengembalikan form ke setelan awal.

---

### 2. Multi-Sinyal Reversal & Combo Mode (OR vs AND)

Tersedia 3 kelompok sinyal pembalikan arah yang dapat dipilih secara fleksibel:
1. **`[ENG]` Strong Engulfing Reversal**: Lilin pembalik menembus dan menutupi lilin sebelumnya dengan body yang lebih dominan.
2. **`[HMR/SS]` Strong Hammer & Shooting Star Reversal**:
   - **Strong Hammer (BUY):** Ekor bawah $\ge 3\times$ body, ekor atas $\le 0.8\times$ body, total rentang lilin lebih panjang dari lilin sebelumnya. SL dipasang di Low $- (50\% \text{ ATR})$.
   - **Strong Shooting Star (SELL):** Ekor atas $\ge 3\times$ body, ekor bawah $\le 0.8\times$ body, total rentang lilin lebih panjang dari lilin sebelumnya. SL dipasang di High $+ (50\% \text{ ATR}) + \text{Spread}$.
3. **`[ST+HA]` Stochastic + Heikin Ashi Momentum Reversal**:
   - BUY: $\%K < 20$ (oversold) dan memantul naik ($\%K > \%K[1]$) didukung Heikin Ashi mengecil atau berubah warna hijau.
   - SELL: $\%K > 80$ (overbought) dan memantul turun ($\%K < \%K[1]$) didukung Heikin Ashi mengecil atau berubah warna merah.

**Mode Sinyal:**
- **ANY (OR) - Default:** Cukup salah satu dari sinyal yang dicentang valid untuk memicu eksekusi order.
- **COMBO (Konfirmasi Ganda Wajib & STOCH+HA):** Sinyal candlestick wajib terverifikasi ganda oleh momentum jenuh Stochastic + Heikin Ashi. Pilihan otomatis disederhanakan menjadi 2 paket:
  1. `[x] ENG & STOCH+HA`
  2. `[x] HAMMER & STOCH+HA` (Buy) / `[x] SHOOTING & STOCH+HA` (Sell) / `[x] HMR/SS & STOCH+HA` (Both)
  - **Mendukung Keduanya Aktif:** Jika kedua paket dicentang, EA siap menerima paket mana saja yang lebih dulu terpicu valid (mirip fleksibilitas mode ANY, namun dengan proteksi ketat konfirmasi ganda STOCH+HA pada setiap sinyal). Pada arah `BOTH`, paket kedua otomatis mengecek `HAMMER` saat mengevaluasi Buy dan `SHOOTING` saat mengevaluasi Sell.

---

### 3. Flexible Price Bounds & Grace Period (Toleransi 1.5x TF)

- **Filter Harga Fleksibel (`<`, `>`, `<=`, `>=`, Rentang `Min-Max`)**:
  - Mendukung operator pembanding langsung (cth: `< 1.0850`, `<= 1.0820`, `>= 1.0910`, `> 1.0900`).
  - Mendukung format rentang harga bolak-balik (cth: `4040-4078` sama dengan `4078-4040`).
- **Grace Period (1.5x Timeframe):**
  - Jika harga sempat keluar dari area bound, order **masih diperbolehkan** selama durasi $1.5\times$ TF belum habis.
  - Syarat mutlak: Harga **harus sudah pernah masuk** ke dalam area bound terlebih dahulu agar timer toleransi ini aktif.
  - Jika harga kembali masuk ke dalam area, timer toleransi di-reset ke awal.

---

### 4. Entry Delay: Persentase Umur Lilin (`% TF Progress`) vs `TF Close`

- **Mode `% TF Progress` (Default 30%):** Lilin harus sudah berjalan minimal $N\%$ dari total durasinya untuk memfilter noise di awal candle baru. Jika sinyal terdeteksi saat umur lilin sudah melewati batas ini, sinyal langsung dieksekusi seketika.
- **Mode `TF Close`:** Sinyal divalidasi pada lilin yang baru saja tertutup (bar index 1).

---

### 5. Arsitektur Trailing EWMA True Range (BE, TP Extend, SL Lock)

Menggantikan ATR lambat dengan rasio volatilitas *Relative Volatility* ($\text{RelVol} = \text{CurrTR} / \text{EWMA\_TR}$):
1. **Trail BE (Pengamanan Modal Mandiri):** Murni berbasis jarak tanpa memerlukan lonjakan volatilitas. Begitu harga mendekati TP ($\le 1.1\times$ EWMA TR) atau mencapai target running profit, SL dikunci ke Break-Even (`Open ± Spread`).
2. **Trail TP Extension (Perpanjangan Target Selektif):** Wajib memenuhi **dua syarat sekaligus**: sisa jarak menuju TP $\le 1.1\times$ EWMA TR **DAN** terjadi lonjakan volatilitas pasar nyata ($\text{RelVol} \ge 1.60\times$).
3. **Trail SL Lock (Penguncian Bertingkat):** Hanya aktif pada siklus berikutnya setelah TP berhasil di-extend, mengunci SL ke level TP sebelumnya.
4. **Multi TP Independen:** Setiap tiket posisi hasil pembagian Multi TP dipantau trailing-nya secara independen, difokuskan dari tingkat TP terdekat.
5. **Toleransi Modifikasi Manual:** Jika SL atau TP digeser manual di chart:
   - *SL Manual:* EA menerapkan proteksi satu arah (tidak akan memundurkan SL jika posisi SL manual sudah lebih baik/profit dari titik BE).
   - *TP Manual:* Jarak proximity dan pemicu extend otomatis mengikuti level TP baru hasil modifikasi pengguna secara live.
6. **Resolusi Tiket Posisi & Auto-Adopt Posisi EA:**
   - *Resolusi Tiket MT5:* Mengatasi perbedaan nomor Order Ticket vs Position Ticket di MT5 (Hedging/Market Execution) menggunakan resolver bertingkat (`order_ticket` -> `DEAL_POSITION_ID` -> active position scan) agar tiket posisi selalu valid dikawal.
   - *Auto-Adopt Posisi Berjalan:* Jika EA ter-reload atau MT5 restart, sistem secara otomatis mengadopsi kembali posisi aktif yang ber-Magic Number EA (`InpMagicNumber`) agar pengawalan Trail BE dan TP Extend tidak terputus. Order manual (`Magic == 0`) maupun order dari EA lain 100% diabaikan dan tidak disentuh.

---

### 6. Mode Continuation vs Sequential Entry (Independensi Simbol)

- **Mode Sequential (`CONT: OFF` - Default):** Rule tidak akan membuka posisi baru jika masih ada posisi aktif pada simbol tersebut.
- **Mode Continuation (`CONT: ON`):** Memperbolehkan penambahan posisi baru searah (*scaling-in*) meskipun ada posisi terbuka yang sedang berjalan.
  - **Interaksi Antar-Rule pada Simbol Sama:** Jika Rule A telah membuka posisi BUY, Rule B pada simbol yang sama **bisa membuka order** selama sinyalnya juga BUY dan `continuation_mode` Rule B bernilai `ON`. Namun jika Rule B mendeteksi SELL, order diblokir otomatis untuk mencegah hedging berlawanan arah.
  - **Independensi Mutlak Lintas Simbol:** Pengecekan posisi aktif dihitung strictly **per-simbol**. Posisi terbuka di `BTCUSD` tidak pernah memblokir rule di `ETHUSD` atau pasangan simbol lainnya, baik mode continuation di rule tersebut bernilai ON maupun OFF.

---

## Parameter Input Dasar

| Parameter | Default | Keterangan |
|---|---|---|
| `InpTradeDirection` | `Buy and Sell` | Default arah order saat menambah rule baru |
| `InpRiskRewardRatio` | `2.0` | Default rasio Risk to Reward (1:RR) |
| `InpMaxOrders` | `1` | Maksimal siklus entri (1 = 1x open lalu paused, 0 = Unlimited) |
| `InpEntryMultiplier` | `1` | Jumlah posisi yang dibuka serentak per sinyal |
| `InpMultiTP` | `1` | Jumlah tingkat Take Profit bertingkat (1 = single TP) |
| `InpDelayTFPct` | `30` | Delay progres umur lilin (% TF Progress, 0..99) |
| `InpDelayIsTfClose` | `false` | Mode delay: `false` = % TF Progress, `true` = TF Close |
| `InpDefaultSigEng` | `true` | Default aktifkan Strong Engulfing Reversal |
| `InpDefaultSigHmrSS` | `true` | Default aktifkan Strong Hammer / Shooting Star |
| `InpDefaultSigStochHA` | `true` | Default aktifkan Stochastic + Heikin Ashi |
| `InpDefaultSigMode` | `SIGNAL_MODE_ANY` | Default mode sinyal: `ANY (OR)` atau `COMBO (AND)` |
| `InpEnableTrail` | `true` | Default aktifkan Trailing Engine EWMA TR |
| `InpTrailBEMode` | `TRAIL_BE_PROXIMITY` | Mode Trail BE: Proximity TP atau Running Profit |
| `InpTrailBERemDistPct` | `0.20` | Ambang sisa jarak TP untuk memicu BE (0.20 = 20%) |
| `InpTrailExtRemDistPct` | `0.20` | Ambang sisa jarak TP untuk memicu TP Extension (0.20 = 20%) |
| `InpRelVolThreshold` | `1.60` | Ambang batas lonjakan volatilitas untuk TP Extend ($\ge 1.60\times$) |
| `InpMaxDistATR` | `1.10` | Jarak kedekatan ke TP untuk pemicu trailing (satuan EWMA TR) |
| `InpExtendFactor` | `0.70` | Faktor pengali perpanjangan TP |
| `InpMaxExtendATR` | `1.80` | Batas maksimal ekstensi TP (satuan ATR) |
| `InpLotMode` | `LOT_RISK_PCT` | Mode lot: `LOT_FIXED` atau `LOT_RISK_PCT` |
| `InpFixedLot` | `0.01` | Ukuran lot jika mode Fixed Lot |
| `InpRiskPercent` | `1.0` | Risiko % saldo jika mode Risk Percentage |
| `InpTimeframe` | `PERIOD_M5` | Default timeframe deteksi sinyal pembalikan |
| `InpATRPeriod` | `14` | Periode ATR untuk kalkulasi buffer SL |
| `InpEnablePushAlerts` | `true` | Kirim notifikasi push ke aplikasi MT5 mobile di HP |
| `InpEnableSoundAlerts` | `true` | Bunyikan suara / pop-up alert di terminal MT5 |
| `InpMagicNumber` | `882201` | ID unik transaksi EA |
| `InpSlippage` | `10` | Toleransi slippage (Points) |

---

## Preview Visual Dashboard
Buka file `MultiRuleAutoTrader_preview.html` di browser Anda untuk melihat simulasi visual cyberpunk neon hitam pekat dengan form berukuran longgar (540px), pemilih sinyal dinamis, dan pemantauan trailing EWMA TR.
