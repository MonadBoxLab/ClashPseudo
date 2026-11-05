import '../../components/feedback/operation_feedback.dart';
import '../../components/feedback/operation_notice.dart';
import '../../../model/app_message.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../components/input/task_shortcuts.dart';
import '../../components/input/toolbar_search_field.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../theme/app_theme.dart';
import '../../components/input/choice_menu_button.dart';
import '../../../l10n/app_localizations.dart';
import '../../components/reading/technical_reading_pane.dart';
import 'logs_controller.dart';

class CoreLogsPage extends StatefulWidget {
  const CoreLogsPage({super.key, required this.app});
  final AppController app;
  @override
  State<CoreLogsPage> createState() => _CoreLogsPageState();
}

class _CoreLogsPageState extends State<CoreLogsPage> {
  late final _controller = CoreLogsController(widget.app);
  Object? _feedbackSource;
  Object _feedbackPeriod = Object();
  AppMessage? _seenError;
  bool _fault = false;
  bool _quiet = false;
  Object? _pendingNotice;
  BuildContext? _noticeContext;

  Object get _sourceIdentity => (
    widget.app.storageEpoch,
    widget.app.state.logSource?.identity,
    widget.app.state.logSource?.logWindow,
  );

  void _changed() {
    _updateRows();
    _syncFeedback();
  }

  void _syncFeedback() {
    if (!mounted) return;
    final source = _sourceIdentity;
    final error = _controller.readError;
    if (_feedbackSource != source) {
      _feedbackSource = source;
      _feedbackPeriod = Object();
      _fault = _quiet = false;
      _pendingNotice = null;
      _seenError = null;
    }
    if (error == null) {
      if (!_controller.loading &&
          (_fault || _quiet || _pendingNotice != null)) {
        _fault = _quiet = false;
        _feedbackPeriod = Object();
        _pendingNotice = null;
      }
      _seenError = null;
      return;
    }
    if (_controller.readErrorSource != source) {
      _seenError = error;
      return;
    }
    if (!_fault && !identical(error, _seenError)) {
      _fault = true;
      _feedbackPeriod = Object();
    }
    _seenError = error;
    if (!_pageLive) {
      _pendingNotice = null;
      return;
    }
    if (!_fault || _quiet || _pendingNotice != null) return;
    final ticket = _pendingNotice = Object();
    final period = _feedbackPeriod;
    bool current() =>
        mounted &&
        _pageLive &&
        _fault &&
        !_quiet &&
        _pendingNotice == ticket &&
        _feedbackPeriod == period &&
        source == _sourceIdentity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final noticeContext = _noticeContext;
      if (noticeContext == null || !noticeContext.mounted || !current()) return;
      showAppNotice(
        noticeContext,
        error,
        identity: ticket,
        eligibilityChanges: Listenable.merge([_controller, widget.app]),
        isCurrent: current,
        onDetails: () async {
          if (!current()) return;
          await _showError(error, source: source, period: period);
        },
        onRetry: () async {
          if (!current()) return;
          _quiet = true;
          await _controller.refresh();
        },
        onClosed: (reason) {
          if (!mounted || _pendingNotice != ticket) return;
          _pendingNotice = null;
          if (reason == SnackBarClosedReason.action ||
              reason == SnackBarClosedReason.dismiss ||
              reason == SnackBarClosedReason.swipe) {
            _quiet = true;
          }
        },
      ).then((presented) {
        if (!presented && mounted && _pendingNotice == ticket) {
          _pendingNotice = null;
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showError(
    AppMessage message, {
    required Object source,
    required Object period,
  }) async {
    bool current({ModalRoute<dynamic>? popup}) =>
        mounted &&
        _fault &&
        source == _sourceIdentity &&
        period == _feedbackPeriod &&
        (popup == null ? _pageLive : _pageWithPopup(popup));
    if (!current()) return;
    _quiet = true;
    _pendingNotice = null;
    await showAppMessage(
      context,
      message,
      title: (strings) => strings.errorDetails,
      eligibilityChanges: Listenable.merge([_controller, widget.app]),
      isCurrent: current,
      isCurrentWithPopup: (popup) => current(popup: popup),
      onRetry: () async {
        if (!current()) return;
        await _controller.refresh();
        if (current()) {
          _quiet = false;
          _syncFeedback();
        }
      },
    );
  }

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
    _feedbackSource = _sourceIdentity;
    _controller.setVisible(true);
    _controller.addListener(_changed);
    widget.app.addListener(_syncFeedback);
    _updateRows();
    _scroll.addListener(_onScroll);
  }

  ModalRoute<dynamic>? _route;

  bool get _pageLive =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context) &&
      (_route?.isCurrent ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      _route?.animation?.removeListener(_syncVisibility);
      _route = route;
      route?.animation?.addListener(_syncVisibility);
    }
    _syncVisibility();
  }

  bool _pageWithPopup(ModalRoute<dynamic> popup) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup);

  bool _visibilityScheduled = false;

  void _syncVisibility() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_visibilityScheduled) return;
      _visibilityScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _visibilityScheduled = false;
        if (mounted) _syncVisibility();
      });
      return;
    }
    _controller.setVisible(_pageLive);
    if (!_pageLive) _searchFocus.unfocus();
    _syncFeedback();
  }

  @override
  void dispose() {
    _route?.animation?.removeListener(_syncVisibility);
    widget.app.removeListener(_syncFeedback);
    _controller.removeListener(_changed);
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

  Color _levelColor(BuildContext context, String level) {
    final palette = HomePalette.of(context);
    return switch (level) {
      'debug' => palette.muted,
      'info' => palette.cobalt,
      'warning' => palette.warning,
      'error' => Theme.of(context).colorScheme.error,
      _ => palette.ink,
    };
  }

  Widget _logRows(BuildContext context, {bool before = false}) {
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
          final level = row['level']?.toString() ?? '';
          final color = _levelColor(context, level);
          return Padding(
            key: _rowKeys.putIfAbsent(
              seq,
              () => GlobalKey(debugLabel: 'log-$seq'),
            ),
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: '${_time(context, row['time']?.toString() ?? '')} · ',
                    children: [
                      TextSpan(
                        text: level.toUpperCase(),
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SelectableText(
                  row['text']?.toString() ?? '',
                  style: TechnicalReadingPane.textStyleOf(context)
                      .copyWith(color: color),
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
    onSearch: () {
      if (_pageLive) _searchFocus.requestFocus();
    },
    onEscape: () {
      if (_pageLive) _searchFocus.unfocus();
    },
    child: OperationNoticeHost(
      child: Builder(
        builder: (noticeContext) {
          _noticeContext = noticeContext;
          return _content(noticeContext);
        },
      ),
    ),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final rows = _rows;
      if (_scroll.hasClients) _scheduleFollow();
      return Scaffold(
        appBar: AppBar(title: Text(strings.coreLogs)),
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
                                child: ToolbarSearchField(
                                  controller: _search,
                                  focusNode: _searchFocus,
                                  hintText: strings.logSearch,
                                  enabled: _pageLive,
                                  canClear: () => _pageLive,
                                  onChanged: (value) {
                                    if (_pageLive) _controller.filter(value);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ChoiceMenuButton<String>(
                                iconColor: HomePalette.of(context).moreAction,
                                tooltip: strings.logLevel,
                                value: _controller.level,
                                onSelected: (value) {
                                  if (_pageLive) _controller.setLevel(value);
                                },
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
                                    '${strings.logTotal(_controller.entries.length)}'
                                    '${_controller.dropped > 0 ? ' · ${strings.logDropped(_controller.dropped)}' : ''}'
                                    '${_controller.localDropped > 0 ? ' · ${strings.logLocalDropped(_controller.localDropped)}' : ''}',
                                    softWrap: false,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: strings.logClear,
                                onPressed: _controller.canClear
                                    ? () {
                                        if (_pageLive) _controller.clear();
                                      }
                                    : null,
                                color: Theme.of(context).colorScheme.error,
                                icon: const Icon(Icons.delete_sweep_outlined),
                              ),
                              IconButton(
                                tooltip: strings.logBackToLatest,
                                onPressed: _controller.follow
                                    ? null
                                    : () {
                                        if (!_pageLive) return;
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
                                    _logRows(context, before: true),
                                    _logRows(context),
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
