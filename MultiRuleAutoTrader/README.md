# MultiRule Auto Trader (EA 2) - Multi-Rule Realtime Tick Engine

Expert Advisor MetaTrader 5 (MQL5) untuk eksekusi otomatis pola breakout pada level tick realtime, dilengkapi **Sistem Multi-Rule Auto Trader**, manajemen resiko dinamis (Risk-to-Reward), serta mesin **Auto Trail SL (BE)** dan **Volatility Trail TP**.

---

## Fitur Utama

### 1. Multi-Rule Auto Trader List (Kombinasi Bebas Tanpa Batas)
Berbeda dengan EA konvensional yang hanya memiliki satu pasang pengaturan, MultiRule Auto Trader memungkinkan Anda menambahkan **banyak aturan (*rules*) independen** langsung di chart:
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
  - `UNL` / `0`: Tanpa batas (*unlimited*), terus aktif membuka order setiap kali pola breakout valid muncul.

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

#### 3.1 Mekanisme Trailing yang Ada

1. **Auto Trail SL ke BE (Break-Even)**:
   - Saat profit posisi telah menempuh perjalanan hingga sisa persentase menuju TP (default sisa 5% TP), Stop Loss otomatis dipindahkan ke harga `Open ± Spread`.
2. **Volatility Trail TP Extension**:
   - Jika ATR Realtime saat mendekati target mencapai $\ge 2\times$ ATR acuan saat open, TP otomatis diperpanjang sejauh $+1\times$ target awal.
3. **Penguncian Profit Bertingkat (Cycle 2+)**:
   - Saat harga mendekati target TP baru yang diperpanjang, SL otomatis dikunci di level harga TP sebelumnya.

#### 3.2 Perbaikan Mekanisme Trailing

Untuk mencegah aktivasi trail yang terlalu dini (misal: volatilitas naik tetapi masih jauh dari TP), logika pada `ProcessAutoTrailSLTP()` telah diperbaiki. Berikut adalah urutan yang benar:

1. **ATR dipantau secara realtime dan terpisah.** Nilai ATR dihitung setiap tick, dan keputusan apakah ATR "explode" (ATR sekarang $\ge$ ATR awal × multiplier) disimpan sebagai penanda. Penanda ini tidak langsung mengeksekusi apa pun.
2. **ATR explode tanpa cek jarak ke TP = tidak mengeksekusi.** Jika ATR explode terjadi tapi harga masih jauh dari TP, tidak ada TP yang diperpanjang dan tidak ada SL yang digeser. Harga harus terlebih dahulu masuk ke zona 5% dari TP.
3. **Harga $\le$ 5% dari TP = trail pertama.** Saat kondisi ini terpenuhi, SL dipindahkan ke Break-Even (`Open ± Spread`). Pada saat yang sama, jika ATR sedang explode dan memenuhi syarat jarak TP, TP juga diperpanjang sekali sebagai ekstensi awal. Trail pertama selalu menghasilkan SL di BE, tanpa memandang apakah TP ikut diperpanjang atau tidak.
4. **Trail SL kedua dan seterusnya (Cycle $\ge$ 1).** Trail kedua hanya aktif setelah TP pernah diperpanjang setidaknya satu kali. Saat harga kembali mendekati TP (masih $\le$ 5%) dan trail_cycle $\ge$ 1, SL dipindahkan ke Previous TP (level TP sebelum perpanjangan terakhir) dan TP diperpanjang lagi sebesar satu jarak TP awal. Pola ini berulang setiap kali trail_cycle naik.

Dengan perbaikan ini, EA tidak akan memperpanjang TP atau menarik SL ke BE saat masih berada di area entry. ATR explode tetap digunakan sebagai pemicu volatilitas, tapi eksekusi trail tertunda sampai harga memenuhi syarat jarak ke TP.

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

### 6. Multi Take Profit (Multi TP)

Multi TP adalah fitur yang memungkinkan satu entry dipisah menjadi beberapa bagian entri, masing-masing dengan tingkat Take Profit berbeda. Tujuannya adalah membuat profit booking bertingkat.

Aturan dasar Multi TP:

- TP pertama memakai jarak TP berdasarkan rasio Risk to Reward (RR) yang ditentukan.
- TP kedua memakai dua kali jarak TP dari RR.
- Seterusnya, tingkat ke-n memiliki jarak TP sebesar n kali jarak TP dasar dari RR.

Multi TP dipengaruhi oleh jumlah lot entri dan entry multiplier. Ini informasi penting yang perlu dimasukkan ke dalam dokumentasi: dua pengatur ini bersama-sama menentukan hasil akhir pembagian TP.

Contoh:

- RR 1:1, lot entri 0,05, entry multiplier 1, dan Multi TP diisi 2, maka lot entri dibagi menjadi dua bagian. Karena 0,05 tidak bisa dibagi rata menjadi dua lot 0,025, maka split memakai lot step dan sisanya masuk ke TP terendah. Hasil akhir: TP satu di 0,03 dan TP dua di 0,02.
- RR 1:1, lot entri 0,05, entry multiplier 3, dan Multi TP diisi 2, maka tidak perlu membagi lagi. Dua entri memakai TP dari RR 1:1 dan satu entri memakai TP dari RR 1:2.

Logika distribusi:

- Jika jumlah posisi lebih besar atau sama dengan jumlah TP, sisa order ditempatkan di TP terendah.
- Jika jumlah posisi lebih kecil, satu unit entri dibagi menjadi beberapa bagian.
- Jika permintaan TP melebihi kapasitas lot, tingkat aktif dipotong secara memadai.

Dalam implementasi `MultiRuleAutoTrader.mq5`, dua pengatur berikut bekerja bersama:

- `InpMultiTP` (default `1`): jumlah tingkat TP. Nilai `1` berarti single TP tanpa pembagian. Nilai `2` berarti TP satu dan TP dua.
- `InpEntryMultiplier` (default `1`): jumlah entri per trigger.

Alur eksekusi pada EA:

- Jika entry multiplier lebih besar atau sama dengan Multi TP, entri diberikan ke tingkat TP secara proporsional. Sisa entri ditempatkan di TP terendah.
- Jika entry multiplier lebih kecil dari Multi TP, satu pool lot entri dibagi rata ke setiap tingkat TP.
- Multi TP bernilai `1` tetap menghasilkan satu TP saja, sehingga perilaku lama tidak berubah.

### 7. Tampilan Form dan Preview

- Form disusun dengan kategori yang jelas agar lebih mudah dipahami.
- Preview dan simulasi menampilkan seluruh informasi penting, masing-masing dikelompokkan per kategori.
- Informasi yang sebelumnya tidak berguna diganti dengan tampilan bertingkat yang mudah dipahami.
- Form sekarang menampilkan field utama dengan label lengkap, tidak ambigu. Field Entri Multiplier ditulis lengkap sebagai `ENTRI MULTIPLIER` dan field Multi TP ditulis `MULTI TP`.
- Preview menampilkan baris info utama, lalu blok trailing, lengkap dengan nilai Entri Multiplier dan jumlah tingkat Multi TP yang dipakai.

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
| `InpMultiTP` | `1` | Default jumlah tingkat TP (Multi TP; `1` = single TP) |
| `InpLotMode` | `LOT_FIXED` | Mode lot: `LOT_FIXED` atau `LOT_RISK_PCT` |
| `InpFixedLot` | `0.01` | Ukuran lot jika mode Fixed Lot |
| `InpRiskPercent` | `1.0` | Risiko % saldo jika mode Risk Percentage |
| `InpTimeframe` | `PERIOD_M5` | Default timeframe deteksi pola breakout |
| `InpATRPeriod` | `14` | Periode ATR untuk kalkulasi buffer SL |
| `InpEnablePushAlerts` | `true` | Kirim notifikasi push ke aplikasi MT5 mobile di HP |
| `InpEnableSoundAlerts` | `true` | Bunyikan suara / pop-up alert di terminal MT5 |
| `InpMagicNumber` | `882201` | ID unik transaksi EA |
| `InpSlippage` | `10` | Toleransi slippage (Points) |

---

## Preview Visual Dashboard
Buka file `MultiRuleAutoTrader_preview.html` di browser Anda untuk melihat simulasi visual cyberpunk neon pitch-black dan interaksi penambahan/pengeditan rule.
