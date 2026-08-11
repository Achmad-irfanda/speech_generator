// Available languages for multilingual TTS
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_generator/main.dart';

enum VoiceCharacter {
  normal,

  funnyGirl,
  funnyGirlB,
  funnyGirlC,
  funnyGirlD,
  funnyGirlE,
  //
  funnyMan,
  funnyManb,
  funnyManc,
  funnyMand,
  funnyMane,

  //
  kawaii,
  deepLady,
  energetic,
}

class VoicePreset {
  final String styleFile;
  final double speed;
  final double pitch;
  final String label;
  final VoiceCharacter char;

  const VoicePreset({
    required this.styleFile,
    required this.speed,
    required this.pitch,
    required this.label,
    required this.char,
  });
}

const Map<VoiceCharacter, VoicePreset> voicePresets = {
  VoiceCharacter.normal: VoicePreset(
    styleFile: 'M1',
    speed: 1.05,
    pitch: 1.0,
    label: 'Normal',
    char: VoiceCharacter.normal,
  ),
  //
  VoiceCharacter.funnyGirl: VoicePreset(
    styleFile: 'F1',
    speed: 1.12,
    pitch: 1.25,
    label: 'Funny Girl',
    char: VoiceCharacter.funnyGirl,
  ),
  VoiceCharacter.funnyGirlB: VoicePreset(
    styleFile: 'F2',
    speed: 1.15,
    pitch: 1.20,
    label: 'Funny Girl B',
    char: VoiceCharacter.funnyGirlB,
  ),
  VoiceCharacter.funnyGirlC: VoicePreset(
    styleFile: 'F3',
    speed: 1.18,
    pitch: 1.30,
    label: 'Funny Girl C',
    char: VoiceCharacter.funnyGirlC,
  ),
  VoiceCharacter.funnyGirlD: VoicePreset(
    styleFile: 'F4',
    speed: 1.20,
    pitch: 1.15,
    label: 'Funny Girl D',
    char: VoiceCharacter.funnyGirlD,
  ),

  VoiceCharacter.funnyGirlE: VoicePreset(
    styleFile: 'F5',
    speed: 1.15,
    pitch: 1.25,
    label: 'Funny Girl E',
    char: VoiceCharacter.funnyGirlE,
  ),

  //
  VoiceCharacter.funnyMan: VoicePreset(
    styleFile: 'M1',
    speed: 1.10,
    pitch: 0.95,
    label: 'Funny Man',
    char: VoiceCharacter.funnyMan,
  ),
  VoiceCharacter.funnyManb: VoicePreset(
    styleFile: 'M2',
    speed: 1.12,
    pitch: 0.90,
    label: 'Funny Man B',
    char: VoiceCharacter.funnyManb,
  ),
  VoiceCharacter.funnyManc: VoicePreset(
    styleFile: 'M3',
    speed: 1.15,
    pitch: 0.85,
    label: 'Funny Man C',
    char: VoiceCharacter.funnyManc,
  ),
  VoiceCharacter.funnyMand: VoicePreset(
    styleFile: 'M4',
    speed: 1.20,
    pitch: 0.92,
    label: 'Funny Man D',
    char: VoiceCharacter.funnyMand,
  ),
  VoiceCharacter.funnyMane: VoicePreset(
    styleFile: 'M5',
    speed: 1.10,
    pitch: 0.88,
    label: 'Funny Man E',
    char: VoiceCharacter.funnyMane,
  ),

  //
  VoiceCharacter.kawaii: VoicePreset(
    styleFile: 'F1',
    speed: 1.2,
    pitch: 1.5,
    label: 'Kawaii',
    char: VoiceCharacter.kawaii,
  ),
  VoiceCharacter.deepLady: VoicePreset(
    styleFile: 'F3',
    speed: 0.95,
    pitch: 0.85,
    label: 'Deep Lady',
    char: VoiceCharacter.deepLady,
  ),
  VoiceCharacter.energetic: VoicePreset(
    styleFile: 'F2',
    speed: 1.3,
    pitch: 1.2,
    label: 'Energetic',
    char: VoiceCharacter.energetic,
  ),
};

List<String> listText = [
  "Hahaha pembayaran interactive qris 50.000 rupiah diterima!",
  "Yey! Pembayaran sebesar 10 rupiah diterima!",
  "Hore! Pembayaran 3 rupiah diterima",
];

// Hangul Jamo constants for NFKD decomposition
const int _hangulSyllableBase = 0xAC00;
const int _hangulSyllableEnd = 0xD7A3;
const int _leadingJamoBase = 0x1100;
const int _vowelJamoBase = 0x1161;
const int _trailingJamoBase = 0x11A7;
const int _vowelCount = 21;
const int _trailingCount = 28;

/// Decompose a Hangul syllable into Jamo (NFKD-like decomposition)
List<int> _decomposeHangulSyllable(int codePoint) {
  if (codePoint < _hangulSyllableBase || codePoint > _hangulSyllableEnd) {
    return [codePoint];
  }

  final syllableIndex = codePoint - _hangulSyllableBase;
  final leadingIndex = syllableIndex ~/ (_vowelCount * _trailingCount);
  final vowelIndex =
      (syllableIndex % (_vowelCount * _trailingCount)) ~/ _trailingCount;
  final trailingIndex = syllableIndex % _trailingCount;

  final result = <int>[
    _leadingJamoBase + leadingIndex,
    _vowelJamoBase + vowelIndex,
  ];

  if (trailingIndex > 0) {
    result.add(_trailingJamoBase + trailingIndex);
  }

  return result;
}

/// Common Latin character decompositions (NFKD) for es, pt, fr
const Map<int, List<int>> _latinDecompositions = {
  // Uppercase with acute accent
  0x00C1: [0x0041, 0x0301], // Á → A + ́
  0x00C9: [0x0045, 0x0301], // É → E + ́
  0x00CD: [0x0049, 0x0301], // Í → I + ́
  0x00D3: [0x004F, 0x0301], // Ó → O + ́
  0x00DA: [0x0055, 0x0301], // Ú → U + ́
  // Lowercase with acute accent
  0x00E1: [0x0061, 0x0301], // á → a + ́
  0x00E9: [0x0065, 0x0301], // é → e + ́
  0x00ED: [0x0069, 0x0301], // í → i + ́
  0x00F3: [0x006F, 0x0301], // ó → o + ́
  0x00FA: [0x0075, 0x0301], // ú → u + ́
  // Grave accent
  0x00C0: [0x0041, 0x0300], // À → A + ̀
  0x00C8: [0x0045, 0x0300], // È → E + ̀
  0x00CC: [0x0049, 0x0300], // Ì → I + ̀
  0x00D2: [0x004F, 0x0300], // Ò → O + ̀
  0x00D9: [0x0055, 0x0300], // Ù → U + ̀
  0x00E0: [0x0061, 0x0300], // à → a + ̀
  0x00E8: [0x0065, 0x0300], // è → e + ̀
  0x00EC: [0x0069, 0x0300], // ì → i + ̀
  0x00F2: [0x006F, 0x0300], // ò → o + ̀
  0x00F9: [0x0075, 0x0300], // ù → u + ̀
  // Circumflex
  0x00C2: [0x0041, 0x0302], // Â → A + ̂
  0x00CA: [0x0045, 0x0302], // Ê → E + ̂
  0x00CE: [0x0049, 0x0302], // Î → I + ̂
  0x00D4: [0x004F, 0x0302], // Ô → O + ̂
  0x00DB: [0x0055, 0x0302], // Û → U + ̂
  0x00E2: [0x0061, 0x0302], // â → a + ̂
  0x00EA: [0x0065, 0x0302], // ê → e + ̂
  0x00EE: [0x0069, 0x0302], // î → i + ̂
  0x00F4: [0x006F, 0x0302], // ô → o + ̂
  0x00FB: [0x0075, 0x0302], // û → u + ̂
  // Tilde
  0x00C3: [0x0041, 0x0303], // Ã → A + ̃
  0x00D1: [0x004E, 0x0303], // Ñ → N + ̃
  0x00D5: [0x004F, 0x0303], // Õ → O + ̃
  0x00E3: [0x0061, 0x0303], // ã → a + ̃
  0x00F1: [0x006E, 0x0303], // ñ → n + ̃
  0x00F5: [0x006F, 0x0303], // õ → o + ̃
  // Diaeresis/Umlaut
  0x00C4: [0x0041, 0x0308], // Ä → A + ̈
  0x00CB: [0x0045, 0x0308], // Ë → E + ̈
  0x00CF: [0x0049, 0x0308], // Ï → I + ̈
  0x00D6: [0x004F, 0x0308], // Ö → O + ̈
  0x00DC: [0x0055, 0x0308], // Ü → U + ̈
  0x00E4: [0x0061, 0x0308], // ä → a + ̈
  0x00EB: [0x0065, 0x0308], // ë → e + ̈
  0x00EF: [0x0069, 0x0308], // ï → i + ̈
  0x00F6: [0x006F, 0x0308], // ö → o + ̈
  0x00FC: [0x0075, 0x0308], // ü → u + ̈
  // Cedilla
  0x00C7: [0x0043, 0x0327], // Ç → C + ̧
  0x00E7: [0x0063, 0x0327], // ç → c + ̧
};

/// Apply NFKD-like decomposition (Hangul + Latin accented characters)
String _applyNfkdDecomposition(String text) {
  final result = <int>[];
  for (final codePoint in text.runes) {
    // Check Hangul first
    if (codePoint >= _hangulSyllableBase && codePoint <= _hangulSyllableEnd) {
      result.addAll(_decomposeHangulSyllable(codePoint));
    }
    // Check Latin decomposition
    else if (_latinDecompositions.containsKey(codePoint)) {
      result.addAll(_latinDecompositions[codePoint]!);
    }
    // Keep as-is
    else {
      result.add(codePoint);
    }
  }
  return String.fromCharCodes(result);
}

String preprocessText(String text, String lang) {
  // Apply NFKD-like decomposition (especially for Hangul syllables → Jamo)
  text = _applyNfkdDecomposition(text);

  // Remove emojis
  text = text.replaceAll(
    RegExp(
      r'[\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|'
      r'[\u{1F700}-\u{1F77F}]|[\u{1F780}-\u{1F7FF}]|[\u{1F800}-\u{1F8FF}]|'
      r'[\u{1F900}-\u{1F9FF}]|[\u{1FA00}-\u{1FA6F}]|[\u{1FA70}-\u{1FAFF}]|'
      r'[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F1E6}-\u{1F1FF}]',
      unicode: true,
    ),
    '',
  );

  // Replace various dashes and symbols
  const replacements = {
    '–': '-',
    '‑': '-',
    '—': '-',
    '_': ' ',
    '\u201C': '"',
    '\u201D': '"',
    '\u2018': "'",
    '\u2019': "'",
    '´': "'",
    '`': "'",
    '[': ' ',
    ']': ' ',
    '|': ' ',
    '/': ' ',
    '#': ' ',
    '→': ' ',
    '←': ' ',
  };
  for (final entry in replacements.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }

  // Remove special symbols
  text = text.replaceAll(RegExp(r'[♥☆♡©\\]'), '');

  // Replace known expressions
  text = text.replaceAll('@', ' at ');
  text = text.replaceAll('e.g.,', 'for example, ');
  text = text.replaceAll('i.e.,', 'that is, ');

  // Fix spacing around punctuation
  text = text.replaceAll(' ,', ',');
  text = text.replaceAll(' .', '.');
  text = text.replaceAll(' !', '!');
  text = text.replaceAll(' ?', '?');
  text = text.replaceAll(' ;', ';');
  text = text.replaceAll(' :', ':');
  text = text.replaceAll(" '", "'");

  // Remove duplicate quotes
  while (text.contains('""')) text = text.replaceAll('""', '"');
  while (text.contains("''")) text = text.replaceAll("''", "'");
  while (text.contains('``')) text = text.replaceAll('``', '`');

  // Remove extra spaces
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  // Add period if needed
  if (text.isNotEmpty &&
      !RegExp(r'[.!?;:,\x27\x22\u2018\u2019)\]}…。」』】〉》›»]$').hasMatch(text)) {
    text += '.';
  }

  // Wrap text with language tags
  text = '<$lang>$text</$lang>';

  return text;
}

class UnicodeProcessor {
  final Map<int, int> indexer;

  UnicodeProcessor._(this.indexer);

  static Future<UnicodeProcessor> load(String path) async {
    final json = jsonDecode(await _readAssetText(path));

    final indexer = json is List
        ? {
            for (var i = 0; i < json.length; i++)
              if (json[i] is int && json[i] >= 0) i: json[i] as int,
          }
        : (json as Map<String, dynamic>).map(
            (k, v) => MapEntry(int.parse(k), v as int),
          );

    return UnicodeProcessor._(indexer);
  }

  Map<String, dynamic> call(List<String> textList, List<String> langList) {
    // Preprocess texts with language tags
    final processedTexts = <String>[];
    for (var i = 0; i < textList.length; i++) {
      processedTexts.add(preprocessText(textList[i], langList[i]));
    }

    final lengths = processedTexts.map((t) => t.runes.length).toList();
    final maxLen = lengths.reduce(math.max);

    final textIds = processedTexts.map((text) {
      final row = List<int>.filled(maxLen, 0);
      final runes = text.runes.toList();
      for (var i = 0; i < runes.length; i++) {
        row[i] = indexer[runes[i]] ?? 0;
      }
      return row;
    }).toList();

    return {'textIds': textIds, 'textMask': _lengthToMask(lengths)};
  }

  List<List<List<double>>> _lengthToMask(List<int> lengths, [int? maxLen]) {
    maxLen ??= lengths.reduce(math.max);
    return lengths
        .map((len) => [List.generate(maxLen!, (i) => i < len ? 1.0 : 0.0)])
        .toList();
  }
}

class Style {
  final OrtValue ttl, dp;
  final List<int> ttlShape, dpShape;
  Style(this.ttl, this.dp, this.ttlShape, this.dpShape);
}

class TextToSpeech {
  final Map<String, dynamic> cfgs;
  final UnicodeProcessor textProcessor;
  final OrtSession dpOrt, textEncOrt, vectorEstOrt, vocoderOrt;
  final int sampleRate, baseChunkSize, chunkCompressFactor, ldim;

  TextToSpeech(
    this.cfgs,
    this.textProcessor,
    this.dpOrt,
    this.textEncOrt,
    this.vectorEstOrt,
    this.vocoderOrt,
  ) : sampleRate = cfgs['ae']['sample_rate'],
      baseChunkSize = cfgs['ae']['base_chunk_size'],
      chunkCompressFactor = cfgs['ttl']['chunk_compress_factor'],
      ldim = cfgs['ttl']['latent_dim'];

  Future<Map<String, dynamic>> call(
    String text,
    String lang,
    Style style,
    int totalStep, {
    double speed = 1.05,
    double silenceDuration = 0.3,
  }) async {
    final maxLen = (lang == 'ko' || lang == 'ja') ? 120 : 300;
    final chunks = _chunkText(text, maxLen: maxLen);
    final langList = List.filled(chunks.length, lang);
    List<double>? wavCat;
    double durCat = 0;

    for (var i = 0; i < chunks.length; i++) {
      final result = await _infer(
        [chunks[i]],
        [langList[i]],
        style,
        totalStep,
        speed: speed,
      );
      final wav = _safeCast<double>(result['wav']);
      final duration = _safeCast<double>(result['duration']);

      if (wavCat == null) {
        wavCat = wav;
        durCat = duration[0];
      } else {
        wavCat = [
          ...wavCat,
          ...List<double>.filled((silenceDuration * sampleRate).floor(), 0.0),
          ...wav,
        ];
        durCat += duration[0] + silenceDuration;
      }
    }

    return {
      'wav': wavCat,
      'duration': [durCat],
    };
  }

  Future<Map<String, dynamic>> _infer(
    List<String> textList,
    List<String> langList,
    Style style,
    int totalStep, {
    double speed = 1.05,
  }) async {
    final bsz = textList.length;
    final result = textProcessor.call(textList, langList);

    final textIdsRaw = result['textIds'];
    final textIds = textIdsRaw is List<List<int>>
        ? textIdsRaw
        : (textIdsRaw as List).map((row) => (row as List).cast<int>()).toList();

    final textMaskRaw = result['textMask'];
    final textMask = textMaskRaw is List<List<List<double>>>
        ? textMaskRaw
        : (textMaskRaw as List)
              .map(
                (batch) => (batch as List)
                    .map((row) => (row as List).cast<double>())
                    .toList(),
              )
              .toList();

    final textIdsShape = [bsz, textIds[0].length];
    final textMaskShape = [bsz, 1, textMask[0][0].length];
    final textMaskTensor = await _toTensor(textMask, textMaskShape);

    final dpResult = await dpOrt.run({
      'text_ids': await _intToTensor(textIds, textIdsShape),
      'style_dp': style.dp,
      'text_mask': textMaskTensor,
    });
    final durOnnx = _safeCast<double>(await dpResult.values.first.asList());
    final scaledDur = durOnnx.map((d) => d / speed).toList();

    final textEncResult = await textEncOrt.run({
      'text_ids': await _intToTensor(textIds, textIdsShape),
      'style_ttl': style.ttl,
      'text_mask': textMaskTensor,
    });

    final latentData = _sampleNoisyLatent(scaledDur);
    final noisyLatentRaw = latentData['noisyLatent'];
    var noisyLatent = noisyLatentRaw is List<List<List<double>>>
        ? noisyLatentRaw
        : (noisyLatentRaw as List)
              .map(
                (batch) => (batch as List)
                    .map((row) => (row as List).cast<double>())
                    .toList(),
              )
              .toList();

    final latentMaskRaw = latentData['latentMask'];
    final latentMask = latentMaskRaw is List<List<List<double>>>
        ? latentMaskRaw
        : (latentMaskRaw as List)
              .map(
                (batch) => (batch as List)
                    .map((row) => (row as List).cast<double>())
                    .toList(),
              )
              .toList();

    final latentShape = [bsz, noisyLatent[0].length, noisyLatent[0][0].length];
    final latentMaskTensor = await _toTensor(latentMask, [
      bsz,
      1,
      latentMask[0][0].length,
    ]);

    final totalStepTensor = await _scalarToTensor(
      List.filled(bsz, totalStep.toDouble()),
      [bsz],
    );

    // Denoising loop
    for (var step = 0; step < totalStep; step++) {
      final result = await vectorEstOrt.run({
        'noisy_latent': await _toTensor(noisyLatent, latentShape),
        'text_emb': textEncResult.values.first,
        'style_ttl': style.ttl,
        'text_mask': textMaskTensor,
        'latent_mask': latentMaskTensor,
        'total_step': totalStepTensor,
        'current_step': await _scalarToTensor(
          List.filled(bsz, step.toDouble()),
          [bsz],
        ),
      });

      final denoisedRaw = await result.values.first.asList();
      final denoised = denoisedRaw is List<double>
          ? denoisedRaw
          : _safeCast<double>(denoisedRaw);
      var idx = 0;
      for (var b = 0; b < noisyLatent.length; b++) {
        for (var d = 0; d < noisyLatent[b].length; d++) {
          for (var t = 0; t < noisyLatent[b][d].length; t++) {
            noisyLatent[b][d][t] = denoised[idx++];
          }
        }
      }
    }

    final vocoderResult = await vocoderOrt.run({
      'latent': await _toTensor(noisyLatent, latentShape),
    });
    final wavRaw = await vocoderResult.values.first.asList();
    final wav = wavRaw is List<double> ? wavRaw : _safeCast<double>(wavRaw);

    return {'wav': wav, 'duration': scaledDur};
  }

  Map<String, dynamic> _sampleNoisyLatent(List<double> duration) {
    final wavLenMax = duration.reduce(math.max) * sampleRate;
    final wavLengths = duration.map((d) => (d * sampleRate).floor()).toList();
    final chunkSize = baseChunkSize * chunkCompressFactor;
    final latentLen = ((wavLenMax + chunkSize - 1) / chunkSize).floor();
    final latentDim = ldim * chunkCompressFactor;

    final random = math.Random();
    final noisyLatent = List.generate(
      duration.length,
      (_) => List.generate(
        latentDim,
        (_) => List.generate(latentLen, (_) {
          final u1 = math.max(1e-10, random.nextDouble());
          final u2 = random.nextDouble();
          return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
        }),
      ),
    );

    final latentMask = _getLatentMask(wavLengths);

    for (var b = 0; b < noisyLatent.length; b++) {
      for (var d = 0; d < noisyLatent[b].length; d++) {
        for (var t = 0; t < noisyLatent[b][d].length; t++) {
          noisyLatent[b][d][t] *= latentMask[b][0][t];
        }
      }
    }

    return {'noisyLatent': noisyLatent, 'latentMask': latentMask};
  }

  List<List<List<double>>> _getLatentMask(List<int> wavLengths) {
    final latentSize = baseChunkSize * chunkCompressFactor;
    final latentLengths = wavLengths
        .map((len) => ((len + latentSize - 1) / latentSize).floor())
        .toList();
    final maxLen = latentLengths.reduce(math.max);
    return latentLengths
        .map((len) => [List.generate(maxLen, (i) => i < len ? 1.0 : 0.0)])
        .toList();
  }

  List<String> _chunkText(String text, {int maxLen = 300}) {
    final paragraphs = text
        .trim()
        .split(RegExp(r'\n\s*\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();

    final chunks = <String>[];
    for (var paragraph in paragraphs) {
      paragraph = paragraph.trim();
      if (paragraph.isEmpty) continue;

      final sentences = paragraph.split(
        RegExp(r'(?<!Mr\.|Mrs\.|Ms\.|Dr\.|Prof\.)(?<!\b[A-Z]\.)(?<=[.!?])\s+'),
      );

      var currentChunk = '';
      for (final sentence in sentences) {
        if (currentChunk.length + sentence.length + 1 <= maxLen) {
          currentChunk += (currentChunk.isNotEmpty ? ' ' : '') + sentence;
        } else {
          if (currentChunk.isNotEmpty) chunks.add(currentChunk.trim());
          currentChunk = sentence;
        }
      }
      if (currentChunk.isNotEmpty) chunks.add(currentChunk.trim());
    }

    return chunks;
  }

  List<T> _safeCast<T>(dynamic raw) {
    if (raw is List<T>) return raw;
    if (raw is List) {
      if (raw.isNotEmpty && raw.first is List) {
        return _flattenList<T>(raw);
      }
      if (T == double) {
        return raw
                .map(
                  (e) => e is num ? e.toDouble() : double.parse(e.toString()),
                )
                .toList()
            as List<T>;
      }
      return raw.cast<T>();
    }
    throw Exception('Cannot convert $raw to List<$T>');
  }

  List<T> _flattenList<T>(dynamic list) {
    if (list is List) {
      return list.expand((e) => _flattenList<T>(e)).toList();
    }
    if (T == double && list is num) {
      return [list.toDouble()] as List<T>;
    }
    return [list as T];
  }

  Future<OrtValue> _toTensor(dynamic array, List<int> dims) async {
    final flat = _flattenList<double>(array);
    return await OrtValue.fromList(Float32List.fromList(flat), dims);
  }

  Future<OrtValue> _scalarToTensor(List<double> array, List<int> dims) async {
    return await OrtValue.fromList(Float32List.fromList(array), dims);
  }

  Future<OrtValue> _intToTensor(List<List<int>> array, List<int> dims) async {
    final flat = array.expand((row) => row).toList();
    return await OrtValue.fromList(Int64List.fromList(flat), dims);
  }
}

Future<TextToSpeech> loadTextToSpeech(
  String onnxDir, {
  bool useGpu = false,
}) async {
  if (useGpu) throw Exception('GPU mode not supported yet');

  logger.i('Loading TTS models from $onnxDir');

  final cfgs = await _loadCfgs(onnxDir);
  final sessions = await _loadOnnxAll(onnxDir);
  final textProcessor = await UnicodeProcessor.load(
    '$onnxDir/unicode_indexer.json',
  );

  logger.i('TTS models loaded successfully');

  return TextToSpeech(
    cfgs,
    textProcessor,
    sessions['dpOrt']!,
    sessions['textEncOrt']!,
    sessions['vectorEstOrt']!,
    sessions['vocoderOrt']!,
  );
}

Future<Style> loadVoiceStyle(List<String> paths) async {
  final bsz = paths.length;

  final firstJson = jsonDecode(await _readAssetText(paths[0]));

  final ttlDims = List<int>.from(firstJson['style_ttl']['dims']);
  final dpDims = List<int>.from(firstJson['style_dp']['dims']);

  final ttlFlat = Float32List(bsz * ttlDims[1] * ttlDims[2]);
  final dpFlat = Float32List(bsz * dpDims[1] * dpDims[2]);

  for (var i = 0; i < bsz; i++) {
    final json = jsonDecode(await _readAssetText(paths[i]));

    final ttlData = _flattenToDouble(json['style_ttl']['data']);
    final dpData = _flattenToDouble(json['style_dp']['data']);

    ttlFlat.setRange(
      i * ttlDims[1] * ttlDims[2],
      (i + 1) * ttlDims[1] * ttlDims[2],
      ttlData,
    );
    dpFlat.setRange(
      i * dpDims[1] * dpDims[2],
      (i + 1) * dpDims[1] * dpDims[2],
      dpData,
    );
  }

  final ttlShape = [bsz, ttlDims[1], ttlDims[2]];
  final dpShape = [bsz, dpDims[1], dpDims[2]];

  return Style(
    await OrtValue.fromList(ttlFlat, ttlShape),
    await OrtValue.fromList(dpFlat, dpShape),
    ttlShape,
    dpShape,
  );
}

Future<Map<String, dynamic>> _loadCfgs(String onnxDir) async {
  final path = '$onnxDir/tts.json';
  final json = jsonDecode(await _readAssetText(path));
  return json as Map<String, dynamic>;
}

Future<String> copyModelToFile(String path) async {
  final byteData = await rootBundle.load(path);
  final tempDir = await getApplicationCacheDirectory();
  final modelPath = '${tempDir.path}/${path.split("/").last}';

  final file = File(modelPath);
  await file.writeAsBytes(byteData.buffer.asUint8List());
  return modelPath;
}

bool _isBundlePath(String path) => path.startsWith('assets/');

/// Baca teks dari bundle atau filesystem, tergantung bentuk path.
Future<String> _readAssetText(String path) async {
  if (_isBundlePath(path)) return rootBundle.loadString(path);

  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException(
      'Asset TTS tidak ditemukan. Pastikan TtsAssetsDownloadService.ensureReady() '
      'sudah selesai sebelum loadTextToSpeech() dipanggil.',
      path,
    );
  }
  return file.readAsString();
}

//
Future<OrtSession> _openModel(OnnxRuntime ort, String path) {
  return _isBundlePath(path)
      ? ort.createSessionFromAsset(path) // plugin yang urus ekstraksi
      : ort.createSession(path); // hasil download, pakai langsung
}

Future<Map<String, OrtSession>> _loadOnnxAll(String dir) async {
  final ort = OnnxRuntime();
  final models = [
    'duration_predictor',
    'text_encoder',
    'vector_estimator',
    'vocoder',
  ];

  final sessions = await Future.wait(
    models.map((name) async {
      final path = '$dir/$name.onnx';
      if (!_isBundlePath(path) && !File(path).existsSync()) {
        throw FileSystemException('ONNX model not found', path);
      }
      logger.d('Loading $name.onnx');
      return _openModel(ort, path);
    }),
  );

  return {
    'dpOrt': sessions[0],
    'textEncOrt': sessions[1],
    'vectorEstOrt': sessions[2],
    'vocoderOrt': sessions[3],
  };
}

List<double> _flattenToDouble(dynamic list) {
  if (list is List) return list.expand((e) => _flattenToDouble(e)).toList();
  return [list is num ? list.toDouble() : double.parse(list.toString())];
}

void writeWavFile(String filename, List<double> audioData, int sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  final dataSize = audioData.length * 2;

  final buffer = ByteData(44 + dataSize);
  var offset = 0;

  // RIFF header
  for (var byte in [0x52, 0x49, 0x46, 0x46]) {
    buffer.setUint8(offset++, byte);
  }
  buffer.setUint32(offset, 36 + dataSize, Endian.little);
  offset += 4;

  // WAVE
  for (var byte in [0x57, 0x41, 0x56, 0x45]) {
    buffer.setUint8(offset++, byte);
  }

  // fmt chunk
  for (var byte in [0x66, 0x6D, 0x74, 0x20]) {
    buffer.setUint8(offset++, byte);
  }
  buffer.setUint32(offset, 16, Endian.little);
  offset += 4;
  buffer.setUint16(offset, 1, Endian.little);
  offset += 2;
  buffer.setUint16(offset, numChannels, Endian.little);
  offset += 2;
  buffer.setUint32(offset, sampleRate, Endian.little);
  offset += 4;
  buffer.setUint32(offset, sampleRate * numChannels * 2, Endian.little);
  offset += 4;
  buffer.setUint16(offset, numChannels * 2, Endian.little);
  offset += 2;
  buffer.setUint16(offset, bitsPerSample, Endian.little);
  offset += 2;

  // data chunk
  for (var byte in [0x64, 0x61, 0x74, 0x61]) {
    buffer.setUint8(offset++, byte);
  }
  buffer.setUint32(offset, dataSize, Endian.little);
  offset += 4;

  // Write audio samples
  for (var i = 0; i < audioData.length; i++) {
    final sample = (audioData[i].clamp(-1.0, 1.0) * 32767).round();
    buffer.setInt16(offset + i * 2, sample, Endian.little);
  }

  File(filename).writeAsBytesSync(buffer.buffer.asUint8List());
}
