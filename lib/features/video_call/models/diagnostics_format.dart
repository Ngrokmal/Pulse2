/// Text for the diagnostics panel. A missing value is always shown as
/// [unavailable], never as 0, so the panel cannot suggest a measurement
/// that does not exist.
class DiagnosticsFormat {
  const DiagnosticsFormat._();

  /// Shown for anything the platform did not report.
  static const String unavailable = '\u2014';

  static String kbps(double? value) {
    if (value == null || value < 0) return unavailable;
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(2)} Mbit/s';
    return '${value.round()} kbit/s';
  }

  static String percent(double? value) {
    if (value == null || value < 0) return unavailable;
    return '${value.toStringAsFixed(1)} %';
  }

  static String milliseconds(double? value) {
    if (value == null || value < 0) return unavailable;
    return '${value.round()} ms';
  }

  static String fps(double? value) {
    if (value == null || value < 0) return unavailable;
    return '${value.round()} fps';
  }

  static String size(int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return unavailable;
    }
    return '${width}x$height';
  }

  static String bytes(double? value) {
    if (value == null || value < 0) return unavailable;
    if (value >= 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${value.round()} B';
  }

  /// A text field such as an encoder name, or [unavailable].
  static String text(String? value) {
    if (value == null || value.isEmpty) return unavailable;
    return value;
  }
}
