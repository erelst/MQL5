# MQL5 Cyberpunk Neon Expert Advisors & Trade Manager

Kumpulan Expert Advisor (EA) MQL5 kustom dengan desain antarmuka cyberpunk neon hitam pekat, deteksi *Strong Engulfing* tingkat tick secara real-time, manajemen multi-symbol/multi-rule, Auto Trail SL/TP, Entry Multiplier, Entry Delay, dan persistensi state biner yang tangguh.

---

## 1. Engulfing Auto Trader (`EngulfingAutoTrader.mq5`)

EA otomatis multi-aturan (*Multi-Rule List*) untuk eksekusi posisi berdasarkan pola Strong Engulfing dan filter tingkat lanjut.

### Fitur Utama:
- **Multi-Rule Management**: Menambah, mengedit, menghapus, dan mengaktifkan/mempaus (*active/paused*) banyak rule sekaligus.
- **Paging Dinamis**: Tombol navigasi `PREV` / `NEXT` otomatis muncul saat rule melebihi kapasitas tampilan per halaman (5 rule).
- **Direction Filter**: Mendukung `BUY & SELL`, `BUY ONLY`, dan `SELL ONLY` dengan pembersihan label sisi harga yang tidak relevan secara otomatis.
- **Flexible Price Bounds**: Filter harga kustom menggunakan operator (`<`, `>`, `<=`, `>=`, rentang `Min-Max` cth: `4040-4078`), atau `ALL`/`BEBAS`.
- **Max Orders & Auto-Pause**: Batasan jumlah open order per rule (cth: `1x PAUSE`), di mana rule otomatis berpindah status menjadi `PAUSED` dan memperbarui tampilan secara real-time setelah target tercapai.
- **Entry Multiplier (`MULT`)**: Memungkinkan pembukaan beberapa posisi sekaligus per sinyal (cth: `3x` open order serentak).
- **Entry Delay & Confirmation**: 
  - **Mode Detik (`Seconds`)**: Syarat harus bertahan terus-menerus tanpa terputus selama $N$ detik (default: 5 detik, 0 = instan). Jika terputus sekejap, timer direset dari awal. Kolom `SEC:` hanya muncul di mode ini.
  - **Mode Close Candle (`TF Close`)**: Sinyal divalidasi pada candle yang **baru saja tertutup** (bar index 1). Mode ini sengaja melewati pemeriksaan candle berjalan, karena candle yang belum tutup bisa berubah bentuk sampai detik terakhir. **Close yang dipakai mengikuti TF sinyalnya**: sinyal M1 divalidasi dengan close M1, sinyal M5 dengan close M5. Kolom `SEC:` disembunyikan di mode ini.
- **Auto Trail SL & TP Engine**: Menggeser Stop Loss ke Break-Even (disesuaikan dengan spread) dan volatilitas ATR saat mendekati Take Profit.
- **Persistent State Storage**: Menyimpan seluruh konfigurasi rule ke file biner per akun secara aman.

---

## 2. Trade Manager & Engulfing Radar (`TradeManagerEngulfingRadar.mq5`)

Dashboard manajemen posisi terbuka dan pemantau multi-symbol real-time.

### Fitur Utama:
- **Order Manager Tab**: Pilih posisi/order secara selektif atau massal (`SELECT ALL`, `CLEAR`), atur SL/TP massal, dan Auto Break-Even (BE).
- **Engulfing Radar Tab**: Pantau berbagai simbol dan timeframe secara simultan dengan deteksi *Strong Engulfing* real-time.
- **Pagination Dinamis**: Navigasi halaman otomatis untuk daftar posisi dan watchlist radar.
- **Persistensi State**: Menyimpan watchlist radar dan konfigurasi Auto-BE secara permanen.

---

## Struktur Repository

```
README.md                          (file ini)
DUAL_TIMEFRAME.md                  (dokumen lintas-EA: ATR base TF & duel M5/M1)
test_autotrader.py                 (self-check logika sinyal & entry AutoTrader)
.gitignore
EngulfingAutoTrader/
   EngulfingAutoTrader.mq5
   README.md
   EngulfingAutoTrader_preview.html
TradeManagerEngulfingRadar/
   TradeManagerEngulfingRadar.mq5
   README.md
   dashboard_preview.html
```

Satu file `.mq5` hanya ada di folder proyeknya masing-masing.

---

## Panduan Instalasi & Penggunaan
1. Letakkan file `.mq5` ke dalam folder `MQL5\Experts\` di MetaTrader 5 Anda.
2. Compile melalui MetaEditor (F7).
3. Lampirkan pada chart dengan mengaktifkan *Allow Algo Trading*.
4. Nikmati antarmuka dashboard cyberpunk neon interaktif langsung pada chart.
