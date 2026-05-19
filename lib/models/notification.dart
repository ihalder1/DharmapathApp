class NotificationItem {
  final String id;
  final String message;
  final DateTime createdAt;
  final bool isRead;
  final String? type;
  final String? status;

  NotificationItem({
    required this.id,
    required this.message,
    required this.createdAt,
    this.isRead = false,
    this.type,
    this.status,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      id: (json['notificationId'] ?? json['id'] ?? '').toString(),
      message: (json['notification'] ?? json['message'] ?? json['body'] ?? '')
          .toString(),
      createdAt: _parseDateTime(
        json['created_at'] ?? json['sent_at'] ?? json['timestamp'],
      ),
      isRead: _parseReadFlag(json['read_flag'] ?? json['is_read'] ?? json['read']),
      type: json['type']?.toString(),
      status: json['status']?.toString(),
    );
  }

  static bool _parseReadFlag(dynamic value) {
    if (value is bool) return value;
    if (value is String) {
      final s = value.toLowerCase();
      return s == 'true' || s == '1';
    }
    return false;
  }

  static DateTime _parseDateTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is int) {
      // Epoch ms (e.g. timestamp / sent_timestamp).
      if (value > 1e12) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value > 1e9) return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    final s = value.toString();
    if (s.isEmpty) return DateTime.now();
    return DateTime.tryParse(s) ?? DateTime.now();
  }

  NotificationItem copyWith({
    String? id,
    String? message,
    DateTime? createdAt,
    bool? isRead,
    String? type,
    String? status,
  }) {
    return NotificationItem(
      id: id ?? this.id,
      message: message ?? this.message,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      type: type ?? this.type,
      status: status ?? this.status,
    );
  }

  String get formattedDate {
    final now = DateTime.now();
    final difference = now.difference(createdAt);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return 'Just now';
        }
        return '${difference.inMinutes}m ago';
      }
      return '${difference.inHours}h ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
    }
  }
}
