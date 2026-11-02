import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../navigation/task_activity.dart';
import '../../navigation/page_route.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../components/feedback/operation_notice.dart';
import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../../model/app_snapshot.dart';
import '../../../model/config_entry.dart';
import '../../components/feedback/confirm_action.dart';
import '../../../logic/overrides/local_custom_actions.dart';
import '../../../logic/overrides/local_yaml_edit.dart';
import '../../../model/override_entry.dart';
import '../forms/provider/provider_form.dart';
import '../forms/proxy/proxy_form.dart';
import '../forms/proxy/proxy_form_type_page.dart';
import '../forms/rule_form.dart';
import '../forms/strategy_group_form.dart';

part 'local_definitions.dart';

/// Open a new GUI draft with the rendered action's storage epoch and source gate.
/// [isContextCurrent] checks the captured data source, not whether the covered
/// caller route is current. [onRoute] exposes only this form's exact route before
/// push and clears it after pop, so callers can distinguish it from unrelated
/// page routes. Task, foreground and form-route qualification belong to the session.
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
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
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
    final route = FocusedPageRoute<void>(
      builder: (_) => _LocalCustomHost(
        session: session,
        builder: (context) {
          Future<void> definition(Map<String, Object?> value) =>
              session.save(section, {'definition': value});
          return switch (section) {
            LocalYamlSection.proxies => ProxyFormPage(
              onSave: definition,
              onSaveHandled: session.acknowledge,
            ),
            LocalYamlSection.strategyGroups => StrategyGroupFormPage(
              members: List.unmodifiable(members),
              providers: List.unmodifiable(providers),
              onSave: definition,
              onSaveHandled: session.acknowledge,
            ),
            LocalYamlSection.proxyProviders ||
            LocalYamlSection.ruleProviders => ProviderFormPage(
              ruleProvider: section == LocalYamlSection.ruleProviders,
              downloadProxies: List.unmodifiable(downloadProxies),
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
              onSave: (value) => session.save(section, {'rule': value}),
              onSaveHandled: session.acknowledge,
            ),
          };
        },
      ),
    );
    session.route = route;
    onRoute?.call(route);
    await Navigator.of(context).push<void>(route);
  } finally {
    onRoute?.call(null);
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
            return switch (section) {
              LocalYamlSection.proxies => ProxyFormPage(
                initialDefinition: original,
                originalValueText: (path) =>
                    editor.definitionOriginalValue(definition, path),
                onSave: (value) =>
                    session.replaceDefinition(section, definition, value),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.strategyGroups => StrategyGroupFormPage(
                initialDefinition: original,
                originalValueText: (path) =>
                    editor.definitionOriginalValue(definition, path),
                members: List.unmodifiable(members),
                providers: List.unmodifiable(providers),
                onSave: (value) =>
                    session.replaceDefinition(section, definition, value),
                onSaveHandled: session.acknowledge,
              ),
              LocalYamlSection.proxyProviders ||
              LocalYamlSection.ruleProviders => ProviderFormPage(
                ruleProvider: section == LocalYamlSection.ruleProviders,
                initialName: definition.value,
                initialDefinition: original,
                originalValueText: (path) =>
                    editor.definitionOriginalValue(definition, path),
                downloadProxies: List.unmodifiable(members),
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
    if (context.mounted) showAppNotice(context, error.message);
    return false;
  } on LocalYamlEditException catch (error) {
    if (context.mounted) {
      showAppNotice(context, localYamlEditMessage(error.code));
    }
    return false;
  } on FormatException {
    if (context.mounted) {
      showAppNotice(context, messages.localYamlUnsupportedEdit);
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
  AppController app,
) async {
  final origin = ModalRoute.of(context);
  ModalRoute<dynamic>? popup;
  return confirmAction(
    context,
    title: (strings) => strings.delete,
    subject: definition.value.isEmpty ? '""' : definition.value,
    message: (strings) => strings.localCustomDeleteConfirm,
    confirmLabel: (strings) => strings.delete,
    onRoute: (route) => popup = route,
    isCurrent: () =>
        context.mounted &&
        app.foreground &&
        AppTaskActivity.isActive(context, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(origin, ownedPopup: popup),
  );
}

_LocalCustomSession? _capture(
  BuildContext context,
  AppController app,
  int epoch,
  bool Function()? isContextCurrent,
) {
  if (!context.mounted ||
      !app.foreground ||
      !AppTaskActivity.isActive(context) ||
      !AppTaskActivity.routeIsActive(ModalRoute.of(context))) {
    return null;
  }
  try {
    return _LocalCustomSession(
        app,
        epoch,
        AppLocalizations.of(context).localCustomTitle,
        isContextCurrent,
      )
      ..isTaskActive = (() =>
          context.mounted && AppTaskActivity.isActive(context));
  } on ConfigFailure catch (error) {
    showAppNotice(context, error.message);
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
  bool Function()? isTaskActive;
  bool get taskActive => isTaskActive?.call() ?? true;
  bool get liveRoute =>
      route?.isActive == true &&
      route?.animation?.status != AnimationStatus.reverse;

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
    if (!app.canEditOverrides) {
      throw ConfigFailure(
        app.overrideErrorMessage ?? messages.operationBusyFile,
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
      if (_closed || !taskActive || route?.isCurrent != true || !liveRoute) {
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
        taskActive &&
        !expired &&
        route?.isCurrent == true &&
        liveRoute;
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
        } catch (error) {
          throw _verificationFailure(
            messages.operationNotCompletedRetry.withDetail(error),
          );
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
        !taskActive ||
        !app.foreground ||
        route?.isCurrent != true ||
        !liveRoute ||
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
  ModalRoute<dynamic>? _route;
  bool _expiredNoticed = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (!mounted || !widget.session.expired || _expiredNoticed) return;
    _expiredNoticed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.session.expired) return;
      showAppNotice(
        context,
        messages.storageContextChanged,
        isCurrent: () => mounted && widget.session.liveRoute,
        eligibilityChanges: widget.session,
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_routeStatusChanged);
      _route = route;
      route?.animation?.addStatusListener(_routeStatusChanged);
    }
    widget.session
      ..route = route
      ..isTaskActive = (() => mounted && AppTaskActivity.isActive(context))
      ..syncOwner();
  }

  void _routeStatusChanged(AnimationStatus _) => widget.session.syncOwner();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    child: widget.builder(context),
    builder: (context, child) => AnimatedBuilder(
      animation: _route?.animation ?? const AlwaysStoppedAnimation(1.0),
      child: child,
      builder: (context, child) {
        final session = widget.session;
        final active =
            session.taskActive &&
            session.app.foreground &&
            session.liveRoute &&
            session.route?.isCurrent == true;
        return IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child!),
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_routeStatusChanged);
    widget.session.removeListener(_sessionChanged);
    widget.session.dispose();
    super.dispose();
  }
}
