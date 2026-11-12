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
- **Tabel Daftar Aturan**: Menampilkan simbol, arah, lot/risk %, rasio RR, timeframe, Max Orders, filter harga, status trailing, status aktif (`ACTIVE` / `PAUSED`), serta tombol **`EDIT`** dan **`DEL`**.
- **Mode Edit Cepat & Persistent Form**: Mengklik `EDIT` memuat nilai rule ke form atas. Setelah menekan Add/Update, form **tidak ter-reset** sehingga memudahkan input beruntun. Tombol **`DEFAULT`** disediakan untuk mengembalikan form ke setelan awal.

---

### 2. Flexible Price Bounds & Max Orders Control
- **Filter Harga Fleksibel (`<`, `>`, `<=`, `>=`, Rentang `Min-Max`)**:
  - Mendukung operator pembanding secara langsung (cth: `< 1.0850`, `<= 1.0820`, `>= 1.0910`, `> 1.0900`).
  - Mendukung format rentang harga (cth: `4040-4078`). Urutan **bebas dibolak-balik** — `4078-4040` sama dengan `4040-4078`. Batas inklusif: `4040` dan `4078` keduanya lolos.
  - **Strict Validation**: Angka mentah tanpa operator atau tanpa rentang akan ditolak dengan *Alert* peringatan.
  - **Dynamic Form**: Kolom Price Bounds menyesuaikan otomatis (jika `BUY ONLY` hanya tampil Buy Bound, jika `SELL ONLY` hanya tampil Sell Bound).
- **Max Orders / Batas Open Order**:
  - `1` (Default): Rule membuka 1x order, lalu otomatis berstatus **`PAUSED`** setelah tereksekusi.
  - `UNL` / `0`: Tanpa batas (*unlimited*), terus aktif membuka order setiap kali pola Engulfing valid muncul.

#### MAX ORDER vs ENTRY MULTIPLIER (Sering Tertukar)

Kedua angka ini berbeda peran dan sering salah dipahami:

| Parameter | Arti | Contoh |
|---|---|---|
| **MAX ORDER** | Jumlah **siklus entry** sebelum rule auto-pause | `2` = boleh entry 2 kali, lalu `PAUSED` |
| **ENTRY MULTIPLIER** | Jumlah **posisi per siklus entry** | `3` = sekali sinyal buka 3 posisi |

| MAX | MULT | Hasil |
|---|---|---|
| `1` | `3` | 3 posisi dalam 1 siklus, lalu pause |
| `2` | `1` | 2 posisi dalam 2 siklus, lalu pause |
| `2` | `3` | 6 posisi (3 per siklus), lalu pause |
| `UNL` | berapa pun | Tanpa batas siklus |

**Siklus berjalan berurutan (sequential)**: siklus berikutnya **tidak** akan dibuka selama masih ada posisi terbuka dari siklus sebelumnya. Baru setelah semua posisi siklus itu tertutup, siklus berikutnya boleh jalan — sampai kuota MAX ORDER habis lalu rule `PAUSED`. Jadi dengan MAX `3` dan MULT `2`, urutannya: buka 2 → tunggu keduanya tutup → buka 2 → tunggu → buka 2 → pause.

> Catatan: posisi dihitung berdasarkan **simbol**, karena Magic Number dipakai bersama oleh semua rule. Bila Anda membuat dua rule pada simbol yang sama, keduanya akan saling menunggu. Trade manual tidak terpengaruh — posisinya bermagic `0`, sedangkan penghitungan hanya mencakup magic EA ini.

**Aturan penting saat kuota terbatas**: bila MAX ORDER tersisa lebih sedikit daripada jumlah candidate timeframe yang valid, **M5 selalu diambil lebih dulu** daripada M1. Rule tidak akan "memakai" kuotanya untuk sinyal M1 lalu melewatkan sinyal M5 pada tick yang sama.

---

#### Logika Dual-Timeframe (M5 + M1)

Rule **M5** menerima sinyal dari **M5** dan **M1**, dengan **M5 diprioritaskan**. Rule **M1 tetap eksklusif M1**, dan TF lain sepenuhnya eksklusif. Selain itu, ATR untuk rule **M1 dipinjam dari M5 lalu dikali 0.5** agar buffer SL tidak terlalu rapat.

Detail lengkap (termasuk alasan, slot state per-TF, dan versioning file state) ada di [`DUAL_TIMEFRAME.md`](../DUAL_TIMEFRAME.md).

---

### 3. Auto Trail SL (BE) & Volatility Trail TP Engine
1. **Auto Trail SL ke BE (Break-Even)**:
   - Saat profit posisi telah menempuh perjalanan hingga sisa persentase menuju TP (default sisa 5% TP), Stop Loss otomatis dipindahkan ke harga `Open ± Spread`.
2. **Volatility Trail TP Extension**:
   - Jika ATR Realtime saat mendekati target mencapai $\ge 2\times$ ATR acuan saat open, TP otomatis diperpanjang sejauh $+1\times$ target awal.
3. **Penguncian Profit Bertingkat (Cycle 2+)**:
   - Saat harga mendekati target TP baru yang diperpanjang, SL otomatis dikunci di level harga TP sebelumnya.

#### Prilaku Saat Rule Auto-Pause (MAX ORDER Tercapai)

Auto-pause **hanya menghentikan pembukaan order baru**. Semua mekanisme lain tetap berjalan:

| Mekanisme | Saat rule `PAUSED` |
|---|---|
| Auto Trail SL & TP Extension | **Tetap jalan** setiap tick |
| Penguncian profit bertingkat | **Tetap jalan** |
| Radar alert (EA terpisah) | **Tetap jalan** |
| BE engine (Trade Manager) | **Tetap jalan** |
| Pembukaan order baru | **Berhenti** |

Hal ini karena `ProcessAutoTrailSLTP()` dipanggil di `OnTick()` **sebelum** loop rules, dan tidak pernah membaca `max_orders` maupun `orders_opened_count`. Ini disengaja: posisi yang baru dibuka justru paling butuh proteksi BE setelah rule berhenti membuka posisi.

**Saat Anda me-reaktivasi rule** (`ACTIVE` kembali):

- Counter `orders_opened_count` **di-reset ke 0** → rule boleh memulai siklus entry baru.
- Posisi **lama** tetap terlacak di `g_tracking_list[]`, dan tetap memakai parameter trail **saat posisi itu dibuka** (trigger %, multiplier ATR, ATR acuan).
- Posisi **baru** otomatis ikut terlacak dan memakai setting trail terbaru.

> Konsekuensi: mengubah setting Auto Trail lalu me-reaktivasi rule **tidak** mengubah perilaku trail pada posisi yang sudah terbuka — hanya posisi baru yang memakai setting baru.

**Dua batasan yang perlu diketahui:**

- **Master Power OFF ≠ auto-pause.** Master power OFF menghentikan trail juga, karena `if(!g_master_power_enabled) return;` berada sebelum pemanggilan trail engine.
- **Posisi tanpa TP tidak di-trail.** Trail dilewati bila `TakeProfit <= 0`, karena perhitungan jarak trailing berbasis sisa jarak menuju TP.

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
