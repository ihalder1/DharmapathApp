class NotificationItem {
  final String id;
  final String title;
  final String message;
  final DateTime createdAt;
  final bool isRead;
  final String? type; // e.g., 'mantra_generated', 'purchase', 'system'
  final Map<String, dynamic>? data; // Additional data

  NotificationItem({
    required this.id,
    required this.title,
    required this.message,
    required this.createdAt,
    this.isRead = false,
    this.type,
    this.data,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      id: json['id'] ?? json['notification_id'] ?? '',
      title: json['title'] ?? '',
      message: json['message'] ?? json['body'] ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
      isRead: json['is_read'] ?? json['read'] ?? false,
      type: json['type'],
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'created_at': createdAt.toIso8601String(),
      'is_read': isRead,
      'type': type,
      'data': data,
    };
  }

  NotificationItem copyWith({
    String? id,
    String? title,
    String? message,
    DateTime? createdAt,
    bool? isRead,
    String? type,
    Map<String, dynamic>? data,
  }) {
    return NotificationItem(
      id: id ?? this.id,
      title: title ?? this.title,
      message: message ?? this.message,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      type: type ?? this.type,
      data: data ?? this.data,
    );
  }

  // Helper method to format date
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

