import 'package:clash_pseudo/src/logic/running_input.dart';

import 'dart:io';

import '../../model/app_platform.dart';
import '../../platform/core/core_input.dart';
import '../storage/preferences_store.dart';
import '../../model/config_entry.dart';
import 'config_store.dart';
import '../../model/strategy_choice.dart';
import '../../model/messages.dart';

class StrategyActions {
  StrategyActions(this.store, this.platform, {required this.runInput});
  final File runInput;
  final ConfigStore store;
  final AppPlatform platform;

  Future<AppMessage?> execute(Map<String, dynamic> command) async {
    final id = command['id'] as String;
    final revision = command['revision'] as int;
    final generation = command['generation'] as int;
    final name = command['name'] as String;
    final choice = StrategyChoice.fromJson(
      Map<String, dynamic>.from(command['choice'] as Map),
    );
    final state = await platform.snapshot();
    final collection = await store.read();
    final entry = collection.find(id);
    if (!state.confirmed ||
        !state.core.ready ||
        state.core.generation != generation ||
        command['processId'] != state.core.processId ||
        command['inputId'] != state.core.inputId ||
        command['composition'] is! String ||
        command['composition'] != state.core.composition ||
        state.core.configId != id ||
        state.core.revision != revision ||
        entry == null ||
        (!state.forwarding && entry.revision != revision) ||
        (state.forwarding
            ? state.core.purpose != 'RUNNING' ||
                  state.configId != id ||
                  state.revision != revision
            : state.core.purpose != 'PREVIEW' || collection.selectedId != id)) {
      throw ConfigFailure(messages.strategyContextChangedRetry);
    }
    // The runtime owns the operation deadline. A native read still owns this
    // execution slot until its real callback, even after UI cancellation.
    final before = await platform.strategies(state.core);
    final group = before.find(name);
    if (before.stale ||
        !before.matches(state.core) ||
        group == null ||
        group.type != choice.type ||
        !group.selectable ||
        (choice.member != null && !group.hasMember(choice.member!))) {
      throw ConfigFailure(messages.strategyGroupChanged);
    }
    final saved = entry.choices[name];
    if (saved?.type != choice.type ||
        saved?.member != choice.member ||
        saved == null) {
      await store.save(collection.replace(entry.withChoice(name, choice)));
    }
    final unchanged = choice.type.automatic
        ? group.fixed == (choice.member ?? '')
        : group.now == choice.member;
    if (unchanged) return null;
    try {
      await platform.stage(messages.applyingStrategySelection);
      final preferences = await PreferencesStore(store.directory).read();
      var expected = state.core;
      if (state.forwarding && preferences.reconnectOnRoutingChange) {
        final loaded = await RunningInput.read(platform, state);
        if (loaded == null) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        await loaded.reconnect(
          platform,
          CoreInput(runInput),
          fallbackMode: loaded.fallbackMode,
          routingOverride: state.mode,
          entry: loaded.entry.withChoice(name, choice),
        );
        final current = await platform.snapshot();
        if (!current.forwarding ||
            current.configId != id ||
            current.revision != revision) {
          throw const FormatException('Strategy session changed');
        }
        expected = current.core;
      } else {
        await platform.setStrategy(state.core, name, choice);
      }
      final after = await platform.strategies(expected);
      final actual = after.find(name);
      if (after.stale ||
          !after.matches(expected) ||
          actual == null ||
          actual.type != choice.type ||
          (choice.type.automatic
              ? actual.fixed != (choice.member ?? '')
              : actual.now != choice.member)) {
        throw const FormatException('Strategy not confirmed');
      }
    } catch (error, stack) {
      throw ConfigFailure(
        messages.strategySelectionUnconfirmed.withDetail(error),
        cause: error,
        stackTrace: stack,
      );
    }
    return null;
  }
}
