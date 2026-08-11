import 'package:flutter/material.dart';
import 'assets_download_progress.dart';
import 'assets_download_service.dart';

/// Kartu progress penyiapan model TTS.
///
/// Menghilang sendiri kalau semua aset sudah lengkap ([AssetsDownloadStatus.ready]),
/// jadi aman ditaruh permanen di atas konten TTSPage.
class AssetsProgressCard extends StatelessWidget {
  const AssetsProgressCard({
    super.key,
    required this.service,
    this.onRetry,
    this.hideWhenReady = true,
  });

  final TtsAssetsDownloadService service;
  final VoidCallback? onRetry;
  final bool hideWhenReady;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AssetsDownloadProgress>(
      stream: service.progress,
      initialData: service.value,
      builder: (context, snapshot) {
        final progress = snapshot.data ?? const AssetsDownloadProgress.idle();

        if (hideWhenReady && progress.isReady) {
          return const SizedBox.shrink();
        }
        if (progress.status == AssetsDownloadStatus.idle) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final failed = progress.status == AssetsDownloadStatus.failed;
        final indeterminate =
            progress.status == AssetsDownloadStatus.checking ||
            progress.totalBytes <= 0;

        final accent = failed
            ? theme.colorScheme.error
            : theme.colorScheme.primary;

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: failed
                ? theme.colorScheme.errorContainer.withValues(alpha: 0.35)
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    failed
                        ? Icons.cloud_off_rounded
                        : Icons.cloud_download_rounded,
                    size: 20,
                    color: accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      failed
                          ? 'Model TTS belum lengkap'
                          : 'Menyiapkan model suara',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!failed && !indeterminate)
                    Text(
                      '${progress.percent}%',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: indeterminate ? null : progress.fraction,
                  minHeight: 8,
                  backgroundColor: accent.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                failed
                    ? (progress.message ?? 'Sebagian file gagal diunduh.')
                    : _subtitleFor(progress),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (!failed) ...[
                const SizedBox(height: 6),
                Text(
                  'Tunggu sebentar, sistem sedang menyiapkan model AI terbaik buat Kamu '
                  'Form dan Tombol putar aktif setelah model siap.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.75,
                    ),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (failed && onRetry != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Coba lagi'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _subtitleFor(AssetsDownloadProgress progress) {
    if (progress.status == AssetsDownloadStatus.checking) {
      return 'Memeriksa file yang sudah tersimpan...';
    }
    final buffer = StringBuffer(progress.readableBytes)
      ..write(' · ')
      ..write('${progress.completedFiles}/${progress.totalFiles} file');
    final current = progress.currentAsset;
    if (current != null) buffer.write(' · ${current.label}');
    return buffer.toString();
  }
}
