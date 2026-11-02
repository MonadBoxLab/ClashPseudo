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
    unawaited(test.start(members: members));
  }

  void _delayChanged() {
    final test = _delay;
    if (test != null && !_expired && !_delayResultsExpired) {
      controller.rememberDelay(name, test.source, test.results);
    }
    if (mounted) setState(() {});
  }

  String _delaySummary(AppLocalizations strings) {
    if (_delayResultsExpired || _expired) return strings.delayExpired;
    final test = _delay;
    if (test == null) return '';
    if (test.error != null) {
      return test.finished ? strings.delayReadFailed : strings.delayStartFailed;
    }
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
      final colors = Theme.of(context).colorScheme;
      final style = DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: 18,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      );
      // The title shares one toolbar with the group probe and close actions.
      // Reserve both targets even while opening or disabled.
      final width = math.max(1.0, constraints.maxWidth - 126);
      final painter = TextPainter(
        text: TextSpan(text: name, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: width);
      final titleHeight = painter.height;
      painter.dispose();
      final initial = TextPainter(
        text: TextSpan(text: name, style: style.copyWith(fontSize: 16)),
        maxLines: 2,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: math.max(1.0, sourceWidth - 28));
      final initialTop =
          40 + math.max(0.0, (24 * scaler.scale(14) / 14 - initial.height) / 2);
      initial.dispose();
      return SizedBox(
        height: math.max(30, titleHeight + 4 + scaler.scale(12) * 1.4),
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
                style: style.copyWith(fontSize: 16 + 2 * progress),
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
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: colors.onSurfaceVariant,
                      ),
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
      final error = errorMessage?.summary(strings);
      final showSelection =
          sameContext &&
          data?.matches(controller.app.state.core) == true &&
          controller.readError == null;
      final details = ((progress - .35) / .65).clamp(0.0, 1.0);
      final muted = TextStyle(
        fontSize: 12,
        height: 1.4,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: colors.onSurfaceVariant,
      );
      final delayWidth = StrategyCardStatus.width(context, textStyle: muted);
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
          DelayMemberStatus.failed => strings.delayFailed,
          DelayMemberStatus.timeout => strings.delayTimeout,
          DelayMemberStatus.expired => strings.delayExpired,
          DelayMemberStatus.cancelled => strings.delayCancelled,
          DelayMemberStatus.running => strings.delayRunning,
          DelayMemberStatus.pending => strings.delayPending,
        };
      }

      Color? delayColor(ColorScheme colors, StrategyMember member) {
        final status = _delay?.results[member.name]?.status;
        return switch (status) {
          DelayMemberStatus.success => colors.onSurfaceVariant,
          DelayMemberStatus.failed || DelayMemberStatus.timeout => colors.error,
          _ => colors.onSurfaceVariant,
        };
      }

      final hasDetails =
          _expired ||
          errorMessage != null ||
          savedDiffers ||
          data?.unrestored[name] != null ||
          _delay?.target != null ||
          _delay?.error != null ||
          _delay?.results.values.any((result) => result.error != null) ==
              true ||
          group?.provenance != null;
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: hasDetails
                  ? () async {
                      ModalRoute<dynamic>? ownedFeedback;
                      final delayError = _delay?.error;
                      final delayRead = _delay?.finished == true;
                      final delayTarget = _delay?.target;
                      final delayErrors = [
                        for (final result
                            in _delay?.results.values ??
                                const <DelayMemberResult>[])
                          if (result.error != null) result,
                      ];
                      try {
                        await showLocalizedOperationMessage(
                          context,
                          (strings) => [
                            if (_expired) strings.popupExpired,
                            if (errorMessage != null)
                              errorMessage.summary(strings),
                            if (savedDiffers)
                              saved.member == null
                                  ? strings.popupSavedDiffersAuto
                                  : strings.popupSavedDiffers(saved.member!),
                            if (data?.unrestored[name] != null)
                              strings.popupNotRestored(
                                strategyUnrestoredReason(
                                  data!.unrestored[name]!,
                                  strings,
                                ),
                              ),
                            if (delayTarget != null)
                              strings.delayTarget(delayTarget),
                            if (delayError != null)
                              delayRead
                                  ? strings.delayReadFailed
                                  : strings.delayStartFailed,
                            for (final result in delayErrors)
                              '${result.name}\n${switch (result.status) {
                                DelayMemberStatus.timeout => strings.delayTimeout,
                                DelayMemberStatus.expired => strings.delayExpired,
                                DelayMemberStatus.cancelled => strings.delayCancelled,
                                _ => strings.delayFailed,
                              }}',
                            ?provenanceDescription(strings, group?.provenance),
                          ].join('\n\n'),
                          technicalDetail: (strings) {
                            final original = [
                              ?errorMessage?.technicalDetail(strings),
                              ?delayError,
                              for (final result in delayErrors)
                                '${result.name}\n${result.error}',
                            ];
                            return original.isEmpty
                                ? null
                                : original.join('\n\n');
                          },
                          title: (_) => name,
                          error:
                              error != null ||
                              delayError != null ||
                              delayErrors.isNotEmpty,
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
                    : error != null
                    ? strings.popupUpdateFailed
                    : savedDiffers
                    ? strings.popupSavedDiffersShort
                    : data?.unrestored.containsKey(name) == true
                    ? strings.popupNotRestoredShort
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
            if (group?.automatic == true)
              Opacity(
                opacity: details,
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          group!.fixed.isEmpty
                              ? strings.autoLabel
                              : strings.fixedTo(group.fixed),
                          softWrap: false,
                          style: muted,
                        ),
                      ),
                    ),
                    Flexible(
                      child: TextButton(
                        key: const ValueKey('strategy-automatic'),
                        onPressed: canChoose ? () => _choose(null) : null,
                        child: Text(
                          strings.restoreAuto,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
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
        final fixed =
            showSelection &&
            first &&
            group.automatic &&
            group.fixed == member.name;
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
                                            style: const TextStyle(
                                              fontSize: 15,
                                              height: 1.3,
                                              fontWeight: FontWeight.w500,
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
                                      'strategy-member-marks-$index',
                                    ),
                                    width: 36,
                                    height: 21,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (fixed)
                                          Tooltip(
                                            message: strings.pinned,
                                            child: Icon(
                                              Icons.push_pin_rounded,
                                              size: 14,
                                              color: colors.primary,
                                            ),
                                          ),
                                        if (selected)
                                          Icon(
                                            Icons.check_rounded,
                                            size: 21,
                                            color: colors.primary,
                                          ),
                                      ],
                                    ),
                                  ),
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
                                          style: muted.copyWith(
                                            color: delayColor(colors, member),
                                          ),
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
                      width: 44,
                      height: 44,
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
