import 'dart:math' show max, min;
import 'dart:ui' show FramePhase, FrameTiming, Rect, TextPosition, TextRange;

import 'package:re_editor/re_editor.dart';

// Test-only input/frame correlation using scalar metadata and callbacks installed by
// the test entrypoint.
class EditorInputSamples {
  EditorInputSamples({this.maximumSamples = 512});

  final int maximumSamples;
  final samples = <EditorInputSample>[];
  final _versions = Expando<int>();
  final _owners = Expando<int>();
  var _nextOwner = 0;
  var _nextVersion = 0;
  int overflow = 0;

  void input(
    int startedAt,
    CodeLineEditingValue previous,
    CodeLineEditingValue accepted,
  ) {
    if (samples.length >= maximumSamples) {
      overflow++;
      return;
    }
    final owner = _owners[previous.codeLines] ?? ++_nextOwner;
    _owners[accepted.codeLines] = owner;
    final version = ++_nextVersion;
    _versions[accepted.codeLines] = version;
    for (final sample in samples) {
      if (sample.owner == owner &&
          sample.frame == null &&
          sample.status == 'awaiting-paint') {
        sample.status = 'coalesced';
      }
    }
    final range = changedRange(previous.codeLines, accepted.codeLines);
    samples.add(
      EditorInputSample(
        id: samples.length + 1,
        owner: owner,
        version: version,
        startedAt: startedAt,
        range: range,
        status: range == null ? 'unresolved-change-range' : 'awaiting-paint',
      ),
    );
  }

  void paint(
    CodeLines document,
    int frame,
    Rect viewport,
    List<CodeLineRenderParagraph> drawn,
  ) {
    final version = _versions[document];
    if (version == null) return;
    for (final sample in samples) {
      if (sample.version != version ||
          sample.frame != null ||
          sample.range == null ||
          sample.status != 'awaiting-paint') {
        continue;
      }
      final range = sample.range!;
      sample.paintObserved = true;
      for (final paragraph in drawn) {
        if (paragraph.index < range.startIndex ||
            paragraph.index > range.endIndex) {
          continue;
        }
        final start = paragraph.index == range.startIndex
            ? range.startOffset
            : 0;
        final end = paragraph.index == range.endIndex
            ? range.endOffset
            : paragraph.length;
        if (start < 0 || end < start || end > paragraph.length) continue;
        bool visible;
        if (start == end) {
          final caret = paragraph.getOffset(TextPosition(offset: start));
          visible =
              caret != null &&
              Rect.fromLTWH(
                caret.dx + paragraph.offset.dx,
                caret.dy + paragraph.offset.dy,
                1,
                paragraph.preferredLineHeight,
              ).overlaps(viewport);
        } else {
          visible = paragraph
              .getRangeRects(TextRange(start: start, end: end))
              .any((rect) => rect.shift(paragraph.offset).overlaps(viewport));
        }
        if (visible) {
          sample.frame = frame;
          sample.status = 'awaiting-timing';
          break;
        }
      }
    }
  }

  void timings(List<FrameTiming> frames) {
    for (final timing in frames) {
      for (final sample in samples) {
        if (sample.frame != timing.frameNumber ||
            sample.status != 'awaiting-timing') {
          continue;
        }
        final finish = timing.timestampInMicroseconds(FramePhase.rasterFinish);
        sample.rasterFinish = finish;
        sample.status = finish >= sample.startedAt
            ? 'matched'
            : 'clock-mismatch';
      }
    }
  }

  void finish() {
    for (final sample in samples) {
      if (sample.status == 'awaiting-paint') {
        sample.status = sample.paintObserved
            ? 'changed-range-not-visible'
            : 'missing-text-paint';
      } else if (sample.status == 'awaiting-timing') {
        sample.status = 'missing-frame-timing';
      }
    }
  }

  Map<String, Object?> get summary {
    final durations =
        samples
            .where((sample) => sample.status == 'matched')
            .map((sample) => sample.rasterFinish! - sample.startedAt)
            .toList()
          ..sort();
    final counts = <String, int>{};
    for (final sample in samples) {
      counts.update(sample.status, (count) => count + 1, ifAbsent: () => 1);
    }
    return {
      'acceptedInputs': samples.length + overflow,
      'matchedInputs': durations.length,
      'overflow': overflow,
      'outcomes': counts,
      'p95Micros': durations.isEmpty
          ? null
          : durations[(durations.length * .95).ceil() - 1],
      'enoughSamples': durations.length >= 100 && overflow == 0,
    };
  }
}

class EditorInputSample {
  EditorInputSample({
    required this.id,
    required this.owner,
    required this.version,
    required this.startedAt,
    required this.range,
    required this.status,
  });

  final int id;
  final int owner;
  final int version;
  final int startedAt;
  final CodeLineSelection? range;
  int? frame;
  int? rasterFinish;
  bool paintObserved = false;
  String status;

  Map<String, Object?> toJson() => {
    'id': id,
    'owner': owner,
    'version': version,
    't0': startedAt,
    'range': range == null
        ? null
        : [
            range!.startIndex,
            range!.startOffset,
            range!.endIndex,
            range!.endOffset,
          ],
    'frame': frame,
    'rasterFinish': rasterFinish,
    'elapsedMicros': rasterFinish == null ? null : rasterFinish! - startedAt,
    'paintObserved': paintObserved,
    'outcome': status,
  };
}

// Reuse copy-on-write segment identities and scan only changed boundary lines for
// UTF-16 prefixes and suffixes.
CodeLineSelection? changedRange(CodeLines before, CodeLines after) {
  var first = 0;
  var segment = 0;
  while (segment < min(before.segments.length, after.segments.length) &&
      identical(
        before.segments[segment].codeLines,
        after.segments[segment].codeLines,
      )) {
    first += after.segments[segment++].length;
  }
  var oldEnd = before.length;
  var newEnd = after.length;
  var oldSegment = before.segments.length - 1;
  var newSegment = after.segments.length - 1;
  while (oldSegment >= segment &&
      newSegment >= segment &&
      identical(
        before.segments[oldSegment].codeLines,
        after.segments[newSegment].codeLines,
      )) {
    oldEnd -= before.segments[oldSegment--].length;
    newEnd -= after.segments[newSegment--].length;
  }
  while (first < min(oldEnd, newEnd) && before[first] == after[first]) {
    first++;
  }
  while (oldEnd > first &&
      newEnd > first &&
      before[oldEnd - 1] == after[newEnd - 1]) {
    oldEnd--;
    newEnd--;
  }
  // Report fold-only or unexpressible changes as unmatched samples; configuration
  // pages use unfolded documents.
  if (first >= oldEnd && first >= newEnd) return null;
  final firstIndex = min(first, min(before.length, after.length) - 1);
  final oldLast = max(firstIndex, oldEnd - 1);
  final newLast = max(firstIndex, newEnd - 1);
  for (var index = firstIndex; index <= newLast; index++) {
    if (after[index].chunks.isNotEmpty) return null;
  }
  if (before[firstIndex].chunks.isNotEmpty ||
      before[oldLast].chunks.isNotEmpty) {
    return null;
  }
  final oldFirstText = before[firstIndex].text;
  final newFirstText = after[firstIndex].text;
  var prefix = 0;
  while (prefix < min(oldFirstText.length, newFirstText.length) &&
      oldFirstText.codeUnitAt(prefix) == newFirstText.codeUnitAt(prefix)) {
    prefix++;
  }
  final oldLastText = before[oldLast].text;
  final newLastText = after[newLast].text;
  var suffix = 0;
  final oldFloor = oldLast == firstIndex ? prefix : 0;
  final newFloor = newLast == firstIndex ? prefix : 0;
  while (suffix <
          min(oldLastText.length - oldFloor, newLastText.length - newFloor) &&
      oldLastText.codeUnitAt(oldLastText.length - suffix - 1) ==
          newLastText.codeUnitAt(newLastText.length - suffix - 1)) {
    suffix++;
  }
  return CodeLineSelection(
    baseIndex: firstIndex,
    baseOffset: prefix,
    extentIndex: newLast,
    extentOffset: newLastText.length - suffix,
  );
}
