import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> editorDelta(
  String old, {
  int start = -1,
  int end = -1,
  String text = '',
  required int caret,
  int? extent,
  int composingStart = -1,
  int composingEnd = -1,
}) => {
  'oldText': old,
  'deltaStart': start,
  'deltaEnd': end,
  'deltaText': text,
  'selectionBase': caret,
  'selectionExtent': extent ?? caret,
  'selectionAffinity': 'TextAffinity.downstream',
  'selectionIsDirectional': false,
  'composingBase': composingStart,
  'composingExtent': composingEnd,
};

// Send JSON deltas through the native channel decoder to the actual
// DeltaTextInputClient.
Future<void> sendEditorDeltas(
  WidgetTester tester,
  List<Map<String, Object?>> deltas, {
  bool paint = true,
}) async {
  final client =
      (tester.testTextInput.log
                      .lastWhere((call) => call.method == 'TextInput.setClient')
                      .arguments
                  as List)
              .first
          as int;
  // ChannelBuffers invokes the listener in its registration zone, outside this
  // test's FakeAsync zone. Its async reply needs real microtask progress.
  await tester.runAsync(() async {
    final replied = Completer<void>();
    tester.binding.channelBuffers.push(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
          {'deltas': deltas},
        ]),
      ),
      (data) {
        try {
          if (data == null) throw const FormatException('Missing delta reply');
          SystemChannels.textInput.codec.decodeEnvelope(data);
          replied.complete();
        } catch (error, stack) {
          replied.completeError(error, stack);
        }
      },
    );
    await replied.future.timeout(const Duration(seconds: 5));
  });
  expect(tester.takeException(), isNull);
  if (paint) await tester.pump();
}
