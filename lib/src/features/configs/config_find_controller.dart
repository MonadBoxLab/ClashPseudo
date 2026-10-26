import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import 'config_editor_limits.dart';

// re_editor 0.10.0 queues every query and rescans preceding lines per match.
// This adapter is for unfolded configuration text: one active scan, latest input
// next, and monotonically advancing line offsets. It uses only public APIs.
class ConfigFindController extends ValueNotifier<CodeFindValue?>
    implements CodeFindController {
  ConfigFindController(
    this.editor, {
    Future<List<CodeLineSelection>> Function(CodeLines, String)? scan,
    VoidCallback? onQueryRejected,
  }) : findInputController = _FindQueryController(onRejected: onQueryRejected),
       _scanMatches = scan ?? _computeMatches,
       super(null) {
    _lines = editor.codeLines;
    editor.addListener(_edited);
    findInputController.addListener(_queryChanged);
  }

  final CodeLineEditingController editor;
  final Future<List<CodeLineSelection>> Function(CodeLines, String)
  _scanMatches;
  @override
  final TextEditingController findInputController;
  @override
  final findInputFocusNode = FocusNode();
  @override
  final replaceInputController = TextEditingController();
  @override
  final replaceInputFocusNode = FocusNode();
  late CodeLines _lines;
  Timer? _timer;
  int _revision = 0;
  bool _busy = false;
  bool _disposed = false;
  bool failed = false;

  @override
  List<CodeLineSelection>? get allMatchSelections => value?.result?.matches;
  @override
  CodeLineSelection? get currentMatchSelection => value?.result?.currentMatch;
  @override
  CodeLineSelection convertMatchToSelection(CodeLineSelection match) => match;

  void _edited() {
    if (identical(editor.codeLines, _lines)) return;
    _lines = editor.codeLines;
    if (value != null) _queue();
  }

  void _queryChanged() {
    if (value == null || value!.option.pattern == findInputController.text) {
      return;
    }
    _queue();
  }

  void _queue() {
    _revision++;
    _timer?.cancel();
    failed = false;
    final pattern = findInputController.text;
    value = CodeFindValue(
      option: CodeFindOption(
        pattern: pattern,
        caseSensitive: false,
        regex: false,
      ),
      replaceMode: false,
      searching: pattern.isNotEmpty,
    );
    if (pattern.isNotEmpty) {
      _timer = Timer(const Duration(milliseconds: 120), _scan);
    }
  }

  Future<void> _scan() async {
    if (_disposed || _busy || value == null || !value!.searching) return;
    _busy = true;
    final revision = _revision;
    final lines = _lines;
    final option = value!.option;
    try {
      final matches = await _scanMatches(lines, option.pattern);
      if (_disposed || revision != _revision || value == null) return;
      final selection = editor.selection;
      var index = 0;
      for (var i = 0; i < matches.length; i++) {
        if (matches[i].endIndex < selection.startIndex ||
            (matches[i].endIndex == selection.startIndex &&
                matches[i].endOffset <= selection.startOffset)) {
          index = i;
        } else {
          break;
        }
      }
      value = CodeFindValue(
        option: option,
        replaceMode: false,
        result: matches.isEmpty
            ? null
            : CodeFindResult(
                index: index,
                matches: matches,
                option: option,
                codeLines: lines,
                dirty: false,
              ),
      );
    } catch (_) {
      if (!_disposed && revision == _revision && value != null) {
        failed = true;
        value = CodeFindValue(option: option, replaceMode: false);
      }
    } finally {
      _busy = false;
      if (!_disposed && revision != _revision && value?.searching == true) {
        unawaited(_scan());
      }
    }
  }

  void retry() => _queue();

  @override
  void findMode() {
    final selected = editor.selection;
    if (!selected.isCollapsed && selected.isSameLine) {
      findInputController.text = editor.selectedText;
    }
    focusOnFindInput();
    _queue();
  }

  @override
  void focusOnFindInput() {
    findInputFocusNode.requestFocus();
    findInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: findInputController.text.length,
    );
  }

  @override
  void close() {
    _revision++;
    _timer?.cancel();
    failed = false;
    value = null;
  }

  void _move(bool next) {
    final result = value?.result;
    if (result == null) return;
    value = value!.copyWith(result: next ? result.next : result.previous);
    if (result.matches.length == 1) {
      editor.makePositionCenterIfInvisible(result.currentMatch!.start);
    }
  }

  @override
  void previousMatch() => _move(false);
  @override
  void nextMatch() => _move(true);

  // Configuration search is literal and find-only, including keyboard actions.
  @override
  void toggleMode() => findMode();
  @override
  void replaceMode() {}
  @override
  void focusOnReplaceInput() {}
  @override
  void toggleRegex() {}
  @override
  void toggleCaseSensitive() {}
  @override
  void replaceMatch() {}
  @override
  void replaceAllMatches() {}

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    editor.removeListener(_edited);
    findInputController.removeListener(_queryChanged);
    findInputController.dispose();
    findInputFocusNode.dispose();
    replaceInputController.dispose();
    replaceInputFocusNode.dispose();
    super.dispose();
  }
}

class _FindQueryController extends TextEditingController {
  _FindQueryController({this.onRejected});

  final VoidCallback? onRejected;

  @override
  set value(TextEditingValue candidate) {
    if (candidate.text.length > maxEditorCodeUnits) {
      onRejected?.call();
      return;
    }
    super.value = candidate;
  }
}

Future<List<CodeLineSelection>> _computeMatches(
  CodeLines lines,
  String pattern,
) => compute(_findMatches, (lines, pattern));

// Intersect bounded SDK regex patterns at required offsets and advance the earliest
// possible start after mismatch. This supports long literals with SDK case folding,
// UTF-16 offsets and overlapping candidate evaluation.
Iterable<(int, int)> _literalMatches(String text, String query) sync* {
  if (query.isEmpty) return;
  const chunkSize = 1024;
  final pieces = <(int, RegExp)>[];
  for (var offset = 0; offset < query.length; offset += chunkSize) {
    final end = offset + chunkSize < query.length
        ? offset + chunkSize
        : query.length;
    pieces.add((
      offset,
      RegExp(RegExp.escape(query.substring(offset, end)), caseSensitive: false),
    ));
  }
  if (pieces.length == 1) {
    for (final match in pieces.single.$2.allMatches(text)) {
      yield (match.start, match.end);
    }
    return;
  }
  var start = 0;
  var piece = 0;
  while (start + query.length <= text.length) {
    final (offset, pattern) = pieces[piece];
    final matches = pattern.allMatches(text, start + offset).iterator;
    if (!matches.moveNext()) return;
    final next = matches.current.start - offset;
    if (next > start) {
      start = next;
      piece = 0;
    } else if (++piece == pieces.length) {
      yield (start, start + query.length);
      start += query.length;
      piece = 0;
    }
  }
}

List<CodeLineSelection> _findMatches((CodeLines, String) input) {
  final lines = input.$1.toList().map((line) => line.text).toList();
  final matches = <CodeLineSelection>[];
  var line = 0;
  var offset = 0;
  CodeLinePosition position(int index) {
    while (line + 1 < lines.length && index > offset + lines[line].length) {
      offset += lines[line++].length + 1;
    }
    return CodeLinePosition(index: line, offset: index - offset);
  }

  for (final match in _literalMatches(lines.join('\n'), input.$2)) {
    final start = position(match.$1);
    final end = position(match.$2);
    matches.add(
      CodeLineSelection(
        baseIndex: start.index,
        baseOffset: start.offset,
        extentIndex: end.index,
        extentOffset: end.offset,
      ),
    );
  }
  return matches;
}
