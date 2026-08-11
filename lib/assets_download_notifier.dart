import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'assets_download_progress.dart';
import 'assets_download_service.dart';

/// Menampilkan progress download aset TTS sebagai local notification.
///
/// Sengaja dipisah dari [TtsAssetsDownloadService]: service-nya tidak punya
/// dependency ke plugin notifikasi sama sekali, jadi bisa di-unit-test tanpa
/// platform channel dan bisa dibuang kalau kamu tidak jadi pakai notifikasi.
///
/// Catatan platform:
/// * **Android** — progress bar di notification tray berfungsi penuh.
///   Channel-nya sengaja `Importance.low` + `silent` supaya tidak berbunyi
///   dan tidak head-up; ini notifikasi progress, bukan notifikasi transaksi.
/// * **iOS** — UNNotification tidak punya progress bar. Di iOS notifier ini
///   hanya menampilkan satu notifikasi saat mulai dan satu saat selesai.
///
/// API `flutter_local_notifications` cukup sering berubah antar major version
/// (khususnya nama method request permission). Kalau kamu naik/turun versi,
/// file ini satu-satunya yang perlu disesuaikan.
class TtsAssetsDownloadNotifier {
  TtsAssetsDownloadNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    this.notificationId = 8801,
    this.minInterval = const Duration(seconds: 1),
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String channelId = 'tts_assets_download';
  static const String channelName = 'Penyiapan Suara Notifikasi';
  static const String channelDescription =
      'Progress pengunduhan model suara untuk notifikasi transaksi';

  final FlutterLocalNotificationsPlugin _plugin;
  final int notificationId;

  /// Notifikasi Android maksimal di-update sekali per interval ini.
  /// `notify()` beruntun bikin GC pressure di device low-end dan justru
  /// memperlambat download itu sendiri.
  final Duration minInterval;

  StreamSubscription<AssetsDownloadProgress>? _subscription;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastPercent = -1;
  bool _initialized = false;
  bool _startShown = false;

  Future<void> init() async {
    if (_initialized) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );

    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
          showBadge: false,
        ),
      );
      // Android 13+. Ditolak pun tidak apa-apa: download tetap jalan,
      // progress tetap kelihatan di halaman TTS.
      await android?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// Pasang ke service. Panggil setelah [init].
  Future<void> attach(TtsAssetsDownloadService service) async {
    await init();
    await _subscription?.cancel();
    _subscription = service.progress.listen(_handle);
    _handle(service.value);
  }

  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _handle(AssetsDownloadProgress progress) {
    switch (progress.status) {
      case AssetsDownloadStatus.checking:
      case AssetsDownloadStatus.downloading:
        _showProgress(progress);
      case AssetsDownloadStatus.ready:
        _showTerminal(
          title: 'Suara notifikasi siap',
          body: 'Model TTS berhasil diunduh dan siap dipakai.',
        );
      case AssetsDownloadStatus.failed:
        _showTerminal(
          title: 'Penyiapan suara belum selesai',
          body: progress.message ?? 'Sebagian model gagal diunduh.',
        );
      case AssetsDownloadStatus.cancelled:
        _plugin.cancel(id: notificationId);
      case AssetsDownloadStatus.idle:
        break;
    }
  }

  Future<void> _showProgress(AssetsDownloadProgress progress) async {
    // iOS tidak punya progress bar — cukup satu notifikasi pembuka.
    if (Platform.isIOS) {
      if (_startShown) return;
      _startShown = true;
      await _plugin.show(
        id: notificationId,
        title: 'Menyiapkan suara notifikasi',
        body:
            'Mengunduh model TTS di latar belakang. Aplikasi tetap bisa dipakai.',
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(presentSound: false),
        ),
      );
      return;
    }

    final now = DateTime.now();
    final percent = progress.percent;
    final indeterminate = progress.totalBytes <= 0;

    if (!indeterminate &&
        percent == _lastPercent &&
        now.difference(_lastUpdate) < minInterval) {
      return;
    }
    if (now.difference(_lastUpdate) < minInterval && percent != 100) return;

    _lastUpdate = now;
    _lastPercent = percent;

    await _plugin.show(
      title: 'Menyiapkan suara notifikasi',
      body: indeterminate
          ? 'Memeriksa model...'
          : '${progress.readableBytes} · '
                '${progress.completedFiles}/${progress.totalFiles} file',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: percent,
          indeterminate: indeterminate,
          // onlyAlertOnce: update berikutnya tidak "membangunkan" tray lagi.
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          silent: true,
          showWhen: false,
        ),
      ),
      id: notificationId,
    );
  }

  Future<void> _showTerminal({
    required String title,
    required String body,
  }) async {
    _lastPercent = -1;
    _startShown = false;
    await _plugin.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: false,
          autoCancel: true,
          playSound: false,
          enableVibration: false,
          silent: true,
        ),
        iOS: DarwinNotificationDetails(presentSound: false),
      ),
    );
  }
}
