import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../model/platform_failure.dart';
import '../../model/platform_port.dart';

import '../../model/application_contract.dart';

class CoreIdentity {
  const CoreIdentity({
    required this.processId,
    this.generation = 0,
    this.inputId,
    this.composition,
    this.networkRevision = 0,
  });

  final String processId;
  final int generation;
  final String? inputId;
  final String? composition;
  final int networkRevision;

  Map<String, Object?> toMap() => {
    'protocol': ApplicationContract.coreIpcVersion,
    'processId': processId,
    'generation': generation,
    if (inputId != null) 'inputId': inputId,
    if (composition != null) 'composition': composition,
    'networkRevision': networkRevision,
  };
}

class CoreFrame {
  const CoreFrame(this.kind, this.payload);
  final int kind;
  final Uint8List payload;

  Object? get json => _decodeJson(payload);
  Map<String, dynamic> get object => Map<String, dynamic>.from(json as Map);
  bool get terminal => kind == ApplicationContract.coreIpcFrameTerminal;
}

Object? _decodeJson(List<int> bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw FormatException(error.message, null, error.offset);
  }
}

Map<String, dynamic> _diagnosticFields(Map<String, dynamic> value) => {
  for (final key in [
    'processId',
    'requestId',
    'phase',
    'reason',
    'complete',
    'exited',
    'stale',
    'recordCount',
    'error',
    'cancelError',
    'nativeReceipt',
  ])
    if (value[key] != null &&
        (const ['error', 'cancelError', 'nativeReceipt'].contains(key) ||
            value[key] is String ||
            value[key] is num ||
            value[key] is bool))
      key: value[key],
};

class CoreResult {
  const CoreResult(this.value, this.terminal);
  final Object? value;
  final Map<String, dynamic> terminal;
  Map<String, dynamic> get object => Map<String, dynamic>.from(value as Map);
  Object? get error => terminal['error'];
  Object? get cancelError => terminal['cancelError'];
  bool get stale => terminal['stale'] == true;
  bool get complete => terminal['complete'] == true;
}

/// A core connection in the default process, handling identity, transport, and actual
/// exit without storing business state.
class CoreClient {
  CoreClient(this.channel);
  final PlatformPort channel;
  final _calls = <(String, int), CoreCall>{};
  int _submitting = 0;
  final _earlyExits = <(String, int), Map<String, dynamic>>{};
  final _earlyDeaths = <String, Map<String, dynamic>>{};
  final _earlyCancellations = <String>{};

  Future<Map<String, dynamic>> handshake() async {
    final state = await _map(ApplicationContract.coreChannelHandshake);
    if (state['protocol'] != ApplicationContract.coreIpcVersion ||
        state['processId'] is! String ||
        (state['processId'] as String).isEmpty) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorProtocolMismatch,
      );
    }
    return state;
  }

  Future<Map<String, dynamic>> status() =>
      _map(ApplicationContract.coreChannelStatus);

  Future<CoreCall> submit(
    int operation,
    CoreIdentity identity, {
    Map<String, Object?> arguments = const {},
    String? inputId,
    String? owner,
    Map<String, Object?>? parts,
  }) async {
    _submitting++;
    try {
      final admission = await _map(ApplicationContract.coreChannelSubmit, {
        'operation': operation,
        'identity': identity.toMap(),
        'arguments': arguments,
        'owner': ?owner,
        'parts': ?parts,
        'inputId': ?inputId,
      });
      final id = admission['requestId'];
      final process = admission['processId'] ?? identity.processId;
      if (admission['accepted'] != true ||
          id is! int ||
          id <= 0 ||
          process != identity.processId) {
        throw PlatformFailure(
          code: admission['error'] is String
              ? admission['error'] as String
              : ApplicationContract.coreErrorCallFailed,
          details: {
            if (admission['accepted'] is bool)
              'accepted': admission['accepted'],
            if (id is int) 'requestId': id,
            if (process is String) 'processId': process,
            if (admission['error'] != null) 'error': admission['error'],
            if (admission['nativeReceipt'] != null)
              'nativeReceipt': admission['nativeReceipt'],
          },
        );
      }
      final key = (identity.processId, id);
      if (_calls.containsKey(key)) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorIdentityMismatch,
        );
      }
      final call = CoreCall._(this, identity, id, owner);
      _calls[key] = call;
      final death = _earlyDeaths[identity.processId];
      if (death != null) {
        call._processDied(death);
      } else if (_earlyExits.containsKey(key)) {
        call._confirmExit(_earlyExits.remove(key));
      }
      if (owner != null &&
          _earlyCancellations.contains(owner) &&
          !call.hasExited) {
        await call.requestCancellation();
      }
      return call;
    } finally {
      _submitting--;
      if (_submitting == 0) {
        _earlyExits.clear();
        _earlyDeaths.clear();
        _earlyCancellations.clear();
      }
    }
  }

  Future<void> cancelOwner(String owner) async {
    if (_submitting > 0) _earlyCancellations.add(owner);
    await Future.wait([
      for (final call in _calls.values.toList())
        if (call.owner == owner && !call.hasExited) call.requestCancellation(),
    ]);
  }

  Future<Map<String, dynamic>> _map(String method, [Object? arguments]) async =>
      Map<String, dynamic>.from(
        await channel.invoke<Map>(method, arguments) ?? const {},
      );

  Future<Map<String, dynamic>> publishRunInput(
    String path,
    String inputId,
  ) async {
    final result = await _map(ApplicationContract.coreChannelPublishRunInput, {
      'path': path,
      'inputId': inputId,
    });
    if (result['saved'] != true ||
        result['durable'] is! bool ||
        result['path'] is! String ||
        result['inputId'] != inputId) {
      throw PlatformFailure(
        code: 'storage',
        details: {
          'expectedInputId': inputId,
          if (result['inputId'] is String) 'inputId': result['inputId'],
          if (result['inputId'] != null && result['inputId'] is! String)
            'inputIdType': result['inputId'].runtimeType.toString(),
          if (result['saved'] is bool) 'saved': result['saved'],
          if (result['saved'] != null && result['saved'] is! bool)
            'savedType': result['saved'].runtimeType.toString(),
          if (result['durable'] is bool) 'durable': result['durable'],
          if (result['durable'] != null && result['durable'] is! bool)
            'durableType': result['durable'].runtimeType.toString(),
          if (result['path'] is String) 'path': result['path'],
          if (result['path'] != null && result['path'] is! String)
            'pathType': result['path'].runtimeType.toString(),
          if (result['error'] != null) 'error': result['error'],
          if (result['cancelError'] != null)
            'cancelError': result['cancelError'],
        },
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> readRunInputRecord(String inputId) => _map(
    ApplicationContract.coreChannelReadRunInputRecord,
    {'inputId': inputId},
  );

  Future<Map<String, dynamic>> localInterfaces() =>
      _map(ApplicationContract.coreChannelLocalInterfaces);

  Future<Map<String, dynamic>> exit({
    required String processId,
    required int admittedAt,
    required int deadline,
    required String reason,
  }) => _map(ApplicationContract.coreChannelExit, {
    'processId': processId,
    'admittedAt': admittedAt,
    'deadline': deadline,
    'reason': reason,
  });

  /// Transport failure does not end a request; release its slot only when the call
  /// exits or the remote process dies.
  void event(Map<String, dynamic> event) {
    final process = event['processId'];
    if (process is! String) return;
    final request = event['requestId'];
    if (request is int && event['exited'] == true) {
      final key = (process, request);
      final call = _calls[key];
      final receipt = event['receipt'] is Map
          ? Map<String, dynamic>.from(event['receipt'] as Map)
          : <String, dynamic>{};
      if (call != null) {
        call._confirmExit(receipt);
      } else if (_submitting > 0) {
        _earlyExits[key] = receipt;
      }
      return;
    }
    if (event['phase'] == ApplicationContract.corePhaseExited &&
        event['exited'] == true) {
      if (_submitting > 0) _earlyDeaths[process] = Map.unmodifiable(event);
      final calls = _calls.entries
          .where((entry) => entry.key.$1 == process)
          .map((entry) => entry.value)
          .toList();
      for (final call in calls) {
        call._processDied(event);
      }
    }
  }
}

class CoreCall {
  CoreCall._(this.client, this.identity, this.requestId, this.owner);
  final String? owner;
  final CoreClient client;
  final CoreIdentity identity;
  final int requestId;
  final _exit = Completer<void>();
  bool _reading = false;
  bool _terminal = false;
  Map<String, dynamic>? _death;
  Map<String, dynamic>? _receipt;
  Map<String, dynamic>? get receipt => _receipt;

  Future<void> get exited => _exit.future;
  bool get hasExited => _exit.isCompleted;

  Map<String, dynamic>? _cancellation;
  Object? _cancelFailure;

  Future<void> requestCancellation() async {
    try {
      await cancel();
    } catch (error) {
      _cancelFailure = _errorValue(error);
    }
  }

  Future<Map<String, dynamic>>? _cancelling;

  Future<Map<String, dynamic>> cancel() => _cancelling ??= _cancel();

  Future<Map<String, dynamic>> _cancel() async {
    try {
      final value = await client._map(ApplicationContract.coreChannelCancel, {
        'processId': identity.processId,
        'requestId': requestId,
      });
      _cancellation = Map.unmodifiable(value);
      return value;
    } catch (error) {
      _cancelFailure = _errorValue(error);
      rethrow;
    } finally {
      _cancelling = null;
    }
  }

  void _confirmExit([Map<String, dynamic>? receipt]) {
    if (receipt != null) {
      _receipt = Map.unmodifiable({...?_receipt, ...receipt});
    }
    if (!_exit.isCompleted) _exit.complete();
    client._calls.remove((identity.processId, requestId));
  }

  void _processDied(Map<String, dynamic> event) {
    _death = Map.unmodifiable(event);
    _confirmExit();
  }

  Stream<CoreFrame> frames() async* {
    if (_reading || _terminal) {
      throw StateError('Core request can only be read once');
    }
    _reading = true;
    while (!_terminal) {
      if (_death != null) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorProcessExited,
          details: _diagnosticFields(_death!),
        );
      }
      final result = await client._map(ApplicationContract.coreChannelRead, {
        'processId': identity.processId,
        'requestId': requestId,
      });
      final nativeReceipt = result['nativeReceipt'];
      if (nativeReceipt is Map) {
        _receipt = Map<String, dynamic>.unmodifiable({
          ...?_receipt,
          ...nativeReceipt,
        });
      }
      final kind = result['kind'];
      final payload = result['payload'];
      if (kind is! int ||
          payload is! Uint8List ||
          !const [
            ApplicationContract.coreIpcFrameData,
            ApplicationContract.coreIpcFrameRecord,
            ApplicationContract.coreIpcFrameTerminal,
            ApplicationContract.coreIpcFrameMetadata,
          ].contains(kind) ||
          payload.length > ApplicationContract.coreIpcFrameBytes) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorTransportInterrupted,
          details: {
            if (kind is int) 'kind': kind,
            if (payload is Uint8List) 'payloadBytes': payload.length,
            if (nativeReceipt is Map) 'nativeReceipt': nativeReceipt,
            if (result['error'] != null) 'error': result['error'],
          },
        );
      }
      final frame = CoreFrame(kind, payload);
      if (frame.terminal) {
        _terminal = true;
        if (frame.object['exited'] == true) _confirmExit();
      }
      yield frame;
    }
  }

  Object? _errorValue(Object? error) => switch (error) {
    PlatformFailure() => error.toMap(),
    FormatException() => {'message': error.message, 'offset': error.offset},
    _ => error?.toString(),
  };

  Future<Map<String, dynamic>> finish(Map<String, dynamic> terminal) async {
    await exited;
    if (_death != null) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorProcessExited,
        details: {
          'event': _diagnosticFields(_death!),
          'terminal': _diagnosticFields(terminal),
          'nativeReceipt': _receipt,
        },
      );
    }
    return Map.unmodifiable({
      ...terminal,
      if (terminal['error'] == null && _receipt?['error'] != null)
        'error': _receipt!['error'],
      if (terminal['cancelError'] == null &&
          (_receipt?['cancelError'] ??
                  _cancellation?['cancelError'] ??
                  _cancellation?['error'] ??
                  _cancelFailure) !=
              null)
        'cancelError':
            _receipt?['cancelError'] ??
            _cancellation?['cancelError'] ??
            _cancellation?['error'] ??
            _cancelFailure,
      if (_receipt != null) 'nativeReceipt': _receipt,
      if (_cancellation != null) 'cancellation': _cancellation,
    });
  }

  /// Waits for actual exit after an FD read failure, preserving the separate native
  /// receipt and cancellation error.
  Future<Never> fail(Object failure, StackTrace stack) async {
    final previousCancelFailure = _cancelFailure;
    Object? cancelFailure;
    if (!hasExited) {
      try {
        await cancel();
      } catch (error) {
        cancelFailure = error;
      }
    }
    await exited;
    if (cancelFailure != null ||
        _cancelFailure != null ||
        _receipt?['error'] != null ||
        _receipt?['cancelError'] != null ||
        _cancellation?['error'] != null ||
        _cancellation?['cancelError'] != null) {
      throw PlatformFailure(
        code: failure is PlatformFailure
            ? failure.code
            : ApplicationContract.coreErrorCallFailed,
        details: {
          'error': _errorValue(failure),
          if (cancelFailure != null || _cancelFailure != null)
            'cancelError': _errorValue(cancelFailure) ?? _cancelFailure,
          if (cancelFailure != null && previousCancelFailure != null)
            'previousCancelError': previousCancelFailure,
          if (_receipt != null) 'nativeReceipt': _receipt,
          if (_cancellation != null) 'cancellation': _cancellation,
        },
      );
    }
    Error.throwWithStackTrace(failure, stack);
  }

  Future<CoreResult> result({required int maximumBytes}) async {
    final bytes = BytesBuilder(copy: false);
    Map<String, dynamic>? terminal;
    try {
      await for (final frame in frames()) {
        if (frame.kind == ApplicationContract.coreIpcFrameData) {
          if (bytes.length + frame.payload.length > maximumBytes) {
            throw PlatformFailure(
              code: ApplicationContract.coreErrorResultTooLarge,
            );
          }
          bytes.add(frame.payload);
        } else if (frame.terminal) {
          terminal = frame.object;
        } else if (frame.kind != ApplicationContract.coreIpcFrameMetadata) {
          throw PlatformFailure(
            code: ApplicationContract.coreErrorTransportInterrupted,
          );
        }
      }
      if (terminal == null) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorTransportInterrupted,
        );
      }
      final completed = await finish(terminal);
      return CoreResult(
        bytes.isEmpty ? null : _decodeJson(bytes.takeBytes()),
        completed,
      );
    } catch (error, stack) {
      return fail(error, stack);
    }
  }
}
