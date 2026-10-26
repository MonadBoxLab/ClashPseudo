import 'package:clash_pseudo/src/model/app_snapshot.dart';

import '../features/configs/config_entry.dart';
import '../features/mode/tunnel_mode.dart';
import '../features/overrides/override_entry.dart';
import '../model/app_preferences.dart';
import '../features/strategies/strategy_choice.dart';
import '../l10n/messages.dart';
import '../platform/app_bridge.dart';
import '../platform/core_input.dart';

/// Actual loaded input used by target-only updates and explicit composition changes.
class RunningInput {
  const RunningInput._(
    this.state,
    this.entry,
    this.parts,
    this.preferences,
    this.fallbackMode,
  );
  final AppSnapshot state;
  final ConfigEntry entry;
  final List<OverrideEntry> parts;
  final AppPreferences preferences;
  final TunnelMode? fallbackMode;

  static Future<RunningInput?> read(
    AppBridge platform,
    AppSnapshot state,
  ) async {
    if (!state.running ||
        state.generation <= 0 ||
        !state.core.ready ||
        !state.core.hasIdentity ||
        state.core.purpose != 'VPN' ||
        state.mode == null ||
        state.core.configId != state.configId ||
        state.core.revision != state.revision) {
      return null;
    }
    final input = await platform.runningInput(state.core);
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
    final strategies = await platform.strategies(state.core.generation);
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
        id != state.configId ||
        revision != state.revision ||
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
      this.preferences.access == preferences.access &&
      this.preferences.packages.toSet().length ==
          preferences.packages.toSet().length &&
      this.preferences.packages.toSet().containsAll(preferences.packages) &&
      target.choices.entries.every(
        (choice) =>
            entry.choices[choice.key]?.type == choice.value.type &&
            entry.choices[choice.key]?.member == choice.value.member,
      );

  /// Prepare and validate complete input before Stop, then recheck owner and running
  /// intent at each subsequent wait before starting.
  Future<void> reconnect(
    AppBridge platform,
    CoreInput input, {
    required TunnelMode? fallbackMode,
    TunnelMode? routingOverride,
    ConfigEntry? entry,
    List<OverrideEntry>? parts,
    AppPreferences? preferences,
    Future<void> Function()? beforeStop,
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
      );
      await platform.checkOperation();
      final now = await platform.snapshot();
      if (!now.running ||
          !now.core.ready ||
          !now.core.matchesIdentity(state.core) ||
          now.configId != state.configId ||
          now.revision != state.revision ||
          now.generation != state.generation ||
          now.mode != state.mode) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      await beforeStop?.call();
      await platform.stop();
      await platform.checkOperation();
      final stopped = await platform.snapshot();
      if (stopped.phase != 'STOPPED' ||
          stopped.generation != state.generation) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      await platform.start(
        id: target.id,
        revision: target.revision,
        mode: fallbackMode,
      );
    } finally {
      await input.clear();
    }
  }
}
