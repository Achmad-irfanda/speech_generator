import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:speech_generator/assets_download_notifier.dart';
import 'package:speech_generator/assets_download_service.dart';
import 'package:speech_generator/supertonic.dart';

var logger = Logger();
final ttsAssets = TtsAssetsDownloadService.instance;
final ttsAssetsNotifier = TtsAssetsDownloadNotifier();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Notifier dipasang duluan supaya progress tetap kelihatan walau user
  // langsung menaruh app di background.
  unawaited(ttsAssetsNotifier.attach(ttsAssets));

  // TIDAK di-await. Download jalan di belakang, UI langsung tampil.
  unawaited(ttsAssets.ensureReady());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Speech Generator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: .fromSeed(
          seedColor: const Color.fromARGB(217, 210, 170, 78),
        ),
      ),
      home: TTSPage(),
    );
  }
}
