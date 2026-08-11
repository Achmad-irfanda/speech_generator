

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:speech_generator/enum.dart';
import 'package:speech_generator/main.dart';

class AssetsManager {
  static String baseUrl = Config.domainQrisApiApp.value;

  //
  static Future<String> getOnnxBasePath() async {
    final base = await _getBaseDir();
    final dir = Directory('${base.path}/${DirMainPathUsage.onnx.name}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  //-> base dir app saved the data assets
  static Future<Directory> _getBaseDir() async {
    Directory dir;

    if (Platform.isAndroid) {
      dir = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
    } else {
      dir = await getApplicationSupportDirectory();
    }

    final baseDir = Directory('${dir.path}/remote_assets');
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    return baseDir;
  }

  //-> convert relative path (e.g. "anim/logo-qris.gif") jadi local File
  static Future<File> _getLocalFile(
    String relativePath, {
    required DirMainPathUsage dirMainPathUsage,
  }) async {
    final base = await _getBaseDir();
    final localPath = '${base.path}/${dirMainPathUsage.name}/$relativePath';
    final localFile = File(localPath);

    // pastikan parent dir exist, dengan retry kalau gagal
    final parentDir = localFile.parent;
    if (!await parentDir.exists()) {
      try {
        await parentDir.create(recursive: true);
        logger.i('Created dir: ${parentDir.path}');
      } catch (e) {
        logger.e('Failed to create dir: ${parentDir.path} — $e');
        rethrow;
      }
    }

    return localFile;
  }

  //-> cek apakah asset sudah ada di local storage
  static Future<bool> isAssetReady(
    String relativePath, {
    required DirMainPathUsage dirMainPathUsage,
    int minimumBytes = 0,
  }) async {
    if (relativePath.isEmpty) {
      logger.i("relative path is empty");
      return false;
    }

    final file = await _getLocalFile(relativePath.trim(),
        dirMainPathUsage: dirMainPathUsage);
    if (!await file.exists()) {
      return false;
    }

    // Validasi ukuran minimum
    if (minimumBytes > 0) {
      final size = await file.length();
      if (size < minimumBytes) {
        logger.w(
            'File too small ($size bytes), treating as corrupt: $relativePath');
        await file.delete();
        return false;
      }
    }
    return true;
  }

  /// Get local path tanpa download (dipakai setelah dipastikan ready)
  static Future<String> getLocalPath(String relativePath,
      {required DirMainPathUsage dirMainPathUsage}) async {
    final file =
        await _getLocalFile(relativePath, dirMainPathUsage: dirMainPathUsage);
    return file.path;
  }

  // -> download assets from server
  static Future<String> downloadIfNeeded(
    String relativePath, {
    required DomainAssetsFrom domainAssetsFrom,
    required DirMainPathUsage dirMainPathUsage,
    Function(double progress)? onProgress,
    int maxRetries = 3,
  }) async {
    relativePath = relativePath.trim();
    logger.i("relative path $relativePath");

    // ── 1. Resolve local file path ──────────────────────────────
    final localFile = await _getLocalFile(
      relativePath,
      dirMainPathUsage: dirMainPathUsage,
    );
    final tempFile = File('${localFile.path}.tmp');

    // ── 2. Cek file final — kalau ada & valid, langsung return ──
    if (await localFile.exists()) {
      final size = await localFile.length();
      if (size > 0) {
        logger.i('Asset already exists, skip download: $relativePath');
        return localFile.path;
      }
      // Ada tapi size 0 — corrupt, hapus dan download ulang
      await localFile.delete();
      logger.w('Found zero-size file, re-downloading: $relativePath');
    }

    // ── 3. Cleanup temp sisa terminate sebelumnya ───────────────
    if (await tempFile.exists()) {
      await tempFile.delete();
      logger.w('Cleaned stale temp file: ${tempFile.path}');
    }

    final parentDir = localFile.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
      logger.i('Created dir: ${parentDir.path}');
    }

    // ── 4. Build URL ────────────────────────────────────────────
    String url = _buildUrl(
      relativePath: relativePath.trim(),
      domainAssetsFrom: domainAssetsFrom,
      dirMainPathUsage: dirMainPathUsage,
    );

    
    

    logger.i("build url $url");
    // ── 5. Retry loop ───────────────────────────────────────────
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;
      logger.i('Download attempt $attempt/$maxRetries: $url');

      final client = http.Client();
      try {
        // ── Send request dengan timeout ──────────────────────
        final request = http.Request('GET', Uri.parse(url));

        logger.i('Request URL: ${request.url}');
        logger.i('Request headers: ${request.headers}');
        logger.i('Request method: ${request.method}');

        final response = await client.send(request).timeout(
              const Duration(minutes: 10),
              onTimeout: () => throw TimeoutException(
                  'Request timeout', const Duration(minutes: 10)),
            );

        if (response.statusCode != 200) {
          logger.e('Response status: ${response.statusCode}');
          logger.e('Response headers: ${response.headers}');
          // Baca body error-nya juga
          final errorBody = await response.stream.bytesToString();
          logger.e('Response body: $errorBody');
          throw Exception('HTTP ${response.statusCode} for $url');
        }

        final contentLength = response.contentLength ?? 0;
        var downloaded = 0;
        final sink = tempFile.openWrite();

        // ── 5b. Stream chunks ke temp file ───────────────────────
        try {
          await response.stream
              .timeout(
            const Duration(minutes: 10),
            onTimeout: (eventSink) => eventSink.close(),
          )
              .forEach((chunk) {
            sink.add(chunk);
            downloaded += chunk.length;
            if (contentLength > 0) {
              onProgress?.call(downloaded / contentLength);
            }
          });
          await sink.flush();
        } finally {
          await sink.close();
        }

        // ── 5c. Validasi ukuran — deteksi silent truncation ──────
        final tempSize = await tempFile.length();
        if (tempSize == 0) {
          throw Exception('Downloaded file is empty (stream closed early)');
        }
        if (contentLength > 0 && tempSize < contentLength) {
          throw Exception(
              'Incomplete: received $tempSize of $contentLength bytes');
        }

        // ── 5d. Atomic rename — hanya kalau 100% selesai ─────────
        await tempFile.rename(localFile.path);
        logger.i('Download complete (attempt $attempt): ${localFile.path}');
        return localFile.path;

        //
      } on TimeoutException catch (e) {
        logger.w('Attempt $attempt timeout: $e');
      } on SocketException catch (e) {
        logger.w('Attempt $attempt socket error: $e');
      } on http.ClientException catch (e) {
        // "Connection closed before full header was received"
        logger.w('Attempt $attempt client error: $e');
      } catch (e) {
        logger.w('Attempt $attempt failed: $e');
      } finally {
        client.close();
        // Cleanup temp setiap kali gagal
        if (await tempFile.exists()) {
          await tempFile.delete();
          logger.w('Cleaned temp after failed attempt $attempt');
        }
      }

      // ── 5e. Exponential backoff sebelum retry ─────────────────
      // attempt 1 → wait 2s, attempt 2 → wait 4s, attempt 3 → skip
      if (attempt < maxRetries) {
        final delay = Duration(seconds: math.pow(2, attempt).toInt());
        logger.i('Retrying in ${delay.inSeconds}s...');
        await Future.delayed(delay);
      }
    }

    // ── 6. all retry habis → throw ───────────────────────────
    throw Exception(
        'Download failed after $maxRetries attempts: $relativePath');
  }

// ── Helper: build URL berdasarkan domain ──────────────────────
  static String _buildUrl({
    required String relativePath,
    required DomainAssetsFrom domainAssetsFrom,
    required DirMainPathUsage dirMainPathUsage,
  }) {
    switch (domainAssetsFrom) {
      case DomainAssetsFrom.onnx:
        return '${Config.onnxAssets}/${dirMainPathUsage.name}/$relativePath';
      case DomainAssetsFrom.myprofit:
        return '${Config.domainMyProfit1.value}/myprofit/assets/${dirMainPathUsage.name}/$relativePath';
      case DomainAssetsFrom.qris:
        return '${Config.domainQrisApiApp.value}/assets/${dirMainPathUsage.name}/$relativePath';
    }
  }

  // downloadBatch — tetap generic untuk Dart download (audio, dll)s -> memungkinkan untuk open app
  static Future<void> downloadBatch(
    List<String> relativePaths, {
    required DomainAssetsFrom domainAssetsFrom,
    required DirMainPathUsage dirMainPathUsage,
    Function(double overallProgress, String currentFile)? onProgress,
  }) async {
    for (var i = 0; i < relativePaths.length; i++) {
      final path = relativePaths[i];
      await downloadIfNeeded(
        path,
        dirMainPathUsage: dirMainPathUsage,
        domainAssetsFrom: domainAssetsFrom,
        onProgress: (fileProgress) {
          final overall = (i + fileProgress) / relativePaths.length;
          onProgress?.call(overall, path);
        },
      );
    }
  }

  // downloadOnnxBatch — khusus ONNX via native background service
  static Future<void> downloadOnnxBatch(
    List<String> relativeFilenames, {
    Function(
      double progress,
      String file,
    )? onProgress,
    VoidCallback? onCompleted,
    Function(String error)? onError,
  }) async {
    final urls = relativeFilenames
        .map((f) => '${Config.onnxAssets}/${DirMainPathUsage.onnx.name}/$f')
        .toList();

    await startBackgroundDownload(
      urls: urls,
      onProgress: (
        file,
        progress,
      ) async {
        onProgress?.call(progress, file);
      },
      onCompleted: () async {
        onCompleted?.call();
        logger.i('ONNX download complete');
        globalStore.dispatch(SetOnnxProgress(
          progress: 1.0,
          isReady: true,
        ));

        await LocalAccess.setData(
            key: "isDoneOnBoardDownload",
            value: false,
            runtimeType: RuntimeType.boolean);
        PublicVariable.showcaseProgressDownload.hide();
      },
      onError: (error) async {
        logger.e('ONNX download error: $error');
        onError?.call(error);
      },
    );
  }

  // start backround download for big assets
  static Future<void> startBackgroundDownload({
    required List<String> urls,
    Function(String file, double progress)? onProgress,
    VoidCallback? onCompleted,
    Function(String error)? onError,
  }) async {
    // resolve dest path dari Dart — konsisten dengan _getBaseDir()
    final destPath = await getOnnxBasePath();

    // set handler dulu sebelum invoke
    Config.downloadAssetsChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onProgress':
          onProgress?.call(
            call.arguments['file'] as String,
            (call.arguments['progress'] as num).toDouble(),
          );
        case 'onCompleted':
          onCompleted?.call();
          // cleanup handler setelah selesai
          Config.downloadAssetsChannel.setMethodCallHandler(null);
        case 'onError':
          onError?.call(call.arguments['error'] as String);
          Config.downloadAssetsChannel.setMethodCallHandler(null);
      }
    });

    // invoke — native looping sendiri
    await Config.downloadAssetsChannel.invokeMethod('startDownload', {
      'urls': urls, // List<String> semua URL ONNX
      'destPath': destPath,
    });
  }

  //-> remove all assets from storges (untuk reset/debug)
  static Future<void> clearAll() async {
    final base = await _getBaseDir();
    if (await base.exists()) {
      await base.delete(recursive: true);
    }
  }

  //-> remove spesific assets
  static Future<void> deleteAsset(String relativePath,
      {required DirMainPathUsage dirMainPathUsage}) async {
    final file =
        await _getLocalFile(relativePath, dirMainPathUsage: dirMainPathUsage);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
