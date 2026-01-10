import 'package:flutter/material.dart';
import '../models/scheduled_message_model.dart';
import '../services/scheduled_message_service.dart';
import '../utils/logger.dart';
import '../utils/app_localizations.dart';

/// 定时发送弹窗
class ScheduledMessageDialog extends StatefulWidget {
  final String token;
  final int receiverId;
  final bool isGroup;
  final String receiverName;

  const ScheduledMessageDialog({
    super.key,
    required this.token,
    required this.receiverId,
    required this.isGroup,
    required this.receiverName,
  });

  @override
  State<ScheduledMessageDialog> createState() => _ScheduledMessageDialogState();
}

class _ScheduledMessageDialogState extends State<ScheduledMessageDialog> {
  List<ScheduledMessageModel> _messages = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final messages = await ScheduledMessageService.getList(
        token: widget.token,
        receiverId: widget.receiverId,
        isGroup: widget.isGroup,
      );
      if (mounted) {
        setState(() {
          _messages = messages;
          _isLoading = false;
        });
      }
    } catch (e) {
      logger.error('加载定时消息列表失败: $e');
      if (mounted) {
        setState(() {
          _error = '加载失败，请重试';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _deleteMessage(ScheduledMessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除定时任务"${message.title}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final success = await ScheduledMessageService.delete(
          token: widget.token,
          id: message.id,
        );
        if (success) {
          _loadMessages();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('删除成功')),
            );
          }
        }
      } catch (e) {
        logger.error('删除定时消息失败: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除失败，请重试')),
          );
        }
      }
    }
  }

  void _showEditDialog([ScheduledMessageModel? message]) {
    showDialog(
      context: context,
      builder: (context) => ScheduledMessageEditDialog(
        token: widget.token,
        receiverId: widget.receiverId,
        isGroup: widget.isGroup,
        message: message,
        onSaved: () {
          _loadMessages();
        },
      ),
    );
  }

  String _getSendTypeText(ScheduledMessageSendType type) {
    switch (type) {
      case ScheduledMessageSendType.once:
        return '单次';
      case ScheduledMessageSendType.daily:
        return '每日';
    }
  }

  String _getStatusText(ScheduledMessageStatus status) {
    switch (status) {
      case ScheduledMessageStatus.pending:
        return '待发送';
      case ScheduledMessageStatus.sent:
        return '已发送';
      case ScheduledMessageStatus.deleted:
        return '已删除';
    }
  }

  Color _getStatusColor(ScheduledMessageStatus status) {
    switch (status) {
      case ScheduledMessageStatus.pending:
        return Colors.orange;
      case ScheduledMessageStatus.sent:
        return Colors.green;
      case ScheduledMessageStatus.deleted:
        return Colors.grey;
    }
  }



  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 标题栏
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '定时发送',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            // 内容区域
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(_error!, style: const TextStyle(color: Colors.red)),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _loadMessages,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : _messages.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.schedule,
                                    size: 64,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    '暂无定时任务',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '点击下方按钮添加定时发送任务',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final message = _messages[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text(
                                      message.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        // 第一行：时间
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.access_time,
                                              size: 14,
                                              color: Colors.grey[600],
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              message.sendTime,
                                              style: TextStyle(
                                                color: Colors.grey[600],
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        // 第二行：标签
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.withOpacity(0.1),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _getSendTypeText(message.sendType),
                                                style: const TextStyle(
                                                  color: Colors.blue,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: _getStatusColor(message.status)
                                                    .withOpacity(0.1),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _getStatusText(message.status),
                                                style: TextStyle(
                                                  color: _getStatusColor(message.status),
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          message.content,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.grey[700],
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                    trailing: message.status == ScheduledMessageStatus.pending
                                        ? PopupMenuButton<String>(
                                            icon: const Icon(Icons.more_vert),
                                            onSelected: (value) {
                                              if (value == 'edit') {
                                                _showEditDialog(message);
                                              } else if (value == 'delete') {
                                                _deleteMessage(message);
                                              }
                                            },
                                            itemBuilder: (context) => [
                                              const PopupMenuItem(
                                                value: 'edit',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.edit, size: 20),
                                                    SizedBox(width: 8),
                                                    Text('编辑'),
                                                  ],
                                                ),
                                              ),
                                              const PopupMenuItem(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.delete, size: 20, color: Colors.red),
                                                    SizedBox(width: 8),
                                                    Text('删除', style: TextStyle(color: Colors.red)),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          )
                                        : null,
                                    isThreeLine: true,
                                  ),
                                );
                              },
                            ),
            ),
            const SizedBox(height: 8),
            // 添加按钮
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showEditDialog(),
                icon: const Icon(Icons.add),
                label: const Text('新增定时任务'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 定时消息编辑弹窗
class ScheduledMessageEditDialog extends StatefulWidget {
  final String token;
  final int receiverId;
  final bool isGroup;
  final ScheduledMessageModel? message;
  final VoidCallback onSaved;

  const ScheduledMessageEditDialog({
    super.key,
    required this.token,
    required this.receiverId,
    required this.isGroup,
    this.message,
    required this.onSaved,
  });

  @override
  State<ScheduledMessageEditDialog> createState() => _ScheduledMessageEditDialogState();
}

class _ScheduledMessageEditDialogState extends State<ScheduledMessageEditDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  TimeOfDay _selectedTime = TimeOfDay.now();
  DateTime _selectedDate = DateTime.now(); // 🔴 新增：单次任务的日期
  bool _isDaily = false;
  bool _isSaving = false;
  String? _timeError; // 🔴 时间验证错误信息

  bool get _isEditing => widget.message != null;

  @override
  void initState() {
    super.initState();
    if (widget.message != null) {
      _titleController.text = widget.message!.title;
      _contentController.text = widget.message!.content;
      _isDaily = widget.message!.sendType == ScheduledMessageSendType.daily;
      // 解析时间
      final timeParts = widget.message!.sendTime.split(':');
      if (timeParts.length == 2) {
        _selectedTime = TimeOfDay(
          hour: int.tryParse(timeParts[0]) ?? 0,
          minute: int.tryParse(timeParts[1]) ?? 0,
        );
      }
      // 🔴 解析日期（如果有）
      if (widget.message!.sendDate != null && widget.message!.sendDate!.isNotEmpty) {
        final dateParts = widget.message!.sendDate!.split('-');
        if (dateParts.length == 3) {
          _selectedDate = DateTime(
            int.tryParse(dateParts[0]) ?? DateTime.now().year,
            int.tryParse(dateParts[1]) ?? DateTime.now().month,
            int.tryParse(dateParts[2]) ?? DateTime.now().day,
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  // 🔴 新增：选择日期
  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _timeError = null;
      });
    }
  }

  Future<void> _selectTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedTime) {
      setState(() {
        _selectedTime = picked;
        _timeError = null; // 🔴 选择新时间时清除错误
      });
    }
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  // 🔴 新增：格式化日期
  String _formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  // 🔴 新增：格式化日期用于显示
  String _formatDateForDisplay(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$month月$day日';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 🔴 验证发送时间：需要距离当前时间至少1分钟
    final now = DateTime.now();
    
    DateTime selectedDateTime;
    if (_isDaily) {
      // 每日任务：只比较时间
      selectedDateTime = DateTime(
        now.year,
        now.month,
        now.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );
    } else {
      // 单次任务：使用选择的日期和时间
      selectedDateTime = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );
    }

    // 计算时间差（秒）
    int diffSeconds = selectedDateTime.difference(now).inSeconds;
    
    if (!_isDaily) {
      // 单次任务：必须是未来至少1分钟
      if (diffSeconds < 60) {
        setState(() {
          _timeError = '发送时间需要距离当前时间至少1分钟';
        });
        return;
      }
    } else {
      // 每日任务：如果今天的时间距离当前不足1分钟（但还没过），也不允许
      if (diffSeconds >= 0 && diffSeconds < 60) {
        setState(() {
          _timeError = '发送时间需要距离当前时间至少1分钟';
        });
        return;
      }
    }

    // 清除时间错误
    setState(() {
      _timeError = null;
      _isSaving = true;
    });

    try {
      final sendTime = _formatTime(_selectedTime);
      final sendDate = _isDaily ? null : _formatDate(_selectedDate); // 🔴 单次任务才传日期

      if (_isEditing) {
        await ScheduledMessageService.update(
          token: widget.token,
          id: widget.message!.id,
          title: _titleController.text.trim(),
          sendTime: sendTime,
          sendDate: sendDate,
          isDaily: _isDaily,
          content: _contentController.text.trim(),
        );
      } else {
        await ScheduledMessageService.create(
          token: widget.token,
          receiverId: widget.receiverId,
          isGroup: widget.isGroup,
          title: _titleController.text.trim(),
          sendTime: sendTime,
          sendDate: sendDate,
          isDaily: _isDaily,
          content: _contentController.text.trim(),
        );
      }

      if (mounted) {
        Navigator.pop(context);
        widget.onSaved();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isEditing ? '更新成功' : '创建成功')),
        );
      }
    } catch (e) {
      logger.error('保存定时消息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题栏
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _isEditing ? '编辑定时任务' : '新增定时任务',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 任务标题
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: '任务标题',
                    hintText: '请输入任务标题',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 100,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return '请输入任务标题';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                // 🔴 发送类型（移到日期/时间选择器之前）
                const Text(
                  '发送类型',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<bool>(
                        title: const Text('单次'),
                        value: false,
                        groupValue: _isDaily,
                        onChanged: (value) {
                          setState(() {
                            _isDaily = value!;
                            _timeError = null;
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<bool>(
                        title: const Text('每日'),
                        value: true,
                        groupValue: _isDaily,
                        onChanged: (value) {
                          setState(() {
                            _isDaily = value!;
                            _timeError = null;
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 🔴 单次任务显示日期选择器
                if (!_isDaily) ...[
                  InkWell(
                    onTap: _selectDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '发送日期',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                      child: Text(
                        _formatDateForDisplay(_selectedDate),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                // 发送时间
                InkWell(
                  onTap: _selectTime,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: '发送时间',
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.access_time),
                      errorText: _timeError,
                      errorStyle: const TextStyle(color: Colors.red),
                    ),
                    child: Text(
                      _formatTime(_selectedTime),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 消息内容
                TextFormField(
                  controller: _contentController,
                  decoration: const InputDecoration(
                    labelText: '消息内容',
                    hintText: '请输入要发送的消息内容',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  maxLength: 1000,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return '请输入消息内容';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                // 保存按钮
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isEditing ? '保存' : '创建'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
