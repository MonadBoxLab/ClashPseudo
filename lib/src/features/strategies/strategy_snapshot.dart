import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../../l10n/app_localizations.dart';
import '../../model/definition_provenance.dart';
import '../mode/tunnel_mode.dart';
import 'strategy_choice.dart';

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
    this.currentIdentity = '',
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
  final String fixed;
  final String icon;
  final DefinitionProvenance? provenance;
  final List<StrategyMember> members;
  StrategyType? get type =>
      StrategyType.values.where((type) => type.value == rawType).firstOrNull;
  bool get selectable => type?.selectable ?? false;
  bool get automatic => type?.automatic ?? false;
  String typeLabel(AppLocalizations strings) => type?.label(strings) ?? rawType;
  bool hasMember(String member) => members.any((value) => value.name == member);

  factory StrategyGroup.fromMap(Map<String, dynamic> value) => StrategyGroup(
    name: value['name'] as String,
    rawType: value['type'] as String,
    hidden: value['hidden'] as bool,
    now: value['now'] as String,
    currentIdentity: value['currentIdentity'] as String? ?? '',
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
    this.composition,
    this.mode,
    required this.globalReferenced,
    required List<StrategyGroup> groups,
    required Map<String, String> unrestored,
  }) : groups = List.unmodifiable(groups),
       unrestored = Map.unmodifiable(unrestored);

  final int generation;
  final String configId;
  final int revision;
  final String purpose;
  final String? composition;
  final TunnelMode? mode;
  final bool globalReferenced;
  final List<StrategyGroup> groups;
  final Map<String, String> unrestored;

  bool matches(CoreSnapshot core) =>
      core.ready &&
      core.hasIdentity &&
      core.identity == (generation, configId, revision, composition, purpose);

  StrategyGroup? find(String name) =>
      groups.where((group) => group.name == name).firstOrNull;

  factory StrategySnapshot.fromMap(Map<String, dynamic> value) =>
      StrategySnapshot(
        generation: value['generation'] as int,
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
