class InferredSong {
  final String inferredId;
  final String songId;
  final String? outputPath;
  final String completedAt;
  final String recordingId;

  const InferredSong({
    required this.inferredId,
    required this.songId,
    this.outputPath,
    required this.completedAt,
    required this.recordingId,
  });

  factory InferredSong.fromJson(Map<String, dynamic> json) {
    return InferredSong(
      inferredId: json['inferred_id']?.toString() ?? '',
      songId: json['song_id']?.toString() ?? '',
      outputPath: json['output_path']?.toString(),
      completedAt: json['completed_at']?.toString() ?? '',
      recordingId: json['recording_id']?.toString() ?? '',
    );
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

  /// `Mahakali 2026-04-17` from song_id + completed_at
  String get displayTitle {
    final date = _dateFromCompletedAt(completedAt);
    final mid = middleLabelFromSongId(songId);
    if (date.isEmpty) return mid;
    return '$mid $date';
  }

  static String _dateFromCompletedAt(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    } catch (_) {
      if (iso.length >= 10) return iso.substring(0, 10);
      return '';
    }
  }

  /// Asset key: `M-MAHAKALI-001.png`
  String get iconAssetFileName => '$songId.png';
}
