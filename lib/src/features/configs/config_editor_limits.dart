import 'package:re_editor/re_editor.dart';

const maxEditorCodeUnits = 32768;

/// Editing/soft-wrap admission only. Storage, imports and backup use their byte
/// budget independently. Match the document model's one leading BOM and CR/LF.
int? firstOversizedEditorLine(String text) {
  var line = 1;
  var length = 0;
  final start = text.startsWith('\u{feff}') ? 1 : 0;
  for (var index = start; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit == 13 || unit == 10) {
      if (unit == 13 &&
          index + 1 < text.length &&
          text.codeUnitAt(index + 1) == 10) {
        index++;
      }
      line++;
      length = 0;
    } else if (++length > maxEditorCodeUnits) {
      return line;
    }
  }
  return null;
}

/// Previously accepted segment lists are shared by re_editor's copy-on-write
/// model. Only changed segments need checking; folded children are still lines.
int? firstOversizedCodeLine(CodeLines candidate, {CodeLines? previous}) {
  final accepted = Set<List<CodeLine>>.identity();
  if (previous != null) {
    for (final segment in previous.segments) {
      accepted.add(segment.codeLines);
    }
  }
  for (var index = 0; index < candidate.segments.length; index++) {
    final segment = candidate.segments[index];
    if (accepted.contains(segment.codeLines)) continue;
    final within = _oversizedSegmentLine(segment.codeLines);
    if (within != null) {
      // Compute the absolute error location only when rejecting a candidate.
      var line = within + 1;
      for (var before = 0; before < index; before++) {
        line += candidate.segments[before].lineCount;
      }
      return line;
    }
  }
  return null;
}

int? _oversizedSegmentLine(List<CodeLine> lines) {
  final pending = <Iterator<CodeLine>>[lines.iterator];
  var offset = 0;
  while (pending.isNotEmpty) {
    final iterator = pending.last;
    if (!iterator.moveNext()) {
      pending.removeLast();
      continue;
    }
    final line = iterator.current;
    if (line.length > maxEditorCodeUnits) return offset;
    offset++;
    if (line.chunks.isNotEmpty) pending.add(line.chunks.iterator);
  }
  return null;
}
