import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'definition_provenance.dart';
import 'tunnel_mode.dart';
import 'strategy_choice.dart';

class StrategyMember {
  const StrategyMember({
    required this.name,
    required this.type,
    this.identity = '',
  });
  final String name;
  final String type;
  final String identity;
}

class StrategyGroup {
  StrategyGroup({
    required this.name,
    required this.rawType,
    required this.hidden,
    required this.now,
    this.currentIdentity = '',
    this.sourceIdentity = '',
    required this.fixed,
    this.icon = '',
    this.provenance,
    required List<StrategyMember> members,
  }) : members = List.unmodifiable(members);

  final String name;
  final String rawType;
  final bool hidden;
  final String now;
  final String currentIdentity;
  final String sourceIdentity;
  final String fixed;
  final String icon;
  final DefinitionProvenance? provenance;
  final List<StrategyMember> members;
  StrategyType? get type => switch (rawType) {
    'Selector' => StrategyType.select,
    'URLTest' => StrategyType.urlTest,
    'Fallback' => StrategyType.fallback,
    'LoadBalance' => StrategyType.loadBalance,
    _ => StrategyType.values.where((type) => type.value == rawType).firstOrNull,
  };
  bool get selectable => type?.selectable ?? false;
  bool get automatic => type?.automatic ?? false;
  bool hasMember(String member) => members.any((value) => value.name == member);

  factory StrategyGroup.fromMap(Map<String, dynamic> value) => StrategyGroup(
    name: value['name'] as String,
    rawType: value['type'] as String,
    hidden: value['hidden'] as bool,
    now: value['now'] as String,
    currentIdentity: value['currentIdentity'] as String? ?? '',
    sourceIdentity: value['sourceIdentity'] as String? ?? '',
    fixed: value['fixed'] as String,
    icon: value['icon'] as String,
    provenance: DefinitionProvenance.fromValue(
      value['provenance'],
      section: 'proxy-groups',
    ),
    members: (value['members'] as List).map((item) {
      final member = Map<String, dynamic>.from(item as Map);
      return StrategyMember(
        name: member['name'] as String,
        type: member['type'] as String,
        identity: member['identity'] as String? ?? '',
      );
    }).toList(),
  );
}

class StrategySnapshot {
  StrategySnapshot({
    required this.generation,
    this.processId,
    this.inputId,
    required this.configId,
    required this.revision,
    required this.purpose,
    this.composition,
    this.mode,
    required this.globalReferenced,
    required List<StrategyGroup> groups,
    required Map<String, String> unrestored,
    this.stale = false,
    Map<String, dynamic> raw = const {},
  }) : groups = List.unmodifiable(groups),
       unrestored = Map.unmodifiable(unrestored),
       raw = Map.unmodifiable(raw);

  final int generation;
  final String? processId;
  final String? inputId;
  final String configId;
  final int revision;
  final String purpose;
  final String? composition;
  final TunnelMode? mode;
  final bool globalReferenced;
  final List<StrategyGroup> groups;
  final Map<String, String> unrestored;
  final bool stale;
  final Map<String, dynamic> raw;

  bool matches(CoreSnapshot core) =>
      core.ready &&
      core.hasIdentity &&
      core.identity ==
          (
            processId,
            inputId,
            generation,
            configId,
            revision,
            composition,
            purpose,
          );

  StrategyGroup? find(String name) =>
      groups.where((group) => group.name == name).firstOrNull;

  factory StrategySnapshot.fromMap(Map<String, dynamic> value) =>
      StrategySnapshot(
        raw: value,
        stale: value['stale'] == true,
        generation: value['generation'] as int,
        processId: value['processId'] as String?,
        inputId: value['inputId'] as String?,
        configId: value['configId'] as String,
        revision: value['revision'] as int,
        purpose: value['purpose'] as String,
        composition: value['composition'] as String?,
        mode: TunnelMode.values
            .where((mode) => mode.name == value['mode'])
            .firstOrNull,
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
