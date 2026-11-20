# Rancang Bangun & Arsitektur TradeManagerReversalRadar (Versi 2)

Dokumen ini merekam secara rinci arsitektur, spesifikasi teknis, rancangan UI/UX, serta logika deteksi sinyal pembalikan arah (*reversal*) untuk `TradeManagerReversalRadar.mq5` (sebelumnya `TradeManagerEngulfingRadar.mq5`).

---

## 1. Latar Belakang & Tujuan Pembaruan

Pada versi awal, `TradeManagerEngulfingRadar` hanya memiliki fungsi alert untuk pola *Engulfing Break*. Berdasarkan evaluasi dan standardisasi dengan `MultiRuleAutoTrader v3`, radar diperluas menjadi pemantau sinyal reversal terpadu (*multi-signal reversal radar*) dengan fitur-fitur baru:
1. **Penyelarasan Sinyal Reversal:** Menambahkan detektor pola *Strong Hammer* (Bullish), *Strong Shooting Star* (Bearish), serta kombinasi *Stochastic (14,1,3) + Heikin Ashi Reversal*.
2. **Kesesuaian Nomenklatur:** Menghilangkan kata *breakout* dan menyelaraskan penamaan menjadi **Reversal**.
3. **Fungsi Saklar Active / Pause per Baris Radar:** Memberikan fleksibilitas bagi trader untuk menonaktifkan atau mengaktifkan sementara alert simbol tertentu langsung dari tabel tanpa harus menghapus rule pemantauan.
4. **Kompensasi Spread Broker pada Stop Loss SELL:** Alert sinyal Sell wajib menambahkan selisih spread broker pada rekomendasi Stop Loss, menjaga keakuratan level risiko riil.
5. **Standarisasi Delay (% TF Progress Delay & TF Close):** Mengganti parameter delay detik statis dengan persentase progres lilin berjalan (% umur candle) atau konfirmasi candle tertutup penuh (*TF Close*).
6. **Dukungan Mode Eksekusi ANY (OR) vs COMBO (AND):** Memberikan opsi apakah alert terpicu jika salah satu sinyal valid (*ANY*) atau seluruh sinyal yang dipilih wajib konvergen bersamaan (*COMBO*).

---

## 2. Struktur Data & Penyimpanan Biner (State Persistence)

### 2.1 Struktur `SRadarSymbol` (State Version 3)
```mql5
struct SRadarSymbol
{
   string               symbol;                        // Pasangan mata uang / instrumen
   ENUM_TIMEFRAMES      timeframe;                     // Timeframe pemantauan (M1, M5, M15, dst)
   bool                 bull_enabled;                  // Saklar deteksi sinyal Bullish
   string               bull_price_filter;             // Filter batas harga Buy (ALL / < / > / rentang)
   bool                 bear_enabled;                  // Saklar deteksi sinyal Bearish
   string               bear_price_filter;             // Filter batas harga Sell (ALL / < / > / rentang)
   int                  atr_period;                    // Periode ATR untuk acuan buffer 50%
   datetime             last_bull_alert_bar;           // Timestamp bar alert bullish terakhir
   datetime             last_bear_alert_bar;           // Timestamp bar alert bearish terakhir
   bool                 delay_is_tf_close;             // Mode konfirmasi TF Close
   int                  delay_tf_pct;                  // % TF Progress Delay (0-99%)
   bool                 active;                        // Saklar status baris: true = ACTIVE, false = PAUSED
   bool                 sig_engulfing;                 // Sinyal Strong Engulfing Reversal
   bool                 sig_hammer_ss;                 // Sinyal Strong Hammer / Shooting Star
   bool                 sig_stoch_ha;                  // Sinyal Stochastic + Heikin Ashi
   ENUM_SIGNAL_MODE     signal_mode;                   // Mode: SIGNAL_MODE_ANY atau SIGNAL_MODE_COMBO
   datetime             bull_cond_start_time_main;     // Waktu awal terpenuhinya kondisi (TF utama)
   datetime             bull_cond_start_time_fallback; // Waktu awal terpenuhinya kondisi (M1 fallback)
   datetime             bear_cond_start_time_main;     // Waktu awal terpenuhinya kondisi (TF utama)
   datetime             bear_cond_start_time_fallback; // Waktu awal terpenuhinya kondisi (M1 fallback)
};
```

### 2.2 Serialisasi Biner (`.bin`)
- Format biner diperbarui ke Versi 3 (`MAGIC_V3`).
- Menyimpan konfigurasi lengkap termasuk status `active`, status ketiga sinyal (`sig_engulfing`, `sig_hammer_ss`, `sig_stoch_ha`), mode sinyal (`signal_mode`), serta parameter delay baru (`delay_tf_pct`, `delay_is_tf_close`).
- Memastikan pengaturan tidak hilang saat terminal MetaTrader 5 dimatikan atau saat timeframe chart diubah.

---

## 3. Logika Deteksi Sinyal Reversal

### 3.1 Strong Engulfing Reversal
- **Bullish:** Candle hijau yang menelan body lilin sebelumnya, di mana ukuran body lilin minimal $1.0\times$ body lilin sebelumnya dan range menembus level tertinggi candle acuan.
- **Bearish:** Candle merah yang menelan body lilin sebelumnya dengan penembusan level terendah candle acuan.
- **Rekomendasi SL:**
  - BUY: $\text{Low} - 50\% \text{ ATR}$.
  - SELL: $\text{High} + 50\% \text{ ATR} + \text{Spread}$.

### 3.2 Strong Hammer & Strong Shooting Star
- **Strong Hammer (BUY):**
  - Shadow bawah: $\text{Lower Shadow} \ge 3 \times \text{Body}$.
  - Shadow atas: $\text{Upper Shadow} \le 0.8 \times \text{Body}$.
  - Sapu likuiditas (*liquidity sweep*): Low candle berjalan wajib lebih rendah daripada low candle sebelumnya (`cur_low < prev_low`). Bebas warna body.
  - Rekomendasi SL: $\text{Low} - 50\% \text{ ATR}$.
- **Strong Shooting Star (SELL):**
  - Shadow atas: $\text{Upper Shadow} \ge 3 \times \text{Body}$.
  - Shadow bawah: $\text{Lower Shadow} \le 0.8 \times \text{Body}$.
  - Sapu likuiditas (*liquidity sweep*): High candle berjalan wajib lebih tinggi daripada high candle sebelumnya (`cur_high > prev_high`). Bebas warna body.
  - Rekomendasi SL: $\text{High} + 50\% \text{ ATR} + \text{Spread}$ (otomatis dikompensasikan dengan spread broker).

### 3.3 Stochastic (14,1,3) + Heikin Ashi Reversal
- **Indikator:** Stochastic %K=14, %D=1, Slowing=3, Level OB=80, Level OS=20.
- **Kondisi BUY:** Sinyal Stochastic $\%K < 20$ dan $\%K > \%K[1]$ (berbelok naik dari area oversold) didukung lilin Heikin Ashi yang menciut ukurannya atau berubah warna menjadi hijau.
  - *Syarat Tambahan Multi-Timeframe (Khusus Sinyal TF M5 ke Atas):* Stochastic pada TF M1 **juga wajib oversold** ($\%K_{\text{M1}} < 20$). Pada M1 tidak perlu syarat perubahan arah $\%K$ atau Heikin Ashi; cukup level ekstrem oversold. Jika sinyal dari M1 sendiri, berlaku seluruh syarat lengkap.
- **Kondisi SELL:** Sinyal Stochastic $\%K > 80$ dan $\%K < \%K[1]$ (berbelok turun dari area overbought) didukung lilin Heikin Ashi yang menciut ukurannya atau berubah warna menjadi merah.
  - *Syarat Tambahan Multi-Timeframe (Khusus Sinyal TF M5 ke Atas):* Stochastic pada TF M1 **juga wajib overbought** ($\%K_{\text{M1}} > 80$). Pada M1 tidak perlu syarat perubahan arah $\%K$ atau Heikin Ashi; cukup level ekstrem overbought. Jika sinyal dari M1 sendiri, berlaku seluruh syarat lengkap.
- Rekomendasi SL:
  - BUY: $\text{Ask} - 2.0 \times \text{ATR}$.
  - SELL: $\text{Bid} + 2.0 \times \text{ATR} + \text{Spread}$.

---

## 4. Evaluasi Mode Sinyal: ANY (OR) vs COMBO (AND)

1. **Mode ANY (OR):**
   - Alert dikirimkan jika salah satu sinyal yang dipilih terbukti valid pada lilin yang sedang dipantau.
   - Ideal bagi trader yang ingin memantau peluang reversal sebanyak mungkin.
2. **Mode COMBO (AND):**
   - Alert hanya dikirimkan jika seluruh sinyal aktif terpenuhi secara serempak.
   - Karena lilin tidak bisa sekaligus menjadi pola Engulfing dan Hammer/Shooting Star, form dashboard memberlakukan eksklusi mutual (*mutual exclusion*) antara Engulfing dan Hammer/Shooting Star.
   - Skenario COMBO yang sah: `Engulfing + Stoch+HA` atau `Hammer/Shooting Star + Stoch+HA`.

---

## 5. Fitur Saklar Active / Pause & Interaksi UI Dashboard

- **Tombol Status di Tabel List Radar:**
  - Setiap baris pemantauan memiliki tombol status:
    - **`[ACTIVE]`** (Warna Neon Hijau): Radar aktif memeriksa harga dan mengirim alert.
    - **`[PAUSE]`** (Warna Scarlet Red): Radar menghentikan evaluasi untuk instrumen tersebut tanpa menghapus parameternya.
  - Klik langsung mengubah status secara instan tanpa me-reload seluruh form.
- **Form Add/Edit Radar:**
  - Tombol pilihan sinyal: `[x] ENGULFING`, `[x] HMR/SS`, `[x] STOCH+HA`.
  - Tombol pilihan mode: `MODE: ANY (OR)` / `MODE: COMBO (AND)`.
  - Mode Delay: `% TF PROGRESS` (dengan input nilai persentase 0-99%) atau `TF CLOSE`.
  - Filter Price Bounds: Tetap mendukung operator `<, >, <=, >=`, rentang `Min-Max`, atau `ALL`.
  - **Persistensi Form Input (`CaptureRadarFormInputs`):** Menangkap seluruh input teks simbol, TF, batas harga, dan delay sebelum tombol toggle diklik, sehingga teks yang sedang diketik tidak terhapus saat berpindah mode sinyal atau delay.

---

## 6. Auto Trail Engine SL & TP (EWMA True Range) di Order Manager

- **Arsitektur Trailing Terintegrasi:**
  - `TradeManagerReversalRadar` kini menyematkan mesin EWMA True Range ($\lambda = 0.90$, 30 bar acuan) yang identik dengan `MultiRuleAutoTrader`.
  - **Trail BE (Break-Even):** Bergerak saat sisa jarak ke target TP awal $\le 20\%$ (`InpTrailBERemDistPct = 0.20`, default baru). Mengunci SL ke `Open + Spread` (Buy) atau `Open - Spread` (Sell).
  - **Trail TP Extension & Proteksi Multi-TP Runner:** Perpanjangan TP dinamis saat proximity ke TP $\le 1.10\text{TR}$ dan lonjakan volatilitas relatif $\text{RelVol} \ge 1.60\times$. Pada posisi Multi-TP ($\ge 2$), **TP1 tidak di-extend** agar profit terdekat pasti terkunci; hanya TP runner paling ekstrem yang di-extend.
  - **Trail SL Lock ke Previous TP:** Mengunci SL ke level TP sebelumnya pada siklus perpanjangan ke-2 dan seterusnya.
- **Deteksi Posisi & Proteksi Konflik AutoTrader:**
  - Membaca Magic Number posisi: jika `POSITION_MAGIC == InpAutoTraderMagic (882201)`, status di kolom tabel otomatis menampilkan label **`[AT TRAIL]`** (neon cyan).
  - Posisi manual/lain yang di-trail melalui Radar menampilkan label **`[ON]`** / **`[ON (C1)]`** (neon gold).
  - Tombol **`[ACTIVATE AUTO TRAIL]`** secara otomatis mendeteksi dan melewati (*skip*) posisi `[AT TRAIL]` untuk mencegah modifikasi ganda antara kedua EA.
- **Persistensi Binary State Format v7:**
  - Menyimpan status tabel posisi aktif (`SPositionTracking`), form input Auto Trail (`MAX DIST TR`, `RELVOL`, `BE DIST %`, `BASE TF`), dan watchlist radar ke dalam `TMRR_State_<login>.bin` v7 dengan kompatibilitas mundur penuh dari file state v6.
