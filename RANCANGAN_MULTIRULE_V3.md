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
- **Mode COMBO (Konfirmasi Ganda Wajib & STOCH+HA):**
  - Mengeliminasi ambiguitas candle fisik yang mustahil merangkap (Engulfing sekaligus Pinbar) dengan menyederhanakan pilihan menjadi 2 paket konfirmasi ganda:
    1. **Paket 1: `[x] ENG & STOCH+HA`** (Pola Engulfing terverifikasi filter momentum jenuh Stochastic + Heikin Ashi).
    2. **Paket 2: `[x] HAMMER & STOCH+HA`** / **`[x] SHOOTING & STOCH+HA`** (Pola Rejection ekor panjang terverifikasi filter momentum jenuh Stochastic + Heikin Ashi).
  - **Dukungan Keduanya Aktif (Filosofi "Sama tapi Berbeda"):** Pengguna dapat mencentang **kedua paket aktif sekaligus**. EA akan mengeksekusi paket mana saja yang lebih dulu terbentuk valid (baik Lilin = `ENG & STOCH+HA` maupun Lilin = `HAMMER/SS & STOCH+HA`). Semua order yang keluar di mode COMBO dijamin 100% selalu terverifikasi filter Stochastic + Heikin Ashi tanpa pengecualian.

### Tampilan Dinamis Berdasarkan Arah (Direction)
- `BUY ONLY`:
  - Mode ANY: `[x] ENG`, `[x] HAMMER`, `[x] STOCH+HA`.
  - Mode COMBO: `[x] ENG & STOCH+HA` dan `[x] HAMMER & STOCH+HA`. Opsi Shooting Star disembunyikan.
- `SELL ONLY`:
  - Mode ANY: `[x] ENG`, `[x] SHOOTING`, `[x] STOCH+HA`.
  - Mode COMBO: `[x] ENG & STOCH+HA` dan `[x] SHOOTING & STOCH+HA`. Opsi Hammer disembunyikan.
- `BUY & SELL` (BOTH):
  - Mode ANY: `[x] ENG`, `[x] HMR/SS`, `[x] STOCH+HA`.
  - Mode COMBO: Menampilkan label terpadu **`[x] HMR/SS & STOCH+HA`** bersanding dengan `[x] ENG & STOCH+HA`.
  - **Perilaku Eksekusi Mode BOTH pada Paket COMBO Kedua:**
    - Saat EA mengevaluasi lilin untuk sinyal **BUY**, tombol ini otomatis bertindak memvalidasi konfirmasi ganda **`HAMMER & STOCH+HA`**.
    - Saat EA mengevaluasi lilin untuk sinyal **SELL**, tombol ini otomatis bertindak memvalidasi konfirmasi ganda **`SHOOTING & STOCH+HA`**.
    - Pendekatan ini menjaga ukuran tombol tetap proporsional dan tidak terpotong di Form Deck tanpa mengorbankan fungsionalitas dua arah.

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

### Perilaku Saat Modifikasi Manual SL / TP oleh Pengguna
Sistem trailing didesain sepenuhnya toleran dan adaptif terhadap intervensi manual pengguna di chart:
- **Modifikasi SL Manual (One-Way Protection):**
  - Mesin trailing membaca nilai SL live posisi (`m_position.StopLoss()`) pada setiap tick.
  - EA menerapkan aturan proteksi satu arah: SL hanya akan dimodifikasi jika level Break-Even yang dihitung lebih menguntungkan dibanding SL saat ini (`be_sl > cur_sl` untuk BUY, atau `be_sl < cur_sl` untuk SELL).
  - Jika pengguna telah menggeser SL secara manual lebih jauh ke arah profit (melebihi titik BE), EA **tidak akan menurunkan/memundurkan SL** kembali ke titik BE, melainkan langsung menandai `be_applied = true` dan mengizinkan tahapan trailing berikutnya berjalan.
- **Modifikasi TP Manual (Dynamic Proximity Adaptation):**
  - Sisa jarak menuju target dihitung secara live terhadap level TP terbaru dari server broker: `dist_to_tp = MathAbs(cur_tp - price) / ewma_tr`.
  - Jika pengguna menggeser TP lebih jauh atau lebih dekat, ambang kedekatan trailing dan trigger Break-Even secara otomatis menyesuaikan diri terhadap TP baru tersebut.
  - Perpanjangan TP lanjutan (*TP Extend*) saat lonjakan volatilitas (`RelVol >= 1.60x`) tetap berfungsi normal dan bertolak dari level TP hasil modifikasi manual tersebut.

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
- **Independensi Lintas Rule dan Lintas Simbol:**
  - **Interaksi Antar-Rule pada Simbol yang Sama:**
    - Jika Rule A telah membuka posisi BUY, lalu Rule B (pada simbol yang sama) mendeteksi sinyal BUY: Rule B **bisa membuka order** asalkan `continuation_mode` pada Rule B aktif (`true`).
    - Jika Rule B mendeteksi sinyal SELL saat posisi BUY masih terbuka: Rule B **tetap diblokir** (meskipun continuation aktif) demi mencegah hedging/locking arah berlawanan di simbol yang sama.
    - Jika `continuation_mode` pada Rule B nonaktif (`false` / sequential): Rule B tidak akan mengeksekusi order baru sampai seluruh posisi di simbol tersebut bersih.
  - **Independensi Penuh Lintas Simbol:**
    - Pengecekan posisi (`CountOpenPositions(sym)`) berjalan strictly **per-simbol**.
    - Keberadaan posisi terbuka di satu simbol (misal `BTCUSD` oleh Rule 1) **sama sekali tidak mempengaruhi** rule di simbol lain (misal `ETHUSD` atau `EURUSD` oleh Rule 2). Rule di simbol lain tetap bebas membuka order terlepas dari apakah `continuation_mode` miliknya bernilai ON maupun OFF.
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

---

## 7. Sistem Resolusi Tiket Posisi MT5 & Auto-Adoption Posisi Berjalan

### A. Resolusi Tiket Posisi MT5 (`ResolvePositionTicket`)
- **Akar Masalah:**
  - Fungsi eksekusi standar `m_trade.Buy()` / `m_trade.Sell()` mengembalikan `m_trade.ResultOrder()` (tiket order) dan `m_trade.ResultDeal()` (tiket deal).
  - Pada akun retail MT5 tipe Hedging maupun broker dengan eksekusi pasar dinamis, nomor tiket posisi terbuka (`PositionSelectByTicket`) kerap berbeda dari nomor order awal.
  - Jika EA hanya mendaftarkan `deal_tkt = m_trade.ResultOrder()`, maka saat `ProcessAutoTrailSLTP()` mengecek `m_position.SelectByTicket(tkt)`, pemanggilan tersebut gagal (`false`) dan menandai tracking nonaktif (`active = false`), sehingga posisi kehilangan pengawalan Auto Trail sejak tick pertama.
- **Standar Solusi:**
  - Dibuat fungsi resolver bertingkat `ResolvePositionTicket(order_ticket, deal_ticket, sym)`:
    1. Cek langsung `PositionSelectByTicket(order_ticket)`. Jika langsung valid, gunakan `order_ticket`.
    2. Cek histori deal eksekusi via `HistoryDealSelect(deal_ticket)` lalu ambil `DEAL_POSITION_ID` dan validasi via `PositionSelectByTicket(pos_id)`.
    3. Fallback: Cari posisi terbuka paling baru pada simbol tersebut yang memiliki `m_position.Magic() == InpMagicNumber`.

### B. Auto-Adoption Posisi Berjalan (`AdoptOpenEAPositions`)
- **Penyebab Insiden (EA Reload / Reset RAM):**
  - Array pelacakan `g_tracking_list[]` berada di memori RAM. Jika EA ter-reload (recompile, ganti timeframe chart, restart terminal MT5, atau submit edit form), list tracking di RAM menjadi kosong sementara order di broker masih berjalan.
  - Akibatnya, posisi yang sudah berjalan tidak lagi dikawal oleh Trail BE maupun TP Extend, sehingga bisa langsung menyentuh TP tanpa pernah di-extend.
- **Standar Solusi:**
  - Diterapkan fungsi `AdoptOpenEAPositions()` yang dipanggil di setiap `OnInit()` dan awal loop `OnTick()`.
  - **Prinsip Keamanan & Isolasi:**
    - **Hanya Posisi Milik EA:** Filter strictly `m_position.Magic() == InpMagicNumber`.
    - **Order Manual Tidak Disentuh:** Order manual (`Magic == 0`) maupun order dari EA lain sama sekali tidak diadopsi atau diganggu.
    - Menghubungkan kembali posisi berjalan dengan konfigurasi rule aktif yang sesuai pada simbol tersebut (timeframe, trail dist, relvol threshold, dan BE distance ratio).
    - Jika rule spesifik telah dihapus atau dipause namun ordernya masih terbuka di broker, posisi tetap dikawal menggunakan default safety trail parameter.
  - Memperbaiki bug typo perbandingan magic number di loop Multi-TP check: `m_position.Magic() == InpMagicNumber` (sebelumnya `m_position.Magic() == m_position.Magic()`).

---

## 8. Pembersihan State Price Bound & Kompensasi Spread pada Perhitungan Net RR

### A. Reset Runtime Price Bound & Sinyal Saat Aktivasi Ulang Rule (BTN_TOGGLE_RULE)
- **Akar Masalah:**
  - Fitur *Price Bound Grace Period* memberi waktu toleransi 1.5x Timeframe sejak harga terakhir kali meninggalkan zona bound (`bull_bound_exit_time`).
  - Ketika sebuah rule selesai membuka order hingga limit tercapai (misal `max_orders = 1`), rule otomatis berstatus `PAUSED`. Namun variabel runtime di RAM: `bull_bound_entered_time`, `bear_bound_entered_time`, `bull_bound_exit_time`, dan `bear_bound_exit_time` masih menyimpan timestamp dari order sebelumnya.
  - Saat pengguna mengaktifkan kembali rule tersebut via tombol `[PAUSED] -> [ACTIVE]` di dashboard, kode lama hanya me-reset `orders_opened_count = 0` tanpa membersihkan variabel bound.
  - Akibatnya, pada tick pertama setelah aktif, EA menganggap harga masih berada dalam Grace Period dari sentuhan bound lama, sehingga order baru langsung terbuka meskipun harga riil saat itu belum menyentuh batas harga (Price Bound).
- **Standar Solusi:**
  - Pada penanganan event klik `BTN_TOGGLE_RULE_`, saat status berubah menjadi aktif (`g_rules[i].active == true`), seluruh variabel runtime bound di-clear bersih ke `0`:
    ```mql5
    g_rules[i].bull_bound_entered_time = 0;
    g_rules[i].bear_bound_entered_time = 0;
    g_rules[i].bull_bound_exit_time    = 0;
    g_rules[i].bear_bound_exit_time    = 0;
    for(int k = 0; k < 2; k++)
    {
       g_rules[i].last_bull_bar[k] = 0;
       g_rules[i].last_bear_bar[k] = 0;
       g_rules[i].bull_last_checked_bar[k] = 0;
       g_rules[i].bear_last_checked_bar[k] = 0;
    }
    ```
  - Ini menjamin rule yang baru diaktifkan kembali wajib menunggu harga benar-benar memasuki zona price bound yang ditentukan dan lilin sinyal baru terkonfirmasi.

### B. Kompensasi Spread pada Target TP untuk Keakuratan Rasio Net RR Moneter
- **Akar Masalah (Erosi Spread saat Likuidasi Posisi):**
  - Pada transaksi **SELL**:
    - Order dibuka di harga **Bid**.
    - Penutupan order (baik terkena SL maupun TP) dieksekusi di harga **Ask** ($\text{Ask} = \text{Bid} + \text{Spread}$).
    - Stop loss diletakkan di `sl_price = High + 50% ATR + Spread`, sehingga $\text{sl\_dist} = \text{sl\_price} - \text{Bid}$. Kerugian aktual saat kena SL adalah penuh sebesar $\text{sl\_dist}$ (contoh: 52 USC).
    - Namun jika TP diletakkan di $\text{Bid} - (\text{sl\_dist} \times \text{RR})$, order hanya akan terlikuidasi saat harga Ask menyentuh level tersebut. Pada saat itu, harga Bid broker berada di level $\text{tp\_price} - \text{Spread}$, sehingga profit moneter bersih yang diterima terpotong sebesar 1x spread ($\text{sl\_dist} \times \text{RR} - \text{Spread}$). Misalnya pada RR 1:2, kerugian SL 52 USC hanya menghasilkan profit TP 97 USC bukan 104 USC.
  - Pada transaksi **BUY**:
    - Order dibuka di harga **Ask** dan ditutup di harga **Bid**.
    - Keuntungan saat menyentuh target kotor $\text{Ask} + (\text{sl\_dist} \times \text{RR})$ mengalami pemotongan serupa saat ditutup di harga Bid.
- **Standar Solusi (Spread-Compensated TP):**
  - Formula penentuan level Take Profit diperluas dengan memasukkan kompensasi spread live broker:
    - **BUY TP:**
      $$\text{tp\_price} = \text{Ask} + (\text{sl\_dist} \times \text{RR}) + \mathbf{\text{Spread}}$$
      (Termasuk pada setiap tingkatan Multi-TP: $\text{Ask} + (\text{sl\_dist} \times \text{RR} \times t) + \mathbf{\text{Spread}}$).
    - **SELL TP:**
      $$\text{tp\_price} = \text{Bid} - (\text{sl\_dist} \times \text{RR}) - \mathbf{\text{Spread}}$$
      (Termasuk pada setiap tingkatan Multi-TP: $\text{Bid} - (\text{sl\_dist} \times \text{RR} \times t) - \mathbf{\text{Spread}}$).
  - Dengan kompensasi ini, begitu harga Bid/Ask pasar menyentuh TP dan order ditutup, profit moneter bersih yang masuk ke saldo akun tepat bernilai $1 : \text{RR}$ secara presisi (contoh: Risk 52 USC menghasilkan Reward 104 USC pada RR 1:2).


