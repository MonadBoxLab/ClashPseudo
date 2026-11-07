import 'messages.dart';

class CoreSnapshot {
  const CoreSnapshot({
    this.generation = 0,
    this.processId,
    this.inputId,
    this.networkRevision = 0,
    this.phase = 'EMPTY',
    this.purpose,
    this.configId,
    this.revision,
    this.composition,
    this.logWindow,
    AppMessage? error,
  }) : errorMessage = error;
  final int generation;
  final String? processId;
  final String? inputId;
  final int networkRevision;
  final String phase;
  final String? purpose;
  final String? configId;
  final int? revision;
  final String? composition;
  final String? logWindow;
  final AppMessage? errorMessage;

  bool get ready => phase == 'READY';
  bool get busy => phase == 'LOADING' || phase == 'RELEASING';
  bool get blocked => phase == 'FAILED' || phase == 'UNKNOWN';

  bool get hasIdentity =>
      generation > 0 &&
      configId?.isNotEmpty == true &&
      revision != null &&
      revision! > 0 &&
      composition?.isNotEmpty == true &&
      const ['RUNNING', 'PREVIEW'].contains(purpose);

  (String?, String?, int, String?, int?, String?, String?) get identity => (
    processId,
    inputId,
    generation,
    configId,
    revision,
    composition,
    purpose,
  );

  Map<String, Object?> get wireIdentity => {
    'processId': processId,
    'inputId': inputId,
    'generation': generation,
    'configId': configId,
    'revision': revision,
    'composition': composition,
    'purpose': purpose,
  };

  bool matchesIdentity(CoreSnapshot other) =>
      hasIdentity && identity == other.identity;

  bool matchesWireIdentity(Map<String, dynamic> value) =>
      hasIdentity &&
      value['generation'] is int &&
      value['revision'] is int &&
      identity ==
          (
            value['processId'],
            value['inputId'],
            value['generation'],
            value['configId'],
            value['revision'],
            value['composition'],
            value['purpose'],
          );

  factory CoreSnapshot.fromMap(Map<String, dynamic> value) {
    try {
      final wirePhase = value['phase'] as String;
      final phase = switch (wirePhase) {
        'ready' => 'READY',
        'loading' || 'starting' => 'LOADING',
        'stopping' => 'RELEASING',
        'disconnected' || 'exited' || 'revoked' => 'EMPTY',
        'recoveryRequired' => 'FAILED',
        'communicationLost' => 'UNKNOWN',
        _ => wirePhase,
      };
      if (!const [
        'EMPTY',
        'LOADING',
        'READY',
        'RELEASING',
        'FAILED',
        'UNKNOWN',
      ].contains(phase)) {
        throw const FormatException('Invalid core phase');
      }
      return CoreSnapshot(
        generation: value['generation'] as int,
        processId: value['processId'] as String?,
        inputId: value['inputId'] as String?,
        networkRevision: value['networkRevision'] as int? ?? 0,
        phase: phase,
        purpose: value['purpose'] as String?,
        configId: value['configId'] as String?,
        revision: value['revision'] as int?,
        composition: value['composition'] as String?,
        logWindow: value['logWindow'] as String?,
        error: AppMessage.fromNullable(value['error']),
      );
    } catch (_) {
      return CoreSnapshot(
        phase: 'UNKNOWN',
        error: messages.coreContextUnconfirmed,
      );
    }
  }
}
