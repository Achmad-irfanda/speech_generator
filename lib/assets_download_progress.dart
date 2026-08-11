import 'package:speech_generator/tts_assets_registry.dart';

enum AssetsDownloadStatus {
  /// Belum pernah dijalankan.
  idle,

  /// Cek file lokal + resolve ukuran remote (HEAD).
  checking,

  /// Sedang menarik byte.
  downloading,

  /// Semua file lengkap dan ukurannya cocok.
  ready,

  /// Ada file yang gagal setelah semua retry habis.
  failed,

  /// Dibatalkan lewat [TtsAssetsDownloadService.cancel].
  cancelled,
}

/// Snapshot immutable state download. Dikirim lewat stream ke UI.
class AssetsDownloadProgress {
  const AssetsDownloadProgress({
    required this.status,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.currentAsset,
    this.coreReady = false,
    this.failures = const {},
    this.message,
  });

  const AssetsDownloadProgress.idle() : this(status: AssetsDownloadStatus.idle);

  final AssetsDownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final int completedFiles;
  final int totalFiles;

  /// File yang paling terakhir menerima byte. Untuk label "Mengunduh vocoder.onnx".
  final TtsAsset? currentAsset;

  /// True kalau seluruh aset `core` sudah lengkap — engine boleh boot walau
  /// voice style sisanya masih jalan.
  final bool coreReady;

  /// Asset -> pesan error terakhir, hanya terisi kalau [status] == failed.
  final Map<TtsAsset, String> failures;

  final String? message;

  bool get isReady => status == AssetsDownloadStatus.ready;

  bool get isWorking =>
      status == AssetsDownloadStatus.checking ||
      status == AssetsDownloadStatus.downloading;

  /// 0.0 – 1.0. Balik 0 kalau total belum diketahui supaya progress bar
  /// bisa dirender indeterminate.
  double get fraction {
    if (totalBytes <= 0) return 0;
    final value = downloadedBytes / totalBytes;
    return value.isNaN ? 0 : value.clamp(0.0, 1.0);
  }

  int get percent => (fraction * 100).round();

  /// "128,4 MB / 210,7 MB"
  String get readableBytes =>
      '${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}';

  /// Label siap pakai untuk banner / notifikasi.
  String get headline => switch (status) {
    AssetsDownloadStatus.idle => 'Model belum disiapkan',
    AssetsDownloadStatus.checking => 'Memeriksa model TTS...',
    AssetsDownloadStatus.downloading =>
      'Menyiapkan model TTS ($percent%)'
          '${currentAsset != null ? ' — ${currentAsset!.label}' : ''}',
    AssetsDownloadStatus.ready => 'Model TTS siap',
    AssetsDownloadStatus.failed => message ?? 'Gagal menyiapkan model TTS',
    AssetsDownloadStatus.cancelled => 'Penyiapan model dibatalkan',
  };

  AssetsDownloadProgress copyWith({
    AssetsDownloadStatus? status,
    int? downloadedBytes,
    int? totalBytes,
    int? completedFiles,
    int? totalFiles,
    TtsAsset? currentAsset,
    bool? coreReady,
    Map<TtsAsset, String>? failures,
    String? message,
  }) {
    return AssetsDownloadProgress(
      status: status ?? this.status,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFiles: totalFiles ?? this.totalFiles,
      currentAsset: currentAsset ?? this.currentAsset,
      coreReady: coreReady ?? this.coreReady,
      failures: failures ?? this.failures,
      message: message ?? this.message,
    );
  }

  @override
  String toString() =>
      'AssetsDownloadProgress(${status.name}, $percent%, '
      '$completedFiles/$totalFiles files)';
}

String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : decimals)} ${units[unit]}';
}