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

  for (final (phase, corePhase) in [
    ('STARTING', 'loading'),
    ('STARTING', 'starting'),
    ('RUNNING', 'ready'),
    ('STOPPED', 'ready'),
  ]) {
    test(
      'missing mode remains unconfirmed in a healthy context $phase/$corePhase',
      () {
        final raw = <String, dynamic>{
          'phase': phase,
          'core': source(corePhase),
          'lanRunning': phase == 'STOPPED',
        };
        for (final pending in [true, false]) {
          final state = AppSnapshot.fromMap({...raw, 'pendingStart': pending});
          expect(state.mode, isNull);
          expect(state.modeErrorMessage, isNull);
          expect(state.modeUnconfirmed, isTrue);
          expect(state.asStale().modeUnconfirmed, isFalse);
        }
        final actual = AppSnapshot.fromMap({...raw, 'mode': 'direct'});
        expect(actual.mode, TunnelMode.direct);
        expect(actual.modeErrorMessage, isNull);
        final failed = AppSnapshot.fromMap({
          ...raw,
          'pendingStart': true,
          'modeError': original.toMap(),
        });
        expect(failed.modeErrorMessage, original);
        for (final value in ['', 'invalid', 7, false, <String, dynamic>{}]) {
          expect(
            AppSnapshot.fromMap({...raw, 'mode': value}).modeErrorMessage,
            messages.temporaryModeUnknown,
          );
        }
        expect(
          () => AppSnapshot.fromMap({
            ...raw,
            'modeError': {'invalid': true},
          }),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'missing mode remains an issue when context identity or health is lost',
    () {
      final core = source('ready');
      for (final change in <Map<String, dynamic>>[
        {'processId': null},
        {'inputId': ''},
        {'generation': 0},
        {'configId': null},
        {'revision': 0},
        {'composition': ''},
        {'error': messages.coreContextUnconfirmed.toMap()},
        {'phase': 'communicationLost'},
        {'phase': 'recoveryRequired'},
        {'phase': 'stopping'},
      ]) {
        final state = AppSnapshot.fromMap({
          'phase': 'RUNNING',
          'core': {...core, ...change},
          'pendingStart': true,
          'writerBusy': true,
          'resourceBusy': true,
        });
        expect(
          state.modeErrorMessage,
          messages.temporaryModeUnknown,
          reason: '$change',
        );
      }
      for (final change in <Map<String, dynamic>>[
        {'phase': 'UNKNOWN'},
        {'phase': 'STOPPING'},
        {'recoveryRequired': true},
      ]) {
        final state = AppSnapshot.fromMap({
          'phase': 'RUNNING',
          'core': core,
          'pendingStart': true,
          ...change,
        });
        expect(
          state.modeErrorMessage,
          messages.temporaryModeUnknown,
          reason: '$change',
        );
      }
    },
  );

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
