import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import 'local_yaml_edit.dart';
import 'override_actions.dart';
import 'override_entry.dart';

/// GUI edits share the ordinary override writer and its saved/apply outcomes.
class LocalCustomActions {
  LocalCustomActions(this.overrides);

  final OverrideActions overrides;

  Future<AppMessage> execute(Map<String, dynamic> command) async {
    // Reset the prior command's saved identity before rejecting a new local edit.
    overrides.result = {
      'overrideStatus': 'notSaved',
      'targetId': command['id'],
    };
    final entries = await overrides.store.read();
    final current = entries
        .where((entry) => entry.role == OverrideRole.localCustom)
        .firstOrNull;
    final id = command['id'];
    final revision = command['revision'];
    if (id == null
        ? current != null || revision != null
        : current == null || current.id != id || current.revision != revision) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    if (command['action'] == 'deleteLocalDefinition' && current == null) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    final String body;
    try {
      var editor = LocalYamlEdit(
        current?.body ?? '',
        initializeEmpty: current == null,
      );
      final section = LocalYamlSection.values.byName(
        command['section'] as String,
      );
      if (command['action'] == 'deleteLocalDefinition') {
        body = editor.remove(
          _directDefinition(editor, section, {
            'path': command['path'],
            'value': command['value'],
          }),
        );
      } else if (command['action'] == 'saveLocalDefinition') {
        final replacement = command['replacement'];
        final inPlace = replacement is Map && replacement['inPlace'] == true;
        if (replacement is Object && !inPlace) {
          if (current == null) {
            throw ConfigFailure(messages.overrideChangedReopen);
          }
          // Replace the direct definition in the exact saved revision; publish only
          // the complete successful remove/add result.
          editor = LocalYamlEdit(
            editor.remove(_directDefinition(editor, section, replacement)),
          );
        }
        Map<String, Object?> definition() =>
            Map<String, Object?>.from(command['definition'] as Map);
        if (inPlace) {
          if (current == null) {
            throw ConfigFailure(messages.overrideChangedReopen);
          }
          final original = _directDefinition(editor, section, replacement);
          body = switch (section) {
            LocalYamlSection.proxies || LocalYamlSection.strategyGroups =>
              editor.replaceNamed(original, definition()),
            LocalYamlSection.proxyProviders ||
            LocalYamlSection.ruleProviders => editor.replaceProvider(
              original,
              command['definitionName'] as String,
              definition(),
            ),
            LocalYamlSection.rules => editor.replaceRule(
              original,
              command['rule'] as String,
            ),
          };
        } else {
          body = switch (section) {
            LocalYamlSection.proxies => editor.addProxy(definition()),
            LocalYamlSection.strategyGroups => editor.addStrategyGroup(
              definition(),
            ),
            LocalYamlSection.proxyProviders => editor.addProxyProvider(
              command['definitionName'] as String,
              definition(),
            ),
            LocalYamlSection.ruleProviders => editor.addRuleProvider(
              command['definitionName'] as String,
              definition(),
            ),
            LocalYamlSection.rules => editor.addRule(command['rule'] as String),
          };
        }
      } else {
        throw ConfigFailure(messages.unknownOverrideOperation);
      }
    } on LocalYamlEditException catch (error) {
      throw ConfigFailure(localYamlEditMessage(error.code));
    }
    return overrides.execute({
      'action': 'saveOverride',
      'localCustom': true,
      'id': current?.id,
      'revision': current?.revision,
      'name': current?.name ?? command['name'],
      'body': body,
    });
  }

  LocalYamlDefinition _directDefinition(
    LocalYamlEdit editor,
    LocalYamlSection section,
    Object identity,
  ) {
    if (identity is! Map ||
        !(identity.length == 2 && !identity.containsKey('inPlace') ||
            identity.length == 3 && identity['inPlace'] == true) ||
        identity['path'] is! List ||
        identity['value'] is! String) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    final path = identity['path'] as List;
    final value = identity['value'] as String;
    final definition = editor.definitions(section).where((definition) {
      return definition.value == value &&
          definition.path.length == path.length &&
          definition.path.indexed.every((entry) => entry.$2 == path[entry.$1]);
    }).firstOrNull;
    return definition ?? (throw ConfigFailure(messages.overrideChangedReopen));
  }
}

AppMessage localYamlEditMessage(LocalYamlEditError error) => switch (error) {
  LocalYamlEditError.invalidYaml ||
  LocalYamlEditError.multipleDocuments ||
  LocalYamlEditError.notMapping ||
  LocalYamlEditError.duplicateKey => messages.localYamlInvalid,
  LocalYamlEditError.invalidStructure => messages.localYamlInvalidStructure,
  LocalYamlEditError.duplicateName => messages.localYamlDuplicateName,
  LocalYamlEditError.missingDefinition ||
  LocalYamlEditError.staleDefinition => messages.overrideChangedReopen,
  LocalYamlEditError.aliasTarget => messages.localYamlAliasTarget,
  LocalYamlEditError.inheritedTarget => messages.localYamlInheritedTarget,
  LocalYamlEditError.unsafeStructure => messages.localYamlUnsafeStructure,
  LocalYamlEditError.tooLarge => messages.textTooLargeSave,
  LocalYamlEditError.unsupportedEdit => messages.localYamlUnsupportedEdit,
};
