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
- **Perampingan Preview Kanan:** Area preview/simulasi diperkecil dan difokuskan pada ringkasan esensial:
  - Identitas simbol, timeframe, arah trading, dan ringkasan sinyal aktif.
  - Distribusi lot pada tiap tingkatan Multi TP aktif.
  - Status saklar Trailing serta mode yang sedang bekerja.
- **Pemisahan Parameter Baku:** Parameter matematis konstan (seperti periode baseline EWMA 30 bar, nilai lambda 0.90, threshold volatilitas 1.60, parameter Stochastic 14/1/3) dikonfigurasi melalui Input Parameter EA (menu F7), menjaga form chart tetap bersih, lega, dan ergonomis. Seluruh angka volatilitas dan jarak trailing tidak di-hardcode sehingga dapat disesuaikan fleksibel.

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
   - Lilin pembalik lebih dominan: Rentang total candle ($\text{High} - \text{Low}$) wajib lebih panjang daripada rentang total candle sebelumnya ($\text{High}[1] - \text{Low}[1]$).
2. **Strong Shooting Star (Eksklusif Sinyal SELL):**
   - Ekor/Shadow atas panjang: $\text{Upper Shadow} \ge 3 \times \text{Body}$.
   - Ekor sebaliknya (bawah) kecil: $\text{Lower Shadow} \le 0.8 \times \text{Body}$.
   - Rentang total candle ($\text{High} - \text{Low}$) wajib lebih panjang daripada rentang total candle sebelumnya.

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
- **Kondisi SELL:**
  1. Nilai $\%K > 80$ (zona overbought).
  2. $\%K < \%K[1]$ (momentum Stochastic mulai memantul ke bawah).
  3. Konfirmasi lilin Heikin Ashi: Ukuran lilin mengecil ($\text{haSize} < \text{haSize}[1]$) **ATAU** warna Heikin Ashi berubah menjadi merah ($\text{haClose} < \text{haOpen}$).

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
   - **Murni berbasis jarak.** Tidak membutuhkan lonjakan volatilitas.
   - Pilihan pendekatan:
     - *Opsi 1 (Profit Berjalan):* Aktif saat running profit mencapai $1.5\times$ atau $2.0\times$ EWMA TR dari harga Open.
     - *Opsi 2 (Kedekatan ke TP - Default):* Aktif saat sisa jarak menuju TP $\le 1.10\times$ EWMA TR.
   - Menggeser SL ke Break-Even (`Open ± Spread`) untuk mengunci posisi bebas risiko meski pasar bergerak lambat.
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

### Interaksi dengan Multi TP Independen
- Setiap tiket posisi yang dibuka oleh pembagian Multi TP dipantau level TP-nya secara **independen**.
- **Fokus Prioritas:** Pemantauan aktif dimulai dari tiket dengan TP terdekat (TP1).
- Jika TP1 terkena ekstensi hingga posisinya mendekati TP2, sistem secara otomatis memantau kedua tiket tersebut secara simultan.
- Begitu TP1 tereksekusi (*Hit TP*), fokus pemantauan beralih penuh mengawal tiket berikutnya (TP2, TP3, dst.).
