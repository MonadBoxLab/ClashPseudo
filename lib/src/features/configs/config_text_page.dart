import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import 'config_entry.dart';
import 'config_find_controller.dart';
import 'config_editor_limits.dart';
import 'config_text.dart';
import 'widgets/confirm_action.dart';

const directConfigTemplate = '# 默认直连配置。\nrules:\n  - MATCH,DIRECT\n';

(ConfigTextDocument, CodeLines) _prepareText(String text) {
  checkConfigText(text);
  final oversized = firstOversizedEditorLine(text);
  if (oversized != null) {
    throw ConfigFailure(
      AppMessage.withArgs('editorLineTooLong', {
        'line': oversized,
        'limit': maxEditorCodeUnits,
      }),
    );
  }
  final document = ConfigTextDocument(text);
  return (document, CodeLines.fromText(document.editable));
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
  late final _selectionToolbar = MobileSelectionToolbarController(
    builder:
        ({
          required context,
          required anchors,
          required controller,
          required onDismiss,
          required onRefresh,
        }) => AdaptiveTextSelectionToolbar.buttonItems(
          anchors: anchors,
          buttonItems: [
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                unawaited(controller.copy());
                onDismiss();
              },
            ),
            if (_editable)
              ContextMenuButtonItem(
                type: ContextMenuButtonType.cut,
                onPressed: () {
                  if (_editable) controller.cut();
                  onDismiss();
                },
              ),
            if (_editable)
              ContextMenuButtonItem(
                type: ContextMenuButtonType.paste,
                onPressed: () {
                  if (_editable) controller.paste();
                  onDismiss();
                },
              ),
            ContextMenuButtonItem(
              type: ContextMenuButtonType.selectAll,
              onPressed: () {
                controller.selectAll();
                onRefresh();
              },
            ),
          ],
        ),
  );
  final _feedbackOwner = ValueNotifier<bool>(true);
  CodeLineEditingController? _editor;
  ConfigFindController? _find;
  ConfigTextDocument? _document;
  CodeLines? _savedLines;
  CodeLines? _lastLines;
  CodeLineSelection? _beforeFind;
  String? _id;
  int? _revision;
  AppMessage? _preparationErrorMessage;
  String? get _preparationError =>
      _preparationErrorMessage?.resolve(AppLocalizations.of(context));
  bool _contentDirty = false;
  bool get _dirty => _contentDirty;
  bool _saving = false;
  bool _overLimit = false;
  bool _sizeCheckFailed = false;
  AppMessage? _inputNotice;
  (String?, int?, int, int, bool)? _admissionIdentity;
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
  late final Future<bool> Function() _overviewLeave = _leaveForOverview;
  Future<bool> _leaveForOverview() => _leave(forOverview: true);

  bool get _readOnly => widget.readOnly || widget.entry?.remote == true;
  bool get _editable =>
      mounted &&
      !_readOnly &&
      !_saving &&
      !_unconfirmed &&
      widget.app.foreground &&
      widget.app.canEdit &&
      widget.app.storageEpoch == _storageEpoch &&
      widget.app.state.storageEpoch == _storageEpoch &&
      (_overviewRoute?.isActive ?? true) &&
      _targetCurrent;

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
    unawaited(_prepare());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _overviewRoute)) return;
    final previous = _overviewRoute;
    if (previous != null) {
      widget.app.unregisterOverviewLeave(previous, _overviewLeave);
    }
    _overviewRoute = route;
    if (route != null) widget.app.registerOverviewLeave(route, _overviewLeave);
  }

  Future<void> _prepare() async {
    try {
      final text = widget.entry?.body ?? widget.initialText;
      final prepared = text.length >= 256 * 1024
          ? await compute(_prepareText, text)
          : _prepareText(text);
      if (!mounted) return;
      _document = prepared.$1;
      final editor = CodeLineEditingController(codeLines: prepared.$2);
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
            : messages.bodyPrepFailed,
      );
    }
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
    if (!mounted || !(_overviewRoute?.isActive ?? true)) return false;
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
    _notice(null);
    return true;
  }

  void _notice(AppMessage? message) {
    if (mounted && message != _inputNotice) {
      setState(() => _inputNotice = message);
    }
  }

  void _appChanged() {
    if (!mounted) return;
    _refreshAdmission();
    if (!_editable) _selectionToolbar.hide(context);
    if (!_readOnly && !_saving && !_editable) {
      _inputNotice ??= const AppMessage('editorContextChanged');
    } else if (_editable && _inputNotice?.id == 'editorContextChanged') {
      _inputNotice = null;
    }
    setState(() {});
  }

  void _queryRejected() => _notice(
    AppMessage.withArgs('editorQueryTooLong', {'limit': maxEditorCodeUnits}),
  );

  void _findChanged() {
    if (mounted) setState(() {});
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
    try {
      int revision;
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
          setState(() {
            _overLimit = size > maxConfigBytes;
            _sizeCheckFailed = false;
          });
        }
      } while (revision != _sizeRevision);
    } catch (_) {
      if (mounted) setState(() => _sizeCheckFailed = true);
    } finally {
      _sizeChecking = false;
    }
  }

  void _openFind() {
    _beforeFind = _editor!.selection;
    _findLines = _editor!.codeLines;
    _focusedBeforeFind = _focus.hasFocus;
    _find!.findMode();
  }

  void _closeFind() {
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
    if (_leaving != null) return false;
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
        );
        if (!leave || !mounted) return false;
      } else if (_dirty) {
        final discard = await confirmAction(
          context,
          title: (strings) => strings.discardEditsTitle,
          message: (strings) => strings.discardEditsMessage,
          confirmLabel: (strings) => strings.discard,
          cancelLabel: (strings) => strings.continueEditing,
        );
        if (!discard || !mounted) return false;
      }
      if (!mounted || !route.isCurrent) return false;
      _focus.unfocus();
      Navigator.pop(context);
      return !route.isActive;
    } finally {
      _leaving = null;
      leaving.complete();
    }
  }

  Future<void> _save() async {
    if (!_editable || _editor == null || !widget.app.canEdit) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null || !route.isActive || !route.isCurrent) return;
    if (_id == null && widget.initialName.trim().isEmpty) {
      await showLocalizedOperationMessage(
        context,
        (strings) => strings.nameRequired,
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
      );
      if (!allowed || !mounted) return;
    }
    String body;
    try {
      body = _document!.serialize(edited);
      checkConfigText(body);
    } on ConfigFailure catch (error) {
      if (mounted) {
        await showAppMessage(context, error.message);
      }
      return;
    }
    if (!mounted || !route.isActive || !route.isCurrent || !_editable) {
      return;
    }
    _focus.unfocus();
    setState(() {
      _saving = true;
      _refreshAdmission();
    });
    final command = {
      'storageEpoch': _storageEpoch,
      'id': _id,
      'revision': _revision,
      'name': widget.initialName.trim(),
      'body': body,
    };
    AppSnapshot? outcome;
    try {
      final result = widget.onSave == null
          ? await widget.app.saveLocal(command, feedbackOwner: _feedbackOwner)
          : await widget.onSave!(command, _feedbackOwner);
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
      final saved =
          const ['saved', 'applied', 'applyFailed'].contains(status) &&
          result!.targetId != null &&
          result.savedRevision != null &&
          (_id == null || _id == result.targetId);
      setState(() {
        _saving = false;
        if (saved) {
          _id = result.targetId;
          _revision = result.savedRevision;
          _document = ConfigTextDocument(body);
          _savedLines = submittedLines;
          _contentDirty = !_editor!.codeLines.equals(submittedLines);
        } else {
          _unconfirmed = status != 'notSaved';
        }
        _refreshAdmission();
      });
      if (saved && status != 'applyFailed' && result.resultSuccess) {
        // Preserve the covering leave decision and saved identity; cancellation leaves
        // the editor open.
        if (!await widget.app.waitUntilInteractive() ||
            !mounted ||
            !route.isActive ||
            !route.isCurrent ||
            !navigator.mounted) {
          return;
        }
        if (!_dirty) {
          navigator.pop();
          return;
        }
        await showLocalizedOperationMessage(
          context,
          (strings) => strings.submittedSavedMessage,
          title: (strings) => strings.submittedSavedTitle,
          error: false,
        );
        return;
      }
      // Reuse the actual leave decision rather than stacking another dialog.
      final leaving = _leaving;
      if (leaving != null) await leaving.future;
      if (!mounted) return;
      if (!route.isActive || !route.isCurrent || !navigator.mounted) {
        _feedbackOwner.value = false;
        return;
      }
      await showAppMessage(
        context,
        outcome?.resultMessageDescription ??
            widget.app.commandErrorMessage ??
            const AppMessage('saveUnconfirmed'),
        title: (strings) => !saved
            ? strings.saveFailed
            : status == 'applyFailed'
            ? strings.savedApplyFailed
            : strings.submittedSavedTitle,
      );
    } finally {
      widget.app.acknowledgeLocalFeedback(_feedbackOwner, result: outcome);
    }
  }

  Widget _toolbar(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final find = _find;
    final finding = find?.value != null;
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
            child: find!.failed
                ? TextButton(onPressed: find.retry, child: Text(strings.retry))
                : Text(
                    find.value!.searching
                        ? '…'
                        : '${(find.value!.result?.index ?? -1) + 1}/${splitCount ? '\n' : ''}${find.value!.result?.matches.length ?? 0}',
                    style: style,
                    textAlign: TextAlign.center,
                    maxLines: splitCount ? 2 : 1,
                  ),
          ),
        );
        final controls = finding
            ? Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: find!.findInputController,
                      focusNode: find.findInputFocusNode,
                      inputFormatters: [
                        TextInputFormatter.withFunction((previous, candidate) {
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
                      onSubmitted: (_) => find.nextMatch(),
                    ),
                  ),
                  if (!stacked) counter(),
                  IconButton(
                    tooltip: strings.previousMatch,
                    onPressed: find.previousMatch,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: strings.nextMatch,
                    onPressed: find.nextMatch,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  IconButton(
                    tooltip: strings.closeFind,
                    onPressed: _closeFind,
                    icon: const Icon(Icons.close),
                  ),
                ],
              )
            : Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _readOnly
                          ? strings.readOnly
                          : _saving
                          ? strings.saving
                          : _unconfirmed
                          ? strings.resultUnconfirmed
                          : _overLimit
                          ? strings.tooLarge
                          : _sizeCheckFailed
                          ? strings.sizePending
                          : _dirty
                          ? strings.unsavedChanges
                          : strings.configBody,
                      maxLines: 1,
                    ),
                  ),
                  IconButton(
                    tooltip: strings.find,
                    onPressed: _editor == null ? null : _openFind,
                    color: HomePalette.of(context).moreAction,
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    tooltip: strings.softWrap,
                    isSelected: _wordWrap,
                    onPressed: _editor == null
                        ? null
                        : () => setState(() => _wordWrap = !_wordWrap),
                    color: HomePalette.of(context).moreAction,
                    icon: const Icon(Icons.wrap_text),
                  ),
                ],
              );
        // Reserve geometry according to viewport and text scale.
        return SizedBox(
          height: stacked
              ? 56 + countHeight
              : countHeight.clamp(56.0, double.infinity),
          child: finding && stacked
              ? Column(
                  children: [
                    SizedBox(height: 56, child: controls),
                    counter(),
                  ],
                )
              : controls,
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
      width - kToolbarHeight - 80 - min(160.0, width / 4),
    );
    actionWidth = min(actionWidth, maximum);
    var actionHeight = 48.0;
    for (final label in labels) {
      measure.text = TextSpan(text: label, style: labelStyle);
      measure.layout(maxWidth: max(1.0, actionWidth - 24));
      actionHeight = max(actionHeight, measure.height + 16);
    }
    final title = widget.entry?.name ?? widget.initialName;
    final titleStyle = theme.textTheme.titleLarge!;
    measure.text = TextSpan(text: title, style: titleStyle);
    measure.maxLines = 2;
    measure.ellipsis = '…';
    measure.layout(
      maxWidth: max(
        1.0,
        width - kToolbarHeight - 80 - (_readOnly ? 0 : actionWidth),
      ),
    );
    final height = max(
      kToolbarHeight,
      max(measure.height + 16, _readOnly ? 0.0 : actionHeight),
    );
    measure.dispose();
    final notice = _inputNotice;
    return AppBar(
      toolbarHeight: height,
      leading: BackButton(onPressed: _leave),
      titleTextStyle: titleStyle,
      title: Tooltip(
        message: title,
        child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      actions: [
        Visibility(
          visible: notice != null,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: SizedBox(
            width: 48,
            child: IconButton(
              key: const ValueKey('editor-input-notice'),
              tooltip: notice?.resolve(strings),
              color: HomePalette.of(context).warning,
              onPressed: notice == null
                  ? null
                  : () => unawaited(
                      showAppMessage(
                        context,
                        notice,
                        title: (strings) => strings.configBody,
                        error: false,
                      ),
                    ),
              icon: const Icon(Icons.warning_amber_rounded),
            ),
          ),
        ),
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
              onPressed: _editable && _editor != null && widget.app.canEdit
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
  Widget build(BuildContext context) => TaskShortcuts(
    onSearch: _editor == null ? null : _openFind,
    onSave: _editable && _editor != null && widget.app.canEdit ? _save : null,
    onEscape: _find?.value == null ? null : _closeFind,
    child: _content(context),
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
                    ? Center(
                        child: _preparationError == null
                            ? const CircularProgressIndicator()
                            : SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(_preparationError!),
                                ),
                              ),
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
