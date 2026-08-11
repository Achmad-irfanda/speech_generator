/// Registry aset TTS.
///
/// Ini satu-satunya tempat daftar file didefinisikan. Kalau bucket bertambah
/// file baru, cukup tambah entri di enum [TtsAsset] — service download, UI
/// progress, dan verifikasi kelengkapan otomatis ikut.
library;

/// Base URL bucket GCS. Sengaja tanpa trailing slash.
///
/// Pola URL: `{base}/{folder}/{filename}` — sama persis dengan
/// `AssetsManager._buildUrl()` di `interactive_holic_v1`, jadi asset yang sama
/// bisa dipakai dua project tanpa penyesuaian path.
const String kTtsAssetsBaseUrl =
    'https://storage.googleapis.com/storage_interactive/interactive/mobile/tts-engine';

/// Folder di bucket. Nilainya identik dengan `DirMainPathUsage.name`
/// di project produksi.
enum TtsAssetDir {
  onnx('onnx'),
  voiceStyles('voice_styles');

  const TtsAssetDir(this.folder);

  final String folder;
}

/// Satu file yang harus tersedia di local storage sebelum engine bisa jalan.
///
/// [core] menandai file yang dibutuhkan `loadTextToSpeech()` untuk boot.
/// Voice style selain M1 tidak core: engine sudah bisa dipakai walau style
/// lain masih men-download di belakang.
///
/// [estimatedBytes] cuma dipakai sebagai bobot progress awal sebelum
/// `Content-Length` asli didapat dari server. Setelah download pertama,
/// ukuran asli disimpan ke `manifest.json` dan estimasi ini tidak dipakai lagi.
/// Jadi tidak masalah kalau angkanya meleset — tapi kalau kamu tahu ukuran
/// persisnya, update saja supaya progress bar akurat sejak detik pertama.
enum TtsAsset {
  // --- Core engine ---------------------------------------------------------
  ttsConfig(
    TtsAssetDir.onnx,
    'tts.json',
    core: true,
    estimatedBytes: 4 * 1024,
  ),
  unicodeIndexer(
    TtsAssetDir.onnx,
    'unicode_indexer.json',
    core: true,
    estimatedBytes: 512 * 1024,
  ),
  durationPredictor(
    TtsAssetDir.onnx,
    'duration_predictor.onnx',
    core: true,
    estimatedBytes: 20 * 1024 * 1024,
  ),
  textEncoder(
    TtsAssetDir.onnx,
    'text_encoder.onnx',
    core: true,
    estimatedBytes: 45 * 1024 * 1024,
  ),
  vectorEstimator(
    TtsAssetDir.onnx,
    'vector_estimator.onnx',
    core: true,
    estimatedBytes: 90 * 1024 * 1024,
  ),
  vocoder(
    TtsAssetDir.onnx,
    'vocoder.onnx',
    core: true,
    estimatedBytes: 55 * 1024 * 1024,
  ),

  // --- Voice styles --------------------------------------------------------
  // M1 core karena VoiceCharacter.normal (default UI) memakainya.
  styleM1(
    TtsAssetDir.voiceStyles,
    'M1.json',
    core: true,
    estimatedBytes: 64 * 1024,
  ),
  styleM2(TtsAssetDir.voiceStyles, 'M2.json', estimatedBytes: 64 * 1024),
  styleM3(TtsAssetDir.voiceStyles, 'M3.json', estimatedBytes: 64 * 1024),
  styleM4(TtsAssetDir.voiceStyles, 'M4.json', estimatedBytes: 64 * 1024),
  styleM5(TtsAssetDir.voiceStyles, 'M5.json', estimatedBytes: 64 * 1024),
  styleF1(TtsAssetDir.voiceStyles, 'F1.json', estimatedBytes: 64 * 1024),
  styleF2(TtsAssetDir.voiceStyles, 'F2.json', estimatedBytes: 64 * 1024),
  styleF3(TtsAssetDir.voiceStyles, 'F3.json', estimatedBytes: 64 * 1024),
  styleF4(TtsAssetDir.voiceStyles, 'F4.json', estimatedBytes: 64 * 1024),
  styleF5(TtsAssetDir.voiceStyles, 'F5.json', estimatedBytes: 64 * 1024);

  const TtsAsset(
    this.dir,
    this.filename, {
    this.core = false,
    this.estimatedBytes = 0,
  });

  final TtsAssetDir dir;
  final String filename;
  final bool core;
  final int estimatedBytes;

  /// `onnx/vocoder.onnx`
  String get relativePath => '${dir.folder}/$filename';

  /// URL penuh di bucket.
  String get remoteUrl => '$kTtsAssetsBaseUrl/$relativePath';

  /// Label pendek untuk UI / notifikasi.
  String get label => filename;

  static List<TtsAsset> get coreAssets =>
      values.where((asset) => asset.core).toList(growable: false);

  /// Mapping dari `VoicePreset.styleFile` ('M1', 'F3', …) ke entri enum.
  ///
  /// Dipakai supaya UI bisa cek "style yang dipilih user sudah ke-download
  /// belum" tanpa hardcode nama file di dua tempat.
  static TtsAsset? styleFor(String styleFileName) {
    final target = '$styleFileName.json';
    for (final asset in values) {
      if (asset.dir == TtsAssetDir.voiceStyles && asset.filename == target) {
        return asset;
      }
    }
    return null;
  }
}