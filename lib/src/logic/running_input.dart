import 'package:clash_pseudo/src/model/app_snapshot.dart';

import '../model/config_entry.dart';
import '../model/tunnel_mode.dart';
import '../model/override_entry.dart';
import '../model/app_preferences.dart';
import '../model/strategy_choice.dart';
import '../model/messages.dart';
import '../model/app_platform.dart';
import '../platform/core/core_input.dart';

/// The actual loaded input confirmed by AppRuntime; targeted updates replace only the
/// affected parts.
class RunningInput {
  const RunningInput._(
    this.state,
    this.entry,
    this.parts,
    this.preferences,
    this.fallbackMode,
    this.vpnIntent,
    this.lanIntent,
  );
  final AppSnapshot state;
  final ConfigEntry entry;
  final List<OverrideEntry> parts;
  final AppPreferences preferences;
  final TunnelMode? fallbackMode;
  final bool vpnIntent;
  final bool lanIntent;
  String? get inputId => state.core.inputId;

  static Future<RunningInput?> read(
    AppPlatform platform,
    AppSnapshot state,
  ) async {
    if (!state.forwarding ||
        !state.core.hasIdentity ||
        state.core.purpose != 'RUNNING') {
      return null;
    }
    final input = await platform.runningRecord(state.core);
    if (input == null || input['inputId'] != state.core.inputId) return null;
    if (!input.containsKey('mode') ||
        input['name'] is! String ||
        (input['name'] as String).trim().isEmpty) {
      return null;
    }
    final values = input['overrides'] as List;
    if (values.any(
      (value) =>
          value['name'] is! String ||
          (value['name'] as String).trim().isEmpty ||
          !value.containsKey('role') ||
          (value['role'] != null &&
              !OverrideRole.values.any((role) => role.name == value['role'])),
    )) {
      return null;
    }
    final fallbackMode = input['mode'] == null
        ? null
        : TunnelMode.parse(input['mode']);
    final strategies = await platform.strategies(state.core);
    if (!strategies.matches(state.core)) return null;
    final choices = <String, StrategyChoice>{
      for (final group in strategies.groups)
        if (group.selectable && (group.automatic || group.now.isNotEmpty))
          group.name: StrategyChoice(
            type: group.type!,
            member: group.automatic
                ? (group.fixed.isEmpty ? null : group.fixed)
                : group.now,
          ),
    };
    final parts = [
      for (final value in values)
        OverrideEntry(
          id: value['id'] as String,
          name: value['name'] as String,
          kind: value['source'] == null ? ConfigKind.local : ConfigKind.remote,
          source: value['source'] as String?,
          role: value['role'] == null
              ? null
              : OverrideRole.values.byName(value['role'] as String),
          revision: value['revision'] as int,
          body: value['body'] as String,
          mode: OverrideMode.values.byName(value['mode'] as String),
          enabled: true,
        ),
    ];
    if (parts.any(
          (part) =>
              part.id.isEmpty ||
              part.revision <= 0 ||
              (part.role != null && part.remote),
        ) ||
        parts.map((part) => part.id).toSet().length != parts.length) {
      return null;
    }
    final id = input['id'];
    final revision = input['revision'];
    if (id is! String ||
        revision is! int ||
        id != state.core.configId ||
        revision != state.core.revision ||
        input['composition'] != state.core.composition ||
        CoreInput.compositionOf(id, revision, parts) !=
            state.core.composition) {
      return null;
    }
    return RunningInput._(
      state,
      ConfigEntry(
        id: id,
        name: input['name'] as String,
        kind: input['source'] == null ? ConfigKind.local : ConfigKind.remote,
        source: input['source'] as String?,
        revision: revision,
        body: input['body'] as String,
        choices: Map.unmodifiable(choices),
      ),
      List.unmodifiable(parts),
      const AppPreferences().withAccess(
        ApplicationAccess.values.byName(input['access'] as String),
        (input['packages'] as List).cast<String>(),
      ),
      fallbackMode,
      input['vpnIntent'] == true,
      input['lanIntent'] == true,
    );
  }

  /// Adopt target content and name while retaining actual running routing choices.
  ConfigEntry updatedEntry(ConfigEntry saved) => ConfigEntry(
    id: saved.id,
    name: saved.name,
    kind: saved.kind,
    source: saved.source,
    revision: saved.revision,
    body: saved.body,
    choices: entry.choices,
  );

  /// A body delta keeps actual membership, role, mode and position. Only the
  /// target adopts its saved content identity and name.
  List<OverrideEntry> updatedParts(OverrideEntry saved) => [
    for (final part in parts)
      part.id == saved.id
          ? OverrideEntry(
              id: saved.id,
              name: saved.name,
              kind: saved.kind,
              source: saved.source,
              revision: saved.revision,
              body: saved.body,
              role: part.role,
              enabled: true,
              mode: part.mode,
            )
          : part,
  ];

  static bool sameParts(
    Iterable<OverrideEntry> before,
    Iterable<OverrideEntry> after,
  ) {
    final a = before.where((part) => part.enabled).toList();
    final b = after.where((part) => part.enabled).toList();
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].body != b[i].body ||
          a[i].mode != b[i].mode) {
        return false;
      }
    }
    return true;
  }

  bool matchesAccess(ApplicationAccess access, Iterable<String> packages) =>
      preferences.access == access &&
      preferences.packages.toSet().length == packages.toSet().length &&
      preferences.packages.toSet().containsAll(packages);

  bool matchesSelection(
    ConfigEntry target,
    TunnelMode? mode,
    List<OverrideEntry> parts,
    AppPreferences preferences,
  ) =>
      entry.id == target.id &&
      entry.body == target.body &&
      fallbackMode == mode &&
      sameParts(this.parts, parts) &&
      matchesAccess(preferences.access, preferences.packages) &&
      target.choices.entries.every(
        (choice) =>
            entry.choices[choice.key]?.type == choice.value.type &&
            entry.choices[choice.key]?.member == choice.value.member,
      );

  /// Prepare and validate complete input before Stop, then recheck owner and running
  /// intent at each subsequent wait before starting.
  Future<void> reconnect(
    AppPlatform platform,
    CoreInput input, {
    required TunnelMode? fallbackMode,
    TunnelMode? routingOverride,
    ConfigEntry? entry,
    List<OverrideEntry>? parts,
    AppPreferences? preferences,
    Future<void> Function()? beforeStop,
    bool? vpnIntent,
    bool? lanIntent,
  }) async {
    final target = entry ?? this.entry;
    try {
      await platform.checkOperation();
      await input.write(
        target,
        fallbackMode,
        routingOverride: routingOverride,
        overrides: parts ?? this.parts,
        preferences: preferences ?? this.preferences,
        vpnIntent: vpnIntent ?? this.vpnIntent,
        lanIntent: lanIntent ?? this.lanIntent,
      );
      await platform.checkOperation();
      final now = await platform.snapshot();
      if (!now.forwarding ||
          !now.core.ready ||
          !now.core.matchesIdentity(state.core) ||
          now.configId != state.configId ||
          now.revision != state.revision ||
          now.generation != state.generation ||
          now.mode != state.mode) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      await beforeStop?.call();
      await platform.stop(preserveLan: false);
      await platform.checkOperation();
      final stopped = await platform.snapshot();
      if (stopped.phase != 'STOPPED' ||
          stopped.generation != state.generation) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      if (!(vpnIntent ?? this.vpnIntent) && !(lanIntent ?? this.lanIntent)) {
        return;
      }
      await platform.start(
        id: target.id,
        revision: target.revision,
        mode: fallbackMode,
        explicitStart: false,
      );
    } finally {
      await input.clear();
    }
  }
}
