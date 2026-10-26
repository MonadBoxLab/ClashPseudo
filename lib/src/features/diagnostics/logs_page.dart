import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../l10n/app_localizations.dart';
import '../../app/widgets/technical_reading_pane.dart';
import 'logs_controller.dart';

class CoreLogsPage extends StatefulWidget {
  const CoreLogsPage({super.key, required this.app});
  final AppController app;
  @override
  State<CoreLogsPage> createState() => _CoreLogsPageState();
}

class _CoreLogsPageState extends State<CoreLogsPage> {
  late final _controller = CoreLogsController(widget.app);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _center = GlobalKey();
  final _rowKeys = <int, GlobalKey>{};
  List<Map<String, dynamic>> _rows = const [];
  Object? _viewIdentity;
  int _centerIndex = 0;
  bool _followScheduled = false;

  // Keep an explicit follow request at the actual end while lazy sliver dimensions
  // settle; follow=false uses its own reading anchor.
  void _scheduleFollow() {
    if (_followScheduled || !_controller.follow || !_scroll.hasClients) return;
    if ((_scroll.offset - _scroll.position.maxScrollExtent).abs() < .5) return;
    _followScheduled = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (mounted && _scroll.hasClients && _controller.follow) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // Rebase the viewport on a measured surviving row before rebuild so the first
  // rendered frame retains its reading anchor.
  void _updateRows() {
    final next = _controller.visible;
    final identity = (
      _controller.level,
      _controller.search,
      widget.app.state.logSource?.logWindow,
    );
    final changed =
        _rows.length != next.length ||
        (_rows.isNotEmpty &&
            (!identical(_rows.first, next.first) ||
                !identical(_rows.last, next.last)));
    if (_scroll.hasClients &&
        changed &&
        !_controller.follow &&
        identity == _viewIdentity) {
      final viewport = _viewport.currentContext?.findRenderObject();
      var anchored = false;
      if (viewport is RenderBox && viewport.hasSize) {
        final top = viewport.localToGlobal(Offset.zero).dy;
        final bottom = top + viewport.size.height;
        final indices = {
          for (var i = 0; i < next.length; i++) next[i]['seq']: i,
        };
        for (final previous in _rows) {
          final index = indices[previous['seq']];
          final box = _rowKeys[previous['seq']]?.currentContext
              ?.findRenderObject();
          if (index == null ||
              box is! RenderBox ||
              !box.hasSize ||
              !box.attached) {
            continue;
          }
          final y = box.localToGlobal(Offset.zero).dy;
          if (y + box.size.height <= top || y >= bottom) continue;
          _centerIndex = index;
          _scroll.position.correctBy(top - y - _scroll.offset);
          anchored = true;
          break;
        }
      }
      if (!anchored) _resetCenter();
    } else if (identity != _viewIdentity ||
        next.isEmpty ||
        (_controller.follow && _centerIndex != 0)) {
      _resetCenter();
    }
    _viewIdentity = identity;
    _rows = next;
    final retained = {for (final row in next) row['seq']};
    _rowKeys.removeWhere((seq, _) => !retained.contains(seq));
  }

  void _resetCenter() {
    if (_scroll.hasClients) {
      _scroll.position.correctBy(-_scroll.offset);
    }
    _centerIndex = 0;
  }

  @override
  void initState() {
    super.initState();
    _controller.setVisible(true);
    _controller.addListener(_updateRows);
    _updateRows();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // Leaving the end pauses auto-follow; returning to the end resumes it.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atEnd = _scroll.offset >= _scroll.position.maxScrollExtent - 8;
    if (atEnd != _controller.follow) _controller.setFollow(atEnd);
  }

  String _levelLabel(AppLocalizations strings, String value) => switch (value) {
    'debug' => strings.logLevelDebug,
    'warning' => strings.logLevelWarning,
    'error' => strings.logLevelError,
    _ => strings.logLevelInfo,
  };

  String _time(BuildContext context, String value) {
    final time = DateTime.tryParse(value)?.toLocal();
    if (time == null) return value;
    final material = MaterialLocalizations.of(context);
    return material.formatTimeOfDay(TimeOfDay.fromDateTime(time));
  }

  Color? _levelColor(BuildContext context, String level) => switch (level) {
    'error' => Theme.of(context).colorScheme.error,
    'warning' => ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    ).warning,
    _ => null,
  };

  Widget _logRows(
    BuildContext context,
    AppLocalizations strings, {
    bool before = false,
  }) {
    final count = before ? _centerIndex : _rows.length - _centerIndex;
    return SliverList(
      key: before ? null : _center,
      delegate: SliverChildBuilderDelegate(
        (context, local) {
          final index = before
              ? _centerIndex - local - 1
              : _centerIndex + local;
          final row = _rows[index];
          final seq = row['seq'] as int;
          final level = row['level'] as String;
          return Padding(
            key: _rowKeys.putIfAbsent(
              seq,
              () => GlobalKey(debugLabel: 'log-$seq'),
            ),
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_time(context, row['time'] as String)} · ${level.toUpperCase()}',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: _levelColor(context, level)),
                ),
                SelectableText(
                  row['text'] as String,
                  style: TechnicalReadingPane.textStyleOf(context),
                ),
                if (row['truncated'] == true)
                  Text(
                    strings.logTruncated,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          );
        },
        childCount: count,
        semanticIndexCallback: (_, local) =>
            before ? _centerIndex - local - 1 : _centerIndex + local,
        findChildIndexCallback: (key) {
          final index = _rows.indexWhere((row) => _rowKeys[row['seq']] == key);
          final local = before
              ? _centerIndex - index - 1
              : index - _centerIndex;
          return index < 0 || local < 0 || local >= count ? null : local;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    onSearch: _searchFocus.requestFocus,
    onEscape: _searchFocus.unfocus,
    child: _content(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final rows = _rows;
      if (_scroll.hasClients) _scheduleFollow();
      final status = _controller.status == CoreLogsStatus.loading
          ? strings.coreReadLoading
          : _controller.status == CoreLogsStatus.failed
          ? strings.coreReadFailed
          : _controller.status == CoreLogsStatus.stale
          ? strings.coreSnapshotStale
          : _controller.status == CoreLogsStatus.empty
          ? strings.runtimeConfigEmpty
          : _controller.status == CoreLogsStatus.recent
          ? strings.coreLogsRecentWindow
          : _controller.status == CoreLogsStatus.preview
          ? strings.runtimeConfigPreview
          : strings.runtimeConfigLive;
      return Scaffold(
        appBar: AppBar(
          title: Text(strings.coreLogs),
          actions: [
            IconButton(
              tooltip: strings.refresh,
              onPressed: _controller.canRefresh ? _controller.refresh : null,
              color: HomePalette.of(context).syncAction,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: TechnicalReadingPane(
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight / 2,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _search,
                                  focusNode: _searchFocus,
                                  onChanged: _controller.filter,
                                  decoration: InputDecoration(
                                    labelText: strings.logSearch,
                                    prefixIconColor: HomePalette.of(context)
                                        .moreAction,
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: IconButton(
                                      tooltip: strings.clearSearch,
                                      onPressed: () {
                                        _search.clear();
                                        _controller.filter('');
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ChoiceMenuButton<String>(
                                iconColor: HomePalette.of(context).moreAction,
                                tooltip: strings.logLevel,
                                value: _controller.level,
                                onSelected: _controller.setLevel,
                                options: {
                                  for (final level in CoreLogsController.levels)
                                    level: _levelLabel(strings, level),
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Icon(
                                    Icons.tune,
                                    color: HomePalette.of(context).moreAction,
                                    semanticLabel: strings.logLevel,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Text(
                                    '$status · ${strings.logTotal(_controller.entries.length)}'
                                    '${_controller.dropped > 0 ? ' · ${strings.logDropped(_controller.dropped)}' : ''}',
                                    softWrap: false,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: strings.logClearLocal,
                                onPressed: _controller.entries.isEmpty
                                    ? null
                                    : _controller.clear,
                                color: Theme.of(context).colorScheme.error,
                                icon: const Icon(Icons.delete_sweep_outlined),
                              ),
                              IconButton(
                                tooltip: strings.logBackToLatest,
                                onPressed: _controller.follow
                                    ? null
                                    : () {
                                        _controller.setFollow(true);
                                        if (_scroll.hasClients) {
                                          _scroll.jumpTo(
                                            _scroll.position.maxScrollExtent,
                                          );
                                        }
                                      },
                                color: HomePalette.of(context).moreAction,
                                icon: const Icon(Icons.vertical_align_bottom),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _controller.entries.isEmpty
                                  ? (_controller.status ==
                                                CoreLogsStatus.loading ||
                                            _controller.status ==
                                                CoreLogsStatus.failed ||
                                            _controller.status ==
                                                CoreLogsStatus.stale ||
                                            _controller.status ==
                                                CoreLogsStatus.empty
                                        ? ''
                                        : strings.noLogs)
                                  : strings.noSearchResults,
                            ),
                          ),
                        )
                      : Scrollbar(
                          key: _viewport,
                          controller: _scroll,
                          child:
                              NotificationListener<ScrollMetricsNotification>(
                                onNotification: (_) {
                                  _scheduleFollow();
                                  return false;
                                },
                                child: CustomScrollView(
                                  controller: _scroll,
                                  center: _center,
                                  slivers: [
                                    _logRows(context, strings, before: true),
                                    _logRows(context, strings),
                                  ],
                                ),
                              ),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
