part of 'strategy_popup.dart';

class StrategyPopup extends StatefulWidget {
  const StrategyPopup({
    super.key,
    required this.controller,
    required this.name,
    required this.generation,
    this.storageEpoch,
    this.progress = 1,
    this.sourceWidth = 180,
    this.anchored = false,
    this.active,
    this.isCurrent,
  });
  final StrategyController controller;
  final String name;
  final int generation;
  final int? storageEpoch;
  final double progress;
  final double sourceWidth;
  final bool anchored;
  final ValueNotifier<bool>? active;
  final bool Function(ModalRoute<dynamic>? feedback)? isCurrent;

  @override
  State<StrategyPopup> createState() => _StrategyPopupState();
}

class _StrategyPopupState extends State<StrategyPopup> {
  StrategyController get controller => widget.controller;
  String get name => widget.name;
  int get generation => widget.generation;
  double get progress => widget.progress;
  double get sourceWidth => widget.sourceWidth;
  ModalRoute<dynamic>? _feedback;
  bool get _interactive =>
      mounted &&
      (widget.active?.value ?? true) &&
      (widget.isCurrent?.call(null) ?? true);
  bool get _ownsLifecycle =>
      mounted &&
      (widget.active?.value ?? true) &&
      (widget.isCurrent?.call(_feedback) ?? true);
  final _focus = FocusScopeNode();
  StrategySnapshot? _lastData;
  StrategyGroup? _lastGroup;
  bool _expired = false;
  late final int _storageEpoch;
  DelayTestController? _delay;
  // Backgrounding invalidates the batch; retain source identity and allow a fresh
  // explicit test after revalidation.
  bool _delayResultsExpired = false;
  int _delayRun = 0;
  List<String>? _delayMembers;
  Object? _delayNotice;
  List<(String, DelayMemberStatus, DateTime?, String?, String?)>
  _noticedDelayFailures = const [];
  Object? _strategyNotice;
  Object? _unrestoredNotice;

  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _center = GlobalKey();
  final _rowKeys = <Object, GlobalKey>{};
  final _nameKeys = <Object, GlobalKey>{};
  final _indices = <Key, int>{};
  List<Object> _ids = [];
  int _centerIndex = 0;

  void _anchorRows(List<Object> ids) {
    if (ids.length == _ids.length &&
        ids.indexed.every((e) => e.$2 == _ids[e.$1])) {
      return;
    }
    Object? anchor;
    double offset = 0;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final top = viewport?.localToGlobal(Offset.zero).dy;
    final remaining = ids.toSet();
    if (widget.anchored && _scroll.hasClients && top != null) {
      // Preserve the first fully readable name, including a row whose outer
      // padding is clipped. Anchor placement still uses that row's top edge.
      for (final id in _ids) {
        final box =
            _rowKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
        final reading =
            _nameKeys[id]?.currentContext?.findRenderObject() as RenderBox? ??
            box;
        if (remaining.contains(id) &&
            box != null &&
            box.hasSize &&
            reading != null &&
            reading.hasSize &&
            reading.localToGlobal(Offset.zero).dy >= top) {
          anchor = id;
          offset = top - box.localToGlobal(Offset.zero).dy;
          break;
        }
      }
    }
    _ids = ids;
    _centerIndex = anchor == null ? 0 : ids.indexOf(anchor);
    _rowKeys.removeWhere((id, _) => !remaining.contains(id));
    _nameKeys.removeWhere((id, _) => !remaining.contains(id));
    _indices.clear();
    for (var i = 0; i < ids.length; i++) {
      final key = _rowKeys[ids[i]];
      if (key != null) _indices[key] = i;
    }
    if (_scroll.hasClients) _scroll.position.correctBy(offset - _scroll.offset);
  }

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? controller.app.storageEpoch;
    controller.addListener(_contextChanged);
    widget.active?.addListener(_contextChanged);
    _contextChanged();
  }

  @override
  void didUpdateWidget(StrategyPopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_contextChanged);
      controller.addListener(_contextChanged);
    }
    if (oldWidget.active != widget.active) {
      oldWidget.active?.removeListener(_contextChanged);
      widget.active?.addListener(_contextChanged);
    }
    _contextChanged();
  }

  // Invalidate lifecycle ownership synchronously, before the next Flutter frame.
  void _contextChanged() {
    final incoming = controller.data;
    final core = controller.app.state.core;
    final candidate = controller.groups
        .where((group) => group.name == name)
        .firstOrNull;
    final previous = _lastData;
    final identityChanged =
        core.generation != generation ||
        core.phase == 'EMPTY' ||
        (core.ready && previous != null && !previous.matches(core));
    if (_storageEpoch != controller.app.storageEpoch ||
        (controller.app.platformError == null && identityChanged) ||
        (incoming?.matches(core) == true && candidate == null)) {
      _expired = true;
    }
    _focus.canRequestFocus = _interactive && controller.active;
    if (!_interactive || !controller.active) _focus.unfocus();
    if (!_ownsLifecycle ||
        _expired ||
        core.phase == 'EMPTY' ||
        !controller.active) {
      _expireDelay();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_contextChanged);
    widget.active?.removeListener(_contextChanged);
    _focus.dispose();
    controller.finishCardDelay(name, expired: _expired || _delayResultsExpired);
    _delay?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  DelayTestController _delayFor(StrategyGroup group) {
    final core = controller.app.state.core;
    final existing = _delay;
    if (existing != null &&
        !_delayResultsExpired &&
        existing.group == group.name &&
        existing.matches(core)) {
      return existing;
    }
    existing?.dispose();
    _delayResultsExpired = false;
    final test = DelayTestController(controller.app.platform, core, group.name);
    test.addListener(_delayChanged);
    return _delay = test;
  }

  void _startDelay(StrategyGroup group, {List<String>? members}) {
    if (!_interactive ||
        _expired ||
        !controller.canChoose ||
        _delay?.busy == true) {
      return;
    }
    controller.finishCardDelay(name, expired: true);
    final test = _delayFor(group);
    _delayRun++;
    _delayMembers = members == null ? null : List.of(members);
    _delayNotice = null;
    unawaited(test.start(members: members));
  }

  void _delayChanged() {
    final test = _delay;
    if (test != null && !_expired && !_delayResultsExpired) {
      controller.rememberDelay(name, test.source, test.results);
    }
    if (mounted) {
      _scheduleDelayNotice();
      setState(() {});
    }
  }

  Future<void> _showErrorDetails(
    String Function(AppLocalizations) summary,
    String? Function(AppLocalizations) technicalDetail,
    bool Function() current,
    Listenable changes, {
    Future<void> Function()? onRetry,
  }) async {
    ModalRoute<dynamic>? owned;
    try {
      await showLocalizedOperationMessage(
        context,
        summary,
        technicalDetail: technicalDetail,
        title: (strings) => strings.errorDetails,
        eligibilityChanges: changes,
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && identical(_feedback, popup) && _ownsLifecycle,
        onRoute: (route) {
          if (route != null) {
            owned = route;
            _feedback = route;
          } else if (identical(_feedback, owned)) {
            _feedback = null;
          }
        },
        onRetry: onRetry,
      );
    } finally {
      if (identical(_feedback, owned)) _feedback = null;
    }
  }

  List<(String, DelayMemberStatus, DateTime?, String?, String?)> _delayFailures(
    DelayTestController test,
  ) => [
    if (test.finished)
      for (final result in test.results.values)
        if (result.status == DelayMemberStatus.failed ||
            result.status == DelayMemberStatus.timeout)
          (
            result.name,
            result.status,
            result.time,
            result.error,
            result.cancellationError,
          ),
  ];

  void _scheduleDelayNotice() {
    final test = _delay;
    if (test == null || _expired || _delayResultsExpired) return;
    final failures = _delayFailures(test);
    final error = test.error;
    if (failures.isEmpty && error == null) {
      _delayNotice = null;
      _noticedDelayFailures = const [];
      return;
    }
    if (!_interactive || !controller.active) return;
    final epoch = controller.app.storageEpoch;
    final run = _delayRun;
    final notice = (test, run, error, test.accepted, test.finished, test.busy);
    if (_delayNotice == notice && listEquals(_noticedDelayFailures, failures)) {
      return;
    }
    _delayNotice = notice;
    _noticedDelayFailures = failures;
    bool current() =>
        mounted &&
        identical(_delay, test) &&
        _delayNotice == notice &&
        _delayRun == run &&
        !_expired &&
        !_delayResultsExpired &&
        epoch == controller.app.storageEpoch &&
        test.source.matchesIdentity(controller.app.state.core) &&
        test.error == error &&
        listEquals(failures, _delayFailures(test));
    String summary(AppLocalizations strings) => failures.isNotEmpty
        ? strings.delayBatchFailed
        : test.accepted
        ? strings.delayReadFailed
        : strings.delayStartFailed;
    String? detail(AppLocalizations strings) {
      final material = MaterialLocalizations.of(context);
      return [
        if (test.target case final target?) strings.delayTarget(target),
        ?error,
        for (final failure in failures)
          [
            [
              failure.$1,
              failure.$2 == DelayMemberStatus.timeout
                  ? strings.delayTimeout
                  : strings.delayFailed,
              if (failure.$3 case final timestamp?)
                '${material.formatCompactDate(timestamp.toLocal())} '
                    '${material.formatTimeOfDay(TimeOfDay.fromDateTime(timestamp.toLocal()))}',
            ].join(' · '),
            ?failure.$4,
            ?failure.$5,
          ].join('\n'),
      ].join('\n\n');
    }

    final changes = Listenable.merge([controller, controller.app, test]);
    Future<void> retry() async {
      if (!current() || !_interactive) return;
      final group = controller.groups
          .where((item) => item.name == name)
          .firstOrNull;
      if (group != null) _startDelay(group, members: _delayMembers);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current() || !_interactive) {
        if (current()) _delayNotice = null;
        return;
      }
      final retryAction = test.busy ? null : retry;
      final presented = await showLocalizedOperationNotice(
        context,
        summary,
        technicalDetail: detail,
        eligibilityChanges: changes,
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && (widget.isCurrent?.call(popup) ?? true),
        onDetails: () => _showErrorDetails(
          summary,
          detail,
          current,
          changes,
          onRetry: retryAction,
        ),
        onRetry: retryAction,
        identity: ('strategy-delay', notice, Object.hashAll(failures)),
      );
      if (!presented && current()) _delayNotice = null;
    });
  }

  void _scheduleStrategyNotice(AppMessage? error) {
    if (error == null) {
      _strategyNotice = null;
      return;
    }
    if (!_interactive || !controller.active) return;
    final app = controller.app;
    final core = app.state.core;
    final epoch = app.storageEpoch;
    final operation = controller.operationErrorMessage == error;
    final notice = (
      controller,
      epoch,
      core.identity,
      error,
      operation ? app.state.resultId : null,
      operation ? app.lastCommand : null,
    );
    if (_strategyNotice == notice) return;
    _strategyNotice = notice;
    bool current() =>
        mounted &&
        _strategyNotice == notice &&
        epoch == app.storageEpoch &&
        core.matchesIdentity(app.state.core) &&
        (operation
                ? controller.operationErrorMessage
                : controller.readErrorMessage) ==
            error;
    final changes = Listenable.merge([controller, app]);
    final retry = operation ? null : controller.retry;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current() || !_interactive) {
        if (current()) _strategyNotice = null;
        return;
      }
      final presented = await showAppNotice(
        context,
        error,
        eligibilityChanges: changes,
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && (widget.isCurrent?.call(popup) ?? true),
        onDetails: () => _showErrorDetails(
          error.summary,
          error.technicalDetail,
          current,
          changes,
          onRetry: retry,
        ),
        onRetry: retry,
        identity: ('strategy-error', notice),
      );
      if (!presented && current()) _strategyNotice = null;
    });
  }

  void _scheduleUnrestoredNotice(StrategySnapshot? data) {
    final reason = data?.unrestored[name];
    if (reason == null) {
      _unrestoredNotice = null;
      return;
    }
    if (!_interactive || !controller.active || _expired) return;
    final app = controller.app;
    final core = app.state.core;
    final epoch = app.storageEpoch;
    if (data?.matches(core) != true) return;
    final notice = (controller, epoch, core.identity, name, reason);
    if (_unrestoredNotice == notice) return;
    _unrestoredNotice = notice;
    bool current() =>
        mounted &&
        _unrestoredNotice == notice &&
        epoch == app.storageEpoch &&
        core.matchesIdentity(app.state.core) &&
        controller.data?.matches(core) == true &&
        controller.data?.unrestored[name] == reason;
    String summary(AppLocalizations strings) => strings.selectionsNotRestored;
    String detail(AppLocalizations strings) =>
        strings.unrestoredLine(name, strategyUnrestoredReason(reason, strings));
    final changes = Listenable.merge([controller, app]);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current() || !_interactive) {
        if (current()) _unrestoredNotice = null;
        return;
      }
      final presented = await showLocalizedOperationNotice(
        context,
        summary,
        technicalDetail: detail,
        eligibilityChanges: changes,
        isCurrent: () => current() && _interactive,
        isCurrentWithPopup: (popup) =>
            current() && (widget.isCurrent?.call(popup) ?? true),
        onDetails: () => _showErrorDetails(summary, detail, current, changes),
        identity: ('strategy-unrestored', notice),
      );
      if (!presented && current()) _unrestoredNotice = null;
    });
  }

  String _delaySummary(AppLocalizations strings) {
    if (_delayResultsExpired || _expired) return strings.delayExpired;
    final test = _delay;
    if (test == null) return '';
    if (test.error != null) return '';
    if (test.terminalState == 'expired') return strings.delayExpired;
    if (test.terminalState == 'cancelled') return strings.delayCancelled;
    return switch (test) {
      _ when test.running => strings.delayProgress(
        test.results.values
            .where(
              (result) => !const [
                DelayMemberStatus.pending,
                DelayMemberStatus.running,
              ].contains(result.status),
            )
            .length,
        test.results.length,
      ),
      _ when test.finished => strings.delayDone,
      _ => '',
    };
  }

  void _expireDelay() {
    if (_delayResultsExpired) return;
    _delayResultsExpired = true;
    controller.finishCardDelay(name, expired: true);
    _delay?.abandon();
  }

  void _choose(String? member) {
    if (!_interactive ||
        _expired ||
        _lastData?.matches(controller.app.state.core) != true ||
        controller.data?.generation != generation) {
      return;
    }
    controller.choose(name, member, storageEpoch: _storageEpoch);
  }

  Widget _heading(
    BuildContext context,
    String type,
    String icon,
    String label,
    double details,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final base = DefaultTextStyle.of(context).style;
      final initialStyle = theme.textTheme.bodyLarge!.copyWith(
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      );
      final style = theme.textTheme.titleLarge!.copyWith(
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      );
      final captionStyle = theme.textTheme.bodySmall!.copyWith(
        height: 1.4,
        color: colors.onSurfaceVariant,
      );
      final locale = Localizations.maybeLocaleOf(context);
      final direction = Directionality.of(context);
      final width = math.max(1.0, constraints.maxWidth - 126);
      final painter = TextPainter(
        text: TextSpan(text: name, style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
      )..layout(maxWidth: width);
      final titleHeight = painter.height;
      painter.dispose();
      final initial = TextPainter(
        text: TextSpan(text: name, style: base.merge(initialStyle)),
        maxLines: 2,
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
      )..layout(maxWidth: math.max(1.0, sourceWidth - 28));
      final initialTop =
          40 +
          math.max(0.0, (2 * initial.preferredLineHeight - initial.height) / 2);
      initial.dispose();
      final caption = TextPainter(
        text: TextSpan(text: label, style: base.merge(captionStyle)),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      final captionHeight = caption.height;
      caption.dispose();
      return SizedBox(
        height: math.max(30, titleHeight + 4 + captionHeight),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: StrategyIcon(type: type, source: icon),
            ),
            Positioned(
              left: 42 * progress,
              top: initialTop * (1 - progress),
              width: (sourceWidth - 28) * (1 - progress) + width * progress,
              child: Text(
                name,
                key: const ValueKey('strategy-popup-title'),
                style: TextStyle.lerp(initialStyle, style, progress),
              ),
            ),
            Positioned(
              left: 42,
              top: titleHeight + 4,
              right: 84,
              child: Opacity(
                opacity: details,
                child: Tooltip(
                  message: [
                    label,
                    if (_delay?.target case final target?)
                      AppLocalizations.of(context).delayTarget(target),
                  ].join('\n'),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      label,
                      key: const ValueKey('strategy-popup-status'),
                      softWrap: false,
                      style: captionStyle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final incoming = controller.data;
      final core = controller.app.state.core;
      final candidate = controller.groups
          .where((group) => group.name == name)
          .firstOrNull;
      if (!_expired &&
          incoming?.generation == generation &&
          candidate != null) {
        _lastData = incoming;
        _lastGroup = candidate;
      }
      final data = _lastData;
      final group = _lastGroup;
      final sameContext = !_expired && data?.matches(core) == true;
      final canChoose = _interactive && sameContext && controller.canChoose;
      final feedbackEpoch = controller.app.storageEpoch;
      final colors = Theme.of(context).colorScheme;
      final strings = AppLocalizations.of(context);
      final saved = sameContext && data != null
          ? controller.app.collection.find(data.configId)?.choices[name]
          : null;
      final savedDiffers =
          saved != null &&
          group != null &&
          (group.automatic
              ? (saved.member ?? '') != group.fixed
              : saved.member != group.now);
      final waiting = controller.changingGroup == name;
      final errorMessage =
          controller.operationErrorMessage ?? controller.readErrorMessage;
      _scheduleStrategyNotice(errorMessage);
      _scheduleUnrestoredNotice(data);
      final showSelection =
          sameContext &&
          data?.matches(controller.app.state.core) == true &&
          controller.readError == null;
      final details = ((progress - .35) / .65).clamp(0.0, 1.0);
      final muted = Theme.of(context).textTheme.bodySmall!
          .copyWith(height: 1.4, color: colors.onSurfaceVariant);
      final delayStyle = muted.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      final delayWidth = StrategyCardStatus.width(
        context,
        textStyle: delayStyle,
      );
      final seen = <String, int>{};
      final ids = <Object>[
        'heading',
        for (final member in group?.members ?? <StrategyMember>[])
          (
            member.name,
            seen.update(member.name, (n) => n + 1, ifAbsent: () => 0),
          ),
      ];
      _anchorRows(ids);
      String delayText(
        AppLocalizations strings,
        StrategyMember member,
        bool first,
      ) {
        if (!first) return '';
        final result = _delay?.results[member.name];
        if (result == null) return '';
        return switch (result.status) {
          DelayMemberStatus.success => '${result.delay} ms',
          DelayMemberStatus.failed || DelayMemberStatus.timeout => '',
          DelayMemberStatus.expired => strings.delayExpired,
          DelayMemberStatus.cancelled => strings.delayCancelled,
          DelayMemberStatus.running => strings.delayRunning,
          DelayMemberStatus.pending => strings.delayPending,
        };
      }

      final hasDetails =
          savedDiffers || _delay?.target != null || group?.provenance != null;
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: hasDetails
                  ? () async {
                      ModalRoute<dynamic>? ownedFeedback;
                      final delayTarget = _delay?.target;
                      try {
                        await showLocalizedOperationMessage(
                          context,
                          (strings) => [
                            if (savedDiffers)
                              saved.member == null
                                  ? strings.popupSavedDiffersAuto
                                  : strings.popupSavedDiffers(saved.member!),
                            if (delayTarget != null)
                              strings.delayTarget(delayTarget),
                            ?provenanceDescription(strings, group?.provenance),
                          ].join('\n\n'),
                          title: (_) => name,
                          error: false,
                          isCurrent: () =>
                              _interactive &&
                              controller.active &&
                              feedbackEpoch == controller.app.storageEpoch &&
                              core.matchesIdentity(controller.app.state.core),
                          onRoute: (route) {
                            if (route != null) {
                              ownedFeedback = route;
                              _feedback = route;
                            } else if (identical(_feedback, ownedFeedback)) {
                              _feedback = null;
                            }
                          },
                          isCurrentWithPopup: (popup) =>
                              identical(_feedback, popup) &&
                              _ownsLifecycle &&
                              controller.active &&
                              feedbackEpoch == controller.app.storageEpoch &&
                              core.matchesIdentity(controller.app.state.core),
                        );
                      } finally {
                        if (identical(_feedback, ownedFeedback)) {
                          _feedback = null;
                        }
                      }
                    }
                  : null,
              child: _heading(
                context,
                group?.rawType ?? '',
                group?.icon ?? '',
                _expired
                    ? strings.popupExpiredShort
                    : waiting
                    ? strings.popupSwitching
                    : savedDiffers
                    ? strings.popupSavedDiffersShort
                    : !controller.current
                    ? strings.popupStale
                    : group == null
                    ? strings.popupReading
                    : _delaySummary(strings).isNotEmpty
                    ? _delaySummary(strings)
                    : [
                        '${group.typeLabel(strings)} · ${group.members.length}',
                        ?provenanceSummary(strings, group.provenance),
                      ].join(' · '),
                details,
              ),
            ),
            if (group?.automatic == true && group!.fixed.isNotEmpty)
              Opacity(
                opacity: details,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final label = strings.fixedTo(group.fixed);
                    final direction = Directionality.of(context);
                    final scaler = MediaQuery.textScalerOf(context);
                    final locale = Localizations.maybeLocaleOf(context);
                    final text = TextPainter(
                      text: TextSpan(text: strings.fixedTo('…'), style: muted),
                      textDirection: direction,
                      textScaler: scaler,
                      locale: locale,
                      maxLines: 1,
                    )..layout();
                    final action = TextPainter(
                      text: TextSpan(
                        text: strings.restoreAuto,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      textDirection: direction,
                      textScaler: scaler,
                      locale: locale,
                      maxLines: 1,
                    )..layout();
                    final inline =
                        text.width + action.width + 48 <= constraints.maxWidth;
                    text.dispose();
                    action.dispose();
                    final fixed = SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(label, style: muted, softWrap: false),
                    );
                    final button = TextButton(
                      onPressed: canChoose ? () => _choose(null) : null,
                      child: Text(strings.restoreAuto),
                    );
                    return inline
                        ? Row(
                            children: [
                              Expanded(child: fixed),
                              button,
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              fixed,
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: button,
                              ),
                            ],
                          );
                  },
                ),
              ),
          ],
        ),
      );
      Widget memberRow(int index) {
        final member = group!.members[index];
        final first =
            group.members.indexWhere((value) => value.name == member.name) ==
            index;
        final selected =
            showSelection &&
            first &&
            group.selectable &&
            group.now == member.name;

        final isGroup = const [
          'select',
          'url-test',
          'fallback',
          'load-balance',
        ].contains(member.type);
        final child = isGroup ? data?.find(member.name) : null;
        final subtitle = !first
            ? AppLocalizations.of(context).sameNameMember
            : child != null
            ? (child.now.isEmpty ? child.typeLabel(strings) : child.now)
            : member.type;
        final resultText = delayText(strings, member, first);
        return Opacity(
          opacity: details,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Semantics(
              selected: selected,
              child: Material(
                key: ValueKey('strategy-member-surface-$index'),
                color: selected
                    ? colors.surfaceContainerHighest
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: ValueKey('strategy-member-$index'),
                        onTap: canChoose && group.selectable && first
                            ? () => _choose(member.name)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // Keep the name and the complete, horizontally
                              // readable result inside the actual popup width.
                              final resultWidth = math.min(
                                delayWidth,
                                math.max(0.0, (constraints.maxWidth - 44) / 2),
                              );
                              return Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        KeyedSubtree(
                                          key: _nameKeys.putIfAbsent(
                                            ids[index + 1],
                                            GlobalKey.new,
                                          ),
                                          child: Text(
                                            member.name,
                                            key: ValueKey(
                                              'strategy-member-name-$index',
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyLarge!
                                                .copyWith(
                                                  height: 1.3,
                                                  fontWeight: selected
                                                      ? FontWeight.w700
                                                      : FontWeight.w400,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Text(
                                            subtitle,
                                            softWrap: false,
                                            style: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    key: ValueKey(
                                      'strategy-delay-result-$index',
                                    ),
                                    width: resultWidth,
                                    child: Tooltip(
                                      message: [
                                        resultText,
                                        if (_delayResultsExpired ||
                                            _expired ||
                                            _delay?.terminalState == 'expired')
                                          strings.delayExpired,
                                      ].join('\n'),
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        reverse: true,
                                        child: Text(
                                          resultText,
                                          softWrap: false,
                                          textAlign: TextAlign.end,
                                          style: delayStyle,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: IconButton(
                        key: ValueKey('strategy-delay-$index'),
                        tooltip: strings.delayTestMember,
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        onPressed: canChoose && first && _delay?.busy != true
                            ? () => _startDelay(group, members: [member.name])
                            : null,
                        color: HomePalette.of(context).moreAction,
                        icon: const Icon(Icons.speed_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      SliverChildBuilderDelegate rows({required bool before}) {
        final count = before ? _centerIndex : ids.length - _centerIndex;
        return SliverChildBuilderDelegate(
          (context, local) {
            final index = before
                ? _centerIndex - local - 1
                : _centerIndex + local;
            final key = _rowKeys.putIfAbsent(ids[index], GlobalKey.new);
            _indices[key] = index;
            return KeyedSubtree(
              key: key,
              child: index == 0
                  ? header
                  : Padding(
                      padding: EdgeInsets.fromLTRB(
                        8,
                        0,
                        8,
                        index == ids.length - 1 ? 10 : 0,
                      ),
                      child: memberRow(index - 1),
                    ),
            );
          },
          childCount: count,
          semanticIndexCallback: (_, local) {
            final index = before
                ? _centerIndex - local - 1
                : _centerIndex + local;
            return index == 0 ? null : index - 1;
          },
          findChildIndexCallback: (key) {
            final index = _indices[key];
            if (index == null) return null;
            final local = before
                ? _centerIndex - index - 1
                : index - _centerIndex;
            return local < 0 || local >= count ? null : local;
          },
        );
      }

      return FocusScope(
        node: _focus,
        autofocus: true,
        child: Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          namesRoute: true,
          label: name,
          child: Material(
            key: ValueKey('strategy-popup-$name'),
            type: MaterialType.transparency,
            child: Stack(
              children: [
                CustomScrollView(
                  key: _viewport,
                  controller: _scroll,
                  shrinkWrap: !widget.anchored,
                  center: widget.anchored ? _center : null,
                  semanticChildCount: ids.length - 1,
                  slivers: [
                    if (widget.anchored)
                      SliverList(delegate: rows(before: true)),
                    SliverList(key: _center, delegate: rows(before: false)),
                  ],
                ),
                Positioned(
                  top: 2,
                  right: 50,
                  child: Opacity(
                    opacity: details,
                    child: IconButton(
                      key: const ValueKey('strategy-delay-group'),
                      tooltip: strings.delayTestGroup,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed:
                          canChoose && group != null && _delay?.busy != true
                          ? () => _startDelay(group)
                          : null,
                      color: HomePalette.of(context).moreAction,
                      icon: const Icon(Icons.speed_rounded, size: 20),
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: Opacity(
                    opacity: details,
                    child: IconButton(
                      onPressed: () {
                        if (_interactive) Navigator.of(context).pop();
                      },
                      tooltip: AppLocalizations.of(context).closeStrategyPopup,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close_rounded, size: 20),
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
