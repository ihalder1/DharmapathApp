import 'package:intl/intl.dart';

class InferredSong {
  final String inferredId;

  /// DELETE `/auth/profile/inferred/songs/{transaction_id}` path segment.
  final String transactionId;
  final String songId;
  final String? outputPath;
  final String completedAt;
  final String recordingId;

  /// From API `recording_name` (user's recording label).
  final String recordingName;

  const InferredSong({
    required this.inferredId,
    required this.transactionId,
    required this.songId,
    this.outputPath,
    required this.completedAt,
    required this.recordingId,
    this.recordingName = '',
  });

  factory InferredSong.fromJson(Map<String, dynamic> json) {
    final inferredId = json['inferred_id']?.toString() ?? '';
    final transactionId = json['transaction_id']?.toString() ?? inferredId;
    return InferredSong(
      inferredId: inferredId,
      transactionId: transactionId,
      songId: json['song_id']?.toString() ?? '',
      outputPath: json['output_path']?.toString(),
      completedAt: json['completed_at']?.toString() ?? '',
      recordingId: json['recording_id']?.toString() ?? '',
      recordingName:
          json['recording_name']?.toString() ??
          json['recordingName']?.toString() ??
          '',
    );
  }

  /// `YYYY-MM-DD` from [completedAt], or empty if unparseable.
  String get completedDateShort {
    try {
      final d = DateTime.parse(completedAt).toLocal();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    } catch (_) {
      if (completedAt.length >= 10) return completedAt.substring(0, 10);
      return '';
    }
  }

  /// e.g. `M-MAHAKALI-001` → middle segment(s) title-cased → `Mahakali`
  static String middleLabelFromSongId(String songId) {
    final parts = songId.split('-');
    if (parts.length >= 3) {
      final mid = parts.sublist(1, parts.length - 1).join(' ');
      return _titleCaseWord(mid.replaceAll('_', ' '));
    }
    if (parts.length == 2) {
      return _titleCaseWord(parts[1]);
    }
    return songId;
  }

  static String _titleCaseWord(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  /// My Mantras card line 1: `recording_name Middle yyyy-MM-dd h:mm AM/PM` (spaces, local time).
  String get myMantrasCardTitle {
    final rec = recordingName.trim();
    final mid = middleLabelFromSongId(songId);
    try {
      final dt = DateTime.parse(completedAt).toLocal();
      final datePart = DateFormat('yyyy-MM-dd').format(dt);
      final timePart = DateFormat('hh:mm a').format(dt);
      final parts = <String>[];
      if (rec.isNotEmpty) parts.add(rec);
      parts.add(mid);
      parts.add(datePart);
      parts.add(timePart);
      return parts.join(' ');
    } catch (_) {
      final parts = <String>[];
      if (rec.isNotEmpty) parts.add(rec);
      if (mid.isNotEmpty) parts.add(mid);
      final d = completedDateShort;
      if (d.isNotEmpty) parts.add(d);
      return parts.join(' ');
    }
  }

  /// Share / snackbar caption — same as [myMantrasCardTitle].
  String get displayTitle => myMantrasCardTitle;

  /// Asset key: `M-MAHAKALI-001.png`
  String get iconAssetFileName => '$songId.png';
}
