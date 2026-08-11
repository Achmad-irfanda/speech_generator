/// Mengganti nominal uang di dalam teks dengan placeholder `|`.
///
/// Dipakai khusus saat menyusun payload clipboard untuk tim admin QRIS —
/// teks yang dikirim ke model TTS tetap memakai nominal aslinya.
///
/// Bentuk yang dikenali:
///
/// | Input                                   | Output              |
/// |-----------------------------------------|---------------------|
/// | `qris 50.000 rupiah diterima`           | `qris | diterima`   |
/// | `sebesar 5000 rupiah, di terima`        | `sebesar |, di terima` |
/// | `lima ribu rupiah diterima`             | `| diterima`        |
/// | `limaribu rupiah diterima`              | `| diterima`        |
/// | `transfer Rp12.500 berhasil`            | `transfer | berhasil` |
/// | `fifty thousand rupiah received`        | `| received`        |
/// | `dua juta lima ratus ribu rupiah`       | `|`                 |
///
/// Aturan mainnya berbeda untuk dua bentuk:
///
/// - **Angka** dikenali berdiri sendiri, dengan atau tanpa penanda mata uang.
/// - **Kata** (`lima ribu`, `fifty thousand`) WAJIB diikuti penanda mata uang
///   (`rupiah` / `rp` / `idr` / `perak`). Tanpa syarat itu kalimat seperti
///   "dua kali percobaan gagal" ikut tertelan jadi "| kali percobaan gagal".
abstract final class AmountMasker {
  /// Penanda yang menggantikan nominal.
  static const String placeholder = '|';

  /// Penanda mata uang. `\b` ditaruh sebelum titik opsional supaya `rp.`
  /// dan `rupiah,` sama-sama kena.
  static const String _currency = r'(?:rupiah|rupiahs|idr|perak|rp)\b\.?';

  /// Token angka bahasa Indonesia. Prefiks `se` digabung ke suffiks supaya
  /// `sepuluh`, `seratus`, `seribu`, `sejuta`, `sebelas` ikut tertangkap
  /// tanpa perlu mendaftar `se` sebagai token berdiri sendiri.
  static const String _idToken =
      r'(?:(?:se)?(?:puluh|belas|ratus|ribu|juta|milyar|miliar|triliun)'
      r'|nol|satu|dua|tiga|empat|lima|enam|tujuh|delapan|sembilan)';

  static const String _enToken =
      r'(?:zero|one|two|three|four|five|six|seven|eight|nine|ten'
      r'|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen'
      r'|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy'
      r'|eighty|ninety|hundred|thousand|million|billion)';

  /// Pemisah antar token dibuat `*` (bukan `+`) supaya `limaribu` yang
  /// ditulis tanpa spasi tetap terbaca sebagai satu nominal.
  static final RegExp _idWordAmount = RegExp(
    r'\b' '$_idToken' r'(?:[\s-]*' '$_idToken' r')*\s*' '$_currency',
    caseSensitive: false,
  );

  static final RegExp _enWordAmount = RegExp(
    r'\b' '$_enToken' r'(?:[\s-]+(?:and[\s-]+)?' '$_enToken' r')*\s*'
        '$_currency',
    caseSensitive: false,
  );

  static final RegExp _digitAmount = RegExp(
    r'\b(?:(?:rp|idr)\.?\s*)?\d+(?:[.,]\d{3})*(?:\s*' '$_currency' r')?',
    caseSensitive: false,
  );

  /// Placeholder yang berdempetan (misal `50.000 ribu rupiah` yang kena dua
  /// pola sekaligus) dirapatkan jadi satu.
  static final RegExp _repeatedPlaceholder = RegExp(r'\|(?:\s*\|)+');
  static final RegExp _extraSpace = RegExp(r'\s+');
  static final RegExp _spaceBeforePunctuation = RegExp(r'\s+([,.!?;:])');

  /// Mengembalikan [input] dengan setiap nominal diganti [placeholder].
  static String mask(String input) {
    if (input.trim().isEmpty) return '';

    var out = input;
    for (final pattern in [_idWordAmount, _enWordAmount, _digitAmount]) {
      out = out.replaceAll(pattern, ' $placeholder ');
    }

    return out
        .replaceAll(_repeatedPlaceholder, placeholder)
        .replaceAll(_extraSpace, ' ')
        .replaceAllMapped(_spaceBeforePunctuation, (m) => m[1]!)
        .trim();
  }

  /// `true` kalau ada minimal satu nominal di [input].
  static bool hasAmount(String input) =>
      _idWordAmount.hasMatch(input) ||
      _enWordAmount.hasMatch(input) ||
      _digitAmount.hasMatch(input);
}