# Trade Manager & Engulfing Radar (MQL5)

Tool Expert Advisor (EA) multi-simbol untuk MetaTrader 5 dengan dashboard interaktif on-chart. Didesain untuk mempermudah Anda mengelola banyak posisi trading sekaligus (*bulk order manager*), mengamankan profit secara instan atau otomatis (*Break-Even engine*), serta memantau pola **Strong Engulfing Break** secara real-time tick-by-tick di berbagai pasangan mata uang.

---

## Fitur Utama

### 1. Multi-Symbol Order Manager (Tab 1)
- **Tabel Posisi & Pending Order**: Menampilkan semua transaksi aktif di akun Anda lengkap dengan informasi Simbol, Tipe Order, Volume (Lots), Open Price, SL, TP, dan status Auto-BE.
- **Checkbox Seleksi Fleksibel**: Anda bebas memilih order mana saja yang ingin diubah menggunakan tombol `[X]` per baris atau tombol cepat `SELECT ALL` / `CLEAR`.
- **Bulk SL & TP Price**: Masukkan nominal harga Stop Loss atau Take Profit yang Anda inginkan, lalu klik `SET SL` atau `SET TP` untuk menerapkan ke semua order yang ditandai sekaligus.
- **Break-Even (BE) Engine**:
  - **`SET BE SPREAD` (Instan)**: Langsung menggeser SL order terpilih ke titik impas (Harga Open + Spread untuk Buy, atau Harga Open - Spread untuk Sell) saat itu juga.
  - **`ACTIVATE BE TRIGGER` (Otomatis)**: Menyetel harga pemicu (*trigger price*). Begitu harga market menyentuh level tersebut, EA akan otomatis menggeser SL ke titik Break-Even.

#### Mode BE Offset (Tombol `BE OFFSET MODE`)

Klik tombol `BE OFFSET MODE` untuk berpindah mode secara berurutan (siklus 4 mode):

| Mode | Tampilan | SL setelah trigger tercapai |
|---|---|---|
| **Auto Spread** | `AUTO SPREAD (+/- Spread)` | Buy: `Open + Spread` / Sell: `Open - Spread` |
| **Exact Open** | `EXACT OPEN (+0 pts)` | Buy & Sell: tepat di `Open` |
| **Custom Lock** | `CUSTOM LOCK (+10 pts)` | Buy: `Open + 10 pts` / Sell: `Open - 10 pts` |
| **Fixed SL Price** | `FIXED SL PRICE (> 0)` | Buy & Sell: tepat di harga pada kolom `SL TARGET PRICE` |

**Mode `FIXED SL PRICE`** memungkinkan Anda menentukan sendiri level SL tujuan. Isi kolom **`SL TARGET PRICE`** dengan harga (misal `1.0965`), lalu klik `ACTIVATE BE TRIGGER`.

- Kolom harga **kosong = OFF**; mode ini akan menolak aktivasi dan menampilkan peringatan.
- Harga yang sudah diketik **tetap tersimpan** saat Anda berpindah mode atau me-render ulang dashboard.
- Harga tersebut juga disimpan ke file state per akun, jadi tidak hilang setelah restart.
- EA hanya menggeser SL jika hasilnya **memperbaiki** posisi (Buy: SL baru > SL sekarang; Sell: SL baru < SL sekarang). Jika tidak, jadwal BE dianggap selesai dan tidak dipaksakan.

> Catatan: harga tetap dipakai apa adanya untuk kedua arah, jadi pastikan level yang Anda masukkan memang valid sebagai SL (di bawah harga untuk Buy, di atas harga untuk Sell). EA tidak akan memaksa SL yang memperburuk posisi.

---

### 2. Engulfing Radar & Mobile Push Alert (Tab 2)
- **Real-time Tick-Level Detection**: Pola dideteksi langsung saat harga running menembus (*breakout*) High/Low candle sebelumnya tanpa perlu menunggu candle selesai (*close*).
- **Dual-Timeframe (M5 + M1)**: Untuk pantauan **M5**, radar juga menerima sinyal dari **M1** dengan prioritas M5. TF lain tetap eksklusif. Lihat [`DUAL_TIMEFRAME.md`](../DUAL_TIMEFRAME.md) untuk detailnya.
- **Basis ATR M1**: Bila simbol dipantau di **M1**, nilai ATR(14) dipinjam dari **M5** lalu dikali **0.5** agar buffer SL tidak terlalu rapat. Sama seperti yang dipakai `EngulfingAutoTrader`.
- **Kalkulasi Otomatis 50% ATR**: Menghitung 50% nilai ATR dari candle yang ditembus dan menyajikannya dalam satuan **pips** dan **points**.
- **Suggested SL Otomatis**:
  - *Bullish Engulfing*: `Low Candle Sebelumnya - 50% ATR`
  - *Bearish Engulfing*: `High Candle Sebelumnya + 50% ATR + Spread`
- **Aturan Harga Fleksibel**:
  - Masukkan harga batas (misal: hanya deteksi Bullish jika harga `< 1.08200` atau Bearish jika harga `> 1.09100`).
  - Ketik **`ALL`** pada kolom harga jika ingin mendeteksi di semua pergerakan harga tanpa batas (*Bebas / Any Price*).
  - Kosongkan kolom jika ingin menonaktifkan salah satu arah (misal hanya memantau Bullish saja).
- **Edit & Hapus Simbol**: Dilengkapi tombol `EDIT` untuk mengubah konfigurasi pantauan yang sudah ada serta tombol `DELETE`.
- **Tombol `TEST ALERT`**: Menguji koneksi notifikasi ke MetaTrader Mobile di HP Anda secara instan.
- **Nama TF di Alert**: Teks alert menyertakan timeframe sumber sinyal (misal `EURUSD (M5)` atau `EURUSD (M1)`), sehingga Anda tahu sinyal mana yang terpicu saat mode dual-TF aktif.

---

### 3. State Persistence (Pengaturan Tidak Hilang)
Sistem penyimpanan persisten otomatis (`.bin`) menjaga data Anda tetap utuh:
- **Tahan Ganti Timeframe & Restart MT5**: Seluruh daftar simbol pantauan di Radar, batas harga filter, posisi tab aktif, mode offset Break-Even, dan trigger Auto-BE yang sedang aktif akan otomatis tersimpan.
- **Auto-Restore saat Re-Attach**: Saat EA ditutup atau dipasang ulang (*re-attach*), EA otomatis membaca data penyimpanan dan mengembalikan kondisi panel persis seperti sebelum ditutup tanpa perlu mengetik ulang.

---

## Panduan Pemasangan

1. **Salin File EA**:
   - Buka MetaTrader 5 di PC Anda.
   - Klik menu **File -> Open Data Folder**.
   - Masuk ke folder **MQL5 -> Experts**.
   - Salin file `TradeManagerEngulfingRadar.mq5` ke dalam folder tersebut.
2. **Kompilasi**:
   - Buka **MetaEditor** (tekan `F4` di MT5).
   - Buka file `TradeManagerEngulfingRadar.mq5`, lalu tekan **Compile** (`F7`).
3. **Pasang ke Chart**:
   - Di jendela Navigator MT5, cari **Expert Advisors -> TradeManagerEngulfingRadar**.
   - Drag & drop EA ke chart simbol apa saja (EA ini bersifat global akun).
   - Pastikan opsi **Allow Algo Trading** (Auto Trading) sudah dicentang.

---

## Menghubungkan Notifikasi ke HP (MetaQuotes ID)

1. Buka aplikasi MetaTrader 5 di smartphone Anda.
2. Masuk ke menu **Pengaturan (Settings) -> Pesan / MetaQuotes ID**.
3. Di MT5 PC, buka menu **Tools -> Options -> Notifications** (atau tekan `Ctrl + O`).
4. Centang **Enable Push Notifications** dan masukkan **MetaQuotes ID** dari HP Anda.
5. Klik tombol **TEST ALERT** pada panel radar di chart untuk memastikan notifikasi sudah masuk ke HP Anda.

---

## Tampilan Visual (Cyberpunk Neon High-Contrast)
Tampilan UI EA dirancang dengan tema gelap kontras tinggi (*pitch black background*) agar sangat jelas terbaca di chart Anda tanpa mengganggu analisa teknikal:
- 🟢 **Neon Mint (`#00E676`)**: Indikator Buy / Bullish Break.
- 🔴 **Laser Scarlet (`#FF2E4D`)**: Indikator Sell / Bearish Break / Stop Loss.
- 🟡 **Luminous Gold (`#FFB300`)**: Status Auto-BE dan Suggested SL.
- 🔵 **Vibrant Cyan (`#00E5FF`)**: Navigasi, judul, dan data ATR.
