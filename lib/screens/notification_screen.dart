import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../models/notification.dart';
import '../services/notification_service.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  List<NotificationItem> _notifications = [];
  bool _isLoading = true;
  String _filter = 'all'; // 'all', 'unread', 'read'

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final notifications = await NotificationService.getNotifications();
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading notifications: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _markAsRead(NotificationItem notification) async {
    if (notification.isRead) return;

    final success = await NotificationService.markAsRead(notification.id);
    if (success) {
      setState(() {
        final index = _notifications.indexWhere((n) => n.id == notification.id);
        if (index != -1) {
          _notifications[index] = notification.copyWith(isRead: true);
        }
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to mark notification as read'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _markAllAsRead() async {
    final success = await NotificationService.markAllAsRead();
    if (success) {
      setState(() {
        _notifications = _notifications.map((n) => n.copyWith(isRead: true)).toList();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All notifications marked as read'),
            backgroundColor: AppColors.successGreen,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to mark all as read'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteNotification(NotificationItem notification) async {
    final success = await NotificationService.deleteNotification(notification.id);
    if (success) {
      setState(() {
        _notifications.removeWhere((n) => n.id == notification.id);
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to delete notification'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  List<NotificationItem> get _filteredNotifications {
    switch (_filter) {
      case 'unread':
        return _notifications.where((n) => !n.isRead).toList();
      case 'read':
        return _notifications.where((n) => n.isRead).toList();
      default:
        return _notifications;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Notifications',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_notifications.any((n) => !n.isRead))
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text(
                'Mark all read',
                style: TextStyle(
                  color: AppColors.primarySaffron,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Filter buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildFilterButton('all', 'All'),
                const SizedBox(width: 8),
                _buildFilterButton('unread', 'Unread'),
                const SizedBox(width: 8),
                _buildFilterButton('read', 'Read'),
              ],
            ),
          ),
          const Divider(height: 1),
          
          // Notifications list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.primarySaffron),
                    ),
                  )
                : _filteredNotifications.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.notifications_none,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _filter == 'all'
                                  ? 'No notifications'
                                  : _filter == 'unread'
                                      ? 'No unread notifications'
                                      : 'No read notifications',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadNotifications,
                        color: AppColors.primarySaffron,
                        child: ListView.builder(
                          itemCount: _filteredNotifications.length,
                          itemBuilder: (context, index) {
                            final notification = _filteredNotifications[index];
                            return _buildNotificationItem(notification);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterButton(String filter, String label) {
    final isSelected = _filter == filter;
    return Expanded(
      child: ElevatedButton(
        onPressed: () {
          setState(() {
            _filter = filter;
          });
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: isSelected
              ? AppColors.primarySaffron
              : Colors.grey[200],
          foregroundColor: isSelected
              ? AppColors.white
              : Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _buildNotificationItem(NotificationItem notification) {
    return Dismissible(
      key: Key(notification.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(
          Icons.delete,
          color: Colors.white,
        ),
      ),
      onDismissed: (direction) {
        _deleteNotification(notification);
      },
      child: InkWell(
        onTap: () {
          if (!notification.isRead) {
            _markAsRead(notification);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: notification.isRead ? Colors.white : AppColors.primarySaffron.withOpacity(0.05),
            border: Border(
              left: BorderSide(
                color: notification.isRead
                    ? Colors.transparent
                    : AppColors.primarySaffron,
                width: 4,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primarySaffron.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _getNotificationIcon(notification.type),
                  color: AppColors.primarySaffron,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: notification.isRead
                                  ? FontWeight.w500
                                  : FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        if (!notification.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.primarySaffron,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notification.message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      notification.formattedDate,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getNotificationIcon(String? type) {
    switch (type) {
      case 'mantra_generated':
        return Icons.music_note;
      case 'purchase':
        return Icons.shopping_bag;
      case 'system':
        return Icons.info;
      default:
        return Icons.notifications;
    }
  }
}

