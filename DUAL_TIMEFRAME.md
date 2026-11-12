# Logika Dual-Timeframe & Basis ATR

Dokumen ini menjelaskan dua aturan yang dipakai bersama oleh **EngulfingAutoTrader** dan **TradeManagerEngulfingRadar**, karena keduanya harus berperilaku identik agar sinyal radar cocok dengan eksekusi EA.

---

## 1. Basis ATR: `AtrBaseTF()`

Nilai ATR(14) **tidak selalu** diambil dari timeframe rule itu sendiri.

| Timeframe Rule | ATR diambil dari | Pengali |
|---|---|---|
| **M1** | **M5** | **× 0.5** |
| M5 | M5 | × 1.0 |
| M15, M30, H1, H4, D1 | Timeframe rule itu sendiri | × 1.0 |

```mql5
ENUM_TIMEFRAMES AtrBaseTF(const ENUM_TIMEFRAMES rule_tf)
{
   return (rule_tf == PERIOD_M1) ? PERIOD_M5 : rule_tf;
}
```

**Alasan:** ATR M1 terlalu kecil dan terlalu *noisy* untuk dipakai sebagai buffer SL/TP — SL jadi terlalu rapat dan mudah kena *spread*. Dengan meminjam ATR M5 lalu dikali 0.5, Anda mendapat **setengah volatilitas candle 5 menit**, yang setara secara kasar dengan volatilitas beberapa menit namun jauh lebih stabil.

**Dampak:** semua perhitungan SL/TP memakai nilai ATR ini — buffer SL 50% ATR pada radar, jarak TP berdasarkan Risk:Reward, dan ambang batas lonjakan ATR pada Auto Trail.

> Konsistensi wajib: `CalculateATR50()` dan `CalculateATR100()` **harus** selalu dipanggil dengan `AtrBaseTF(tf)`, bukan `tf` langsung. Jika tidak, radar akan menampilkan SL yang berbeda dari yang dipakai EA saat membuka posisi.

---

## 2. Deteksi Dual-Timeframe: `CandidateTFs()`

Hanya **satu** kombinasi yang menerima dua timeframe:

| Timeframe Rule | Timeframe yang dievaluasi | Prioritas |
|---|---|---|
| **M5** | **M5, lalu M1** | M5 diutamakan |
| M1 | M1 saja | Eksklusif |
| M15 dan lainnya | TF itu sendiri saja | Eksklusif |

```mql5
int CandidateTFs(const ENUM_TIMEFRAMES rule_tf, ENUM_TIMEFRAMES &out[])
{
   if(rule_tf == PERIOD_M5)
   {
      ArrayResize(out, 2);
      out[0] = PERIOD_M5;   // priority: the rule's own TF first
      out[1] = PERIOD_M1;   // fallback early signal
      return 2;
   }
   ArrayResize(out, 1);
   out[0] = rule_tf;
   return 1;
}
```

**Alasan:** rule M5 mendapat konfirmasi struktur dari M5, tetapi juga boleh masuk lebih awal bila sinyal M1 sudah muncul — tanpa harus menunggu candle M5. Sinyal M5 tetap diperiksa lebih dulu, sehingga bila keduanya valid pada tick yang sama, M5 yang menang.

**Catatan penting:** rule **M1 tetap eksklusif M1**. M1 tidak "naik" ke M5, karena tujuannya memang menangkap sinyal mikro. Hanya arah M5 → M1 yang diizinkan.

---

## 3. Slot State Terpisah per Signal-TF

Karena satu rule M5 dapat menerima sinyal dari M5 **dan** M1, state internal tidak boleh berupa satu variabel tunggal — jika tidak, sinyal M1 akan memblokir sinyal M5 dan sebaliknya.

Karena itu, variabel berikut disimpan sebagai **array 2 elemen** (indeks `0` = TF utama, indeks `1` = TF fallback):

- `last_bull_bar[2]`
- `last_bear_bar[2]`
- `<arah>_cond_start_time[2]`
- `<arah>_last_checked_bar[2]`

Efeknya:

- Sinyal M1 dan M5 punya "ingatan" masing-masing, jadi keduanya bisa terpicu pada bar yang sama tanpa saling menutup.
- Ada **dua jalur reset** yang harus selalu me-reset **kedua** slot: reset setelah entry sukses, dan reset saat master power / rule di-toggle. Me-reset hanya indeks `0` akan membuat slot M1 menyimpan bar lama dan melewatkan sinyal berikutnya.

---

## 4. Hubungan MAX ORDER vs ENTRY MULTIPLIER

Keduanya mudah tertukar, jadi definisinya ditegaskan di sini:

| Parameter | Arti | Contoh |
|---|---|---|
| **MAX ORDER** | Jumlah **siklus entry** sebelum rule auto-pause | `2` = boleh entry 2 kali, lalu `PAUSED` |
| **ENTRY MULTIPLIER** | Jumlah **posisi per siklus entry** | `3` = sekali sinyal buka 3 posisi |

Contoh kombinasi:

| MAX | MULT | Hasil |
|---|---|---|
| 1 | 3 | 3 posisi, 1 siklus, lalu pause |
| 2 | 1 | 2 posisi, 2 siklus, lalu pause |
| 2 | 3 | 6 posisi (3 per siklus), lalu pause |
| 0 / UNL | berapa pun | Tanpa batas siklus |

Implementasi: counter `orders_opened_count` dinaikkan **satu kali per siklus** (bukan per posisi), dan hanya jika minimal satu order berhasil. Gate MAX ORDER dicek ulang di dalam loop candidate-TF dan langsung `break` bila sudah tercapai — sehingga M5 yang berprioritas tidak bisa terlewati hanya karena M1 sudah memenuhi kuota.

---

## 5. Perilaku Saat Auto-Pause (Penting)

Saat rule mencapai MAX ORDER, yang berhenti **hanya pembukaan order baru**:

```mql5
void OnTick()
{
   if(!g_master_power_enabled) return;

   ProcessAutoTrailSLTP();   // <- di LUAR loop rules, tidak pernah dibatasi MAX ORDER

   for(int r = 0; r < total_rules; r++) { ... }
}
```

| Mekanisme | Saat rule auto-pause |
|---|---|
| Auto Trail SL/TP | **Tetap jalan** setiap tick |
| Radar alert (EA terpisah) | **Tetap jalan** |
| BE engine (Trade Manager) | **Tetap jalan** |
| Pembukaan order baru | **Berhenti** |

Posisi lama tetap terlacak karena `g_tracking_list[]` adalah array global yang terpisah dari `g_rules[]` dan tidak pernah dikosongkan saat pause.

**Reaktivasi rule** me-reset `orders_opened_count` ke `0` (boleh mulai siklus baru), tetapi **tidak** mengubah `g_tracking_list`. Konsekuensinya: posisi lama tetap memakai parameter trail **saat ia dibuka** (`trail_trigger_pct`, `atr_multiplier`, `initial_atr100` disimpan per posisi), sedangkan posisi baru memakai setting terbaru.

Dua catatan tambahan:

- **Master power OFF berbeda dari auto-pause.** `if(!g_master_power_enabled) return;` berada **sebelum** `ProcessAutoTrailSLTP()`, jadi mematikan master power menghentikan trail juga.
- **Trail butuh TP > 0.** Baris `if(cur_tp <= 0) continue;` membuat posisi tanpa TP tidak pernah di-trail, karena trail dihitung dari sisa jarak ke TP.

---

## 6. Format File State (Versioning)

File state biner (`*_State_<login>.bin`) memakai header versi agar upgrade tidak menghapus konfigurasi Anda.

**EngulfingAutoTrader:**
- Versi `2` = format saat ini.
- File lama (v1) **tetap terbaca**: versi dibaca dari posisi integer pertama, sehingga tidak ada pergeseran offset. Jumlah rule dibaca dari posisi yang benar sesuai versi.
- Ada guard yang menolak nilai `total_rules` di luar rentang `0–1000` agar file rusak tidak menyebabkan crash.

**TradeManagerEngulfingRadar:**
- Versi `2` = menambahkan `fixed_price` per item Auto-BE dan `g_be_fixed_price` global (ditulis **di akhir** file, bukan di tengah, agar tetap kompatibel).
- Deteksi versi: integer pertama `2` = v2; nilai `1` atau `2` pada posisi itu juga bisa berasal dari `g_active_tab` file v1, sehingga pembacaan ditangani bercabang.
- Field baru dibaca **hanya jika** `version >= 2`; jika tidak, `fixed_price` diisi `0.0`.

Saat menambah field baru di masa depan: **selalu tambahkan di akhir**, jangan menyisipkan di tengah record, dan naikkan nomor versi.
