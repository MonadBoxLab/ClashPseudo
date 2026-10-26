import '../l10n/messages.dart';

class CoreSnapshot {
  const CoreSnapshot({
    this.generation = 0,
    this.phase = 'EMPTY',
    this.purpose,
    this.configId,
    this.revision,
    this.composition,
    this.logWindow,
    AppMessage? error,
  }) : errorMessage = error;
  final int generation;
  final String phase;
  final String? purpose;
  final String? configId;
  final int? revision;
  final String? composition;
  final String? logWindow;
  final AppMessage? errorMessage;
  String? get error => errorMessage?.text;

  bool get ready => phase == 'READY';
  bool get busy => phase == 'LOADING' || phase == 'RELEASING';
  bool get blocked => phase == 'FAILED' || phase == 'UNKNOWN';

  bool get hasIdentity =>
      generation > 0 &&
      configId?.isNotEmpty == true &&
      revision != null &&
      revision! > 0 &&
      composition?.isNotEmpty == true &&
      const ['VPN', 'PREVIEW'].contains(purpose);

  (int, String?, int?, String?, String?) get identity =>
      (generation, configId, revision, composition, purpose);

  bool matchesIdentity(CoreSnapshot other) =>
      hasIdentity && identity == other.identity;

  bool matchesWireIdentity(Map<String, dynamic> value) =>
      hasIdentity &&
      value['generation'] is int &&
      value['revision'] is int &&
      identity ==
          (
            value['generation'],
            value['configId'],
            value['revision'],
            value['composition'],
            value['purpose'],
          );

  factory CoreSnapshot.fromMap(Map<String, dynamic> value) {
    try {
      final phase = value['phase'] as String;
      if (!const [
        'EMPTY',
        'LOADING',
        'READY',
        'RELEASING',
        'FAILED',
      ].contains(phase)) {
        throw const FormatException('Invalid core phase');
      }
      return CoreSnapshot(
        generation: value['generation'] as int,
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
