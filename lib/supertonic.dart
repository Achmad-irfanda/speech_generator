import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_generator/amout_masker.dart';
import 'package:speech_generator/assets_download_progress.dart';
import 'package:speech_generator/assets_download_service.dart';
import 'package:speech_generator/assets_progerss_card.dart';
import 'package:speech_generator/helper.dart';
import 'package:speech_generator/main.dart';
import 'package:speech_generator/tts_assets_registry.dart';

/// Bahasa yang didukung halaman ini.
/// `code` dipakai saat memanggil model ONNX, `label` untuk tampilan.
enum TtsLang {
  id('id', 'Indonesia'),
  en('en', 'Inggris');

  const TtsLang(this.code, this.label);

  final String code;
  final String label;
}

class TTSPage extends StatefulWidget {
  const TTSPage({super.key});

  @override
  State<TTSPage> createState() => _TTSPageState();
}

class _TTSPageState extends State<TTSPage> {
  /// Denoising steps dikunci di 5 supaya generate tidak kelamaan.
  static const int kDenoisingSteps = 5;

  final AudioPlayer _audioPlayer = AudioPlayer();

  final TextEditingController _textIdController = TextEditingController(
    text: listText.isNotEmpty ? listText.first : '',
  );
  final TextEditingController _textEnController = TextEditingController();

  final TtsAssetsDownloadService _assets = TtsAssetsDownloadService.instance;

  StreamSubscription<AssetsDownloadProgress>? _assetsSub;

  bool _assetsReady = false;

  TextToSpeech? _textToSpeech;
  Style? _style;

  bool _isLoading = false;

  /// Bahasa yang sedang di-generate. `null` artinya idle.
  TtsLang? _generatingLang;

  /// Bahasa dari audio yang sedang dimuat / diputar.
  TtsLang? _activeLang;

  bool _isPlaying = false;
  bool _hasError = false;
  String _status = 'Belum diinisialisasi';

  double _speed = 1.05;
  double _pitch = 1.0;
  VoiceCharacter _selectedChar = VoiceCharacter.normal;
  int _indexTextSelected = 0;

  bool get _isBusy =>
      _isLoading || _generatingLang != null || !_assets.value.isReady;
  bool get _isReady => _textToSpeech != null && _style != null;

  @override
  void initState() {
    super.initState();
    _watchAssets();
    _setupAudioPlayerListeners();
  }

  @override
  void dispose() {
    _assetsSub?.cancel();
    _textIdController.dispose();
    _textEnController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Model & audio
  // ---------------------------------------------------------------------------

  /// Model baru boleh di-load setelah aset core lengkap.
  /// Sisa voice style boleh menyusul — engine tidak butuh semuanya untuk boot.
  void _watchAssets() {
    _assetsSub = _assets.progress.listen((progress) {
      if (!mounted) return;

      final canBoot = progress.coreReady || progress.isReady;
      if (canBoot && !_assetsReady) {
        _assetsReady = true;
        _loadModels();
      }

      if (!canBoot) {
        setState(() => _status = progress.headline);
      }
    });

    // Kalau semua aset sudah ada dari sesi sebelumnya, langsung boot.
    _assets.isComplete(coreOnly: true).then((ready) {
      if (ready && mounted && !_assetsReady) {
        _assetsReady = true;
        _loadModels();
      }
    });

    _assets.ensureReady();
  }

  void _setupAudioPlayerListeners() {
    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        _isPlaying = state.playing;

        switch (state.processingState) {
          case ProcessingState.completed:
            _isPlaying = false;
            _activeLang = null;
            _status = 'Siap';
            break;
          case ProcessingState.loading:
            _status = 'Memuat audio...';
            break;
          case ProcessingState.buffering:
            _status = 'Buffering...';
            break;
          default:
            break;
        }
      });
    });
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
      _status = 'Memuat model...';
    });

    try {
      final onnxDir = await _assets.onnxDirPath;
      _textToSpeech = await loadTextToSpeech(onnxDir, useGpu: false);

      await _applyStyle(_selectedChar);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _status = 'Siap';
      });
    } catch (e, stackTrace) {
      logger.e('Gagal memuat model', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
        _status = 'Model gagal dimuat: $e';
      });
    }
  }

  Future<void> _applyStyle(VoiceCharacter char) async {
    final preset = voicePresets[char];
    if (preset == null) {
      logger.w('Preset untuk ${char.name} tidak ditemukan');
      return;
    }

    final asset = TtsAsset.styleFor(preset.styleFile);
    if (asset != null) {
      final file = File(await _assets.localPathOf(asset));
      if (!file.existsSync()) {
        _notify(
          'Voice style ${preset.label} masih diunduh. '
          'Coba lagi sebentar lagi.',
        );
        return;
      }
    }

    try {
      final styleDir = await _assets.voiceStyleDirPath;
      final style = await loadVoiceStyle([
        '$styleDir/${preset.styleFile}.json',
      ]);

      if (!mounted) return;
      setState(() {
        _style = style;
        _selectedChar = char;
        _speed = preset.speed;
        _pitch = preset.pitch;
      });
    } catch (e, stackTrace) {
      logger.e('Gagal memuat voice style', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _status = 'Voice style gagal dimuat: $e';
      });
    }
  }

  Future<void> _generateSpeech(TtsLang lang) async {
    final text = _controllerFor(lang).text.trim();

    final assetState = _assets.value;
    if (!assetState.coreReady && !assetState.isReady) {
      _notify(
        'Proses menyiapkan model masih berlangsung (${assetState.percent}%). '
        'Tunggu sebentar ya.',
      );
      return;
    }

    if (!_isReady) {
      _notify('Model belum siap. Tunggu proses pemuatan selesai.');
      return;
    }
    if (text.isEmpty) {
      _notify('Teks ${lang.label} masih kosong.');
      return;
    }

    await _audioPlayer.stop();

    setState(() {
      _generatingLang = lang;
      _activeLang = lang;
      _hasError = false;
      _status = 'Membuat suara ${lang.label}...';
    });

    try {
      final result = await _textToSpeech!.call(
        text,
        lang.code,
        _style!,
        kDenoisingSteps,
        speed: _speed,
      );

      // `TextToSpeech.call` mengembalikan wav == null kalau _chunkText
      // menghasilkan nol chunk (teks yang isinya cuma simbol/emoji akan
      // habis dibuang di preprocessText).
      final rawWav = result['wav'];
      if (rawWav == null) {
        throw Exception(
          'Model tidak menghasilkan audio. Teks kemungkinan hanya berisi '
          'simbol yang dibuang saat preprocessing.',
        );
      }

      final wav = (rawWav as List).cast<double>();
      final duration = (result['duration'] as List).cast<double>();

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${tempDir.path}/speech_${lang.code}_$timestamp.wav';

      writeWavFile(outputPath, wav, _textToSpeech!.sampleRate);

      final file = File(outputPath);
      if (!file.existsSync()) {
        throw Exception('File WAV gagal dibuat di $outputPath');
      }

      logger.i('Audio tersimpan di ${file.absolute.path}');

      if (!mounted) return;
      setState(() {
        _generatingLang = null;
        _status =
            'Memutar ${duration.isNotEmpty ? duration.first.toStringAsFixed(2) : '?'}s '
            'audio ${lang.label}';
      });

      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.file(file.absolute.path)),
      );
      await _audioPlayer.setPitch(_pitch);
      await _audioPlayer.play();
    } catch (e, stackTrace) {
      logger.e('Gagal generate suara', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _generatingLang = null;
        _activeLang = null;
        _hasError = true;
        _status = 'Generate gagal: $e';
      });
    }
  }

  Future<void> _stopPlayback() async {
    await _audioPlayer.stop();
    if (!mounted) return;
    setState(() {
      _isPlaying = false;
      _activeLang = null;
      _status = 'Siap';
    });
  }

  TextEditingController _controllerFor(TtsLang lang) =>
      lang == TtsLang.id ? _textIdController : _textEnController;

  // ---------------------------------------------------------------------------
  // Clipboard
  // ---------------------------------------------------------------------------

  String _buildClipboardPayload() {
    final styleLabel =
        voicePresets[_selectedChar]?.styleFile ?? _selectedChar.name;

    // Nominal di-mask hanya di payload. Teks yang dikirim ke model TTS
    // tetap memakai angka aslinya.
    final maskedEn = AmountMasker.mask(_textEnController.text);
    final maskedId = AmountMasker.mask(_textIdController.text);

    return 'note: tolong kirimkan copy data ini ke tim admin qris ya untuk di '
        'tambahkan melalui dashboard internal.\n'
        '\n'
        'teks inggris: "$maskedEn"\n'
        'teks indonesia: "$maskedId"\n'
        '\n'
        'denoising steps: $kDenoisingSteps\n'
        '\n'
        'speed: ${_speed.toStringAsFixed(2)}\n'
        '\n'
        'voice styles: $styleLabel'
        '\n'
        'pitch $_pitch';
  }

  Future<void> _copyToClipboard() async {
    if (_textEnController.text.trim().isEmpty ||
        _textIdController.text.trim().isEmpty) {
      _notify('Isi dulu kedua teks sebelum menyalin.');
      return;
    }

    final payload = _buildClipboardPayload();
    await Clipboard.setData(ClipboardData(text: payload));
    logger.i('Payload disalin:\n$payload');
    _notify('Data tersalin. Kirim ke tim admin QRIS.');
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Speech Generator'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AssetsProgressCard(
                service: _assets,
                onRetry: () => _assets.ensureReady(),
              ),
              _StatusBanner(
                status: _status,
                isBusy: _isBusy,
                hasError: _hasError,
              ),
              const SizedBox(height: 20),
              _buildTextSection(),
              const SizedBox(height: 20),
              _buildParameterSection(),
              const SizedBox(height: 20),
              _buildActionSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextSection() {
    return _SectionCard(
      title: 'Teks',
      subtitle: 'Isi keduanya sebelum menyalin data ke tim admin.',
      children: [
        if (listText.isNotEmpty) ...[
          _LabeledRow(
            label: 'Teks instan (ID)',
            child: DropdownButton<int>(
              value: _indexTextSelected,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              onChanged: _isBusy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _indexTextSelected = value;
                        _textIdController.text = listText[value];
                      });
                    },
              items: List.generate(
                listText.length,
                (index) => DropdownMenuItem<int>(
                  value: index,
                  child: Text(
                    listText[index],
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _textIdController,
          maxLines: 4,
          enabled: !_isBusy,
          textInputAction: TextInputAction.newline,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Teks Indonesia',
            hintText: 'Transaksi berhasil, terima kasih.',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _textEnController,
          maxLines: 4,
          enabled: !_isBusy,
          textInputAction: TextInputAction.newline,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Teks Inggris',
            hintText: 'Transaction successful, thank you.',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Widget _buildParameterSection() {
    return _SectionCard(
      title: 'Parameter',
      children: [
        _LabeledRow(
          label: 'Voice style',
          child: DropdownButton<VoiceCharacter>(
            value: _selectedChar,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            onChanged: _isBusy
                ? null
                : (value) {
                    if (value == null) return;
                    _applyStyle(value);
                  },
            items: voicePresets.entries
                .map(
                  (entry) => DropdownMenuItem<VoiceCharacter>(
                    value: entry.key,
                    child: Text(entry.value.label),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 8),
        _LabeledRow(
          label: 'Speed',
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  label: _speed.toStringAsFixed(2),
                  onChanged: _isBusy
                      ? null
                      : (value) => setState(() => _speed = value),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  _speed.toStringAsFixed(2),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _InfoChip(
              label: 'Denoising steps',
              value: '$kDenoisingSteps (tetap)',
            ),
            _InfoChip(label: 'Pitch', value: _pitch.toStringAsFixed(2)),
          ],
        ),
      ],
    );
  }

  Widget _buildActionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGenerateButton(TtsLang.id),
        const SizedBox(height: 12),
        _buildGenerateButton(TtsLang.en),
        const SizedBox(height: 24),
        _buildMaskPreview(),
        OutlinedButton.icon(
          onPressed: _isBusy ? null : _copyToClipboard,
          icon: const Icon(Icons.copy_all),
          label: const Text('Salin data untuk tim admin QRIS'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ],
    );
  }

  /// Preview teks setelah nominal di-mask, supaya salah deteksi ketahuan
  /// sebelum data dikirim ke tim admin.
  Widget _buildMaskPreview() {
    final maskedId = AmountMasker.mask(_textIdController.text);
    final maskedEn = AmountMasker.mask(_textEnController.text);

    if (maskedId.isEmpty && maskedEn.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Yang akan disalin', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            if (maskedId.isNotEmpty)
              Text('ID: $maskedId', style: theme.textTheme.bodySmall),
            if (maskedEn.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('EN: $maskedEn', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateButton(TtsLang lang) {
    final isThisGenerating = _generatingLang == lang;
    final isThisPlaying = _isPlaying && _activeLang == lang;

    final String label;
    if (isThisGenerating) {
      label = 'Membuat suara ${lang.label}...';
    } else if (isThisPlaying) {
      label = 'Hentikan ${lang.label}';
    } else {
      label = 'Putar suara ${lang.label}';
    }

    return FilledButton.icon(
      onPressed: _isBusy
          ? null
          : isThisPlaying
          ? _stopPlayback
          : () => _generateSpeech(lang),
      icon: isThisGenerating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(isThisPlaying ? Icons.stop : Icons.play_arrow),
      label: Text(label, style: const TextStyle(fontSize: 16)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Widget pendukung
// -----------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.status,
    required this.isBusy,
    required this.hasError,
  });

  final String status;
  final bool isBusy;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final IconData icon;

    if (hasError) {
      background = Colors.red.shade50;
      icon = Icons.error_outline;
    } else if (isBusy) {
      background = Colors.orange.shade50;
      icon = Icons.hourglass_top;
    } else {
      background = Colors.green.shade50;
      icon = Icons.check_circle_outline;
    }

    return Card(
      color: background,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (isBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(status, style: const TextStyle(fontSize: 15))),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}

class _LabeledRow extends StatelessWidget {
  const _LabeledRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 2, child: Text(label)),
        Expanded(flex: 3, child: child),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$label: $value', style: theme.textTheme.bodySmall),
    );
  }
}
