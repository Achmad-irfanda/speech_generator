# speech_generator

Aplikasi Flutter untuk membangkitkan suara notifikasi dinamis pada produk InterActive QRIS. Inferensi TTS berjalan sepenuhnya **on-device** lewat ONNX Runtime — tidak ada panggilan ke server TTS mana pun, jadi tidak ada latensi jaringan dan tidak ada teks transaksi yang keluar dari perangkat.

Output utamanya bukan file audio, melainkan **payload konfigurasi** yang disalin ke tim admin QRIS untuk dimasukkan ke dashboard internal. Aplikasi ini dipakai untuk mendengarkan dulu bagaimana sebuah kalimat notifikasi terdengar sebelum konfigurasinya dikirim.

---

## Cara kerja

```
teks  ──▶  preprocess  ──▶  unicode indexer  ──▶  duration_predictor
                                    │                      │
                                    ▼                      ▼
                              text_encoder ──▶ vector_estimator ──▶ vocoder ──▶ PCM
                                                  (N denoising steps)              │
                                                                                   ▼
                                                                              WAV ──▶ just_audio
```

1. **Preprocess** (`preprocessText`) — dekomposisi NFKD, buang emoji, normalisasi tanda baca, lalu bungkus teks dengan tag bahasa `<id>…</id>`.
2. **Indexing** (`UnicodeProcessor`) — tiap rune dipetakan ke integer lewat `unicode_indexer.json`, plus mask panjang.
3. **Duration predictor** — memperkirakan durasi ucapan. Nilai ini dibagi `speed`, jadi speed di UI bekerja dengan mengubah durasi target, bukan me-resample audio.
4. **Text encoder + vector estimator** — latent acak Gaussian didenoise sebanyak `totalStep` iterasi.
5. **Vocoder** — latent menjadi PCM float, ditulis sebagai WAV 16-bit mono.

Teks panjang otomatis dipecah per kalimat (maks 300 karakter; 120 untuk `ko`/`ja`) dan disambung dengan jeda 0,3 detik.

---

## Kebutuhan

| | |
|---|---|
| Flutter | 3.x |
| Dart | 3.10+ jika memakai dot-shorthand `.fromSeed(...)` di `main.dart` |
| Platform | Android, iOS |
| Java / JVM target | 17 (dibutuhkan desugaring `flutter_local_notifications`) |

Dependency utama: `flutter_onnxruntime`, `just_audio`, `path_provider`, `http`, `flutter_local_notifications`, `logger`.

> `path_provider` sebelumnya nebeng sebagai transitive dependency `just_audio`. Sekarang dideklarasikan eksplisit di `pubspec.yaml` — jangan dihapus.

---

## Assets

**Tidak perlu setup manual.** Model ONNX dan voice style di-download otomatis saat aplikasi pertama kali dibuka, lalu disimpan permanen di storage internal aplikasi. Peluncuran berikutnya langsung memakai file lokal tanpa menyentuh jaringan.

Aset **tidak** di-bundle ke dalam APK/IPA — kalau ikut, ukuran build naik sekitar 200 MB.

Base URL bucket:

```
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine
```

Daftar file dan URL-nya tidak ditulis manual di mana-mana. Semuanya diturunkan dari enum `TtsAsset` di `lib/tts_assets/tts_asset_registry.dart`:

```dart
enum TtsAsset {
  vocoder(TtsAssetDir.onnx, 'vocoder.onnx', core: true, estimatedBytes: 55 * 1024 * 1024),
  styleF3(TtsAssetDir.voiceStyles, 'F3.json', estimatedBytes: 64 * 1024),
  // ...
}
```

URL dibentuk `{base}/{dir.folder}/{filename}` — pola yang sama dengan `AssetsManager._buildUrl()` di `interactive_holic_v1`, dan segmen `onnx` / `voice_styles` persis nilai `DirMainPathUsage.name`. Jadi bucket yang sama melayani dua project tanpa penyesuaian path.

Tambah file baru di bucket cukup dengan menambah satu entri enum. Service download, progress bar, notifikasi, dan verifikasi kelengkapan otomatis ikut.

### Struktur di storage

```
<applicationSupportDirectory>/tts-engine/
├── manifest.json                # cache Content-Length per file
├── onnx/
│   ├── tts.json                 # konfigurasi sample_rate, chunk size, latent dim
│   ├── unicode_indexer.json     # peta rune → token id
│   ├── duration_predictor.onnx
│   ├── text_encoder.onnx
│   ├── vector_estimator.onnx
│   └── vocoder.onnx
└── voice_styles/
    ├── F1.json … F5.json        # style vector suara perempuan
    └── M1.json … M5.json        # style vector suara laki-laki
```

### Kenapa `applicationSupport`, bukan external storage

| Kandidat | Masalah |
|---|---|
| `/storage/emulated/0/Download` | Ruang milik user. File manager bisa menghapusnya kapan saja dan app rusak tanpa error yang jelas. Akses penuh di Android 11+ butuh `MANAGE_EXTERNAL_STORAGE`, yang ditolak Play Store untuk use case ini. |
| `getExternalStorageDirectory()` | Android-only, iOS tidak punya padanannya. |
| `getApplicationCacheDirectory()` | Boleh dihapus OS kapan saja, termasuk di tengah sesi. Model 200 MB jadi target purge pertama saat storage menipis. |
| **`getApplicationSupportDirectory()`** ✅ | Sama di Android & iOS, tanpa permission, ikut terhapus saat uninstall, tidak tersentuh file manager. |

> **Catatan iOS yang belum diselesaikan.** `applicationSupport` ikut ter-backup ke iCloud. 200 MB file yang bisa di-download ulang tidak layak makan kuota user, dan bisa jadi temuan saat App Store review. Perbaikannya: set `NSURLIsExcludedFromBackupKey` lewat platform channel di `AppDelegate.swift`.

---

## Assets download service

`lib/tts_assets/` berisi lima file:

| File | Isi |
|---|---|
| `tts_asset_registry.dart` | Enum `TtsAsset` + `TtsAssetDir`. Sumber tunggal daftar file. |
| `assets_download_progress.dart` | `AssetsDownloadProgress` — snapshot state immutable yang di-stream ke UI. |
| `assets_download_service.dart` | Downloader. Tidak punya dependency ke Flutter widget maupun plugin notifikasi. |
| `assets_download_notifier.dart` | Local notification. Opsional, bisa dihapus tanpa menyentuh service. |
| `assets_progress_card.dart` | Widget progress untuk TTSPage. |

### Pemakaian

```dart
final assets = TtsAssetsDownloadService.instance;

// main() — jangan di-await, biar UI langsung tampil
unawaited(assets.ensureReady());

// setelah selesai
final onnxDir = await assets.onnxDirPath;
final tts = await loadTextToSpeech(onnxDir);
```

`ensureReady()` idempotent — panggilan kedua saat masih jalan menempel ke future yang sama. Aman dipanggil dari `main()`, `initState`, tombol retry, dan `AppLifecycleState.resumed` sekaligus.

### Perilaku yang perlu diketahui

**Resume, bukan restart.** Byte ditulis ke `<nama>.part` dengan `FileMode.append` dan header `Range: bytes=N-`. Socket putus di byte ke-80 juta, retry berikutnya lanjut dari 80 juta. Membuang progress saat gagal itu fatal untuk file 200 MB di jaringan seluler.

**Rename atomik.** `.part` baru di-rename ke nama final setelah ukurannya cocok dengan `Content-Length`. ONNX Runtime tidak akan pernah membuka file setengah jadi.

**Server bisa mengabaikan `Range`.** Kalau GCS balas `200` padahal diminta `206`, counter di-reset ke 0 dan file ditulis ulang dari awal. Tanpa penanganan ini progress bar tembus 100% dan file korup karena byte ditumpuk.

**`Accept-Encoding: identity`.** Kalau response di-gzip, `Content-Length` adalah ukuran terkompresi sedangkan yang mendarat di disk ukuran asli — verifikasi ukuran dan resume dua-duanya jadi salah. File `.onnx` sudah padat, gzip tidak menghemat apa pun.

**Emit di-throttle 200 ms.** Emit per-chunk berarti ribuan `setState` per detik. Di device kelas Helio G85 itu menaikkan GC pressure sampai download-nya sendiri melambat. Throttling di sini menaikkan throughput, bukan menahannya.

**Ukuran dari server, bukan hardcode.** `HEAD` sekali di awal, hasilnya di-cache ke `manifest.json`. Peluncuran kedua tidak perlu `HEAD` lagi. `estimatedBytes` di enum hanya bobot sementara sebelum `HEAD` selesai — kalau meleset, progress bar tetap benar setelahnya.

**Core dulu.** Enam file di `onnx/` plus `M1.json` ditandai `core: true` dan di-download lebih dulu. Begitu core lengkap, `coreReady` jadi true dan engine boleh boot sementara sembilan voice style sisanya menyusul.

**Paralel 3, retry 4× dengan backoff** 1s → 2s → 4s. Progress `.part` dipertahankan antar attempt.

### Konfigurasi

```dart
TtsAssetsDownloadService(
  maxConcurrent: 3,
  maxRetries: 4,
  emitInterval: Duration(milliseconds: 200),
  requestTimeout: Duration(seconds: 30),
)
```

Untuk unit test, konstruktornya menerima `http.Client` sendiri.

---

## Setup Android

`android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission
        android:name="android.permission.POST_NOTIFICATIONS"
        tools:targetApi="33"/>
```

`xmlns:tools` wajib ada, kalau tidak manifest merger gagal dengan `MergeFailureException: Error parsing`. `tools:targetApi` murni untuk meredam lint — permission tetap ikut merged manifest, dan Android di bawah API 33 memang mengabaikannya.

`android/app/build.gradle.kts` — project ini pakai **Kotlin DSL**, jadi assignment pakai `=` dan dependency pakai kurung:

```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// level teratas, sejajar dengan android { } — bukan di dalamnya
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

Desugaring dibutuhkan `flutter_local_notifications` 10+.

---

## Struktur kode

```
lib/
├── main.dart            # entry point, bootstrap download service
├── supertonic.dart      # TTSPage — UI
├── helper.dart          # engine TTS, preprocessing, WAV writer
├── amout_masker.dart    # masking nominal untuk payload clipboard
└── tts_assets/
    ├── tts_asset_registry.dart
    ├── assets_download_progress.dart
    ├── assets_download_service.dart
    ├── assets_download_notifier.dart
    └── assets_progress_card.dart
```

`helper.dart` memuat inti engine-nya:

- `TextToSpeech` — orkestrasi keempat session ONNX, chunking, denoising loop
- `UnicodeProcessor` — tokenisasi berbasis rune
- `Style` — pasangan tensor `style_ttl` dan `style_dp`
- `preprocessText` — normalisasi teks + validasi bahasa
- `writeWavFile` — penulis header RIFF/WAVE manual, PCM 16-bit mono

### Resolusi path di loader

Keempat loader sekarang seragam lewat `_readAssetText()` dan `_materializeModel()`:

| Bentuk path | Sumber |
|---|---|
| diawali `assets/` | `rootBundle` (diekstrak ke cache untuk `.onnx`) |
| selain itu | filesystem, dipakai apa adanya |

Artinya path hasil download langsung bisa dioper ke `loadTextToSpeech()`. Untuk path filesystem, model **tidak** di-copy ulang ke cache — sebelumnya `copyModelToFile` menulis ulang 200 MB setiap boot.

Kalau suatu saat model kecil (int8 quantized) mau di-ship di dalam bundle, tinggal aktifkan kembali `assets:` di `pubspec.yaml` dan oper `'assets/onnx'` — dua-duanya tetap didukung.

---

## Pemakaian

1. Buka app. Kalau ini peluncuran pertama, kartu progress di atas halaman menampilkan proses download model. Aplikasi tetap bisa dipakai — teks boleh diisi sambil menunggu, hanya tombol putar yang nonaktif.
2. Tunggu status berubah jadi **Siap**.
3. Isi **Teks Indonesia** dan **Teks Inggris**. Dropdown *Teks instan* menyediakan beberapa kalimat siap pakai untuk kolom Indonesia.
4. Pilih **Voice style**. Setiap preset otomatis menyetel speed dan pitch bawaannya — speed masih bisa digeser manual setelahnya.
5. Tekan **Putar suara Indonesia** atau **Putar suara Inggris**.
6. Tekan **Salin data untuk tim admin QRIS**.

### Bahasa

Engine-nya mendukung 32 bahasa (lihat `availableLangs`), tapi UI sengaja dibatasi ke `id` dan `en` lewat enum `TtsLang` karena hanya dua itu yang dipakai produk.

### Denoising steps

Dikunci di **5** (`TTSPage.kDenoisingSteps`). Nilai lebih tinggi sedikit menaikkan kualitas tapi waktu generate naik linear terhadap jumlah step, karena tiap step adalah satu inferensi penuh `vector_estimator`.

---

## Voice presets

| Preset | Style file | Speed | Pitch |
|---|---|---|---|
| Normal | M1 | 1.05 | 1.00 |
| Funny Girl | F1 | 1.12 | 1.25 |
| Funny Girl B | F2 | 1.15 | 1.20 |
| Funny Girl C | F3 | 1.18 | 1.30 |
| Funny Girl D | F4 | 1.20 | 1.15 |
| Funny Girl E | F5 | 1.15 | 1.25 |
| Funny Man | M1 | 1.10 | 0.95 |
| Funny Man B | M2 | 1.12 | 0.90 |
| Funny Man C | M3 | 1.15 | 0.85 |
| Funny Man D | M4 | 1.20 | 0.92 |
| Funny Man E | M5 | 1.10 | 0.88 |
| Kawaii | F1 | 1.20 | 1.50 |
| Deep Lady | F3 | 0.95 | 0.85 |
| Energetic | F2 | 1.30 | 1.20 |

**Speed** diterapkan di tingkat model (membagi durasi prediksi). **Pitch** diterapkan di tingkat pemutaran lewat `AudioPlayer.setPitch()` — jadi pitch memengaruhi apa yang kamu dengar, tapi **tidak** ikut tersimpan ke dalam file WAV.

Preset yang style file-nya belum selesai di-download akan ditolak dengan pesan, bukan crash. M1 ditandai core, jadi preset Normal selalu tersedia paling awal.

---

## Payload clipboard

```
note: tolong kirimkan copy data ini ke tim admin qris ya untuk di tambahkan melalui dashboard internal.

teks inggris: "Payment of | received"
teks indonesia: "Hore, pembayaran | diterima"

denoising steps: 5

speed: 1.05

voice styles: Normal
```

### Masking nominal

Nominal uang diganti placeholder `|` supaya dashboard bisa menyisipkan angka transaksi yang sebenarnya saat runtime. Aturannya berbeda untuk dua bentuk:

- **Angka** dikenali berdiri sendiri: `5000`, `50.000`, `Rp12.500`, `IDR 1,250,000`.
- **Kata** wajib diikuti penanda mata uang (`rupiah` / `rp` / `idr` / `perak`): `lima ribu rupiah` ✅, `limaribu rupiah` ✅, `fifty thousand rupiah` ✅, `limaribu` ❌.

Syarat penanda mata uang itu disengaja. Tanpanya, kata seperti "dua", "satu", dan "ratus" terlalu umum di bahasa Indonesia — kalimat `"dua kali percobaan gagal"` akan ikut termakan jadi `"| kali percobaan gagal"`.

Masking **hanya** berlaku pada payload clipboard. Teks yang dikirim ke model tetap memakai nominal aslinya, jadi hasil yang kamu dengar adalah kalimat utuh.

Panel *Yang akan disalin* di atas tombol salin menampilkan hasil masking secara live. Gunakan itu untuk memeriksa salah deteksi — misalnya `"jam 10:30"` akan menjadi `"jam |:|"` karena `10` dan `30` sama-sama terbaca angka.

---

## Troubleshooting

| Gejala | Penyebab |
|---|---|
| Kartu progress mentok di satu angka | Koneksi putus. Service retry 4× dengan backoff sebelum menyerah; setelah itu tombol **Coba lagi** muncul dan melanjutkan dari byte terakhir, bukan dari nol. |
| `Asset TTS tidak ditemukan` | `loadTextToSpeech()` dipanggil sebelum `ensureReady()` selesai. Cek gating di `_watchAssets()`. |
| Download selalu mulai dari 0 | Server tidak menghormati header `Range`. Cek apakah ada proxy/CDN di depan bucket. |
| `MergeFailureException: Error parsing AndroidManifest.xml` | `xmlns:tools` belum dideklarasikan di tag `<manifest>` padahal `tools:targetApi` dipakai. |
| `Unresolved reference: coreLibraryDesugaringEnabled` | Syntax Groovy dipakai di `build.gradle.kts`. Lihat bagian Setup Android. |
| Notifikasi progress tidak muncul di Android 13+ | `POST_NOTIFICATIONS` ditolak user. Download tetap jalan; progress tetap terlihat di halaman TTS. |
| Notifikasi progress tidak muncul di iOS | Wajar. UNNotification tidak punya progress bar — iOS hanya menampilkan notifikasi mulai dan selesai. |
| `ArgumentError: Invalid language` | Kode bahasa di luar `availableLangs`; `TtsLang` seharusnya sudah mencegah ini. |
| `Model tidak menghasilkan audio` | Teks habis dibuang saat preprocessing (isinya hanya simbol atau emoji). |
| Voice style gagal dimuat | File style-nya belum selesai di-download. Tunggu progress mencapai 100%. |
| Generate terasa lambat | Naikkan dulu curiganya ke jumlah denoising step dan panjang teks, bukan ke ukuran model. |

Untuk memaksa unduh ulang dari nol: `TtsAssetsDownloadService.instance.clear()`.

---

## Roadmap

- [x] Ekstraksi asset otomatis saat pertama dijalankan, supaya loader path konsisten
- [ ] **Quantization fp32 → int8.** Pengungkit terbesar yang belum disentuh — memotong ukuran model sekitar 4×, dari ~200 MB ke ~50 MB. Seluruh kompleksitas download di atas jadi masalah yang jauh lebih kecil kalau ini duluan dikerjakan.
- [ ] **Verifikasi checksum.** Sekarang hanya membandingkan ukuran byte. File yang ukurannya pas tapi isinya korup tetap lolos. Butuh `sha256` per file tersedia di bucket, lalu tambah field di `TtsAsset`.
- [ ] **Versioning model.** Belum ada mekanisme invalidasi kalau model baru di-upload dengan nama file sama. Opsi paling ringan: satu `version.json` di root bucket, mismatch → `clear()` + unduh ulang.
- [ ] **Bucket region `asia-southeast2`.** Mengurangi latensi unduh untuk user Indonesia.
- [ ] `NSURLIsExcludedFromBackupKey` di iOS supaya model tidak ikut backup iCloud
- [ ] Export MP3 dan share sheet (butuh encoder native — `flutter_lame` kandidat paling ringan; catatan lisensinya LGPL-3.0)
- [ ] Daftar teks instan untuk bahasa Inggris
- [ ] Unit test untuk `AmountMasker`
- [ ] Unit test untuk `TtsAssetsDownloadService` (resume, `Range` diabaikan, `.part` korup)

---

## Contributors

- **Achmad Irfanda** — Mobile Developer · [@Achmad-irfanda](https://github.com/Achmad-irfanda)