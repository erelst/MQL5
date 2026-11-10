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

---

### 2. Engulfing Radar & Mobile Push Alert (Tab 2)
- **Real-time Tick-Level Detection**: Pola dideteksi langsung saat harga running menembus (*breakout*) High/Low candle sebelumnya tanpa perlu menunggu candle selesai (*close*).
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
