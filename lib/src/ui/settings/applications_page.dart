import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../components/input/task_shortcuts.dart';
import '../components/input/toolbar_search_field.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';
import '../components/feedback/confirm_action.dart';
import '../../model/app_preferences.dart';

class ApplicationsPage extends StatefulWidget {
  const ApplicationsPage({super.key, required this.app, this.storageEpoch});
  final AppController app;
  final int? storageEpoch;
  @override
  State<ApplicationsPage> createState() => _ApplicationsPageState();
}

class _ApplicationsPageState extends State<ApplicationsPage> {
  AppController get app => widget.app;
  late final int _storageEpoch;
  ModalRoute<dynamic>? _route;
  late final Future<bool> Function() _overviewLeave = _leave;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _header = GlobalKey();
  final _top = const ValueKey('applications-header');
  final _center = const ValueKey('applications-center');
  bool _anchored = false;
  int _centerIndex = 0;
  double _headerExtent = 0;
  (double, double, String, TextTheme, bool)? _layout;
  // Raw icon bytes have the same per-icon limit as the Android bridge. This
  // page-local LRU holds at most 32 icons (including in-flight requests).
  final _icons = <String, Future<Uint8List?>>{};
  List<Map<String, dynamic>>? _applications;
  Map<String, Set<String>> _groups = {};
  bool _failed = false;
  Object? _listError;
  bool _readFailed = false;
  bool _readingDetails = false;
  Object? _detailError;
  (Object, (int, int), int)? _pendingListError;
  ModalRoute<dynamic>? _detailsRoute;
  bool _epochNoticeShown = false;
  final _noticeChanges = ValueNotifier(0);
  bool _active = false;
  bool _loading = true;
  bool _system = false;
  ApplicationAccess _access = ApplicationAccess.all;
  Set<String> _selected = {};
  final _knownPackages = <String>{};
  late bool _preferencesLoaded;
  bool _saving = false;
  bool _leaving = false;
  String? _query;
  int _request = 0;
  bool _reading = false;
  bool _readAgain = false;
  bool _readAgainReport = false;
  int _readFailures = 0;
  Timer? _retry;
  Timer? _deadline;
  late int _seenApplicationsRevision;
  double _rowHeight = 72;

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? app.storageEpoch;
    _access = app.preferences.access;
    _selected = app.preferences.packages.toSet();
    _knownPackages.addAll(_selected);
    _preferencesLoaded = app.preferencesLoaded && app.preferencesError == null;
    _seenApplicationsRevision = app.applicationsRevision;
    app.addListener(_appChanged);
  }

  bool _current({ModalRoute<dynamic>? ownedPopup}) =>
      mounted &&
      app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: ownedPopup);

  bool get _eligible => _current();
  bool get _detailsActive =>
      _readingDetails && _current(ownedPopup: _detailsRoute);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      final previous = _route;
      if (previous != null) {
        app.unregisterOverviewLeave(previous, _overviewLeave);
      }
      _route = route;
      if (route != null) app.registerOverviewLeave(route, _overviewLeave);
    }
    if (_syncReadVisibility()) unawaited(_load());
  }

  bool _syncReadVisibility() {
    if (_detailsActive) return false;
    final active = _eligible;
    if (_active == active) return false;
    _active = active;
    if (active) {
      _readFailed = false;
      return true;
    }
    _request++;
    _retry?.cancel();
    _loading = false;
    _searchFocus.unfocus();
    return false;
  }

  void _appChanged() {
    if (!_preferencesLoaded &&
        app.preferencesLoaded &&
        app.preferencesError == null) {
      final previous = _visible;
      setState(() {
        _access = app.preferences.access;
        _selected = app.preferences.packages.toSet();
        _knownPackages.addAll(_selected);
        _preferencesLoaded = true;
        _keepReadingAnchor(_applications ?? const [], previous: previous);
      });
    }
    var refresh = _syncReadVisibility();
    if (_seenApplicationsRevision != app.applicationsRevision) {
      _seenApplicationsRevision = app.applicationsRevision;
      if (app.changedApplication case final package?) _icons.remove(package);
      _request++;
      _readFailures = 0;
      _readFailed = false;
      _listError = null;
      _pendingListError = null;
      refresh = true;
    }
    if (refresh) {
      if (_eligible) {
        unawaited(_load());
      } else if (_detailsActive) {
        _readAgain = true;
      }
    }
  }

  @override
  void dispose() {
    _request++;
    _retry?.cancel();
    _deadline?.cancel();
    final route = _route;
    if (route != null) app.unregisterOverviewLeave(route, _overviewLeave);
    app.removeListener(_appChanged);
    _icons.clear();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _noticeChanges.dispose();
    super.dispose();
  }

  void _scheduleReadRetry() {
    if (!_eligible || !_readFailed || _reading || _retry?.isActive == true) {
      return;
    }
    const backoff = [5, 10, 30, 60];
    final seconds = backoff[(_readFailures - 1).clamp(0, 3)];
    _retry = Timer(Duration(seconds: seconds), _load);
  }

  void _reportListFailure(Object error, (int, int) epoch, int request) {
    final owner = app;
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch) &&
        _storageEpoch == app.storageEpoch &&
        request == _request &&
        (identical(_listError, error) ||
            _readingDetails && identical(_detailError, error));
    String summary(AppLocalizations strings) => strings.applicationListFailed;
    String detail(AppLocalizations _) => error.toString();
    Future<void> showDetails() async {
      final restoreSearch = _searchFocus.hasFocus;
      _readingDetails = true;
      _detailError = error;
      try {
        await showLocalizedOperationMessage(
          context,
          summary,
          technicalDetail: detail,
          title: (strings) => strings.errorDetails,
          eligibilityChanges: Listenable.merge([owner, _noticeChanges]),
          isCurrent: () => sameSource() && _eligible,
          isCurrentWithPopup: (popup) =>
              sameSource() && _current(ownedPopup: popup),
          onRoute: (route) => _detailsRoute = route,
          onRetry: () => _load(reportFailure: true),
        );
      } finally {
        _readingDetails = false;
        _detailsRoute = null;
        _detailError = null;
        if (mounted) {
          _syncReadVisibility();
          if (_eligible) {
            if (restoreSearch &&
                epoch == (app.state.storageEpoch, app.storageEpoch)) {
              _searchFocus.requestFocus();
            }
            final pending = _pendingListError;
            _pendingListError = null;
            if (pending != null &&
                _readFailed &&
                pending.$2 == (app.state.storageEpoch, app.storageEpoch) &&
                pending.$3 == _request) {
              _reportListFailure(pending.$1, pending.$2, pending.$3);
            }
            if (_readAgain && !_reading) {
              unawaited(_load(reportFailure: _readAgainReport));
            } else {
              _scheduleReadRetry();
            }
          }
        }
      }
    }

    unawaited(
      showLocalizedOperationNotice(
        context,
        summary,
        technicalDetail: detail,
        eligibilityChanges: Listenable.merge([owner, _noticeChanges]),
        isCurrent: () => sameSource() && _eligible,
        isCurrentWithPopup: (popup) =>
            sameSource() && _current(ownedPopup: popup),
        onRetry: () => _load(reportFailure: true),
        onDetails: showDetails,
        identity: ('applications-read', _storageEpoch, request),
      ),
    );
  }

  Future<void> _load({bool reportFailure = false}) async {
    if (!_eligible) return;
    if (_reading) {
      if (reportFailure) _request++;
      _readAgain = true;
      _readAgainReport |= reportFailure;
      return;
    }
    _retry?.cancel();
    _readAgain = _readAgainReport = false;
    _reading = true;
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    final request = ++_request;
    bool current() =>
        mounted &&
        identical(owner, app) &&
        (_eligible || _detailsActive) &&
        request == _request &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch);
    var failed = false;
    void failure(Object error) {
      if (!current()) return;
      final notify = !_readFailed || reportFailure || failed;
      if (!failed) _readFailures++;
      failed = true;
      if (notify) _listError = error;
      _readFailed = true;
      setState(() {
        _failed = true;
        _loading = false;
      });
      if (notify) {
        if (_detailsActive) {
          _pendingListError = (error, epoch, request);
        } else {
          _reportListFailure(error, epoch, request);
        }
      }
    }

    setState(() => _loading = true);
    _deadline = Timer(const Duration(seconds: 5), () {
      failure(TimeoutException('Reading applications is still in progress'));
    });
    try {
      final value = await owner.platform.applications();
      if (!current()) return;
      final byUid = <int, Set<String>>{};
      for (final row in value) {
        if (row['uid'] case final int uid) {
          (byUid[uid] ??= {}).add(row['package'] as String);
        }
      }
      final groups = {
        for (final group in byUid.values)
          for (final package in group) package: group,
      };
      final previous = {
        for (final row in _applications ?? const <Map<String, dynamic>>[])
          row['package'] as String: row['updatedAt'],
      };
      final versions = {
        for (final row in value) row['package'] as String: row['updatedAt'],
      };
      _icons.removeWhere(
        (package, _) =>
            !versions.containsKey(package) ||
            !previous.containsKey(package) ||
            previous[package] != versions[package],
      );
      _keepReadingAnchor(value);
      setState(() {
        _applications = value;
        _groups = groups;
        _loading = false;
        _failed = false;
        _listError = null;
        _pendingListError = null;
      });
      _readFailed = false;
      _readFailures = 0;
      _noticeChanges.value++;
    } catch (error) {
      failure(error);
    } finally {
      _deadline?.cancel();
      _deadline = null;
      _reading = false;
      if (mounted) {
        if (_loading) setState(() => _loading = false);
        if (_eligible) {
          if (_readAgain) {
            final report = _readAgainReport;
            unawaited(_load(reportFailure: report));
          } else {
            _scheduleReadRetry();
          }
        }
      }
    }
  }

  // Anchor the first fully visible surviving row at the SDK viewport center before
  // layout changes.
  void _keepReadingAnchor(
    List<Map<String, dynamic>> next, {
    List<Map<String, dynamic>>? previous,
  }) {
    if (!_scroll.hasClients || _applications == null) return;
    final header = _header.currentContext?.findRenderObject();
    if (header is! RenderBox || !header.hasSize) return;
    final origin = _anchored ? -_centerIndex * _rowHeight : _headerExtent;
    if (_scroll.offset < origin) {
      _resetCenter();
      return;
    }
    final old = previous ?? _visible;
    final updated = _filter(next);
    final nextIndices = {
      for (var i = 0; i < updated.length; i++) updated[i]['package']: i,
    };
    final first = math.max(0, ((_scroll.offset - origin) / _rowHeight).ceil());
    for (var i = first; i < old.length; i++) {
      final index = nextIndices[old[i]['package']];
      if (index == null) continue;
      final top = origin + i * _rowHeight - _scroll.offset;
      _centerIndex = index;
      _anchored = true;
      _scroll.position.correctBy(-top - _scroll.offset);
      return;
    }
    _resetCenter();
  }

  // Start an explicit search/filter from header coordinates while keeping the search
  // field fixed.
  void _resetCenter() {
    if (!_anchored) return;
    final header = _header.currentContext?.findRenderObject();
    if (_scroll.hasClients && header is RenderBox && header.hasSize) {
      _scroll.position.correctBy(_centerIndex * _rowHeight + _headerExtent);
    }
    _centerIndex = 0;
    _anchored = false;
  }

  Set<String> _group(String package) => _groups[package] ?? {package};

  Set<String> _expandSelection(Iterable<String> packages) => {
    for (final package in packages) ..._group(package),
  };

  Future<Uint8List?> _iconFor(String package) {
    final cached = _icons.remove(package);
    if (cached != null) {
      _icons[package] = cached;
      return cached;
    }
    final value = () async {
      try {
        final bytes = await app.platform
            .applicationIcon(package)
            .timeout(const Duration(seconds: 5));
        return bytes != null && bytes.length <= 256 * 1024 ? bytes : null;
      } catch (_) {
        return null;
      }
    }();
    if (_icons.length >= 32) _icons.remove(_icons.keys.first);
    _icons[package] = value;
    return value;
  }

  bool get _dirty {
    final saved = _expandSelection(app.preferences.packages);
    final selected = _expandSelection(_selected);
    return _access != app.preferences.access ||
        selected.length != saved.length ||
        !selected.containsAll(saved);
  }

  bool get _needsApply {
    if (!app.state.running) return false;
    final actual = app.state.runningApplicationAccess;
    return actual == null ||
        actual.generation != app.state.generation ||
        !actual.matches(app.preferences.access, app.preferences.packages);
  }

  List<Map<String, dynamic>> get _visible =>
      _filter(_applications ?? const <Map<String, dynamic>>[]);

  List<Map<String, dynamic>> _filter(List<Map<String, dynamic>> rows) {
    final installed = {for (final row in rows) row['package']};
    final candidates = [
      ...rows,
      for (final package in _knownPackages)
        if (!installed.contains(package))
          {
            'package': package,
            'label': package,
            'system': false,
            'installed': false,
          },
    ];
    if (candidates.length != rows.length) {
      candidates.sort(
        (a, b) => (a['label'] as String).toLowerCase().compareTo(
          (b['label'] as String).toLowerCase(),
        ),
      );
    }
    final query = _query?.trim().toLowerCase();
    return candidates.where((row) {
      if (!_system && row['system'] == true) return false;
      if (query == null || query.isEmpty) return true;
      return '${row['label']} ${row['package']}'.toLowerCase().contains(query);
    }).toList();
  }

  void _toggle(String package) {
    if (!_canEdit) return;
    final group = _group(package);
    setState(() {
      if (group.any(_selected.contains)) {
        _selected.removeAll(group);
      } else {
        _selected.addAll(group);
        _knownPackages.addAll(group);
      }
    });
    _noticeChanges.value++;
  }

  bool get _canEdit =>
      _eligible &&
      _storageEpoch == app.storageEpoch &&
      app.canEdit &&
      app.canChangePreferences &&
      !_saving &&
      !_loading &&
      !_failed &&
      _applications != null;

  bool get _canSave => _canEdit && (_dirty || _needsApply);

  Future<void> _save() async {
    if (!_canSave) return;
    final owner = app;
    final epoch = owner.state.storageEpoch;
    final preferences = app.preferences;
    final session = (app.state.generation, app.state.phase);
    ModalRoute<dynamic>? confirmation;
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        app.foreground &&
        epoch == app.state.storageEpoch &&
        _storageEpoch == app.storageEpoch &&
        identical(preferences, app.preferences) &&
        session == (app.state.generation, app.state.phase);
    bool current() => sameSource() && _current(ownedPopup: confirmation);
    if (_access == ApplicationAccess.only && _selected.isEmpty) {
      await showLocalizedOperationNotice(
        context,
        (strings) => strings.applicationAllowEmpty,
        eligibilityChanges: Listenable.merge([app, _noticeChanges]),
        isCurrent: () =>
            current() && _access == ApplicationAccess.only && _selected.isEmpty,
        isCurrentWithPopup: (popup) =>
            sameSource() &&
            _access == ApplicationAccess.only &&
            _selected.isEmpty &&
            _current(ownedPopup: popup),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      if (app.state.running) {
        final accepted = await confirmAction(
          context,
          title: (strings) => strings.applicationReconnectTitle,
          message: (strings) => strings.applicationReconnectMessage,
          confirmLabel: (strings) => strings.applicationReconnect,
          onRoute: (route) => confirmation = route,
          eligibilityChanges: app,
          isCurrent: current,
        );
        confirmation = null;
        if (!accepted || !mounted) return;
      }
      if (!current() || !app.canEdit || !app.canChangePreferences) {
        return;
      }
      await app.submit({
        'action': 'setApplicationAccess',
        'storageEpoch': _storageEpoch,
        'access': _access.name,
        'packages': _expandSelection(_selected).toList()..sort(),
      });
      // submit only acknowledges acceptance. Shared operation feedback owns both
      // rejection and the eventual result, avoiding duplicate dialogs.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_eligible,
    child: ExcludeFocus(
      excluding: !_eligible && !_detailsActive,
      child: ExcludeSemantics(
        excluding: !_eligible,
        child: TaskShortcuts(
          onSearch: () {
            if (_eligible) _searchFocus.requestFocus();
          },
          onSave: _save,
          onEscape: _searchFocus.unfocus,
          child: _content(context),
        ),
      ),
    ),
  );

  void _scheduleEpochNotice() {
    if (_epochNoticeShown || _storageEpoch == app.storageEpoch) return;
    _epochNoticeShown = true;
    if (!_eligible) return;
    final epoch = app.storageEpoch;
    bool sameSource() => mounted && epoch == app.storageEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sameSource() || !_eligible) return;
      unawaited(
        showLocalizedOperationNotice(
          context,
          (strings) => strings.storageContextChanged,
          eligibilityChanges: app,
          isCurrent: () => sameSource() && _eligible,
          isCurrentWithPopup: (popup) =>
              sameSource() && _current(ownedPopup: popup),
        ),
      );
    });
  }

  Widget _content(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final strings = AppLocalizations.of(context);
        final colors = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final actual = app.state.runningApplicationAccess;
        _scheduleEpochNotice();
        final policyStatus = _storageEpoch != app.storageEpoch
            ? strings.storageContextChanged
            : app.preferencesError != null
            ? strings.settingsLoadFailed
            : !_preferencesLoaded
            ? ''
            : !app.state.confirmed || app.platformError != null
            ? strings.statusUnconfirmedVerify
            : !app.state.running
            ? strings.applicationPolicyNextConnection
            : actual == null || actual.generation != app.state.generation
            ? strings.applicationPolicyUnknown
            : _needsApply
            ? strings.applicationPolicyPending
            : strings.applicationPolicyApplied;
        double lineHeight(TextStyle? style) {
          final painter = TextPainter(
            text: TextSpan(text: 'Ag', style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final height = painter.height;
          painter.dispose();
          return height;
        }

        final rowHeight = math
            .max(
              72,
              lineHeight(text.bodyLarge) + lineHeight(text.bodyMedium) + 16,
            )
            .ceilToDouble();
        final controlWidth =
            (320 * MediaQuery.textScalerOf(context).scale(16) / 16).clamp(
              320.0,
              480.0,
            );
        final usableHeight =
            constraints.maxHeight -
            MediaQuery.viewInsetsOf(context).bottom -
            MediaQuery.paddingOf(context).vertical -
            kToolbarHeight;
        final contentWidth =
            constraints.maxWidth - MediaQuery.paddingOf(context).horizontal;
        final wide =
            contentWidth >= 840 &&
            contentWidth >= controlWidth + 360 &&
            usableHeight >= 480;
        final layout = (
          constraints.maxWidth,
          rowHeight,
          strings.localeName,
          text,
          wide,
        );
        if (_layout != null && _layout != layout) {
          _keepReadingAnchor(_applications ?? const []);
        }
        _layout = layout;
        _rowHeight = rowHeight;
        final canEdit = _canEdit;
        final controls = Padding(
          key: _header,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.applicationAccessNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              ToolbarSearchField(
                controller: _search,
                focusNode: _searchFocus,
                hintText: strings.searchApplications,
                onChanged: (value) => setState(() {
                  _resetCenter();
                  _query = value;
                }),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final mode in ApplicationAccess.values)
                    ChoiceChip(
                      key: ValueKey('access-${mode.name}'),
                      showCheckmark: false,
                      selected: _access == mode,
                      onSelected: canEdit
                          ? (_) {
                              setState(() => _access = mode);
                              _noticeChanges.value++;
                            }
                          : null,
                      label: Text(switch (mode) {
                        ApplicationAccess.all => strings.accessAll,
                        ApplicationAccess.only => strings.accessOnly,
                        ApplicationAccess.except => strings.accessExcept,
                      }),
                    ),
                  FilterChip(
                    key: const ValueKey('access-system'),
                    showCheckmark: false,
                    selected: _system,
                    onSelected: (value) => setState(() {
                      _resetCenter();
                      _system = value;
                    }),
                    label: Text(strings.showSystemApps),
                  ),
                ],
              ),
              SizedBox(
                height: math.max(24, lineHeight(text.bodySmall)),
                child: _access == ApplicationAccess.all
                    ? null
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          strings.selectedCount(
                            _expandSelection(_selected).length,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
              ),
              Tooltip(
                key: const ValueKey('applications-policy-status'),
                message: policyStatus,
                child: _ApplicationStatusText(
                  text: _storageEpoch != app.storageEpoch
                      ? strings.applicationPolicyUnknownShort
                      : app.preferencesError != null ||
                            !_preferencesLoaded ||
                            !app.state.confirmed ||
                            app.platformError != null
                      ? strings.applicationPolicyUnknownShort
                      : !app.state.running
                      ? strings.applicationPolicyNextConnectionShort
                      : actual == null ||
                            actual.generation != app.state.generation
                      ? strings.applicationPolicyUnknownShort
                      : _needsApply
                      ? strings.applicationPolicyPendingShort
                      : strings.applicationPolicyAppliedShort,
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(strings.applicationAccess),
            actions: [
              TextButton(
                key: const ValueKey('applications-save'),
                onPressed: _canSave ? _save : null,
                child: Text(strings.save),
              ),
            ],
          ),
          body: PopScope<void>(
            canPop: !_dirty,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _leave();
            },
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: _layoutBody(
                  controls: controls,
                  wide: wide,
                  controlWidth: controlWidth,
                  canEdit: canEdit,
                  strings: strings,
                  colors: colors,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  // One controls subtree moves between the scrolling header and the side slot.
  // During the transition it is overlaid once, at its interpolated real bounds;
  // the list reserves only the remaining header extent. The GlobalKey retains
  // TextField/EditableText state across the two steady-state scroll parents.
  Widget _layoutBody({
    required Widget controls,
    required bool wide,
    required double controlWidth,
    required bool canEdit,
    required AppLocalizations strings,
    required ColorScheme colors,
  }) => TweenAnimationBuilder<double>(
    key: const ValueKey('applications-layout-motion'),
    tween: Tween(begin: wide ? 1.0 : 0.0, end: wide ? 1.0 : 0.0),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    curve: Curves.easeInOutCubic,
    builder: (context, animated, _) {
      final fraction = MediaQuery.disableAnimationsOf(context)
          ? (wide ? 1.0 : 0.0)
          : animated;
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 840 + 600 * fraction),
        child: LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: _scroll,
            builder: (context, _) {
              final header = _header.currentContext?.findRenderObject();
              final headerHeight = header is RenderBox && header.hasSize
                  ? header.size.height
                  : 0.0;
              final side = fraction > 0;
              _headerExtent = headerHeight * (1 - fraction);
              final offset = _scroll.hasClients ? _scroll.offset : 0.0;
              final headerTop =
                  (_anchored
                      ? -_centerIndex * _rowHeight - headerHeight
                      : 0.0) -
                  offset;
              return Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: controlWidth * fraction),
                      Expanded(
                        child: CustomScrollView(
                          controller: _scroll,
                          center: _anchored ? _center : _top,
                          semanticChildCount: _visible.length,
                          key: const PageStorageKey('applications-page'),
                          slivers: [
                            SliverToBoxAdapter(
                              key: _top,
                              child: side
                                  ? SizedBox(height: _headerExtent)
                                  : controls,
                            ),
                            if (_anchored && _centerIndex > 0)
                              _body(strings, colors, canEdit, before: true),
                            SliverPadding(
                              key: _center,
                              padding: const EdgeInsets.only(bottom: 24),
                              sliver: _body(strings, colors, canEdit),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (side)
                    Positioned(
                      left: 0,
                      top: headerTop * (1 - fraction),
                      width:
                          constraints.maxWidth +
                          (controlWidth - constraints.maxWidth) * fraction,
                      height:
                          headerHeight +
                          (constraints.maxHeight - headerHeight) * fraction,
                      child: SingleChildScrollView(
                        physics: fraction < 1
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        child: controls,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );

  Future<bool> _leave() async {
    if (_leaving || !_eligible) return false;
    if (!_dirty) {
      if (!Navigator.of(context).canPop()) return false;
      Navigator.pop(context);
      return true;
    }
    _leaving = true;
    ModalRoute<dynamic>? confirmation;
    bool current() => _current(ownedPopup: confirmation);
    try {
      final accepted = await confirmAction(
        context,
        title: (strings) => strings.discardChanges,
        message: (strings) => strings.discardApplicationChanges,
        confirmLabel: (strings) => strings.discard,
        cancelLabel: (strings) => strings.continueEditing,
        onRoute: (route) => confirmation = route,
        isCurrent: current,
      );
      confirmation = null;
      if (!accepted || !mounted || !_eligible) return false;
      Navigator.pop(context);
      return true;
    } finally {
      _leaving = false;
    }
  }

  Widget _body(
    AppLocalizations strings,
    ColorScheme colors,
    bool canEdit, {
    bool before = false,
  }) {
    if (_applications == null) {
      return SliverToBoxAdapter(
        child: SizedBox(
          height: 96,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : null,
        ),
      );
    }
    final rows = _visible;
    if (rows.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Center(child: Text(strings.noSearchResults)),
        ),
      );
    }
    final selecting = _access != ApplicationAccess.all;
    final count = before ? _centerIndex : rows.length - _centerIndex;
    return SliverFixedExtentList(
      itemExtent: _rowHeight,
      delegate: SliverChildBuilderDelegate(
        (context, local) {
          final index = before
              ? _centerIndex - local - 1
              : _centerIndex + local;
          final row = rows[index];
          final package = row['package'] as String;
          final group = _group(package).toList()..sort();
          final selected = group.any(_selected.contains);
          final installed = row['installed'] != false;
          final subtitle = installed
              ? package
              : strings.applicationNotInstalled;
          final iconColor = selecting && selected
              ? colors.primary
              : colors.onSurfaceVariant;
          return CheckboxListTile(
            key: ValueKey('application-$package'),
            value: selecting && selected,
            onChanged: selecting && canEdit ? (_) => _toggle(package) : null,
            secondary: Tooltip(
              excludeFromSemantics: true,
              message: group.length > 1
                  ? strings.applicationSharedUidNotice(group.join(', '))
                  : '',
              child: SizedBox(
                width: 32,
                height: 32,
                child: installed
                    ? ApplicationIcon(
                        icon: _iconFor(package),
                        fallback: row['system'] == true
                            ? Icons.memory
                            : Icons.apps,
                        color: iconColor,
                      )
                    : Icon(Icons.apps_outlined, color: iconColor),
              ),
            ),
            title: Text(
              row['label'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              group.length > 1
                  ? '${strings.applicationSharedUidShort} · $subtitle'
                  : subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: group.length > 1
                  ? '$subtitle · ${strings.applicationSharedUidNotice(group.join(', '))}'
                  : null,
            ),
            controlAffinity: ListTileControlAffinity.trailing,
          );
        },
        childCount: count,
        semanticIndexCallback: (_, local) =>
            before ? _centerIndex - local - 1 : _centerIndex + local,
        findChildIndexCallback: (key) {
          final index = rows.indexWhere(
            (row) => key == ValueKey('application-${row['package']}'),
          );
          final local = before
              ? _centerIndex - index - 1
              : index - _centerIndex;
          return index < 0 || local < 0 || local >= count ? null : local;
        },
      ),
    );
  }
}

/// Updates short status on one line; the Tooltip provides the full explanation of when
/// changes take effect.
class _ApplicationStatusText extends StatelessWidget {
  const _ApplicationStatusText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Text(text, maxLines: 1, softWrap: false, style: style),
  );
}

/// A fixed icon slot backed by its page's bounded cache. FutureBuilder ignores
/// obsolete completions when a row receives a refreshed icon future.
class ApplicationIcon extends StatelessWidget {
  const ApplicationIcon({
    super.key,
    required this.icon,
    required this.fallback,
    required this.color,
  });

  final Future<Uint8List?> icon;
  final IconData fallback;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: FutureBuilder<Uint8List?>(
      future: icon,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return bytes == null
            ? Icon(fallback, color: color)
            : Image.memory(
                bytes,
                width: 32,
                height: 32,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Icon(fallback, color: color),
              );
      },
    ),
  );
}
