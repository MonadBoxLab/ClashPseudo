import '../../platform/app_bridge.dart';
import '../configs/config_entry.dart';
import '../configs/config_store.dart';
import 'strategy_choice.dart';

class StrategyActions {
  StrategyActions(this.store, this.platform);
  final ConfigStore store;
  final AppBridge platform;

  Future<String> execute(Map<String, dynamic> command) async {
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
        state.core.configId != id ||
        state.core.revision != revision ||
        entry == null ||
        entry.revision != revision ||
        entry.body == null ||
        (state.running
            ? state.core.purpose != 'VPN' ||
                  state.configId != id ||
                  state.revision != revision
            : state.core.purpose != 'PREVIEW' || collection.selectedId != id)) {
      throw const ConfigFailure('策略上下文已变化，请等待当前配置重新读取。');
    }
    final before = await platform
        .strategies(generation)
        .timeout(const Duration(seconds: 5));
    final group = before.find(name);
    if (!before.matches(state.core) ||
        group == null ||
        group.type != choice.type ||
        !group.selectable ||
        (choice.member != null && !group.hasMember(choice.member!))) {
      throw const ConfigFailure('策略组或成员已变化，本次选择未保存。');
    }
    final saved = entry.choices[name];
    if (saved?.type != choice.type ||
        saved?.member != choice.member ||
        saved == null) {
      await store.save(collection.replace(entry.withChoice(name, choice)));
    }
    try {
      await platform.stage('正在应用策略选择');
      await platform.setStrategy(generation, name, choice);
      final after = await platform
          .strategies(generation)
          .timeout(const Duration(seconds: 5));
      final actual = after.find(name);
      if (!after.matches(state.core) ||
          actual == null ||
          actual.type != choice.type ||
          (choice.type.automatic
              ? actual.fixed != (choice.member ?? '')
              : actual.now != choice.member)) {
        throw const FormatException('Strategy not confirmed');
      }
    } catch (_) {
      throw const ConfigFailure('选择已保存供下次加载使用；本次策略切换未确认。');
    }
    return '';
  }
}
