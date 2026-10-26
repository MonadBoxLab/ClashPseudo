import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:ui';

import 'package:clash_pseudo/main.dart' as application;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../test/support/editor_input_samples.dart';

const _run = String.fromEnvironment('EDITOR_INPUT_RUN');
const _negativeControl = bool.fromEnvironment('EDITOR_INPUT_NEGATIVE_CONTROL');
const _controlSamples = 5;
const _controlDelay = Duration(milliseconds: 150);

void main() {
  if (!CodeEditorObservation.enabled ||
      !RegExp(r'^[a-z0-9-]{8,48}$').hasMatch(_run)) {
    throw StateError('测量入口需要显式启用编辑观测并提供有效的实验标识。');
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final observation = _EditorObservation();
  binding.addObserver(observation);
  binding.addTimingsCallback(observation.timings);
  CodeEditorObservation.onInput = observation.input;
  CodeEditorObservation.onPaint = observation.paint;
  _emit({'kind': 'started', 't0': Timeline.now});
  application.main();
}

@pragma('vm:entry-point')
void appBackgroundMain() => application.appBackgroundMain();

void _emit(Map<String, Object?> value) => debugPrintSynchronously(
  'EDITOR_INPUT_OBSERVATION ${jsonEncode({'run': _run, 'pid': pid, ...value})}',
);

class _EditorObservation extends WidgetsBindingObserver {
  final _samples = EditorInputSamples();
  final _viewports = <int, List<double>>{};
  final _emitted = <int>{};

  void input(
    int startedAt,
    CodeLineEditingValue previous,
    CodeLineEditingValue accepted,
  ) {
    _samples.input(startedAt, previous, accepted);
    _flush();
    if (_negativeControl && _samples.samples.length <= _controlSamples) {
      sleep(_controlDelay);
    }
  }

  void paint(
    CodeLines document,
    int frame,
    Rect viewport,
    List<CodeLineRenderParagraph> drawn,
  ) {
    _samples.paint(document, frame, viewport, drawn);
    for (final sample in _samples.samples) {
      if (sample.frame == frame) {
        _viewports.putIfAbsent(
          sample.id,
          () => [viewport.left, viewport.top, viewport.right, viewport.bottom],
        );
      }
    }
  }

  void timings(List<FrameTiming> frames) {
    _samples.timings(frames);
    _flush();
  }

  void _flush() {
    for (final sample in _samples.samples) {
      if (sample.status == 'awaiting-paint' ||
          sample.status == 'awaiting-timing' ||
          !_emitted.add(sample.id)) {
        continue;
      }
      _emit({
        'kind': 'input-frame',
        ...sample.toJson(),
        'viewport': _viewports[sample.id],
        'controlDelayMicros': _negativeControl && sample.id <= _controlSamples
            ? _controlDelay.inMicroseconds
            : 0,
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    _samples.finish();
    _flush();
    _emit({
      'kind': 'paused',
      't0': Timeline.now,
      'acceptedInputs': _samples.samples.length + _samples.overflow,
      'overflow': _samples.overflow,
    });
  }
}
