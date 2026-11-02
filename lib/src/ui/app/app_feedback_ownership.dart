import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../model/app_snapshot.dart';

/// 记录负责显示命令反馈的界面及其已处理的结果，不结束业务操作。
class AppFeedbackOwnership {
  AppFeedbackOwnership(this._changed);

  final VoidCallback _changed;
  ValueListenable<bool>? _owner;
  Map<String, Object?>? _command;
  String? _operationId;
  Map<String, Object?>? _handledSubmissionCommand;
  String? _handledResultId;
  bool _disposed = false;

  bool owns(Map<String, Object?>? command) =>
      _owner != null && identical(_command, command);

  bool handledLocally(
    Map<String, Object?> command, {
    required bool submissionFailed,
    String? resultId,
  }) => submissionFailed
      ? identical(command, _handledSubmissionCommand)
      : resultId != null && resultId == _handledResultId;

  void acknowledge(
    ValueListenable<bool> owner, {
    required Map<String, Object?>? command,
    required bool submissionFailed,
    AppSnapshot? result,
  }) {
    if (_disposed ||
        !identical(owner, _owner) ||
        !identical(_command, command)) {
      return;
    }
    if (result != null &&
        (result.resultId == null || result.resultId != _operationId)) {
      return;
    }
    if (result != null) {
      _handledResultId = result.resultId;
    } else if (_operationId == null && submissionFailed) {
      _handledSubmissionCommand = command;
    }
    detach();
    changed();
  }

  void beginCommand() {
    detach();
    _handledSubmissionCommand = null;
  }

  void attach(ValueListenable<bool>? owner, Map<String, Object?> command) {
    detach();
    if (_disposed || owner == null || !owner.value) return;
    _owner = owner;
    _command = command;
    owner.addListener(_ownerChanged);
  }

  void admitted(Map<String, Object?> command, String? operationId) {
    if (identical(_command, command)) _operationId = operationId;
  }

  void _ownerChanged() {
    if (_owner?.value != false) return;
    detach();
    changed();
  }

  void detach() {
    _owner?.removeListener(_ownerChanged);
    _owner = null;
    _command = null;
    _operationId = null;
  }

  void changed() {
    // 页面可能在 build/dispose 中清除反馈归属标记，树更新结束后再发送通知。
    scheduleMicrotask(() {
      if (!_disposed) _changed();
    });
  }

  void dispose() {
    _disposed = true;
    detach();
    _handledSubmissionCommand = null;
    _handledResultId = null;
  }
}
