import 'strategy_choice.dart';

class CoreSnapshot {
  const CoreSnapshot({
    this.generation = 0,
    this.phase = 'EMPTY',
    this.purpose,
    this.configId,
    this.revision,
    this.error,
  });
  final int generation;
  final String phase;
  final String? purpose;
  final String? configId;
  final int? revision;
  final String? error;

  bool get ready => phase == 'READY';
  bool get busy => phase == 'LOADING' || phase == 'RELEASING';
  bool get blocked => phase == 'FAILED' || phase == 'UNKNOWN';

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
        error: value['error'] as String?,
      );
    } catch (_) {
      return const CoreSnapshot(phase: 'UNKNOWN', error: '内核上下文尚未确认。');
    }
  }
}

class StrategyMember {
  const StrategyMember({required this.name, required this.type});
  final String name;
  final String type;
}

class StrategyGroup {
  StrategyGroup({
    required this.name,
    required this.rawType,
    required this.hidden,
    required this.now,
    required this.fixed,
    this.icon = '',
    required List<StrategyMember> members,
  }) : members = List.unmodifiable(members);

  final String name;
  final String rawType;
  final bool hidden;
  final String now;
  final String fixed;
  final String icon;
  final List<StrategyMember> members;
  StrategyType? get type =>
      StrategyType.values.where((type) => type.value == rawType).firstOrNull;
  bool get selectable => type?.selectable ?? false;
  bool get automatic => type?.automatic ?? false;
  String get typeLabel => type?.label ?? rawType;
  bool hasMember(String member) => members.any((value) => value.name == member);

  factory StrategyGroup.fromMap(Map<String, dynamic> value) => StrategyGroup(
    name: value['name'] as String,
    rawType: value['type'] as String,
    hidden: value['hidden'] as bool,
    now: value['now'] as String,
    fixed: value['fixed'] as String,
    icon: value['icon'] as String,
    members: (value['members'] as List).map((item) {
      final member = Map<String, dynamic>.from(item as Map);
      return StrategyMember(
        name: member['name'] as String,
        type: member['type'] as String,
      );
    }).toList(),
  );
}

class StrategySnapshot {
  StrategySnapshot({
    required this.generation,
    required this.configId,
    required this.revision,
    required this.purpose,
    required this.globalReferenced,
    required List<StrategyGroup> groups,
    required Map<String, String> unrestored,
  }) : groups = List.unmodifiable(groups),
       unrestored = Map.unmodifiable(unrestored);

  final int generation;
  final String configId;
  final int revision;
  final String purpose;
  final bool globalReferenced;
  final List<StrategyGroup> groups;
  final Map<String, String> unrestored;

  bool matches(CoreSnapshot core) =>
      core.ready &&
      generation == core.generation &&
      configId == core.configId &&
      revision == core.revision &&
      purpose == core.purpose;

  StrategyGroup? find(String name) =>
      groups.where((group) => group.name == name).firstOrNull;

  factory StrategySnapshot.fromMap(Map<String, dynamic> value) =>
      StrategySnapshot(
        generation: value['generation'] as int,
        configId: value['configId'] as String,
        revision: value['revision'] as int,
        purpose: value['purpose'] as String,
        globalReferenced: value['globalReferenced'] as bool,
        groups: (value['groups'] as List)
            .map(
              (item) =>
                  StrategyGroup.fromMap(Map<String, dynamic>.from(item as Map)),
            )
            .toList(),
        unrestored: {
          for (final item in value['unrestored'] as List)
            (item as Map)['group'] as String: item['reason'] as String,
        },
      );
}
