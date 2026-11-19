# Trade Manager & Reversal Radar (MQL5)

Tool Expert Advisor (EA) multi-simbol untuk MetaTrader 5 dengan dashboard interaktif on-chart. Didesain untuk mempermudah Anda mengelola banyak posisi trading sekaligus (*bulk order manager*), mengamankan profit secara instan atau otomatis (*Break-Even engine*), serta memantau pola **Multi-Signal Reversal** secara real-time tick-by-tick di berbagai pasangan mata uang.

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

---

### 2. Multi-Signal Reversal Radar & Mobile Push Alert (Tab 2)
- **Multi-Signal Detection**: Mendukung 3 sinyal pembalikan arah utama yang identik dengan `MultiRuleAutoTrader`:
  - **Strong Engulfing Reversal (`[ENG]`)**: Lilin menelan candle sebelumnya dengan rasio body valid.
  - **Strong Hammer & Strong Shooting Star (`[HMR/SS]`)**: Penolakan harga ekstrem dengan panjang shadow $\ge 3\times$ body dan shadow berlawanan $\le 0.8\times$ body.
  - **Stochastic (14,1,3) + Heikin Ashi (`[STOCH+HA]`)**: Konfirmasi momentum oversold/overbought dan perubahan ukuran/warna candle Heikin Ashi.
- **Mode Sinyal ANY (OR) vs COMBO (AND)**:
  - **ANY (OR)**: Memicu alert jika salah satu dari sinyal aktif terpenuhi.
  - **COMBO (AND)**: Memicu alert jika semua sinyal aktif terpenuhi secara serempak. Eksklusi mutual berlaku antara Engulfing dan Hammer/Shooting Star.
- **Tombol Active / Pause per Baris Watchlist**:
  - Setiap simbol pada daftar radar memiliki tombol saklar status `[ACTIVE]` (hijau neon) dan `[PAUSED]` (merah).
  - Anda dapat menghentikan sementara pemantauan simbol tertentu tanpa menghapusnya dari radar.
- **Kompensasi Spread Broker Otomatis pada Alert SELL**:
  - Suggested SL untuk Sell otomatis memperhitungkan selisih spread broker: `High + 50% ATR + Spread` sehingga akurat terhadap eksekusi riil.
- **Standarisasi Delay (% TF Progress & TF Close)**:
  - **% TF Progress Delay**: Menunggu lilin berjalan mencapai umur tertentu (misal 30% dari durasi candle) sebelum alert terkirim.
  - **TF Close Mode**: Alert hanya dikirim saat candle yang dipantau telah resmi ditutup.
- **Dual-Timeframe (M5 + M1)**: Untuk pantauan **M5**, radar juga memantau **M1** secara paralel.
- **Aturan Harga Fleksibel (Price Bounds)**:
  - Mendukung operator pembanding (`<`, `>`, `<=`, `>=`), rentang harga (`Min-Max`), serta kata kunci `ALL` untuk deteksi di segala level harga.
- **Tombol `TEST ALERT`**: Menguji koneksi notifikasi push ke MetaTrader Mobile di HP Anda secara instan.

---

### 3. State Persistence (Pengaturan Tidak Hilang)
Sistem penyimpanan persisten otomatis (`.bin`) menjaga data Anda tetap utuh:
- Disimpan dalam file binary format v6: `TMRR_State_<login>.bin` (dengan fallback otomatis ke `TMER_State_<login>.bin`).
- Seluruh daftar simbol pantauan, status `active` / `paused`, checkbox sinyal aktif, mode sinyal ANY/COMBO, dan mode delay tersimpan permanen.

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
