# Rancang Bangun & Spesifikasi Arsitektur MultiRuleAutoTrader (Versi 3)

Dokumen ini merekam seluruh diskusi, penjelasan kebutuhan pengguna, analisis teknis, serta kesepakatan final mengenai pengembangan fitur dan perbaikan antarmuka Expert Advisor `MultiRuleAutoTrader.mq5`.

---

## 1. Perbaikan Tata Letak Visual UI & Form Dashboard MQL5

### Masalah pada Desain Lama
- Kolom dan area input terlalu sempit, menyebabkan pemotongan teks secara ekstrem (contoh: `Inst`, `Entri M`, `Er Multi`).
- Singkatan yang terlalu pendek membingungkan pengguna dan menyebabkan tumpang tindih (*overlap*) antarkomponen di chart MT5.
- Kotak preview/simulasi terlalu padat dengan informasi yang kurang relevan untuk eksekusi cepat.

### Solusi Desain Baru
- **Pelebaran Form Kiri:** Lebar kolom dan koordinat piksel objek input diperlebar secara signifikan agar label tertulis lengkap tanpa singkatan (seperti `ENTRY MULTIPLIER`, `MULTI TP`, `% TF DELAY`).
- **Pembersihan Tabel Bawah:** Kolom `SIGNALS` yang panjang dan berpotensi memicu teks berdempetan atau tumpang tindih dihapus dari tabel list rules bawah, dan dipusatkan ke **Preview Terminal Box** kanan atas (menampilkan status sinyal aktif serta mode `ANY (OR)` vs `COMBO (AND)`). Ruang tabel bawah menjadi jauh lebih lapang untuk kolom `SYMBOL`, `DIRECTION`, `LOT/RISK`, `RR`, `TF`, `MAX`, `MULT`, `DELAY`, `PRICE BOUNDS`, `AUTO TRAIL`, `STATUS`, dan `ACTIONS`.
- **Perampingan & Penyelarasan Form Trailing:** Istilah usang `BE TP%` dihapus sepenuhnya. Digantikan dengan parameter aktif **`MAX DIST TR`** (jarak kedekatan ke TP dalam satuan EWMA TR, default `1.10`) dan **`RELVOL THR`** (ambang lonjakan volatilitas, default `1.60`). Parameter ini dapat diatur langsung secara mandiri untuk setiap rule di form dashboard tanpa hardcode.
- **Perampingan Preview Kanan:** Area preview/simulasi diperkecil dan difokuskan pada ringkasan esensial:
  - Identitas simbol, timeframe, arah trading, dan ringkasan sinyal aktif.
  - Distribusi lot pada tiap tingkatan Multi TP aktif.
  - Status saklar Trailing serta simulasi matematis dinamis berbasis setting rule aktif.

---

## 2. Mekanisme Grace Period Price Bound (Toleransi 1.5x Timeframe)

### Konsep Dasar
Memberikan toleransi waktu (*grace period*) bagi harga yang sempat keluar dari area Price Bound yang ditentukan (bukan `ALL`), agar tidak kehilangan momentum pembalikan arah di sekitar batas area.

### Aturan & Logika Kerja
1. **Syarat Masuk Terlebih Dahulu:**
   - Mekanisme ini **hanya aktif jika harga sudah pernah masuk** ke dalam zona Price Bound secara sah.
   - Jika harga sejak awal berada di luar area bound dan belum pernah menyentuh rentang harga, toleransi tidak aktif dan order tidak boleh dibuka.
2. **Durasi Toleransi (1.5x TF):**
   - Begitu harga keluar dari zona bound, timer toleransi mulai berjalan dengan durasi $1.5 \times \text{Durasi Timeframe Rule}$.
   - *Contoh:* Pada Rule M5, durasi toleransi adalah $1.5 \times 300\text{ detik} = 450\text{ detik}$ (7,5 menit).
   - Mengikuti basis TF rule yang ditentukan: meskipun sinyal M1 aktif pada rule M5, basis perhitungan durasi toleransi tetap menggunakan M5.
3. **Izin Entri Selama Toleransi:**
   - Selama durasi $1.5\times$ TF ini belum habis, pembukaan posisi **tetap diperbolehkan** meskipun harga secara realtime berada di luar rentang bound.
4. **Reset Timer:**
   - Jika harga sempat masuk kembali ke dalam area bound sebelum durasi habis, timer toleransi di-reset ke nol. Ketika harga keluar lagi di waktu berikutnya, timer $1.5\times$ TF dihitung ulang dari awal.
   - Jika durasi habis dan harga belum kembali masuk, hak entri dicabut sampai harga benar-benar masuk kembali ke dalam bound.
5. **Perilaku Saat Terminal Dimuat Ulang (Restart / Ganti TF):**
   - Timer grace period **tidak disimpan** ke file state biner (`.bin`) untuk menghindari eksekusi order basi/rusak jika terminal ditutup lama.
   - Saat re-attach, jika harga berada di luar bound, statusnya langsung dianggap di luar (tidak berhak entri). Harga wajib masuk kembali ke dalam area secara realtime untuk memulai siklus baru.

---

## 3. Penambahan Sinyal Candlestick: Strong Hammer & Strong Shooting Star

### Logika Deteksi
Kedua pola ini mengidentifikasi penolakan harga ekstrem (*price rejection*) dengan ketentuan proporsi ekor terhadap body.

1. **Strong Hammer (Eksklusif Sinyal BUY):**
   - Ekor/Shadow bawah panjang: $\text{Lower Shadow} \ge 3 \times \text{Body}$.
   - Ekor sebaliknya (atas) kecil: $\text{Upper Shadow} \le 0.8 \times \text{Body}$ (maksimal 80% dari ukuran body lilin).
   - Sapu likuiditas (*liquidity sweep*): Low candle berjalan wajib lebih rendah daripada low candle sebelumnya (`cur_low < prev_low`). Bebas warna body (bisa candle bullish maupun bearish).
2. **Strong Shooting Star (Eksklusif Sinyal SELL):**
   - Ekor/Shadow atas panjang: $\text{Upper Shadow} \ge 3 \times \text{Body}$.
   - Ekor sebaliknya (bawah) kecil: $\text{Lower Shadow} \le 0.8 \times \text{Body}$.
   - Sapu likuiditas (*liquidity sweep*): High candle berjalan wajib lebih tinggi daripada high candle sebelumnya (`cur_high > prev_high`). Bebas warna body.

### Penempatan Stop Loss & Kompensasi Spread
- **Sinyal BUY (Hammer):**
  $$\text{SL} = \text{Low Candle} - (50\% \text{ ATR})$$
  *(Ditutup di harga Bid secara natural, tidak memerlukan tambahan spread).*
- **Sinyal SELL (Shooting Star):**
  $$\text{SL} = \text{High Candle} + (50\% \text{ ATR}) + \text{Spread}$$
  *(Ditutup di harga Ask. Penambahan spread wajib dilakukan agar posisi Sell tidak terpicu stopout prematur oleh selisih spread broker saat harga Bid baru menyentuh High).*

---

## 4. Penambahan Sinyal Indikator: Stochastic + Heikin Ashi Momentum Reversal

Diadaptasi dari logika indikator pembalikan tren dengan penyempurnaan pembacaan serial data MQL5:

### Parameter Baku
- Stochastic: $\%K = 14$, Smoothing $K = 1$, Smoothing $D = 3$.
- Level Ekstrem: Overbought = 80, Oversold = 20.

### Syarat Pembalikan
- **Kondisi BUY:**
  1. Nilai $\%K < 20$ (zona oversold).
  2. $\%K > \%K[1]$ (momentum Stochastic mulai memantul ke atas).
  3. Konfirmasi lilin Heikin Ashi: Ukuran lilin mengecil ($\text{haSize} < \text{haSize}[1]$) **ATAU** warna Heikin Ashi berubah menjadi hijau ($\text{haClose} > \text{haOpen}$).
  4. **Syarat Tambahan Multi-Timeframe (Khusus Sinyal TF M5 ke Atas):** Nilai Stochastic pada TF M1 **juga wajib berada di zona oversold** ($\%K_{\text{M1}} < 20$). Pada M1 tidak perlu syarat perubahan arah $\%K$ atau ukuran lilin Heikin Ashi; cukup konfirmasi level ekstrem oversold. Jika sinyal datang dari M1 itu sendiri, maka berlaku seluruh syarat 1-3 lengkap.
- **Kondisi SELL:**
  1. Nilai $\%K > 80$ (zona overbought).
  2. $\%K < \%K[1]$ (momentum Stochastic mulai memantul ke bawah).
  3. Konfirmasi lilin Heikin Ashi: Ukuran lilin mengecil ($\text{haSize} < \text{haSize}[1]$) **ATAU** warna Heikin Ashi berubah menjadi merah ($\text{haClose} < \text{haOpen}$).
  4. **Syarat Tambahan Multi-Timeframe (Khusus Sinyal TF M5 ke Atas):** Nilai Stochastic pada TF M1 **juga wajib berada di zona overbought** ($\%K_{\text{M1}} > 80$). Pada M1 tidak perlu syarat perubahan arah $\%K$ atau ukuran lilin Heikin Ashi; cukup konfirmasi level ekstrem overbought. Jika sinyal datang dari M1 itu sendiri, maka berlaku seluruh syarat 1-3 lengkap.

---

## 5. Mode Sinyal: ANY (OR) vs COMBO (AND) & UI Adaptif

### Pilihan Sinyal pada Form
Tersedia 3 kelompok sinyal:
1. `[ENG]` : *Strong Engulfing Reversal*
2. `[HMR/SS]` : *Strong Hammer* (Buy) / *Strong Shooting Star* (Sell)
3. `[ST+HA]` : *Stochastic + Heikin Ashi Reversal*

### Saklar Signal Mode
- **Mode ANY (OR) - Default:**
  - Default: Semua opsi sinyal tercentang aktif.
  - Eksekusi terjadi jika **salah satu** dari sinyal yang dicentang valid.
- **Mode COMBO (AND):**
  - Default: Checkbox tidak tercentang semua (pengguna menentukan kombinasi).
  - Eksekusi hanya terjadi jika seluruh sinyal yang dipilih valid secara simultan.
  - **Proteksi Logika (Mutual Exclusion):** Karena sebuah candle fisik tidak dapat berbentuk *Engulfing* dan *Hammer/Shooting Star* sekaligus, UI secara otomatis me-nonaktifkan (*disable*) atau meredupkan opsi candle lain saat salah satu pola dipilih. Kombinasi yang sah berfokus pada: *(Pola Candlestick terpilih) + (Stoch + Heikin Ashi)*.

### Tampilan Dinamis Berdasarkan Arah (Direction)
- `BUY ONLY`: Opsi sinyal hanya memunculkan sinyal Buy (*Engulfing Buy*, *Hammer*, *Stoch+HA Buy*). Opsi Shooting Star disembunyikan.
- `SELL ONLY`: Opsi sinyal hanya memunculkan sinyal Sell (*Engulfing Sell*, *Shooting Star*, *Stoch+HA Sell*). Opsi Hammer disembunyikan.
- `BUY & SELL`: Menampilkan kelompok terpadu `[ENG]`, `[HMR/SS]`, dan `[ST+HA]`.

### Tampilan pada Tabel Daftar Rule
Kolom sinyal pada tabel menampilkan daftar tag ringkas dan rapi:
`[ENG]` `[HMR/SS]` `[ST+HA]` disertai penanda mode `[OR]` atau `[AND]`.

---

## 6. Penggantian Delay Detik Menjadi `% TF Delay`

### Alasan Penggantian
Satuan detik (`InpDelaySeconds = 5`) kaku pada multi-timeframe dan rawan memicu false signal pada lilin Heikin Ashi yang baru terbentuk beberapa detik.

### Konsep: Minimum Candle Progress Gate
- Mengukur usia perjalanan candle berjalan:
  $$\text{Progress} = \frac{\text{Waktu Berjalan Candle}}{\text{Total Durasi Timeframe}} \times 100\%$$
- Parameter input berupa persentase (contoh default: `30%`).
- **Cara Kerja:**
  - Sinyal diabaikan selama usia candle masih di bawah ambang batas (misal $< 30\%$).
  - Begitu usia candle $\ge 30\%$, sinyal valid diizinkan untuk dieksekusi.
  - Jika sinyal muncul saat candle sudah mendekati akhir (misal sisa 30 detik pada M5, di mana progres sudah 90%), sinyal **langsung dieksekusi seketika** tanpa tertahan.
  - Pada Rule M5 yang memvalidasi sinyal M1, basis perhitungan persennya dihitung dari durasi lilin M1 (60 detik).
- Mode `TF Close` (validasi pada candle bar index 1 yang sudah tertutup) tetap dipertahankan sebagai opsi alternatif.

---

## 7. Arsitektur Trailing TP Baru: EWMA True Range

Menggantikan indikator ATR klasik yang lambat dengan model *Relative Volatility* berbasis *Exponential Weighted Moving Average of True Range* (EWMA TR) pada candle berjalan (`shift 0`).

### Rumus Matematis
1. **True Range Bar Berjalan (`CurrTR`):**
   $$\text{TR} = \max\Big(\text{High} - \text{Low},\; |\text{High} - \text{Close}[1]|,\; |\text{Low} - \text{Close}[1]|\Big)$$
2. **Baseline Volatilitas (`EWMA_TR`):**
   Dihitung dari 30 bar sebelumnya dengan koefisien peluruhan $\lambda = 0.90$:
   $$\text{EWMA}_t = \lambda \cdot \text{EWMA}_{t-1} + (1 - \lambda) \cdot \text{TR}_t$$
3. **Relative Volatility (`RelVol`):**
   $$\text{RelVol} = \frac{\text{CurrTR}}{\text{EWMA\_TR}}$$

### Pemisahan Perilaku: Trail BE vs Trail TP vs Trail SL

```
                                  [ POSISI TERBUKA ]
                                          |
                      +-------------------+-------------------+
                      |                                       |
           [ KEDEKATAN JARAK ]                        [ KEDEKATAN JARAK ]
       (Sisa Jarak <= 1.10x EWMA TR)              (Sisa Jarak <= 1.10x EWMA TR)
                      |                                       |
                      v                                       +-------------------+
               [ TRAIL BE ]                                                       |
        (Amankan Modal ke Impas)                                          [ LONJAKAN VOLATILITAS ]
       *Berjalan Tanpa Menghiraukan                                       (RelVol >= 1.60x EWMA)
         Kondisi Volatilitas Pasar                                                |
                                                                                  v
                                                                          [ TRAIL TP EXTEND ]
                                                                      (Target Diperpanjang Proporsional)
                                                                                  |
                                                                                  v
                                                                           [ TRAIL SL LOCK ]
                                                                       (Kunci Profit ke Level TP Lama)
```

1. **Trail BE (Pengamanan Modal Mandiri):**
   - **Murni berbasis jarak target TP.** Tidak membutuhkan lonjakan volatilitas.
   - Pilihan pendekatan:
     - *Opsi 1 (Kedekatan ke TP - Default & Rekomendasi):* Aktif saat sisa jarak menuju TP $\le 30\%$ dari target TP awal (`rem_dist <= initial_tp_dist * 0.30`) dan posisi dalam keadaan floating profit (`Bid > Open + Spread` untuk Buy / `Ask < Open - Spread` untuk Sell).
     - *Opsi 2 (Profit Berjalan):* Aktif saat running profit mencapai $1.5\times$ EWMA TR dari harga Open.
   - Menggeser SL ke Break-Even (`Open ± Spread`) untuk mengunci posisi bebas risiko tanpa risiko terpicu prematur di awal pergerakan posisi.
2. **Trail TP Extension (Perpanjangan Target Selektif):**
   - Wajib memenuhi **dua syarat sekaligus**:
     1. Jarak ke TP sudah dekat ($\text{distToTP} \le 1.10\times \text{EWMA TR}$).
     2. Terjadi ledakan momentum nyata ($\text{RelVol} > 1.60$).
   - TP diperpanjang secara proporsional terhadap kelebihan volatilitas:
     $$\text{Extend} = (\text{RelVol} - 1.60) \times \text{ATR} \times 0.70$$
     *(Dibatasi maksimal ekstensi $1.80\times \text{ATR}$).*
3. **Trail SL Bertingkat:**
   - Hanya terpicu jika Trail TP berhasil di-extend terlebih dahulu.
   - Begitu TP diperpanjang, SL otomatis digeser mengunci level TP sebelumnya saat harga mendekati TP baru.

### Interaksi dengan Multi TP Independen & Proteksi TP Runner
- Pada pembagian `Multi TP >= 2`:
  - **TP1 (target terdekat) DILARANG di-extend** agar profit pertama dapat terealisasi secara pasti dan cepat.
  - **Hanya target TP paling ekstrem (runner)** yang memenuhi syarat perpanjangan saat terjadi lonjakan volatilitas (`RelVol >= 1.60x`). Untuk BUY adalah tiket dengan TP tertinggi; untuk SELL adalah tiket dengan TP terendah.
- Trail BE tetap bekerja mengamankan modal (menggeser SL ke BE) ketika sisa jarak menuju target mencapai threshold $\le 20\%$.

---

## 4. Persistensi Form Input Saat Interaksi Dashboard

### Masalah Form Reset Saat Toggle
Saat pengguna sedang mengisi atau mengubah kolom di form deck (misalnya simbol, lot, RR, TF, batas harga, trailing distance, multiplier, atau limit order), lalu mengklik tombol toggle (seperti tombol sinyal **ENG / HMR / STOCH**, tombol mode **ANY / COMBO**, tombol **DELAY % / TF CLOSE**, tombol **MAX ORD**, atau navigasi **PREV / NEXT** tabel rules), fungsi UI memanggil `CreateDashboardUI()`. Karena objek-objek input teks di MT5 dihancurkan dan dibuat ulang saat rebuild UI, isi kolom yang sudah diketik pengguna terhapus dan kembali ke nilai default.

### Solusi Sinkronisasi Terpusat (`CaptureFormInputs`)
- Membuat helper sinkronisasi `CaptureFormInputs()` yang dipanggil sebelum rebuild UI pada setiap event klik tombol form.
- Menyimpan teks simbol, nilai RR, lot, TF, Max Orders, Multiplier, Multi TP, % TF Delay, Trailing Distance, RelVol, dan Price Bounds ke variabel status memori (`g_form_*`).
- Menerapkan mekanisme yang sama pada `TradeManagerReversalRadar` (`CaptureRadarFormInputs()`) sehingga form input radar tidak pernah hilang saat beralih mode sinyal atau toggle % delay.

---

## 5. Instant Auto-Pause pada Max Orders, Toggle M1 (M5), dan Kontrol UI Sisa Jarak BE

### A. Instant Auto-Pause Seketika Saat Batas Max Order Tercapai
- **Penyebab Masalah Sebelumnya:** Penonaktifan rule (`active = false`) sebelumnya hanya diperiksa di awal loop tick, sehingga jika rule membuka order ke-$N$ (misalnya 2 dari limit 2), status rule tertunda menjadi `PAUSED` sampai seluruh posisi tersebut tertutup.
- **Penyempurnaan:** Begitu order ke-$N$ dieksekusi di blok BUY maupun SELL dan `orders_opened_count >= max_orders`, rule **seketika langsung dinonaktifkan (`active = false`)**, status disimpan ke file bin, dan tombol pada tabel bawah seketika berubah menjadi **`[PAUSED]` (merah)**.
- **Transparansi Tampilan Counter:** Kolom `MAX` di tabel bawah menampilkan progres riil `orders_opened_count / max_orders` (contoh: `2/2x` dengan teks merah saat limit tercapai, atau `UNL` untuk unlimited).
- **Aktivasi Ulang Bersih (Reliable Reactivation Lifecycle):**
  - **Akar Masalah (Bug Lama):** Jika rule sudah mencapai batas order (`orders_opened_count >= max_orders`) lalu user melakukan `EDIT` untuk memperbarui parameter tanpa menaikkan angka `Max Orders`, rule tetap tertahan dalam status `PAUSED` dan counter tidak ter-reset, sehingga EA terlihat mati suri dan menuntut re-attach EA.
  - **Standar Solusi:**
    1. **Saat Submit Form Edit (`BTN_SUBMIT_RULE`):** Menyimpan perubahan rule langsung mengeset `active = true` dan mereset `orders_opened_count = 0` secara mutlak, sehingga rule siap menyongsong siklus sinyal baru.
    2. **Saat Toggle Manual Status (`BTN_TOGGLE_RULE`):** Menekan tombol untuk mengaktifkan kembali rule (`active = true`) otomatis mereset `orders_opened_count = 0` tanpa syarat, menjamin rule tidak langsung dibekukan ulang di tick pertama.

### B. Toggle M1 Khusus Timeframe M5
- **Tampilan Dinamis:** Tombol toggle **`[M1: ON]` / `[M1: OFF]`** tampil di Row C Form Deck bersanding dengan input Timeframe **hanya jika Timeframe yang dipilih adalah M5**. Jika Timeframe selain M5 (M1, M15, M30, H1), tombol ini otomatis disembunyikan.
- **Logika:** Default adalah **ON**. Jika `ON`, rule M5 akan mendeteksi sinyal utama lilin M5 dan menerima early signal lilin M1. Jika `OFF`, rule M5 murni hanya mengecek lilin M5. Pilihan ini tersimpan persisten per rule (`allow_m1_fallback`) pada format binary v5.
- **Tabel Bawah:** Rule yang aktif fallback M1 menampilkan indikator `[M5+M1]`.

### C. Kontrol UI Parameter Sisa Jarak Trail BE (`BE DIST%`)
- **Form Deck (Row E):** Ditambahkan input **`BE DIST%:`** (default `30%`, rentang 1-100%) bersanding dengan `MAX DIST TR` (1.1) dan `RELVOL THR` (1.6).
- **Preview Terminal Box:** Menampilkan kalkulasi: `Auto Trail BE: Sisa Target <= 30% -> Kunci BE`.
- **Tabel Bawah (Kolom `AUTO TRAIL`):** Menampilkan ringkasan konfigurasi rule: `BE:30%|D:1.1|RV:1.6`.
- **Format State Persistence (v5):** Format file binary `EAT_MultiRules_<login>.bin` ditingkatkan ke versi 5 untuk menyimpan `trail_be_rem_dist_pct` dan `allow_m1_fallback` dengan backward compatibility penuh terhadap file versi 4.

### D. Normalisasi Volume Multi-TP & Diagnostic Trade Logging
- **Akar Masalah (Bug Invalid Volume):** Pada Multi-TP (misal Multi TP = 2), pembagian lot (`pool / mtp`) menghasilkan pecahan desimal yang melanggar `SYMBOL_VOLUME_STEP` broker (contoh: 0.51 lot dibagi 2 menjadi 0.255 lot pada BTCUSD dengan step 0.01), sehingga server broker menolak order dengan pesan `[Invalid volume]`.
- **Standar Solusi:**
  1. **Fungsi Terpusat `NormalizeLotSize(sym, raw_lot)`:** Menyelaraskan seluruh kalkulasi lot (Fixed, Risk %, Risk Money, dan pembagian pecahan Multi-TP) dengan `SYMBOL_VOLUME_STEP`, `SYMBOL_VOLUME_MIN`, serta pembulatan presisi desimal dinamis (`lot_digits`).
  2. **Audit Eksekusi Multi-TP:** Setiap pecahan lot pada `plan_lot[p]` dan `cur_lot` dipastikan melewati normalisasi sebelum dikirim ke `m_trade.Buy()` / `m_trade.Sell()`.
  3. **Trade Error Diagnostics:** Menambahkan log penolakan eksekusi broker (`PrintFormat("[BUY/SELL FAILED]...")`) yang merinci kode error `ResultRetcode()` dan deskripsinya ke tab Experts agar masalah server/broker selalu terlihat transparan.

---

## 6. Mode Continuation Entry & Mode Lot Berbasis Mata Uang Akun (Risk Money)

### A. Mode Continuation Entry (Default: OFF / Sequential)
- **Logika:**
  - Jika `continuation_mode = false` (Sequential): Rule menunggu seluruh posisi yang sedang terbuka pada simbol tersebut tertutup sebelum dapat membuka siklus order baru.
  - Jika `continuation_mode = true` (Continuation): Rule diperbolehkan membuka entri baru meskipun ada posisi terbuka yang sedang berjalan, **dengan syarat arah sinyal searah** dengan posisi berjalan (Buy hanya boleh tambah Buy, Sell hanya boleh tambah Sell). Jika ada posisi berlawanan, entri diblokir.
- **UI:** Tombol `CONT: ON` (neon gold) / `CONT: OFF` (abu-abu) di Form Deck Row D serta badge status `[CONT]` / `[SEQ]` di tabel rule list.

### B. Mode Lot Berbasis Mata Uang Akun (`LOT_RISK_MONEY`)
- Menghitung ukuran lot secara dinamis berdasarkan nominal mata uang akun (contoh: 30 USD, 30 EUR, atau 50 USC).
- Menggunakan nilai tick per simbol (`SYMBOL_TRADE_TICK_VALUE` / `SYMBOL_TRADE_TICK_SIZE`) terhadap jarak stop loss point.
- **Prinsip Granularitas Diskrit & Konservatif:**
  - Di pasar riil, risiko nominal tidak pernah bisa persis sampai sen terakhir karena volume trading terikat batasan diskrit broker (`SYMBOL_VOLUME_STEP` dan `SYMBOL_VOLUME_MIN`).
  - Kalkulasi lot menggunakan pembulatan ke bawah (`MathFloor`) ke kelipatan step terdekat untuk menjamin kerugian aktual saat terkena SL **tidak akan melampaui** nominal risiko yang ditetapkan (contoh: target risiko 50 USC menghasilkan lot diskrit dengan risiko riil ~49 USC, bukan dinaikkan ke atas yang bisa membengkak menjadi 51+ USC).
  - Normalisasi ini juga diaplikasikan secara rekursif saat lot dipecah ke beberapa tingkatan Multi-TP.
- Tombol lot mode di UI berputar: `FIXED LOT` -> `% RISK` -> `[CURRENCY]` (contoh: `USD` / `USC`).

### C. Pembaruan Nilai Default Sistem
- Timeframe acuan default: **M5** (`5`).
- Sisa jarak target untuk Trail BE: **20%** (`InpTrailBERemDistPct = 0.20` / `20%`).
- Multi TP: **2** (`InpMultiTP = 2`).
- Format binary state naik ke **v6** untuk AutoTrader dan **v7** untuk Radar.
