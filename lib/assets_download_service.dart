import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:speech_generator/tts_assets_registry.dart';
import 'assets_download_progress.dart';

/// Men-download seluruh aset di [TtsAsset] ke application support directory,
/// lalu mengekspos path lokalnya supaya `loadTextToSpeech()` bisa dipanggil
/// dengan path filesystem (bukan bundle).
///
/// Karakteristik yang disengaja:
///
/// * **Resume**, bukan restart. Byte ditulis ke `<file>.part` dengan
///   `FileMode.append` + header `Range`. Di jaringan seluler Indonesia,
///   membuang 80 MB progress cuma karena socket putus itu fatal.
/// * **Atomic**. `.part` baru di-rename ke nama final setelah ukurannya
///   diverifikasi. Jadi file setengah jadi tidak akan pernah terbaca sebagai
///   model valid oleh ONNX Runtime.
/// * **Throttled emit**. Progress dipush maksimal tiap [emitInterval].
///   Emit per-chunk bikin setState badai dan naikin GC pressure di device
///   low-end — throttling di sini justru menaikkan throughput, bukan menahan.
/// * **Ukuran dari server**. Total byte diambil dari `Content-Length` (HEAD),
///   disimpan ke `manifest.json`, jadi progress akurat tanpa hardcode ukuran.
/// * **Idempotent**. [ensureReady] aman dipanggil berkali-kali; panggilan
///   kedua saat masih jalan akan menempel ke future yang sama.
class TtsAssetsDownloadService {
  TtsAssetsDownloadService({
    http.Client? client,
    this.maxConcurrent = 3,
    this.maxRetries = 4,
    this.emitInterval = const Duration(milliseconds: 200),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  /// Instance global. Dipakai bareng oleh TTSPage dan layer notifikasi.
  static final TtsAssetsDownloadService instance = TtsAssetsDownloadService();

  final http.Client _client;
  final int maxConcurrent;
  final int maxRetries;
  final Duration emitInterval;
  final Duration requestTimeout;

  final StreamController<AssetsDownloadProgress> _controller =
      StreamController<AssetsDownloadProgress>.broadcast();

  AssetsDownloadProgress _value = const AssetsDownloadProgress.idle();

  Directory? _root;
  Future<AssetsDownloadProgress>? _running;
  bool _cancelled = false;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Ukuran remote per asset (nama enum -> bytes), di-cache ke manifest.json.
  final Map<String, int> _sizes = <String, int>{};

  /// Byte yang sudah ada di disk per asset. Dipakai untuk hitung total,
  /// tahan terhadap rollback saat server mengabaikan header Range.
  final Map<TtsAsset, int> _bytesOnDisk = <TtsAsset, int>{};

  /// Asset yang file finalnya sudah ada dan terverifikasi.
  final Set<TtsAsset> _completed = <TtsAsset>{};

  final Map<TtsAsset, String> _failures = <TtsAsset, String>{};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// State terakhir. Pakai ini sebagai `initialData` di StreamBuilder supaya
  /// listener yang telat pasang tidak melihat layar kosong.
  AssetsDownloadProgress get value => _value;

  Stream<AssetsDownloadProgress> get progress => _controller.stream;

  /// Root aset lokal, mis. `/data/user/0/<pkg>/files/tts-engine`.
  Future<Directory> resolveRoot() async {
    final cached = _root;
    if (cached != null) return cached;

    // Kenapa applicationSupport, bukan external storage:
    //  - iOS tidak punya konsep external storage sama sekali.
    //  - Di Android scoped storage, /Download itu ruang milik user; 200 MB
    //    file model di sana bisa kehapus file manager dan bikin app rusak
    //    tanpa jejak.
    //  - applicationSupport ikut kehapus saat uninstall — itu yang kita mau.
    //  - Cache directory bisa di-purge OS di tengah sesi, jadi dihindari.
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/tts-engine');
    for (final sub in TtsAssetDir.values) {
      await Directory('${dir.path}/${sub.folder}').create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  /// Path folder untuk `loadTextToSpeech(onnxDirPath)`.
  Future<String> get onnxDirPath async =>
      '${(await resolveRoot()).path}/${TtsAssetDir.onnx.folder}';

  /// Path folder untuk `loadVoiceStyle(['$voiceStyleDirPath/M1.json'])`.
  Future<String> get voiceStyleDirPath async =>
      '${(await resolveRoot()).path}/${TtsAssetDir.voiceStyles.folder}';

  Future<String> localPathOf(TtsAsset asset) async =>
      '${(await resolveRoot()).path}/${asset.relativePath}';

  /// True kalau seluruh aset lengkap. Cek ukuran, bukan cuma `exists()` —
  /// file 0 byte hasil download gagal juga "exists".
  Future<bool> isComplete({bool coreOnly = false}) async {
    await resolveRoot();
    await _loadManifest();
    final list = coreOnly ? TtsAsset.coreAssets : TtsAsset.values;
    for (final asset in list) {
      if (!await _isFileValid(asset)) return false;
    }
    return true;
  }

  /// Jalankan (atau lanjutkan) download. Aman dipanggil dari initState,
  /// dari resume lifecycle, atau dari tombol retry.
  Future<AssetsDownloadProgress> ensureReady({bool force = false}) {
    final running = _running;
    if (running != null) return running;

    final future = _run(force: force);
    _running = future;
    return future.whenComplete(() {
      if (identical(_running, future)) _running = null;
    });
  }

  void cancel() => _cancelled = true;

  /// Hapus semua aset lokal. Untuk tombol "Unduh ulang model".
  Future<void> clear() async {
    cancel();
    final root = await resolveRoot();
    if (root.existsSync()) await root.delete(recursive: true);
    _root = null;
    _sizes.clear();
    _bytesOnDisk.clear();
    _completed.clear();
    _failures.clear();
    await resolveRoot();
    _emit(const AssetsDownloadProgress.idle(), force: true);
  }

  void dispose() {
    _client.close();
    _controller.close();
  }

  // ---------------------------------------------------------------------------
  // Orkestrasi
  // ---------------------------------------------------------------------------

  Future<AssetsDownloadProgress> _run({required bool force}) async {
    _cancelled = false;
    _failures.clear();

    _emit(
      const AssetsDownloadProgress(
        status: AssetsDownloadStatus.checking,
        totalFiles: 0,
      ),
      force: true,
    );

    try {
      await resolveRoot();
      await _loadManifest();

      if (force) {
        for (final asset in TtsAsset.values) {
          final file = File(await localPathOf(asset));
          if (file.existsSync()) await file.delete();
        }
      }

      // 1. Petakan apa yang sudah ada.
      final pending = <TtsAsset>[];
      _bytesOnDisk.clear();
      _completed.clear();
      for (final asset in TtsAsset.values) {
        if (await _isFileValid(asset)) {
          _bytesOnDisk[asset] = await File(await localPathOf(asset)).length();
          _completed.add(asset);
        } else {
          _bytesOnDisk[asset] = await _partLength(asset);
          pending.add(asset);
        }
      }

      if (pending.isEmpty) {
        return _finish(AssetsDownloadStatus.ready);
      }

      // 2. Ambil Content-Length untuk yang belum diketahui ukurannya.
      await _resolveSizes(pending);
      await _saveManifest();

      if (_cancelled) return _finish(AssetsDownloadStatus.cancelled);

      // 3. Core dulu, supaya engine bisa boot lebih cepat sementara voice
      //    style sisanya menyusul.
      pending.sort((a, b) {
        if (a.core != b.core) return a.core ? -1 : 1;
        return a.index.compareTo(b.index);
      });

      _emit(
        _snapshot(status: AssetsDownloadStatus.downloading),
        force: true,
      );

      await _runPool(pending, _downloadWithRetry);

      if (_cancelled) return _finish(AssetsDownloadStatus.cancelled);
      if (_failures.isNotEmpty) {
        return _finish(
          AssetsDownloadStatus.failed,
          message:
              'Gagal mengunduh ${_failures.length} file. '
              'Periksa koneksi lalu coba lagi.',
        );
      }
      return _finish(AssetsDownloadStatus.ready);
    } catch (e) {
      return _finish(AssetsDownloadStatus.failed, message: e.toString());
    }
  }

  Future<void> _runPool(
    List<TtsAsset> items,
    Future<void> Function(TtsAsset) job,
  ) async {
    final queue = List<TtsAsset>.from(items);
    final workerCount = math.min(maxConcurrent, queue.length);

    await Future.wait(
      List.generate(workerCount, (_) async {
        while (queue.isNotEmpty && !_cancelled) {
          await job(queue.removeAt(0));
        }
      }),
    );
  }

  Future<AssetsDownloadProgress> _finish(
    AssetsDownloadStatus status, {
    String? message,
  }) async {
    final coreReady = await isComplete(coreOnly: true);
    final result = _snapshot(status: status, message: message).copyWith(
      coreReady: coreReady,
      failures: Map<TtsAsset, String>.unmodifiable(_failures),
    );
    _emit(result, force: true);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Download satu file
  // ---------------------------------------------------------------------------

  Future<void> _downloadWithRetry(TtsAsset asset) async {
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      if (_cancelled) return;
      try {
        await _attemptDownload(asset);
        _failures.remove(asset);
        return;
      } on _CancelledException {
        return;
      } catch (e) {
        _failures[asset] = e.toString();
        if (attempt == maxRetries) return;
        // Backoff 1s, 2s, 4s. Progress .part tetap dipertahankan, attempt
        // berikutnya lanjut dari byte terakhir.
        await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
      }
    }
  }

  Future<void> _attemptDownload(TtsAsset asset) async {
    final path = await localPathOf(asset);
    final target = File(path);
    final part = File('$path.part');

    final expected = _sizes[asset.name];
    var resumeFrom = part.existsSync() ? await part.length() : 0;

    // .part lebih besar dari ukuran asli = korup. Buang, mulai bersih.
    if (expected != null && resumeFrom > expected) {
      await part.delete();
      resumeFrom = 0;
    }
    if (expected != null && resumeFrom == expected) {
      await _promote(part, target, asset, expected);
      return;
    }

    final request = http.Request('GET', Uri.parse(asset.remoteUrl))
      // identity: cegah gzip, supaya Content-Length == byte yang mendarat di
      // disk. Tanpa ini, verifikasi ukuran dan resume jadi salah.
      ..headers['Accept-Encoding'] = 'identity';
    if (resumeFrom > 0) request.headers['Range'] = 'bytes=$resumeFrom-';

    final response = await _client.send(request).timeout(requestTimeout);

    if (response.statusCode == 416) {
      // Range di luar jangkauan — .part sudah tidak sinkron dengan server.
      if (part.existsSync()) await part.delete();
      _bytesOnDisk[asset] = 0;
      throw HttpException('Range tidak valid untuk ${asset.filename}');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException(
        'HTTP ${response.statusCode} saat mengunduh ${asset.filename}',
      );
    }

    // Server mengabaikan Range dan mengirim ulang dari 0.
    if (resumeFrom > 0 && response.statusCode == 200) {
      resumeFrom = 0;
    }

    final totalForThisFile =
        expected ??
        (response.contentLength != null
            ? resumeFrom + response.contentLength!
            : null);
    if (expected == null && totalForThisFile != null) {
      _sizes[asset.name] = totalForThisFile;
    }

    var written = resumeFrom;
    _bytesOnDisk[asset] = written;

    final sink = part.openWrite(
      mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
    );

    try {
      await for (final chunk in response.stream) {
        if (_cancelled) throw const _CancelledException();
        sink.add(chunk);
        written += chunk.length;
        _bytesOnDisk[asset] = written;
        _emit(
          _snapshot(
            status: AssetsDownloadStatus.downloading,
            currentAsset: asset,
          ),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final actual = await part.length();
    if (totalForThisFile != null && actual != totalForThisFile) {
      throw HttpException(
        '${asset.filename} tidak utuh: $actual dari $totalForThisFile byte',
      );
    }

    await _promote(part, target, asset, actual);
    await _saveManifest();
  }

  Future<void> _promote(
    File part,
    File target,
    TtsAsset asset,
    int size,
  ) async {
    if (target.existsSync()) await target.delete();
    await part.rename(target.path);
    _bytesOnDisk[asset] = size;
    _completed.add(asset);
    _emit(
      _snapshot(status: AssetsDownloadStatus.downloading, currentAsset: asset),
      force: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Ukuran & manifest
  // ---------------------------------------------------------------------------

  Future<void> _resolveSizes(List<TtsAsset> assets) async {
    final unknown =
        assets.where((a) => !_sizes.containsKey(a.name)).toList(growable: false);
    if (unknown.isEmpty) return;

    await _runPool(unknown, (asset) async {
      final size = await _headSize(asset);
      if (size != null) _sizes[asset.name] = size;
    });
  }

  Future<int?> _headSize(TtsAsset asset) async {
    try {
      final response = await _client
          .head(Uri.parse(asset.remoteUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final raw = response.headers['content-length'];
      return raw == null ? null : int.tryParse(raw);
    } catch (_) {
      // HEAD gagal bukan alasan membatalkan download. Fallback ke
      // estimatedBytes untuk bobot progress; ukuran asli tetap didapat dari
      // Content-Length response GET.
      return null;
    }
  }

  File get _manifestFile => File('${_root!.path}/manifest.json');

  Future<void> _loadManifest() async {
    if (_sizes.isNotEmpty) return;
    try {
      if (!_manifestFile.existsSync()) return;
      final raw = jsonDecode(await _manifestFile.readAsString());
      if (raw is Map) {
        raw.forEach((key, value) {
          if (key is String && value is int) _sizes[key] = value;
        });
      }
    } catch (_) {
      // Manifest korup bukan masalah fatal — tinggal HEAD ulang.
    }
  }

  Future<void> _saveManifest() async {
    try {
      await _manifestFile.writeAsString(jsonEncode(_sizes), flush: true);
    } catch (_) {}
  }

  Future<bool> _isFileValid(TtsAsset asset) async {
    final file = File(await localPathOf(asset));
    if (!file.existsSync()) return false;
    final length = await file.length();
    if (length == 0) return false;
    final expected = _sizes[asset.name];
    // Ukuran belum diketahui (offline first-run setelah install ulang):
    // file yang ada dianggap valid, verifikasi ukuran dilakukan saat online.
    return expected == null || length == expected;
  }

  Future<int> _partLength(TtsAsset asset) async {
    final part = File('${await localPathOf(asset)}.part');
    return part.existsSync() ? part.length() : 0;
  }

  int get _knownTotal {
    var total = 0;
    for (final asset in TtsAsset.values) {
      total += _sizes[asset.name] ?? asset.estimatedBytes;
    }
    return total;
  }

  // ---------------------------------------------------------------------------
  // Emit
  // ---------------------------------------------------------------------------

  AssetsDownloadProgress _snapshot({
    required AssetsDownloadStatus status,
    TtsAsset? currentAsset,
    String? message,
  }) {
    var downloaded = 0;
    for (final asset in TtsAsset.values) {
      downloaded += _bytesOnDisk[asset] ?? 0;
    }

    return AssetsDownloadProgress(
      status: status,
      downloadedBytes: downloaded,
      totalBytes: math.max(_knownTotal, downloaded),
      completedFiles: _completed.length,
      totalFiles: TtsAsset.values.length,
      currentAsset: currentAsset ?? _value.currentAsset,
      coreReady: _value.coreReady,
      failures: Map<TtsAsset, String>.unmodifiable(_failures),
      message: message,
    );
  }

  void _emit(AssetsDownloadProgress next, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastEmit) < emitInterval) return;
    _lastEmit = now;
    _value = next;
    if (!_controller.isClosed) _controller.add(next);
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Download dibatalkan';
}