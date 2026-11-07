import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> source(String phase, {String purpose = 'RUNNING'}) => {
    'phase': phase,
    'processId': 'stopped-process',
    'inputId': 'stopped-input',
    'generation': 3,
    'configId': 'one',
    'revision': 2,
    'composition': '["one",2]',
    'purpose': purpose,
    'networkRevision': 4,
  };
  const original = AppMessage(
    'temporaryModeUnknown',
    detail: '原始 cause、stack、suppressed 与未知字段',
  );

  for (final corePhase in ['exited', 'disconnected', 'revoked', 'EMPTY']) {
    for (final mode in [null, 'rule', 'invalid']) {
      test(
        'stopped core with historical purpose does not create mode issues phase=$corePhase mode=$mode',
        () {
          final raw = {
            'phase': 'STOPPED',
            'core': source(corePhase),
            'mode': mode,
            'modeError': original.toMap(),
          };
          final state = AppSnapshot.fromMap(raw);
          expect(state.confirmed, isTrue);
          expect(state.running, isFalse);
          expect(state.core.phase, 'EMPTY');
          expect(state.core.purpose, 'RUNNING');
          expect(state.core.processId, 'stopped-process');
          expect(state.core.hasIdentity, isTrue);
          expect(state.mode, isNull);
          expect(state.modeErrorMessage, isNull);
          expect(raw['modeError'], original.toMap());
        },
      );
    }
  }

  for (final corePhase in [
    'ready',
    'loading',
    'stopping',
    'communicationLost',
    'recoveryRequired',
  ]) {
    for (final mode in [null, 'global']) {
      test(
        'RUNNING core without confirmed exit still projects actual mode or original error phase=$corePhase mode=$mode',
        () {
          final state = AppSnapshot.fromMap({
            'phase': 'STOPPED',
            'core': source(corePhase),
            'lanRunning': corePhase == 'ready',
            'mode': mode,
            'modeError': original.toMap(),
          });
          expect(state.mode, mode == null ? null : TunnelMode.global);
          expect(state.modeErrorMessage, mode == null ? original : null);
          expect(state.forwarding, corePhase == 'ready');
          expect(state.core.phase, isNot('EMPTY'));
        },
      );
    }
  }

  test('VPN reporting RUNNING still checks mode; missing core identity alone does not remove issues', () {
    final state = AppSnapshot.fromMap({'phase': 'RUNNING'});
    expect(state.running, isTrue);
    expect(state.modeErrorMessage, messages.temporaryModeUnknown);
  });

  test('PREVIEW core does not create runtime mode issues', () {
    final state = AppSnapshot.fromMap({
      'phase': 'STOPPED',
      'core': source('ready', purpose: 'PREVIEW'),
      'modeError': original.toMap(),
    });
    expect(state.core.ready, isTrue);
    expect(state.mode, isNull);
    expect(state.modeErrorMessage, isNull);
  });

  test('always-on projection distinguishes true, false and unknown', () {
    for (final value in [true, false, null, 'false', 0]) {
      final state = AppSnapshot.fromMap({
        'phase': 'RUNNING',
        'alwaysOn': value,
      });
      expect(state.alwaysOn, value is bool ? value : null);
    }
  });

  test('ordinary preparation stays cancellable before native STARTING', () {
    final state = AppSnapshot.fromMap({
      'phase': 'STOPPED',
      'pendingStart': true,
    });
    expect(state.pendingStart, isTrue);
    expect(state.pendingSystemStart, isFalse);
    expect(state.busy, isTrue);
    expect(state.running, isFalse);
  });

  test('resource IO flag remains busy without a writer or operation text', () {
    final state = AppSnapshot.fromMap({
      'phase': 'STOPPED',
      'resourceBusy': true,
      'resourceStatus': 'unconfirmed',
    });
    expect(state.busy, isTrue);
    expect(state.resourceBusy, isTrue);
    expect(state.writerBusy, isFalse);
    expect(state.resourceStatus, 'unconfirmed');
  });

  test('platform writer drain flag remains busy without operation text', () {
    final state = AppSnapshot.fromMap({'phase': 'STOPPED', 'writerBusy': true});
    expect(state.busy, isTrue);
    expect(state.scheduleBusy, isFalse);
    expect(state.pendingSystemStart, isFalse);
  });
}
