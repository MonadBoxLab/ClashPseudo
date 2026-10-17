import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/operation_feedback.dart';
import 'config_entry.dart';
import 'config_find_controller.dart';
import 'config_text.dart';
import 'widgets/confirm_action.dart';

const directConfigTemplate =
    '# 默认直连配置；运行模式和策略选择仍以客户端为准。\nrules:\n  - MATCH,DIRECT\n';

(ConfigTextDocument, CodeLines) _prepareText(String text) {
  checkConfigText(text);
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
  });

  final AppController app;
  final ConfigEntry? entry;
  final String initialText;
  final String initialName;

  @override
  State<ConfigTextPage> createState() => _ConfigTextPageState();
}

class _ConfigTextPageState extends State<ConfigTextPage> {
  final _focus = FocusNode();
  CodeLineEditingController? _editor;
  ConfigFindController? _find;
  ConfigTextDocument? _document;
  CodeLines? _savedLines;
  CodeLines? _lastLines;
  CodeLineSelection? _beforeFind;
  String? _id;
  int? _revision;
  String? _preparationError;
  bool _contentDirty = false;
  bool get _dirty => _contentDirty;
  bool _saving = false;
  bool _overLimit = false;
  bool _sizeCheckFailed = false;
  bool _sizeChecking = false;
  int _sizeRevision = 0;
  Timer? _sizeTimer;
  bool _unconfirmed = false;
  bool _wordWrap = true;
  bool _focusedBeforeFind = false;
  CodeLines? _findLines;
  bool _leaving = false;

  bool get _readOnly => widget.entry?.remote == true;
  bool get _editable => !_readOnly && !_saving && !_unconfirmed;
  bool get _running =>
      _id != null &&
      widget.app.state.running &&
      widget.app.state.configId == _id;

  @override
  void initState() {
    super.initState();
    _id = widget.entry?.id;
    _revision = widget.entry?.revision;
    widget.app.addListener(_appChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_guardReadOnlyKeys);
    unawaited(_prepare());
  }

  KeyEventResult _guardReadOnlyKeys(KeyEvent event) {
    // re_editor 0.10.0 handles mobile Backspace/Enter before readOnly checks.
    if (!_editable &&
        _focus.hasFocus &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _prepare() async {
    try {
      if (widget.entry != null && widget.entry!.body == null) {
        throw const ConfigFailure('该配置没有可用正文，请先更新来源。');
      }
      final text = widget.entry?.body ?? widget.initialText;
      final prepared = text.length >= 256 * 1024
          ? await compute(_prepareText, text)
          : _prepareText(text);
      if (!mounted) return;
      _document = prepared.$1;
      final editor = CodeLineEditingController(codeLines: prepared.$2);
      _editor = editor;
      _savedLines = editor.codeLines;
      _lastLines = editor.codeLines;
      _find = ConfigFindController(editor)..addListener(_findChanged);
      editor.addListener(_edited);
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _preparationError = error is ConfigFailure
            ? error.message
            : '无法准备配置正文，请返回后重试。',
      );
    }
  }

  void _appChanged() {
    if (mounted) setState(() {});
  }

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
        // Unchanged text is saved verbatim, not with normalized mixed endings.
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

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      if (_find?.value != null) {
        _closeFind();
        return;
      }
      if (_saving || _unconfirmed) {
        final leave = await confirmAction(
          context,
          title: '离开正文？',
          message: '已提交的保存不会因离开而取消。结果尚未确认，请回配置列表核实，不要重复提交。',
          confirmLabel: '离开',
        );
        if (!leave || !mounted) return;
      } else if (_dirty) {
        final discard = await confirmAction(
          context,
          title: '放弃未保存修改？',
          message: '当前输入仅保留在此页，离开后不会保存。',
          confirmLabel: '放弃修改',
          cancelLabel: '继续编辑',
        );
        if (!discard || !mounted) return;
      }
      if (mounted) Navigator.pop(context);
    } finally {
      _leaving = false;
    }
  }

  Future<void> _save() async {
    if (!_editable || _editor == null || !widget.app.canEdit) return;
    if (_id == null && widget.initialName.trim().isEmpty) {
      await showOperationMessage(context, '请输入配置名称。');
      return;
    }
    final submittedLines = _editor!.codeLines;
    final edited = _editor!.text;
    if (_document!.mixed && edited != _document!.editable) {
      final allowed = await confirmAction(
        context,
        title: '统一混合换行？',
        message: '此正文包含多种换行。保存修改将统一为主要换行风格，BOM 保持不变。',
        confirmLabel: '统一并保存',
      );
      if (!allowed || !mounted) return;
    }
    String body;
    try {
      body = _document!.serialize(edited);
      checkConfigText(body);
    } on ConfigFailure catch (error) {
      if (mounted) await showOperationMessage(context, error.message);
      return;
    }
    if (!mounted || !widget.app.canEdit) return;
    _focus.unfocus();
    setState(() => _saving = true);
    final outcome = await widget.app.saveLocal({
      'id': _id,
      'revision': _revision,
      'name': widget.initialName.trim(),
      'body': body,
    });
    if (!mounted) return;
    final status = outcome?.configStatus;
    final saved =
        const ['saved', 'applied', 'applyFailed'].contains(status) &&
        outcome!.targetId != null &&
        outcome.savedRevision != null &&
        (_id == null || _id == outcome.targetId);
    setState(() {
      _saving = false;
      if (saved) {
        _id = outcome.targetId;
        _revision = outcome.savedRevision;
        _document = ConfigTextDocument(body);
        _savedLines = submittedLines;
        _contentDirty = !_editor!.codeLines.equals(submittedLines);
      } else {
        _unconfirmed = status != 'notSaved';
      }
    });
    if (saved && status != 'applyFailed' && !_dirty) {
      Navigator.pop(context);
      return;
    }
    if (saved && status != 'applyFailed') {
      await showOperationMessage(
        context,
        '提交的正文已保存，此后产生的修改仍保留在编辑器中，尚未保存。',
        title: '提交版本已保存',
        error: false,
      );
      return;
    }
    await showOperationMessage(
      context,
      outcome?.resultMessage ??
          widget.app.commandError ??
          '保存结果尚未确认，已重新读取配置。请返回列表核实；当前输入保留，未自动重试。',
      title: saved ? '已保存，应用未完成' : '保存未完成',
    );
  }

  Widget _toolbar(BuildContext context) {
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
                ? TextButton(onPressed: find.retry, child: const Text('重试'))
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
                      decoration: const InputDecoration(
                        hintText: '查找正文',
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => find.nextMatch(),
                    ),
                  ),
                  if (!stacked) counter(),
                  IconButton(
                    tooltip: '上一个',
                    onPressed: find.previousMatch,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: '下一个',
                    onPressed: find.nextMatch,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  IconButton(
                    tooltip: '关闭查找',
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
                          ? '只读'
                          : _saving
                          ? '正在保存'
                          : _unconfirmed
                          ? '结果未确认'
                          : _overLimit
                          ? '超过 16 MiB · 未截断'
                          : _sizeCheckFailed
                          ? '大小待确认 · 保存时重检'
                          : _dirty
                          ? '未保存修改'
                          : '配置正文',
                      maxLines: 1,
                    ),
                  ),
                  IconButton(
                    tooltip: '查找',
                    onPressed: _editor == null ? null : _openFind,
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    tooltip: '软换行',
                    isSelected: _wordWrap,
                    onPressed: _editor == null
                        ? null
                        : () => setState(() => _wordWrap = !_wordWrap),
                    icon: const Icon(Icons.wrap_text),
                  ),
                ],
              );
        // Reserve by viewport and text scale, never by changing match counts.
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final editor = _editor;
    return PopScope<void>(
      canPop: !_dirty && !_saving && !_unconfirmed && _find?.value == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _leave),
          title: Text(widget.entry?.name ?? widget.initialName),
          actions: [
            if (!_readOnly)
              TextButton(
                onPressed: _editable && editor != null && widget.app.canEdit
                    ? _save
                    : null,
                child: IndexedStack(
                  index: _running ? 1 : 0,
                  alignment: Alignment.center,
                  children: const [Text('保存'), Text('保存并应用')],
                ),
              ),
          ],
        ),
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
                            : Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(_preparationError!),
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
                          toolbarController: MobileSelectionToolbarController(
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
                                          controller.cut();
                                          onDismiss();
                                        },
                                      ),
                                    if (_editable)
                                      ContextMenuButtonItem(
                                        type: ContextMenuButtonType.paste,
                                        onPressed: () {
                                          controller.paste();
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
                          ),
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
    _sizeTimer?.cancel();
    FocusManager.instance.removeEarlyKeyEventHandler(_guardReadOnlyKeys);
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
        CodeShortcutType.esc,
      ].contains(type)
      ? const []
      : super.build(type);
}
