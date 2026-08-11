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

Dependency utama: `flutter_onnxruntime`, `just_audio`, `path_provider`, `logger`.

---

## Setup assets

Model ONNX dan voice style **tidak ikut di dalam repo** karena ukurannya. Kalau folder `assets/` kamu kosong, unduh dari bucket berikut.

Base URL:

```
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine
```

Segmen setelah base URL mengikuti nama folder, jadi struktur di bucket sama persis dengan struktur lokal — tinggal copy apa adanya.

### Model ONNX

```
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/tts.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/unicode_indexer.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/duration_predictor.onnx
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/text_encoder.onnx
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/vector_estimator.onnx
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/onnx/vocoder.onnx
```

### Voice styles

```
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/M1.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/M2.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/M3.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/M4.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/M5.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/F1.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/F2.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/F3.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/F4.json
https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine/voice_styles/F5.json
```

> **Catatan.** Di aplikasi produksi (`interactive_holic_v1`), URL ini dibentuk oleh `AssetsManager._buildUrl()` dengan pola `{Config.onnxAssets}/{DirMainPathUsage.name}/{relativePath}`, dan daftar filenya ada di `AssetRegistry`. Segmen folder di atas — `onnx` dan `voice_styles` — persis nilai `DirMainPathUsage.name`, jadi asset yang sama bisa dipakai kedua project tanpa penyesuaian path.

Struktur yang diharapkan:

```
assets/
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

### ⚠️ Catatan penting soal path

Loader saat ini **tidak konsisten** dan ini bukan bug yang sudah diperbaiki:

| Loader | Sumber |
|---|---|
| `_loadOnnxAll` (4 file `.onnx`) | `File(path)` — filesystem |
| `_loadCfgs` (`tts.json`) | `File(path)` — filesystem |
| `UnicodeProcessor.load` | `rootBundle` jika path diawali `assets/` |
| `loadVoiceStyle` | `rootBundle` jika path diawali `assets/` |

Artinya pemanggilan `loadTextToSpeech('assets/onnx')` mencari file `.onnx` dan `tts.json` sebagai **path filesystem relatif terhadap working directory proses**, bukan sebagai Flutter bundle asset. Di device, itu akan gagal kecuali file-nya sudah diekstrak duluan ke storage.

Helper `copyModelToFile()` sudah tersedia untuk keperluan ini tapi belum dipanggil dari mana pun. Kalau kamu dapat `Exception: ONNX model not found`, ini penyebabnya. Dua jalan keluar: ekstrak asset ke `getApplicationCacheDirectory()` saat pertama kali app dijalankan lalu oper path absolutnya, atau seragamkan semua loader supaya memakai `rootBundle`.

`unicode_indexer.json` dan voice style tetap perlu terdaftar di `pubspec.yaml` karena keduanya dibaca dari bundle:

```yaml
flutter:
  assets:
    - assets/onnx/
    - assets/voice_styles/
```

---

## Struktur kode

```
lib/
├── main.dart            # entry point, MaterialApp
├── supertonic.dart      # TTSPage — UI
├── helper.dart          # engine TTS, preprocessing, WAV writer
└── amount_masker.dart   # masking nominal untuk payload clipboard
```

`helper.dart` memuat inti engine-nya:

- `TextToSpeech` — orkestrasi keempat session ONNX, chunking, denoising loop
- `UnicodeProcessor` — tokenisasi berbasis rune
- `Style` — pasangan tensor `style_ttl` dan `style_dp`
- `preprocessText` — normalisasi teks + validasi bahasa
- `writeWavFile` — penulis header RIFF/WAVE manual, PCM 16-bit mono

---

## Pemakaian

1. Buka app, tunggu status berubah jadi **Siap** (pemuatan model perlu beberapa detik).
2. Isi **Teks Indonesia** dan **Teks Inggris**. Dropdown *Teks instan* menyediakan beberapa kalimat siap pakai untuk kolom Indonesia.
3. Pilih **Voice style**. Setiap preset otomatis menyetel speed dan pitch bawaannya — speed masih bisa digeser manual setelahnya.
4. Tekan **Putar suara Indonesia** atau **Putar suara Inggris** untuk mendengarkan hasilnya.
5. Tekan **Salin data untuk tim admin QRIS**.

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
| `Exception: ONNX model not found` | Lihat bagian ⚠️ path di atas — model dicari di filesystem, bukan bundle |
| `ArgumentError: Invalid language` | Kode bahasa di luar `availableLangs`; `TtsLang` seharusnya sudah mencegah ini |
| `Model tidak menghasilkan audio` | Teks habis dibuang saat preprocessing (isinya hanya simbol atau emoji) |
| Voice style gagal dimuat | File `assets/voice_styles/{F1…M5}.json` belum terdaftar di `pubspec.yaml` |
| Generate terasa lambat | Naikkan dulu curiganya ke jumlah denoising step dan panjang teks, bukan ke ukuran model |

---

## Roadmap

- [ ] Ekstraksi asset otomatis saat pertama dijalankan, supaya loader path konsisten
- [ ] Export MP3 dan share sheet (butuh encoder native — `flutter_lame` kandidat paling ringan; catatan lisensinya LGPL-3.0)
- [ ] Daftar teks instan untuk bahasa Inggris
- [ ] Unit test untuk `AmountMasker`

---

## Contributors

- **Achmad Irfanda** — Mobile Developer · [@Achmad-irfanda](https://github.com/Achmad-irfanda)
