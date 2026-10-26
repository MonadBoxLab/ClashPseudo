import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_task.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/reading_list.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../../model/app_snapshot.dart';
import '../../model/core_snapshot.dart';
import '../../model/definition_provenance.dart';
import '../configs/config_entry.dart';
import 'local_custom_actions.dart';
import 'local_yaml_edit.dart';
import 'override_entry.dart';
import 'provider_form.dart';
import 'proxy_form.dart';
import 'proxy_form_type_page.dart';
import 'rule_form.dart';
import 'strategy_group_form.dart';

part 'local_definitions.dart';

/// Open a new GUI draft with the rendered action's storage epoch and additional source
/// gate.
Future<void> showLocalCustomForm(
  BuildContext context, {
  required AppController app,
  required LocalYamlSection section,
  required int storageEpoch,
  List<String> members = const [],
  List<String> providers = const [],
  List<String> targets = const [],
  List<String> ruleProviders = const [],
  List<String> subRules = const [],
  List<String> downloadProxies = const [],
  String initialType = 'DOMAIN',
  String? initialValue,
  String? initialTarget,
  bool restrictTargets = false,
  bool Function()? isContextCurrent,
}) async {
  members = List.unmodifiable(members);
  providers = List.unmodifiable(providers);
  targets = List.unmodifiable(targets);
  ruleProviders = List.unmodifiable(ruleProviders);
  subRules = List.unmodifiable(subRules);
  downloadProxies = List.unmodifiable(downloadProxies);
  final session = _capture(context, app, storageEpoch, isContextCurrent);
  if (session == null) return;
  try {
    await Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => _LocalCustomHost(
          session: session,
          builder: (context) {
            final notice = _LocalCustomNotice(session: session);
            Future<void> definition(Map<String, Object?> value) =>
                session.save(section, {'definition': value});
            return switch (section) {
              LocalYamlSection.proxies => ProxyFormPage(
                notice: notice,
                onSave: definition,
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.strategyGroups => StrategyGroupFormPage(
                members: List.unmodifiable(members),
                providers: List.unmodifiable(providers),
                notice: notice,
                onSave: definition,
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.proxyProviders ||
              LocalYamlSection.ruleProviders => ProviderFormPage(
                ruleProvider: section == LocalYamlSection.ruleProviders,
                downloadProxies: List.unmodifiable(downloadProxies),
                notice: notice,
                onSave: (name, value) => session.save(section, {
                  'definitionName': name,
                  'definition': value,
                }),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.rules => RuleFormPage(
                targets: List.unmodifiable(targets),
                ruleProviders: List.unmodifiable(ruleProviders),
                subRules: List.unmodifiable(subRules),
                initialType: initialType,
                initialValue: initialValue,
                initialTarget: initialTarget,
                restrictTargets: restrictTargets,
                notice: notice,
                onSave: (value) => session.save(section, {'rule': value}),
                onSaveHandled: session.acknowledge,
              ),
            };
          },
        ),
      ),
    );
  } finally {
    session.dispose();
  }
}

/// Reopen the complete saved fields of the named direct local strategy group. Return
/// true after saving.
Future<bool> showLocalCustomGroupEditor(
  BuildContext context, {
  required AppController app,
  required int storageEpoch,
  required String name,
  List<String> members = const [],
  List<String> providers = const [],
}) async {
  final session = _capture(context, app, storageEpoch, null);
  if (session == null) return false;
  try {
    final entry = session.entry;
    if (entry == null) {
      if (context.mounted) {
        showAppMessage(context, messages.overrideChangedReopen);
      }
      return false;
    }
    final editor = LocalYamlEdit(entry.body);
    final definition = editor.definitionNamed(
      LocalYamlSection.strategyGroups,
      name,
    );
    if (definition == null) {
      if (context.mounted) {
        showAppMessage(context, messages.overrideChangedReopen);
      }
      return false;
    }
    final original = editor.definitionValue(definition);
    if (!guiStrategyGroupTypes.contains(original['type'])) {
      if (context.mounted) {
        showAppMessage(context, messages.localYamlUnsupportedEdit);
      }
      return false;
    }
    final result = await Navigator.of(context).push<Map<String, Object?>>(
      FocusedPageRoute(
        builder: (_) => _LocalCustomHost(
          session: session,
          builder: (_) => StrategyGroupFormPage(
            initialDefinition: original,
            members: List.unmodifiable(members),
            providers: List.unmodifiable(providers),
            notice: _LocalCustomNotice(session: session),
            onSave: (value) => session.replaceDefinition(
              LocalYamlSection.strategyGroups,
              definition,
              value,
            ),
            onSaveHandled: session.acknowledge,
          ),
        ),
      ),
    );
    return result != null;
  } on ConfigFailure catch (error) {
    if (context.mounted) showAppMessage(context, error.message);
    return false;
  } on LocalYamlEditException catch (error) {
    if (context.mounted) {
      showAppMessage(context, localYamlEditMessage(error.code));
    }
    return false;
  } finally {
    session.dispose();
  }
}

/// Reopens a direct definition from the exact saved body represented by a row.
/// The local writer rechecks ID/revision/epoch/path at the actual publication.
Future<bool> showLocalCustomDefinitionEditor(
  BuildContext context, {
  required AppController app,
  required int storageEpoch,
  required OverrideEntry entry,
  required LocalYamlDefinition definition,
  List<String> members = const [],
  List<String> providers = const [],
  List<String> targets = const ['DIRECT', 'REJECT'],
  List<String> ruleProviders = const [],
  List<String> subRules = const [],
}) async {
  final session = _capture(context, app, storageEpoch, null);
  if (session == null) return false;
  try {
    if (session.entry?.id != entry.id ||
        session.entry?.revision != entry.revision ||
        session.entry?.body != entry.body) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    final editor = LocalYamlEdit(entry.body);
    final section = definition.section;
    final Map<String, Object?>? original;
    if (section == LocalYamlSection.rules) {
      // Separate outer fields while retaining native condition strings.
      ruleFormFields(definition.value);
      original = null;
    } else {
      original = editor.definitionValue(definition);
      if (section == LocalYamlSection.proxies &&
              !ProxyFormType.values.any(
                (type) => type.raw == original!['type'],
              ) ||
          section == LocalYamlSection.strategyGroups &&
              !guiStrategyGroupTypes.contains(original['type']) ||
          (section == LocalYamlSection.proxyProviders ||
                  section == LocalYamlSection.ruleProviders) &&
              !const ['http', 'file', 'inline'].contains(original['type'])) {
        throw ConfigFailure(messages.localYamlUnsupportedEdit);
      }
    }
    if (!context.mounted) return false;
    final result = await Navigator.of(context).push<Object>(
      FocusedPageRoute(
        builder: (_) => _LocalCustomHost(
          session: session,
          builder: (_) {
            final notice = _LocalCustomNotice(session: session);
            return switch (section) {
              LocalYamlSection.proxies => ProxyFormPage(
                initialDefinition: original,
                notice: notice,
                onSave: (value) =>
                    session.replaceDefinition(section, definition, value),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.strategyGroups => StrategyGroupFormPage(
                initialDefinition: original,
                members: List.unmodifiable(members),
                providers: List.unmodifiable(providers),
                notice: notice,
                onSave: (value) =>
                    session.replaceDefinition(section, definition, value),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.proxyProviders ||
              LocalYamlSection.ruleProviders => ProviderFormPage(
                ruleProvider: section == LocalYamlSection.ruleProviders,
                initialName: definition.value,
                initialDefinition: original,
                downloadProxies: List.unmodifiable(members),
                notice: notice,
                onSave: (name, value) => session.replaceDefinition(
                  section,
                  definition,
                  value,
                  name: name,
                ),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.rules => RuleFormPage(
                initialRule: definition.value,
                targets: List.unmodifiable(targets),
                ruleProviders: List.unmodifiable(ruleProviders),
                subRules: List.unmodifiable(subRules),
                notice: notice,
                onSave: (value) => session.replaceRule(definition, value),
                onSaveHandled: session.acknowledge,
              ),
            };
          },
        ),
      ),
    );
    return result != null;
  } on ConfigFailure catch (error) {
    if (context.mounted) showAppMessage(context, error.message);
    return false;
  } on LocalYamlEditException catch (error) {
    if (context.mounted) {
      showAppMessage(context, localYamlEditMessage(error.code));
    }
    return false;
  } on FormatException {
    if (context.mounted) {
      showAppMessage(context, messages.localYamlUnsupportedEdit);
    }
    return false;
  } finally {
    session.dispose();
  }
}

/// Confirmation precedes write-gate acquisition and session changes.
Future<bool> _confirmLocalDefinitionRemoval(
  BuildContext context,
  LocalYamlDefinition definition,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        final strings = AppLocalizations.of(context);
        return AlertDialog(
          scrollable: true,
          title: Text(strings.delete),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                definition.value.isEmpty ? '""' : definition.value,
              ),
              const SizedBox(height: 12),
              Text(strings.localCustomDeleteConfirm),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.delete),
            ),
          ],
        );
      },
    ) ??
    false;

_LocalCustomSession? _capture(
  BuildContext context,
  AppController app,
  int epoch,
  bool Function()? isContextCurrent,
) {
  if (!context.mounted) return null;
  try {
    return _LocalCustomSession(
      app,
      epoch,
      AppLocalizations.of(context).localCustomTitle,
      isContextCurrent,
    );
  } on ConfigFailure catch (error) {
    showAppMessage(context, error.message);
    return null;
  }
}

class _LocalCustomSession extends ChangeNotifier {
  _LocalCustomSession(
    this.app,
    this.epoch,
    this.newName,
    this.isContextCurrent,
  ) {
    _checkStorage();
    _entry = _actualEntry();
    _id = _entry?.id;
    _revision = _entry?.revision;
    _checkAvailable();
    app.addListener(_changed);
  }

  final AppController app;
  final int epoch;
  final String newName;
  final bool Function()? isContextCurrent;
  final owner = ValueNotifier(false);
  OverrideEntry? _entry;
  String? _id;
  int? _revision;
  ModalRoute<dynamic>? route;

  /// A form pushed from a definitions list is current instead of the list
  /// route that owns this session. It still belongs to the same session and
  /// feedback owner.
  AppSnapshot? _feedback;
  // Preserve the completed save fact while current-body verification is pending.
  AppMessage? _unverifiedSavedResult;
  bool _submissionFailed = false;
  bool _closed = false;
  bool _inFlight = false;
  bool _uncertain = false;
  bool _relinquished = false;
  bool _retryApply = false;
  AppMessage? _expired;
  Map<String, Object?>? _savedDraft;
  LocalYamlDefinition? _created;

  OverrideEntry? get entry => _entry;
  bool get expired => _expired != null;

  bool get _storageCurrent =>
      app.storageEpoch == epoch &&
      app.state.storageEpoch == epoch &&
      app.state.storageReady &&
      !app.state.storageRestoring;

  void _checkStorage() {
    if (!_storageCurrent || expired) {
      throw ConfigFailure(_expired ?? messages.storageContextChanged);
    }
  }

  OverrideEntry? _actualEntry() {
    if (!app.overridesLoaded || app.overrideErrorMessage != null) {
      throw ConfigFailure(
        app.overrideErrorMessage ?? messages.temporaryOverridesUnreadable,
      );
    }
    final entries = app.overrides
        .where((entry) => entry.role == OverrideRole.localCustom)
        .toList();
    if (entries.length > 1) {
      throw ConfigFailure(messages.temporaryOverridesUnreadable);
    }
    return entries.firstOrNull;
  }

  void _checkAvailable() {
    if (!app.foreground) {
      throw ConfigFailure(messages.operationNotCompletedRetry);
    }
    if (!app.state.confirmed) {
      throw ConfigFailure(messages.statusUnconfirmedVerify);
    }
    if (!app.canEdit) {
      throw ConfigFailure(
        app.platformErrorMessage ??
            app.configErrorMessage ??
            messages.operationBusyFile,
      );
    }
    if (isContextCurrent?.call() == false) {
      throw ConfigFailure(messages.strategyContextChangedRetry);
    }
  }

  void _checkEntry() {
    _checkStorage();
    final actual = _actualEntry();
    if (_entry == null
        ? actual != null
        : actual == null ||
              actual.id != _entry!.id ||
              actual.revision != _entry!.revision ||
              actual.body != _entry!.body ||
              actual.enabled != _entry!.enabled ||
              actual.mode != _entry!.mode) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
  }

  void _checkSubmission() {
    try {
      if (_closed || route?.isCurrent != true || route?.isActive != true) {
        throw ConfigFailure(messages.overrideChangedReopen);
      }
      _checkEntry();
      _checkAvailable();
      if (_uncertain) throw ConfigFailure(messages.operationNotCompletedRetry);
    } on ConfigFailure catch (error) {
      throw _verificationFailure(error.message);
    }
  }

  ConfigFailure _verificationFailure(AppMessage reason) => ConfigFailure(
    _unverifiedSavedResult == null
        ? reason
        : messages.localCustomSavedVerificationFailed(
            result: _unverifiedSavedResult!,
            reason: reason,
          ),
  );

  void _changed() {
    if (!_storageCurrent) _expired ??= messages.storageContextChanged;
    syncOwner();
    if (!_closed) notifyListeners();
  }

  void syncOwner() {
    if (_closed) return;
    final current =
        app.foreground &&
        !expired &&
        route?.isCurrent == true &&
        route?.isActive == true;
    if (!current && (_inFlight || _feedback != null || _submissionFailed)) {
      _relinquished = true;
    }
    owner.value = current && !_relinquished;
  }

  Map<String, Object?> get _identity => {
    'id': _id,
    'revision': _revision,
    'storageEpoch': epoch,
    'name': _entry?.name ?? newName,
  };

  Future<void> save(
    LocalYamlSection section,
    Map<String, Object?> draft,
  ) async {
    _checkSubmission();
    if (_savedDraft != null && _sameValue(_savedDraft, draft)) {
      await retry();
      return;
    }
    await _submit(
      {
        'action': 'saveLocalDefinition',
        ..._identity,
        'section': section.name,
        ...draft,
        if (_created case final definition?)
          'replacement': {'path': definition.path, 'value': definition.value},
      },
      section: section,
      draft: draft,
    );
  }

  /// Replace one direct definition in place after matching its identity in the exact
  /// saved body. The supplied complete draft retains unknown fields.
  Future<void> replaceDefinition(
    LocalYamlSection section,
    LocalYamlDefinition original,
    Map<String, Object?> definition, {
    String? name,
  }) => _replace(section, original, {
    'definition': definition,
    'definitionName': ?name,
  }, name ?? definition['name'] as String?);

  Future<void> replaceRule(LocalYamlDefinition original, String rule) =>
      _replace(LocalYamlSection.rules, original, {'rule': rule}, rule);

  Future<void> _replace(
    LocalYamlSection section,
    LocalYamlDefinition original,
    Map<String, Object?> draft,
    String? value,
  ) async {
    _checkSubmission();
    if (_savedDraft != null && _sameValue(_savedDraft, draft)) {
      await retry();
      return;
    }
    final entry = _entry;
    if (entry == null) throw ConfigFailure(messages.overrideChangedReopen);
    final previous = _created ?? original;
    final exists = LocalYamlEdit(entry.body)
        .definitions(section)
        .any(
          (current) =>
              _sameValue(current.path, previous.path) &&
              current.value == previous.value,
        );
    if (!exists) throw ConfigFailure(messages.overrideChangedReopen);
    final provider =
        section == LocalYamlSection.proxyProviders ||
        section == LocalYamlSection.ruleProviders;
    await _submit(
      {
        'action': 'saveLocalDefinition',
        ..._identity,
        'section': section.name,
        ...draft,
        'replacement': {
          'path': previous.path,
          'value': previous.value,
          'inPlace': true,
        },
      },
      section: section,
      draft: draft,
      replacedPath: provider ? [section.key, value!] : previous.path,
      replacedName: value,
    );
  }

  Future<void> remove(
    LocalYamlDefinition definition,
    OverrideEntry expectedEntry,
  ) async {
    _checkSubmission();
    if (expectedEntry.role != OverrideRole.localCustom ||
        expectedEntry.id != _entry?.id ||
        expectedEntry.revision != _entry?.revision ||
        expectedEntry.body != _entry?.body) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    await _submit({
      'action': 'deleteLocalDefinition',
      ..._identity,
      'section': definition.section.name,
      'path': definition.path,
      'value': definition.value,
    });
  }

  Future<void> retry() async {
    _checkSubmission();
    if (_entry == null || !_retryApply) {
      throw ConfigFailure(messages.overrideChangedReopen);
    }
    await _submit({
      'action': 'saveOverride',
      ..._identity,
      'localCustom': true,
      'body': _entry!.body,
    });
  }

  Future<void> _submit(
    Map<String, Object?> command, {
    LocalYamlSection? section,
    Map<String, Object?>? draft,
    List<Object>? replacedPath,
    String? replacedName,
  }) async {
    if (_inFlight) throw ConfigFailure(messages.operationBusyFile);
    _inFlight = true;
    _feedback = null;
    _submissionFailed = false;
    _relinquished = false;
    syncOwner();
    try {
      AppSnapshot? result;
      try {
        result = await app.submitAndWait(command, feedbackOwner: owner);
      } catch (_) {
        _uncertain = true;
        _relinquished = true;
        if (!_closed) owner.value = false;
        rethrow;
      }
      _feedback = result;
      _submissionFailed = result == null && app.commandErrorMessage != null;
      if (result == null) {
        // Resolve lost receipts and timeouts through the original operation result.
        _uncertain = true;
        if (!_submissionFailed) {
          _relinquished = true;
          if (!_closed) owner.value = false;
        }
        throw ConfigFailure(
          app.commandErrorMessage ?? messages.operationNotCompletedRetry,
        );
      }
      if (const [
        'saved',
        'applied',
        'applyFailed',
      ].contains(result.overrideStatus)) {
        final id = result.targetId;
        final revision = result.savedRevision;
        if (id == null ||
            id.isEmpty ||
            (_id != null && id != _id) ||
            revision == null ||
            revision < 1) {
          _uncertain = true;
          throw ConfigFailure(messages.operationNotCompletedRetry);
        }
        // Retain the returned ID/revision through refresh failure and use it for
        // subsequent edits.
        _id = id;
        _revision = revision;
        _uncertain = true;
        _unverifiedSavedResult =
            result.resultMessageDescription ?? messages.overrideSavedApplyLater;
        try {
          _checkStorage();
          final saved = _actualEntry();
          if (saved == null || saved.id != id || saved.revision != revision) {
            throw ConfigFailure(messages.overrideChangedReopen);
          }
          _entry = saved;
          _retryApply =
              result.overrideStatus == 'applyFailed' || !result.resultSuccess;
          if (draft != null && section != null) {
            if (replacedPath != null) {
              // In-place edits keep their original list position and identity.
              _savedDraft = Map<String, Object?>.from(
                jsonDecode(jsonEncode(draft)) as Map,
              );
              final verified = LocalYamlEdit(saved.body)
                  .definitions(section)
                  .where(
                    (definition) =>
                        _sameValue(definition.path, replacedPath) &&
                        definition.value == replacedName,
                  )
                  .firstOrNull;
              if (verified == null) {
                throw ConfigFailure(messages.overrideChangedReopen);
              }
              _created = verified;
            } else {
              final value = section == LocalYamlSection.rules
                  ? draft['rule'] as String
                  : section == LocalYamlSection.proxyProviders ||
                        section == LocalYamlSection.ruleProviders
                  ? draft['definitionName'] as String
                  : (draft['definition'] as Map)['name'] as String;
              final path = <Object>[
                section.key,
                if (section == LocalYamlSection.proxyProviders ||
                    section == LocalYamlSection.ruleProviders)
                  value
                else
                  0,
              ];
              _created = LocalYamlEdit(saved.body)
                  .definitions(section)
                  .where(
                    (definition) =>
                        definition.value == value &&
                        _sameValue(definition.path, path),
                  )
                  .firstOrNull;
              if (_created == null) {
                throw ConfigFailure(messages.overrideChangedReopen);
              }
              _savedDraft = Map<String, Object?>.from(
                jsonDecode(jsonEncode(draft)) as Map,
              );
            }
          }
          _uncertain = false;
          _unverifiedSavedResult = null;
        } on ConfigFailure catch (error) {
          throw _verificationFailure(error.message);
        } on LocalYamlEditException catch (error) {
          throw _verificationFailure(localYamlEditMessage(error.code));
        } catch (_) {
          throw _verificationFailure(messages.operationNotCompletedRetry);
        }
      } else {
        // Only explicit notSaved permits retry as a new add; retain uncertain outcomes
        // for result resolution.
        if (result.overrideStatus != 'notSaved') _uncertain = true;
        throw ConfigFailure(
          result.resultMessageDescription ??
              messages.operationNotCompletedRetry,
        );
      }
      if (!result.resultSuccess || result.overrideStatus == 'applyFailed') {
        throw ConfigFailure(
          result.resultMessageDescription ??
              messages.operationNotCompletedRetry,
        );
      }
    } finally {
      _inFlight = false;
      if (!_closed) notifyListeners();
    }
  }

  /// The form/list calls this only after adopting the result in its own reader.
  void acknowledge() {
    if (_closed ||
        !_storageCurrent ||
        expired ||
        route?.isCurrent != true ||
        route?.isActive != true ||
        _relinquished ||
        !owner.value) {
      return;
    }
    if (_feedback != null || _submissionFailed) {
      app.acknowledgeLocalFeedback(owner, result: _feedback);
      _feedback = null;
      _submissionFailed = false;
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    owner.value = false;
    app.removeListener(_changed);
    owner.dispose();
    super.dispose();
  }
}

bool _sameValue(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    return left.length == right.length &&
        left.indexed.every((item) => _sameValue(item.$2, right[item.$1]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameValue(left[key], right[key]),
        );
  }
  return left == right;
}

class _LocalCustomHost extends StatefulWidget {
  const _LocalCustomHost({required this.session, required this.builder});
  final _LocalCustomSession session;
  final WidgetBuilder builder;

  @override
  State<_LocalCustomHost> createState() => _LocalCustomHostState();
}

class _LocalCustomHostState extends State<_LocalCustomHost> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.session.route = ModalRoute.of(context);
    widget.session.syncOwner();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);

  @override
  void dispose() {
    // Release the identity immediately when the route begins closing.
    widget.session.dispose();
    super.dispose();
  }
}

class _LocalCustomNotice extends StatelessWidget {
  const _LocalCustomNotice({required this.session});
  final _LocalCustomSession session;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final disabled = session.entry?.enabled == false;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.localCustomNotice),
          if (disabled) ...[
            const SizedBox(height: 8),
            Text(strings.localCustomDisabled),
          ],
          const SizedBox(height: 8),
          Tooltip(
            message: session.expired ? strings.storageContextChanged : '',
            child: Text(
              session.expired ? strings.storageContextChanged : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              strutStyle: const StrutStyle(height: 1.5, forceStrutHeight: true),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
