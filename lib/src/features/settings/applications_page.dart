import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_theme.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../l10n/app_localizations.dart';
import '../configs/widgets/confirm_action.dart';
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
  bool _wide = false;
  (double, double, String, TextTheme, bool)? _layout;
  // Raw icon bytes have the same per-icon limit as the Android bridge. This
  // page-local LRU holds at most 32 icons (including in-flight requests).
  final _icons = <String, Future<Uint8List?>>{};
  List<Map<String, dynamic>>? _applications;
  Map<String, Set<String>> _groups = {};
  bool _failed = false;
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
  late bool _foreground;
  double _rowHeight = 72;

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? app.storageEpoch;
    _access = app.preferences.access;
    _selected = app.preferences.packages.toSet();
    _knownPackages.addAll(_selected);
    _preferencesLoaded = app.preferencesLoaded && app.preferencesError == null;
    _foreground = app.foreground;
    app.addListener(_appChanged);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    final previous = _route;
    if (previous != null) app.unregisterOverviewLeave(previous, _overviewLeave);
    _route = route;
    if (route != null) app.registerOverviewLeave(route, _overviewLeave);
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
    if (_foreground == app.foreground) return;
    _foreground = app.foreground;
    if (_foreground) {
      unawaited(_load());
    } else {
      _request++;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _request++;
    final route = _route;
    if (route != null) app.unregisterOverviewLeave(route, _overviewLeave);
    app.removeListener(_appChanged);
    _icons.clear();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!app.foreground) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final value = await app.platform.applications().timeout(
        const Duration(seconds: 5),
      );
      if (!mounted || request != _request || !app.foreground) return;
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
      _keepReadingAnchor(value);
      setState(() {
        _applications = value;
        _groups = groups;
        _icons.clear();
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request || !app.foreground) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
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
    final origin = _anchored
        ? -_centerIndex * _rowHeight
        : (_wide ? 0 : header.size.height);
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
      _scroll.position.correctBy(
        _centerIndex * _rowHeight + (_wide ? 0 : header.size.height),
      );
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
    final group = _group(package);
    setState(() {
      if (group.any(_selected.contains)) {
        _selected.removeAll(group);
      } else {
        _selected.addAll(group);
        _knownPackages.addAll(group);
      }
    });
  }

  bool get _canEdit =>
      _storageEpoch == app.storageEpoch &&
      app.canEdit &&
      app.canChangePreferences &&
      !_saving &&
      !_loading &&
      !_failed &&
      _applications != null;

  bool get _canSave => _canEdit && (_dirty || _needsApply);

  Future<void> _save() async {
    if (!_canSave || ModalRoute.of(context)?.isCurrent != true) return;
    if (_access == ApplicationAccess.only && _selected.isEmpty) {
      await showLocalizedOperationMessage(
        context,
        (strings) => strings.applicationAllowEmpty,
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
        );
        if (!accepted || !mounted) return;
      }
      if (_storageEpoch != app.storageEpoch ||
          !app.canEdit ||
          !app.canChangePreferences ||
          ModalRoute.of(context)?.isCurrent != true) {
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
  Widget build(BuildContext context) => TaskShortcuts(
    onSearch: _searchFocus.requestFocus,
    onSave: _save,
    onEscape: _searchFocus.unfocus,
    child: _content(context),
  );

  Widget _content(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final strings = AppLocalizations.of(context);
        final colors = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final actual = app.state.runningApplicationAccess;
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
        _wide = wide;
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
              SizedBox(
                key: const ValueKey('applications-policy-status'),
                height: lineHeight(text.bodySmall) * 2 + 8,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: policyStatus,
                    child: Text(
                      policyStatus,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: math.max(56, lineHeight(text.bodyLarge) + 24),
                child: TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: strings.searchApplications,
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: strings.clearSearch,
                      onPressed: _query?.isNotEmpty == true
                          ? () {
                              _search.clear();
                              setState(() {
                                _resetCenter();
                                _query = '';
                              });
                            }
                          : null,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  onChanged: (value) => setState(() {
                    _resetCenter();
                    _query = value;
                  }),
                ),
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
                          ? (_) => setState(() => _access = mode)
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
              SizedBox(
                height: math.max(48, lineHeight(text.bodySmall) + 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _failed
                          ? Tooltip(
                              message: strings.applicationListFailed,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  alignment: Alignment.centerLeft,
                                  padding: EdgeInsets.zero,
                                  foregroundColor: colors.error,
                                ),
                                onPressed: () => showLocalizedOperationMessage(
                                  context,
                                  (strings) => strings.applicationListFailed,
                                ),
                                child: Text(
                                  strings.applicationListFailed,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                          : _loading
                          ? Text(
                              strings.runtimeConfigLoading,
                              style: text.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : const SizedBox.shrink(),
                    ),
                    IconButton(
                      tooltip: _failed ? strings.retry : strings.refresh,
                      onPressed: _loading || !app.foreground ? null : _load,
                      color: HomePalette.of(context).syncAction,
                      icon: Icon(
                        _failed ? Icons.refresh_rounded : Icons.refresh,
                      ),
                    ),
                  ],
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
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1440 : 840),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: wide ? controlWidth : 0,
                        child: wide
                            ? SingleChildScrollView(child: controls)
                            : null,
                      ),
                      Expanded(
                        child: CustomScrollView(
                          controller: _scroll,
                          center: _anchored ? _center : _top,
                          semanticChildCount: _visible.length,
                          key: const PageStorageKey('applications-page'),
                          slivers: [
                            SliverToBoxAdapter(
                              key: _top,
                              child: wide ? const SizedBox.shrink() : controls,
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
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Future<bool> _leave() async {
    final route = _route;
    if (_leaving || !mounted || route?.isCurrent != true) return false;
    if (!_dirty) {
      if (!Navigator.of(context).canPop()) return false;
      Navigator.pop(context);
      return true;
    }
    _leaving = true;
    try {
      final accepted = await confirmAction(
        context,
        title: (strings) => strings.discardChanges,
        message: (strings) => strings.discardApplicationChanges,
        confirmLabel: (strings) => strings.discard,
        cancelLabel: (strings) => strings.continueEditing,
      );
      if (!accepted || !mounted || route?.isCurrent != true) return false;
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
          final iconColor = selecting && selected
              ? colors.primary
              : colors.onSurfaceVariant;
          return CheckboxListTile(
            key: ValueKey('application-$package'),
            value: selecting && selected,
            onChanged: selecting && canEdit ? (_) => _toggle(package) : null,
            secondary: Tooltip(
              message: group.length > 1
                  ? strings.applicationSharedUidNotice(group.join(', '))
                  : '',
              child: SizedBox(
                width: 32,
                height: 32,
                child: Stack(
                  children: [
                    if (installed)
                      ApplicationIcon(
                        icon: _iconFor(package),
                        fallback: row['system'] == true
                            ? Icons.memory
                            : Icons.apps,
                        color: iconColor,
                      )
                    else
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: Icon(Icons.apps_outlined, color: iconColor),
                      ),
                    if (group.length > 1)
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Icon(
                          Icons.link,
                          size: 16,
                          color: colors.primary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            title: Text(
              row['label'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              installed ? package : strings.applicationNotInstalled,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
