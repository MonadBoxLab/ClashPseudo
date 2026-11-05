import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:clash_pseudo/src/ui/components/input/task_shortcuts.dart';

import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_find_controller.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/ui/components/feedback/confirm_action.dart';

const directConfigTemplate = '# 默认直连配置。\nrules:\n  - MATCH,DIRECT\n';

(ConfigTextDocument, CodeLines?, int?) _prepareText(String text) {
  checkConfigText(text);
  final oversized = firstOversizedEditorLine(text);
  final document = ConfigTextDocument(text);
  return (
    document,
    oversized == null ? CodeLines.fromText(document.editable) : null,
    oversized,
  );
}

int _encodedSize((String, String, bool) value) => utf8
    .encode(
      '${value.$3 ? '\u{feff}' : ''}${value.$1.replaceAll('\n', value.$2)}',
    )
    .length;

class ConfigTextPage extends StatefulWidget {
  const ConfigTextPage({
    super.key,
    required this.app,
    this.entry,
    this.initialText = directConfigTemplate,
    this.initialName = '本地配置',
    this.readOnly = false,
    this.onSave,
    this.saveLabel,
    this.storageEpoch,
  });

  final AppController app;
  final ConfigEntry? entry;
  final String initialText;
  final String initialName;
  final int? storageEpoch;

  /// Overrides the default local-config save with another store action, such as
  /// an override fragment. [initialText] is then the current body.
  final bool readOnly;
  final Future<AppSnapshot?> Function(
    Map<String, Object?> command,
    ValueListenable<bool> feedbackOwner,
  )?
  onSave;
  final String Function(AppLocalizations)? saveLabel;

  @override
  State<ConfigTextPage> createState() => _ConfigTextPageState();
}

class _ConfigTextPageState extends State<ConfigTextPage> {
  final _focus = FocusNode();
  final _toolbarContentKey = GlobalKey();
  late final _selectionToolbar = MobileSelectionToolbarController(
    builder:
        ({
          required context,
          required anchors,
          required controller,
          required onDismiss,
          required onRefresh,
        }) {
          final authority = _inputAuthority;
          bool canUse() =>
              identical(authority, _inputAuthority) && _interactive;
          bool canEdit() => canUse() && _editable;
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: anchors,
            buttonItems: [
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: () {
                  if (canUse()) unawaited(controller.copy());
                  onDismiss();
                },
              ),
              if (_editable)
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.cut,
                  onPressed: () {
                    if (canEdit()) controller.cut();
                    onDismiss();
                  },
                ),
              if (_editable)
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.paste,
                  onPressed: () {
                    if (canEdit()) controller.paste();
                    onDismiss();
                  },
                ),
              ContextMenuButtonItem(
                type: ContextMenuButtonType.selectAll,
                onPressed: () {
                  if (!canUse()) {
                    onDismiss();
                    return;
                  }
                  controller.selectAll();
                  onRefresh();
                },
              ),
            ],
          );
        },
  );
  final _feedbackOwner = ValueNotifier<bool>(true);
  Object? _saveFeedbackIdentity;
  CodeLineEditingController? _editor;
  ConfigFindController? _find;
  Object? _findErrorNoticed;
  bool _findNoticeScheduled = false;
  ConfigTextDocument? _document;
  CodeLines? _savedLines;
  CodeLines? _lastLines;
  CodeLineSelection? _beforeFind;
  String? _id;
  int? _revision;
  int? _previewLine;
  bool _preparationStarted = false;
  AppMessage? _preparationErrorMessage;
  bool _preparationNoticed = false;
  bool _preparationNoticeScheduled = false;
  bool _contentDirty = false;
  bool get _dirty => _contentDirty;
  bool _saving = false;
  bool _overLimit = false;
  bool _sizeCheckFailed = false;
  (Object, AppMessage)? _inputNotice;
  AppMessage? _saveError;
  (String?, int?, int, int, bool, bool, bool)? _admissionIdentity;
  bool get _taskActive => mounted && AppTaskActivity.isActive(context);
  Object _inputAuthority = Object();
  bool _sizeChecking = false;
  int _sizeRevision = 0;
  Timer? _sizeTimer;
  bool _unconfirmed = false;
  bool _wordWrap = true;
  bool _focusedBeforeFind = false;
  CodeLines? _findLines;
  Completer<void>? _leaving;
  late final int _storageEpoch;
  ModalRoute<dynamic>? _overviewRoute;
  ModalRoute<dynamic>? _confirmationRoute;
  late final Future<bool> Function() _overviewLeave = _leaveForOverview;
  Future<bool> _leaveForOverview() => _leave(forOverview: true);

  bool get _liveRoute =>
      (_overviewRoute?.isActive ?? true) &&
      _overviewRoute?.animation?.status != AnimationStatus.reverse;
  bool _eligible({ModalRoute<dynamic>? ownedPopup}) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
      AppTaskActivity.routeIsActive(_overviewRoute, ownedPopup: ownedPopup);
  bool get _interactive => _eligible();
  bool get _readOnly =>
      widget.readOnly ||
      widget.entry?.remote == true ||
      _preparationErrorMessage != null;
  bool get _canWrite =>
      (widget.onSave == null
          ? widget.app.canEdit
          : widget.app.canEditOverrides) &&
      !_unconfirmed &&
      widget.app.storageEpoch == _storageEpoch &&
      widget.app.state.storageEpoch == _storageEpoch &&
      _targetCurrent;
  bool get _editorContextCurrent => _eligible(ownedPopup: _confirmationRoute);
  bool get _editable => _editorContextCurrent && !_readOnly && !_saving;

  bool get _targetCurrent {
    if (widget.onSave != null) {
      if (!widget.app.overridesLoaded) return false;
      if (_id == null) return _revision == null;
      for (final entry in widget.app.overrides) {
        if (entry.id == _id) {
          return entry.revision == _revision && !entry.remote;
        }
      }
      return false;
    }
    if (_id == null) return _revision == null;
    final current = widget.app.collection.find(_id);
    return current != null && current.revision == _revision && !current.remote;
  }

  bool get _running =>
      _id != null &&
      widget.app.state.running &&
      widget.app.state.configId == _id;

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? widget.app.storageEpoch;
    _id = widget.entry?.id;
    _revision = widget.entry?.revision;
    widget.app.addListener(_appChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _overviewRoute)) {
      final previous = _overviewRoute;
      if (previous != null) {
        widget.app.unregisterOverviewLeave(previous, _overviewLeave);
        previous.animation?.removeStatusListener(_routeStatusChanged);
      }
      _overviewRoute = route;
      if (route != null) {
        widget.app.registerOverviewLeave(route, _overviewLeave);
        route.animation?.addStatusListener(_routeStatusChanged);
      }
    }
    if (!_preparationStarted) {
      _preparationStarted = true;
      unawaited(_prepare());
    }
    _refreshAdmission();
    if (!_interactive) {
      _retireInput();
    } else {
      _schedulePreparationNotice();
      _scheduleFindNotice();
    }
  }

  void _retireInput() {
    _selectionToolbar.hide(context);
    _find?.findInputFocusNode.unfocus();
    _focus.unfocus();
    // A covering leave confirmation keeps its pending result until the actual
    // decision. A retired task, background app or exiting route releases it.
    if (!widget.app.foreground ||
        !_liveRoute ||
        (!_taskActive && (_overviewRoute?.isCurrent ?? true))) {
      _feedbackOwner.value = false;
    }
  }

  void _routeStatusChanged(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed) {
      _schedulePreparationNotice();
      _scheduleFindNotice();
    }
    if (status != AnimationStatus.reverse) return;
    _refreshAdmission();
    _retireInput();
  }

  Future<void> _prepare() async {
    try {
      final text = widget.entry?.body ?? widget.initialText;
      final prepared = text.length >= 256 * 1024
          ? await compute(_prepareText, text)
          : _prepareText(text);
      if (!mounted) return;
      _document = prepared.$1;
      _previewLine = prepared.$3;
      final lines = prepared.$2;
      if (lines == null) {
        _preparationErrorMessage = AppMessage.withArgs('editorLineTooLong', {
          'line': _previewLine!,
          'limit': maxEditorCodeUnits,
        });
        setState(() {});
        _schedulePreparationNotice();
        return;
      }
      final editor = CodeLineEditingController(codeLines: lines);
      _editor = editor;
      _refreshAdmission();
      _savedLines = editor.codeLines;
      _lastLines = editor.codeLines;
      _find = ConfigFindController(editor, onQueryRejected: _queryRejected)
        ..addListener(_findChanged);
      editor.addListener(_edited);
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _preparationErrorMessage = error is ConfigFailure
            ? error.message
            : messages.bodyPrepFailed.withDetail(error),
      );
      _schedulePreparationNotice();
    }
  }

  void _schedulePreparationNotice() {
    if (_preparationErrorMessage == null ||
        _preparationNoticed ||
        _preparationNoticeScheduled) {
      return;
    }
    _preparationNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _preparationNoticeScheduled = false;
      final message = _preparationErrorMessage;
      if (!mounted || message == null || _preparationNoticed || !_interactive) {
        return;
      }
      _preparationNoticed = true;
      bool current() => mounted && identical(_preparationErrorMessage, message);
      final presented = await showAppNotice(
        context,
        message,
        identity: message,
        eligibilityChanges: widget.app,
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && _eligible(ownedPopup: popup),
      );
      if (!presented && current()) {
        _preparationNoticed = false;
        if (_interactive) _schedulePreparationNotice();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _refreshAdmission() {
    final editor = _editor;
    if (editor == null) return;
    final identity = (
      _id,
      _revision,
      widget.app.storageEpoch,
      widget.app.state.storageEpoch,
      _editable,
      _canWrite,
      _interactive,
    );
    if (identity == _admissionIdentity) return;
    _admissionIdentity = identity;
    final authority = Object();
    _inputAuthority = authority;
    editor.acceptValue = (current, candidate) =>
        identical(authority, _inputAuthority) &&
        _acceptEditorValue(current, candidate);
  }

  bool _acceptEditorValue(
    CodeLineEditingValue current,
    CodeLineEditingValue candidate,
  ) {
    if (!_editorContextCurrent) return false;
    if (identical(current.codeLines, candidate.codeLines)) return true;
    if (!_editable) {
      _notice(const AppMessage('editorContextChanged'));
      return false;
    }
    final oversized = firstOversizedCodeLine(
      candidate.codeLines,
      previous: current.codeLines,
    );
    if (oversized != null) {
      _notice(
        AppMessage.withArgs('editorChangeTooLong', {
          'line': oversized,
          'limit': maxEditorCodeUnits,
        }),
      );
      return false;
    }
    _notice(_canWrite ? null : const AppMessage('editorContextChanged'));
    return true;
  }

  void _notice(AppMessage? message) {
    final authority = _inputAuthority;
    final notice = message == null ? null : (authority, message);
    if (mounted && notice != _inputNotice) {
      setState(() => _inputNotice = notice);
      if (message != null) {
        bool current() =>
            mounted &&
            identical(authority, _inputAuthority) &&
            _inputNotice == notice;
        unawaited(
          showAppNotice(
            context,
            message,
            identity: notice,
            isCurrent: () => current() && _interactive,
            isCurrentWithPopup: (popup) =>
                current() && _eligible(ownedPopup: popup),
            eligibilityChanges: widget.app,
          ),
        );
      }
    }
  }

  void _appChanged() {
    if (!mounted) return;
    final authority = _inputAuthority;
    _refreshAdmission();
    if (!_interactive) {
      _retireInput();
    } else if (!_editable || !identical(authority, _inputAuthority)) {
      _selectionToolbar.hide(context);
    }
    if (!_readOnly &&
        !_saving &&
        !identical(authority, _inputAuthority) &&
        (!_editable || !_canWrite)) {
      _notice(_inputNotice?.$2 ?? const AppMessage('editorContextChanged'));
    } else if (_editable &&
        _canWrite &&
        _inputNotice?.$2.id == 'editorContextChanged') {
      _inputNotice = null;
    }
    if (_interactive) {
      _schedulePreparationNotice();
      _scheduleFindNotice();
    }
    setState(() {});
  }

  void _queryRejected() => _notice(
    AppMessage.withArgs('editorQueryTooLong', {'limit': maxEditorCodeUnits}),
  );

  void _findChanged() {
    if (!mounted) return;
    if (_find?.error == null) _findErrorNoticed = null;
    _scheduleFindNotice();
    setState(() {});
  }

  void _scheduleFindNotice() {
    final find = _find;
    final error = find?.error;
    if (error == null ||
        identical(_findErrorNoticed, error) ||
        _findNoticeScheduled) {
      return;
    }
    _findNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _findNoticeScheduled = false;
      bool current() =>
          mounted && identical(_find, find) && identical(find!.error, error);
      if (!current()) {
        if (mounted) _scheduleFindNotice();
        return;
      }
      if (!_interactive || identical(_findErrorNoticed, error)) return;
      _findErrorNoticed = error;
      final presented = await showLocalizedOperationNotice(
        context,
        (strings) => strings.operationFailed,
        technicalDetail: (_) => error.toString(),
        identity: error,
        eligibilityChanges: Listenable.merge([find, widget.app]),
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && _eligible(ownedPopup: popup),
        onRetry: () async {
          if (current() && _interactive) find!.retry();
        },
      );
      if (!presented && current() && identical(_findErrorNoticed, error)) {
        _findErrorNoticed = null;
        if (_interactive) _scheduleFindNotice();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _edited() {
    final lines = _editor!.codeLines;
    if (identical(lines, _lastLines)) return;
    _lastLines = lines;
    final dirty = !lines.equals(_savedLines!);
    if (_contentDirty != dirty) setState(() => _contentDirty = dirty);
    _sizeRevision++;
    _sizeTimer?.cancel();
    _sizeTimer = Timer(const Duration(milliseconds: 150), _measureSize);
  }

  Future<void> _measureSize() async {
    if (_sizeChecking || !mounted) return;
    _sizeChecking = true;
    var revision = _sizeRevision;
    try {
      do {
        revision = _sizeRevision;
        // Save unchanged text with its original bytes and mixed line endings.
        if (!_dirty) {
          if (_overLimit || _sizeCheckFailed) {
            setState(() {
              _overLimit = false;
              _sizeCheckFailed = false;
            });
          }
          return;
        }
        final text = _editor!.text;
        final input = (text, _document!.newline, _document!.bom);
        final size = text.length >= 256 * 1024
            ? await compute(_encodedSize, input)
            : _encodedSize(input);
        if (!mounted) return;
        if (revision == _sizeRevision &&
            (_sizeCheckFailed || _overLimit != (size > maxConfigBytes))) {
          final notifyLimit = !_overLimit && size > maxConfigBytes;
          setState(() {
            _overLimit = size > maxConfigBytes;
            _sizeCheckFailed = false;
          });
          if (notifyLimit) {
            unawaited(
              showLocalizedOperationNotice(
                context,
                (strings) => strings.tooLarge,
                isCurrent: () => _interactive && _overLimit,
                isCurrentWithPopup: (popup) =>
                    _eligible(ownedPopup: popup) && _overLimit,
                eligibilityChanges: widget.app,
              ),
            );
          }
        }
      } while (revision != _sizeRevision);
    } catch (error) {
      if (mounted && revision == _sizeRevision) {
        setState(() => _sizeCheckFailed = true);
        unawaited(
          showLocalizedOperationNotice(
            context,
            (strings) => strings.sizePending,
            technicalDetail: (_) => error.toString(),
            isCurrent: () => _interactive && _sizeCheckFailed,
            isCurrentWithPopup: (popup) =>
                _eligible(ownedPopup: popup) && _sizeCheckFailed,
            eligibilityChanges: widget.app,
            onRetry: _measureSize,
          ),
        );
      }
    } finally {
      _sizeChecking = false;
      if (mounted && revision != _sizeRevision) unawaited(_measureSize());
    }
  }

  VoidCallback _inputAction(VoidCallback action) {
    final authority = _inputAuthority;
    return () {
      if (identical(authority, _inputAuthority) && _interactive) action();
    };
  }

  void _openFind() {
    if (!_interactive || _editor == null || _find?.value != null) return;
    _beforeFind = _editor!.selection;
    _findLines = _editor!.codeLines;
    _focusedBeforeFind = _focus.hasFocus;
    _find!.findMode();
    final authority = _inputAuthority;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(authority, _inputAuthority) &&
          _interactive &&
          _find?.value != null) {
        _find!.findInputFocusNode.requestFocus();
      }
    });
  }

  void _closeFind() {
    if (!_interactive || _find?.value == null) return;
    _find!.findInputFocusNode.unfocus();
    _find!.close();
    if (_beforeFind != null && identical(_findLines, _editor!.codeLines)) {
      _editor!.selection = _beforeFind!;
    }
    if (_focusedBeforeFind) {
      _focus.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  Future<bool> _leave({bool forOverview = false}) async {
    if (!_interactive || _leaving != null) return false;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    final leaving = Completer<void>();
    _leaving = leaving;
    try {
      if (_find?.value != null) {
        _closeFind();
        if (!forOverview) return false;
      }
      if (_saving || _unconfirmed) {
        final leave = await confirmAction(
          context,
          title: (strings) => strings.leaveBodyTitle,
          message: (strings) => strings.leaveBodyMessage,
          confirmLabel: (strings) => strings.leave,
          onRoute: (route) => _confirmationRoute = route,
          isCurrent: () => _eligible(ownedPopup: _confirmationRoute),
        );
        if (!leave || !mounted) return false;
      } else if (_dirty) {
        final discard = await confirmAction(
          context,
          title: (strings) => strings.discardEditsTitle,
          message: (strings) => strings.discardEditsMessage,
          confirmLabel: (strings) => strings.discard,
          cancelLabel: (strings) => strings.continueEditing,
          onRoute: (route) => _confirmationRoute = route,
          isCurrent: () => _eligible(ownedPopup: _confirmationRoute),
        );
        if (!discard || !mounted) return false;
      }
      if (!_interactive || !route.isCurrent) return false;
      _focus.unfocus();
      Navigator.pop(context);
      return !route.isActive;
    } finally {
      _leaving = null;
      leaving.complete();
    }
  }

  Future<void> _save() async {
    if (!_editable || _editor == null || !_canWrite) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null || !route.isActive || !route.isCurrent) return;
    if (_id == null && widget.initialName.trim().isEmpty) {
      await showLocalizedOperationNotice(
        context,
        (strings) => strings.nameRequired,
        isCurrent: () => _interactive,
        isCurrentWithPopup: (popup) => _eligible(ownedPopup: popup),
      );
      return;
    }
    final submittedLines = _editor!.codeLines;
    final edited = _editor!.text;
    if (_document!.mixed && edited != _document!.editable) {
      final allowed = await confirmAction(
        context,
        title: (strings) => strings.normalizeNewlinesTitle,
        message: (strings) => strings.normalizeNewlinesMessage,
        confirmLabel: (strings) => strings.normalizeAndSave,
        onRoute: (route) => _confirmationRoute = route,
        isCurrent: () => _eligible(ownedPopup: _confirmationRoute),
      );
      if (!allowed || !mounted) return;
    }
    String body;
    try {
      body = _document!.serialize(edited);
      checkConfigText(body);
    } on ConfigFailure catch (error) {
      if (_interactive) {
        await showAppNotice(
          context,
          error.message,
          isCurrent: () => _interactive,
          isCurrentWithPopup: (popup) => _eligible(ownedPopup: popup),
        );
      }
      return;
    }
    if (!mounted ||
        !route.isActive ||
        !route.isCurrent ||
        !_editable ||
        !_canWrite) {
      return;
    }
    _selectionToolbar.hide(context);
    _focus.unfocus();
    final feedbackIdentity = Object();
    _saveFeedbackIdentity = feedbackIdentity;
    _feedbackOwner.value = true;
    setState(() {
      _saving = true;
      _refreshAdmission();
    });
    final command = {
      'storageEpoch': _storageEpoch,
      'id': _id,
      'revision': _revision,
      'name': widget.initialName,
      'body': body,
    };
    AppSnapshot? outcome;
    Object? feedbackSource;
    Object currentSource() {
      (String, int, bool)? entryIdentity;
      final id = _id;
      if (id != null) {
        if (widget.onSave == null) {
          final entry = widget.app.collection.find(id);
          if (entry != null) {
            entryIdentity = (entry.id, entry.revision, entry.remote);
          }
        } else {
          final entry = widget.app.overrides
              .where((item) => item.id == id)
              .firstOrNull;
          if (entry != null) {
            entryIdentity = (entry.id, entry.revision, entry.remote);
          }
        }
      }
      return (
        widget.app,
        widget.app.storageEpoch,
        widget.app.state.storageEpoch,
        _id,
        _revision,
        entryIdentity,
      );
    }

    var feedbackPresented = false;
    bool sameFeedback() =>
        mounted &&
        identical(_saveFeedbackIdentity, feedbackIdentity) &&
        (feedbackSource == null || feedbackSource == currentSource());
    bool ownsFeedback() => _feedbackOwner.value || feedbackPresented;
    bool canPresent() => sameFeedback() && _interactive && ownsFeedback();
    bool withPopup(ModalRoute<dynamic> popup) =>
        sameFeedback() && ownsFeedback() && _eligible(ownedPopup: popup);
    void presented() => feedbackPresented = true;

    try {
      final AppSnapshot? result;
      try {
        result = widget.onSave == null
            ? await widget.app.saveLocal(command, feedbackOwner: _feedbackOwner)
            : await widget.onSave!(command, _feedbackOwner);
      } catch (error) {
        if (!mounted) return;
        final message = error is ConfigFailure
            ? error.message
            : const AppMessage('saveUnconfirmed').withDetail(error);
        setState(() {
          _saving = false;
          _unconfirmed = true;
          _saveError = message;
          _refreshAdmission();
        });
        feedbackSource = currentSource();
        await showAppNotice(
          context,
          message,
          title: (strings) => strings.resultUnconfirmed,
          isCurrent: canPresent,
          onPresented: presented,
          identity: feedbackIdentity,
          eligibilityChanges: widget.app,
          isCurrentWithPopup: withPopup,
        );
        return;
      }
      outcome = result;
      if (!mounted) return;
      if (!route.isActive || !navigator.mounted) {
        // A popped route may remain mounted during reverse transition; hand its
        // pending feedback to the global reader.
        _feedbackOwner.value = false;
        return;
      }
      final status = widget.onSave == null
          ? result?.configStatus
          : result?.overrideStatus;
      final targetId = result?.targetId;
      final savedRevision = result?.savedRevision;
      final saved =
          const ['saved', 'applied', 'applyFailed'].contains(status) &&
          targetId != null &&
          targetId.isNotEmpty &&
          savedRevision != null &&
          savedRevision >= 1 &&
          (_id == null || _id == targetId);
      setState(() {
        _saving = false;
        _saveError =
            saved && status != 'applyFailed' && result?.resultSuccess == true
            ? null
            : result?.resultMessageDescription ??
                  widget.app.commandErrorMessage ??
                  const AppMessage('saveUnconfirmed');
        if (saved) {
          _unconfirmed = false;
          _id = targetId;
          _revision = savedRevision;
          _document = ConfigTextDocument(body);
          _savedLines = submittedLines;
          _contentDirty = !_editor!.codeLines.equals(submittedLines);
        } else {
          _unconfirmed = status != 'notSaved';
        }
        _refreshAdmission();
      });
      feedbackSource = currentSource();
      // Reuse the actual leave decision rather than stacking another dialog.
      final leaving = _leaving;
      if (leaving != null) await leaving.future;
      if (!mounted) return;
      if (!canPresent() || !navigator.mounted) {
        _feedbackOwner.value = false;
        return;
      }
      if (saved && status != 'applyFailed' && result?.resultSuccess == true) {
        if (!await widget.app.waitUntilInteractive() ||
            !mounted ||
            !canPresent() ||
            !navigator.mounted) {
          if (mounted) _feedbackOwner.value = false;
          return;
        }
        await showLocalizedOperationNotice(
          context,
          (strings) => strings.submittedSavedMessage,
          title: (strings) => strings.submittedSavedTitle,
          error: false,
          isCurrent: canPresent,
          onPresented: presented,
          identity: feedbackIdentity,
          eligibilityChanges: widget.app,
          isCurrentWithPopup: withPopup,
        );
        if (feedbackPresented && leaving == null && canPresent() && !_dirty) {
          navigator.pop();
        }
        return;
      }
      await showAppNotice(
        context,
        _saveError!,
        title: (strings) => !saved
            ? status == 'notSaved'
                  ? strings.saveFailed
                  : strings.resultUnconfirmed
            : status == 'applyFailed'
            ? strings.savedApplyFailed
            : strings.submittedSavedTitle,
        isCurrent: canPresent,
        onRetry: status == 'notSaved' ? _save : null,
        onPresented: presented,
        identity: feedbackIdentity,
        eligibilityChanges: widget.app,
        isCurrentWithPopup: withPopup,
      );
    } finally {
      if (feedbackPresented) {
        widget.app.acknowledgeLocalFeedback(_feedbackOwner, result: outcome);
      } else if (mounted &&
          identical(_saveFeedbackIdentity, feedbackIdentity)) {
        _feedbackOwner.value = false;
      }
    }
  }

  Widget _toolbar(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final find = _find;
    final finding = find?.value != null;
    final authority = _inputAuthority;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = Theme.of(context).textTheme.bodyMedium!;
        final scaler = MediaQuery.textScalerOf(context);
        final measure = TextPainter(
          text: TextSpan(text: '88888888/88888888', style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout();
        final countWidth = measure.width.ceilToDouble() + 8;
        final stacked = constraints.maxWidth < 12 + 96 + countWidth + 144;
        final splitCount = stacked && countWidth > constraints.maxWidth - 24;
        final countHeight = (measure.height * (splitCount ? 2 : 1) + 8).clamp(
          48.0,
          double.infinity,
        );
        measure.dispose();
        Widget counter() => SizedBox(
          width: stacked ? null : countWidth,
          height: countHeight,
          child: Center(
            child: Text(
              find?.failed == true
                  ? '—'
                  : find?.value?.searching == true
                  ? '…'
                  : '${(find?.value?.result?.index ?? -1) + 1}/${splitCount ? '\n' : ''}${find?.value?.result?.matches.length ?? 0}',
              style: style,
              textAlign: TextAlign.center,
              maxLines: splitCount ? 2 : 1,
            ),
          ),
        );
        final searchControls = find == null
            ? const SizedBox.shrink()
            : Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: find.findInputController,
                      focusNode: find.findInputFocusNode,
                      readOnly: !_interactive,
                      inputFormatters: [
                        TextInputFormatter.withFunction((previous, candidate) {
                          if (!identical(authority, _inputAuthority) ||
                              !_interactive) {
                            return previous;
                          }
                          if (candidate.text.length <= maxEditorCodeUnits) {
                            return candidate;
                          }
                          _queryRejected();
                          return previous;
                        }),
                      ],
                      decoration: InputDecoration(
                        hintText: strings.findBody,
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) {
                        if (identical(authority, _inputAuthority) &&
                            _interactive) {
                          find.nextMatch();
                        }
                      },
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: max(0.0, constraints.maxWidth - 12 - 96 - 144),
                    ),
                    child: AnimatedContainer(
                      duration: duration,
                      width: stacked ? 0 : countWidth,
                    ),
                  ),
                  IconButton(
                    tooltip: strings.previousMatch,
                    onPressed: _inputAction(find.previousMatch),
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: strings.nextMatch,
                    onPressed: _inputAction(find.nextMatch),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  IconButton(
                    tooltip: strings.closeFind,
                    onPressed: _inputAction(_closeFind),
                    icon: const Icon(Icons.close),
                  ),
                ],
              );
        final statusControls = Row(
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _readOnly
                          ? strings.readOnly
                          : _saving
                          ? strings.saving
                          : _unconfirmed
                          ? strings.resultUnconfirmed
                          : _dirty
                          ? strings.unsavedChanges
                          : strings.configBody,
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: strings.find,
              onPressed: _editor == null ? null : _inputAction(_openFind),
              color: HomePalette.of(context).moreAction,
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: strings.softWrap,
              isSelected: _wordWrap,
              onPressed: _editor == null
                  ? null
                  : _inputAction(() => setState(() => _wordWrap = !_wordWrap)),
              color: HomePalette.of(context).moreAction,
              icon: const Icon(Icons.wrap_text),
            ),
          ],
        );
        Widget surface({
          required bool active,
          required double opacity,
          required Widget child,
        }) => IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(
              excluding: !active,
              child: Offstage(
                offstage: opacity == 0,
                child: Opacity(opacity: opacity, child: child),
              ),
            ),
          ),
        );
        final height = finding && stacked
            ? 56 + countHeight
            : countHeight.clamp(56.0, double.infinity);
        final content = KeyedSubtree(
          key: _toolbarContentKey,
          child: TweenAnimationBuilder<double>(
            key: const ValueKey('editor-toolbar-transition'),
            tween: Tween(end: finding ? 1.0 : 0.0),
            duration: duration,
            builder: (context, progress, _) => SizedBox(
              height: height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: surface(
                      active: !finding,
                      opacity: 1 - progress,
                      child: statusControls,
                    ),
                  ),
                  Positioned.fill(
                    child: surface(
                      active: finding,
                      opacity: progress,
                      child: Stack(
                        children: [
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: countHeight.clamp(56.0, double.infinity),
                            child: searchControls,
                          ),
                          AnimatedPositioned(
                            key: const ValueKey('editor-find-counter'),
                            duration: duration,
                            top: stacked ? 56 : 0,
                            right: stacked ? 12 : 144,
                            width: stacked
                                ? max(0.0, constraints.maxWidth - 24)
                                : countWidth,
                            height: countHeight,
                            child: counter(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return SizedBox(
          key: const ValueKey('editor-toolbar-size'),
          child: reduced
              ? content
              : AnimatedSize(
                  duration: duration,
                  alignment: Alignment.topCenter,
                  child: content,
                ),
        );
      },
    );
  }

  AppBar _appBar(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final width =
        MediaQuery.sizeOf(context).width -
        MediaQuery.paddingOf(context).horizontal;
    final labels = [
      widget.saveLabel?.call(strings) ?? strings.save,
      widget.saveLabel == null
          ? strings.saveAndApply
          : widget.saveLabel!(strings),
    ];
    final labelStyle = theme.textTheme.labelLarge!;
    final measure = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: scaler,
    );
    var actionWidth = 64.0;
    for (final label in labels) {
      measure.text = TextSpan(text: label, style: labelStyle);
      measure.layout();
      actionWidth = max(actionWidth, measure.width + 24);
    }
    final maximum = max(
      48.0,
      width - kToolbarHeight - 32 - min(160.0, width / 4),
    );
    actionWidth = min(actionWidth, maximum);
    var actionHeight = 48.0;
    for (final label in labels) {
      measure.text = TextSpan(text: label, style: labelStyle);
      measure.layout(maxWidth: max(1.0, actionWidth - 24));
      actionHeight = max(actionHeight, measure.height + 16);
    }
    final title = widget.entry?.name ?? widget.initialName;
    final titleStyle = theme.textTheme.titleLarge!.copyWith(
      fontWeight: FontWeight.w600,
    );
    measure.text = TextSpan(text: title, style: titleStyle);
    measure.maxLines = 2;
    measure.ellipsis = '…';
    measure.layout(
      maxWidth: max(
        1.0,
        width - kToolbarHeight - 32 - (_readOnly ? 0 : actionWidth),
      ),
    );
    final height = max(
      kToolbarHeight,
      max(measure.height + 16, _readOnly ? 0.0 : actionHeight),
    );
    measure.dispose();
    return AppBar(
      toolbarHeight: height,
      leading: BackButton(onPressed: _leave),
      titleTextStyle: titleStyle,
      title: Tooltip(
        message: title,
        child: Text(
          title,
          softWrap: true,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      actions: [
        if (!_readOnly)
          SizedBox(
            width: actionWidth,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                textStyle: labelStyle,
              ),
              onPressed: _editable && _editor != null && _canWrite
                  ? _save
                  : null,
              child: IndexedStack(
                index: _running ? 1 : 0,
                alignment: Alignment.center,
                children: [for (final label in labels) Text(label)],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _overviewRoute?.animation ?? const AlwaysStoppedAnimation(1.0),
    builder: (context, child) => IgnorePointer(
      ignoring: !_interactive,
      child: ExcludeFocus(
        excluding: !_interactive,
        child: ExcludeSemantics(excluding: !_interactive, child: child!),
      ),
    ),
    child: TaskShortcuts(
      onSearch: _editor == null ? null : _inputAction(_openFind),
      onSave: _editable && _editor != null && _canWrite ? _save : null,
      onEscape: _find?.value == null ? null : _inputAction(_closeFind),
      child: _content(context),
    ),
  );

  Widget _content(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final editor = _editor;
    return PopScope<void>(
      canPop: !_dirty && !_saving && !_unconfirmed && _find?.value == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: _appBar(context),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _toolbar(context),
              Expanded(
                child: editor == null
                    ? _preparationErrorMessage == null
                          ? const Center(child: CircularProgressIndicator())
                          : OriginalTextView(
                              text:
                                  _document?.original ??
                                  widget.entry?.body ??
                                  widget.initialText,
                              identity: (_storageEpoch, _id, _revision),
                              isCurrent: () => _interactive,
                              isCurrentWithPopup: (popup) =>
                                  _eligible(ownedPopup: popup),
                            )
                    : ListenableBuilder(
                        listenable: _focus,
                        builder: (context, child) => Semantics(
                          textField: true,
                          readOnly: !_editable,
                          focused: _focus.hasFocus,
                          child: child,
                        ),
                        child: CodeEditor(
                          controller: editor,
                          findController: _find,
                          focusNode: _focus,
                          readOnly: !_editable,
                          wordWrap: _wordWrap,
                          autocompleteSymbols: false,
                          chunkAnalyzer: const NonCodeChunkAnalyzer(),
                          shortcutsActivatorsBuilder: const _TextShortcuts(),
                          indicatorBuilder:
                              (context, controller, _, notifier) =>
                                  DefaultCodeLineNumber(
                                    controller: controller,
                                    notifier: notifier,
                                    textStyle: TextStyle(
                                      fontFamily: 'monospace',
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                          toolbarController: _selectionToolbar,
                          style: CodeEditorStyle(
                            fontFamily: 'monospace',
                            fontSize: MediaQuery.textScalerOf(context)
                                .scale(14),
                            fontHeight: 1.5,
                            textColor: colors.onSurface,
                            backgroundColor: colors.surface,
                            selectionColor: colors.primary.withValues(
                              alpha: 0.18,
                            ),
                            highlightColor: colors.secondary.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _inputAuthority = Object();
    final route = _overviewRoute;
    if (route != null) {
      widget.app.unregisterOverviewLeave(route, _overviewLeave);
      route.animation?.removeStatusListener(_routeStatusChanged);
    }
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    _sizeTimer?.cancel();
    _selectionToolbar.hide(context);
    widget.app.removeListener(_appChanged);
    _find?.removeListener(_findChanged);
    _find?.dispose();
    _editor?.removeListener(_edited);
    _editor?.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _TextShortcuts extends DefaultCodeShortcutsActivatorsBuilder {
  const _TextShortcuts();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) =>
      const [
        CodeShortcutType.replace,
        CodeShortcutType.findToggleRegex,
        CodeShortcutType.findToggleMatchCase,
        CodeShortcutType.find,
        CodeShortcutType.save,
        CodeShortcutType.esc,
      ].contains(type)
      ? const []
      : super.build(type);
}
