part of 'connections_page.dart';

class _ConnectionDetail extends StatefulWidget {
  const _ConnectionDetail({
    super.key,
    required this.controller,
    required this.active,
    required this.isPresented,
    required this.onClose,
    required this.onMenuChanged,
  });
  final ConnectionController controller;
  final bool active;
  final bool Function() isPresented;
  final VoidCallback onClose;
  final void Function(GlobalKey, bool) onMenuChanged;
  @override
  State<_ConnectionDetail> createState() => _ConnectionDetailState();
}

enum _ConnectionInfoField { targetIp, sourceAddress, inbound }

class _ConnectionDetailState extends State<_ConnectionDetail> {
  bool? _visible;
  AppMessage? _shownError;
  String? _shownRuleError;
  final _infoFields = <_ConnectionInfoField>[];
  final _ruleActionsKey = GlobalKey();
  final _actionsMenu = GlobalKey();
  bool _ruleOpening = false;
  bool _ruleFormOpen = false;
  ModalRoute<dynamic>? _ruleRoute;
  bool _ruleMenuOpen = false;
  late final Object? _lease;

  bool get _live =>
      mounted &&
      widget.active &&
      widget.controller.detailLease == _lease &&
      AppTaskActivity.isActive(context) &&
      widget.controller.app.interactive &&
      CollectionWorkspace.paneActiveOf(context, listen: false);
  bool _liveWithPopup(ModalRoute<dynamic> popup) =>
      mounted &&
      widget.active &&
      widget.controller.detailLease == _lease &&
      widget.controller.app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      widget.isPresented();

  bool get _canPresent => _live && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    _lease = widget.controller.detailLease;
    widget.controller.addListener(_resultChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resultChanged();
    });
  }

  void _resultChanged() {
    final controller = widget.controller;
    final message = controller.closeMessageDescription;
    final ruleError = controller.detail?.ruleError;
    if (message == null) _shownError = null;
    if (ruleError == null) _shownRuleError = null;
    if ((message == null || message == _shownError) &&
        (ruleError == null || ruleError == _shownRuleError)) {
      return;
    }
    final source = controller.detailSource;
    final epoch = controller.app.storageEpoch;
    final id = controller.detail?.id;
    if (source == null || id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bool sameSelection() =>
          controller.app.storageEpoch == epoch &&
          controller.detail?.id == id &&
          source.matchesIdentity(controller.app.state.core);
      if (!_canPresent || !sameSelection()) return;
      if (message != null &&
          message != _shownError &&
          controller.closeMessageDescription == message) {
        _shownError = message;
        showAppNotice(
          context,
          message,
          title: (strings) => strings.disconnectFailedTitle,
          eligibilityChanges: controller,
          isCurrent: () =>
              _canPresent &&
              sameSelection() &&
              controller.closeMessageDescription == message,
          isCurrentWithPopup: (popup) =>
              _liveWithPopup(popup) &&
              sameSelection() &&
              controller.closeMessageDescription == message,
        );
      }
      if (ruleError != null &&
          ruleError != _shownRuleError &&
          controller.detail?.ruleError == ruleError) {
        _shownRuleError = ruleError;
        showLocalizedOperationNotice(
          context,
          (strings) => strings.connectionRuleUnavailable,
          technicalDetail: (_) => ruleError,
          identity: (id, ruleError),
          eligibilityChanges: controller,
          isCurrent: () =>
              _canPresent &&
              sameSelection() &&
              controller.detail?.ruleError == ruleError,
          isCurrentWithPopup: (popup) =>
              _liveWithPopup(popup) &&
              sameSelection() &&
              controller.detail?.ruleError == ruleError,
        );
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resultChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    CollectionWorkspace.paneActiveOf(context);
    _syncVisibility();
    _resultChanged();
  }

  @override
  void didUpdateWidget(_ConnectionDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncVisibility();
  }

  void _syncVisibility() {
    if (!mounted) return;
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    final workspace = context
        .findAncestorStateOfType<CollectionWorkspaceState>();
    final masterVisible =
        widget.active &&
        AppTaskActivity.isActive(context) &&
        widget.controller.app.interactive &&
        workspace?.masterVisible == true &&
        current;
    // The main list and retained details share connection reads; returning to the list
    // on narrow screens keeps reading.
    // Detail actions check pane eligibility separately through _live.
    final visible =
        masterVisible || (_live && (_ruleFormOpen || _ruleMenuOpen || current));
    if (_visible == visible) return;
    _visible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setVisible(_visible!);
    });
  }

  void _closeRuleMenu() {
    _ruleMenuOpen = false;
    widget.onMenuChanged(_ruleActionsKey, false);
    if (mounted) _syncVisibility();
  }

  Future<void> _createRule(
    ConnectionRuleCandidate candidate, {
    ConnectionRuleSuggestions? expectedSource,
    int? expectedEpoch,
  }) async {
    if (!_canPresent || _ruleOpening) return;
    final controller = widget.controller;
    final source = expectedSource ?? controller.ruleSuggestions;
    final epoch = expectedEpoch ?? controller.detailStorageEpoch;
    if (!controller.canCreateRule ||
        source == null ||
        epoch == null ||
        !controller.isRuleSourceCurrent(source, epoch, candidate: candidate)) {
      await showLocalizedOperationNotice(
        context,
        (strings) => strings.popupExpiredShort,
        title: (strings) => strings.ruleFormTitle,
        isCurrent: () => _canPresent,
        isCurrentWithPopup: _liveWithPopup,
      );
      return;
    }
    setState(() => _ruleOpening = true);
    try {
      final targets = await controller.loadRuleTargets(
        source,
        epoch,
        candidate,
      );
      if (!mounted || !_canPresent) return;
      if (!controller.isRuleSourceCurrent(
        source,
        epoch,
        candidate: candidate,
      )) {
        throw ConfigFailure(messages.strategyContextChangedRetry);
      }
      _ruleFormOpen = true;
      _syncVisibility();
      await showLocalCustomForm(
        context,
        app: controller.app,
        section: LocalYamlSection.rules,
        storageEpoch: epoch,
        targets: {
          ...targets.groups.map((group) => group.name),
          'DIRECT',
          'REJECT',
        }.toList(),
        initialType: candidate.type,
        initialValue: candidate.value,
        restrictTargets: true,
        onRoute: (route) => _ruleRoute = route,
        isContextCurrent: () {
          if (!mounted ||
              !widget.active ||
              !widget.isPresented() ||
              widget.controller.detailLease != _lease) {
            return false;
          }
          final origin = ModalRoute.of(context);
          final form = _ruleRoute;
          return (origin?.isActive ?? true) &&
              origin?.animation?.status != AnimationStatus.reverse &&
              // The form checks its own page and popup state; retain the rule source
              // while its popup is open.
              form?.animation?.status != AnimationStatus.reverse &&
              controller.isRuleSourceCurrent(
                source,
                epoch,
                candidate: candidate,
              ) &&
              targets.matches(controller.app.state.core);
        },
      );
    } on ConfigFailure catch (error) {
      if (mounted) setState(() => _ruleOpening = false);
      if (mounted && _canPresent) {
        await showAppNotice(
          context,
          error.message,
          title: (strings) => strings.ruleFormTitle,
          isCurrent: () =>
              _canPresent &&
              source.source.matchesIdentity(controller.app.state.core),
          isCurrentWithPopup: (popup) =>
              _liveWithPopup(popup) &&
              source.source.matchesIdentity(controller.app.state.core),
        );
      }
    } catch (failure) {
      if (mounted) setState(() => _ruleOpening = false);
      if (mounted && _canPresent) {
        await showAppNotice(
          context,
          const AppMessage('connectionRuleTargetsFailed').withDetail(failure),
          title: (strings) => strings.ruleFormTitle,
          isCurrent: () =>
              _canPresent &&
              source.source.matchesIdentity(controller.app.state.core),
          isCurrentWithPopup: (popup) =>
              _liveWithPopup(popup) &&
              source.source.matchesIdentity(controller.app.state.core),
        );
      }
    } finally {
      _ruleFormOpen = false;
      if (mounted) {
        setState(() => _ruleOpening = false);
        _syncVisibility();
      }
    }
  }

  ({double width, Widget child}) _ruleActions() {
    final controller = widget.controller;
    final strings = AppLocalizations.of(context);
    final source = controller.ruleSuggestions;
    final enabled = _live && controller.canCreateRule && !_ruleOpening;
    final epoch = controller.detailStorageEpoch;
    final labelStyle =
        TextButtonTheme.of(context).style?.textStyle?.resolve({}) ??
        Theme.of(context).textTheme.labelLarge!;
    const iconSize = 18.0;
    const iconGap = 8.0;
    const scopeGap = 4.0;
    const padding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final measure = TextPainter(
      text: TextSpan(text: strings.ruleFormTitle, style: labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final buttonWidth =
        (measure.width + padding.horizontal + iconSize + iconGap).clamp(
          kMinInteractiveDimension,
          double.infinity,
        );
    measure.dispose();
    final reason = _ruleOpening || controller.app.busy
        ? messages.operationInProgress.resolve(strings)
        : source?.candidates.isNotEmpty != true
        ? strings.connectionRuleUnavailable
        : !controller.canCreateRule
        ? strings.popupExpiredShort
        : '';
    return (
      width: buttonWidth + scopeGap + kMinInteractiveDimension,
      child: Row(
        key: _ruleActionsKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Tooltip(
              message: reason,
              child: TextButton(
                key: const ValueKey('connection-add-rule'),
                style: TextButton.styleFrom(
                  textStyle: labelStyle,
                  padding: padding,
                  minimumSize: const Size(
                    kMinInteractiveDimension,
                    kMinInteractiveDimension,
                  ),
                  visualDensity: VisualDensity.standard,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: enabled
                    ? () => _createRule(source!.candidates.first)
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: iconSize,
                      child: _ruleOpening
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : const Icon(Icons.playlist_add, size: iconSize),
                    ),
                    const SizedBox(width: iconGap),
                    Flexible(child: Text(strings.ruleFormTitle)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: scopeGap),
          SizedBox.square(
            dimension: kMinInteractiveDimension,
            child: ChoiceMenuButton<ConnectionRuleCandidate>(
              key: const ValueKey('connection-rule-scope'),
              identity: (
                epoch,
                source?.connectionId,
                source?.source.generation,
                source?.source.configId,
                source?.source.revision,
                source?.source.composition,
                source?.source.purpose,
              ),
              tooltip: strings.connectionRuleScope,
              enabled: enabled,
              maxHeight: MediaQuery.sizeOf(context).height * 0.45,
              options: {
                for (final candidate
                    in source?.candidates ?? <ConnectionRuleCandidate>[])
                  candidate: candidate.value,
              },
              optionBuilder: (candidate, label) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidate.type,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(label),
                  ],
                ),
              ),
              onOpened: () {
                _ruleMenuOpen = true;
                widget.onMenuChanged(_ruleActionsKey, true);
                _syncVisibility();
              },
              onClosed: _closeRuleMenu,
              onSelected: (candidate) {
                if (source != null && epoch != null) {
                  _createRule(
                    candidate,
                    expectedSource: source,
                    expectedEpoch: epoch,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final record = controller.detail;
      if (record == null) return const SizedBox.shrink();
      final strings = AppLocalizations.of(context);
      final colors = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;
      final routeStyle = text.bodyLarge!.copyWith(
        height: 1.4,
        leadingDistribution: TextLeadingDistribution.even,
      );
      final routeLine = TextPainter(
        text: TextSpan(
          text: record.path.isEmpty ? '—' : record.path,
          style: DefaultTextStyle.of(context).style.merge(routeStyle),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      final routeIconHeight = (routeLine.height + 4).clamp(
        36.0,
        double.infinity,
      );
      routeLine.dispose();
      final palette = ConnectionPalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      final at = controller.detailAt;
      final duration = at != null && record.start != null
          ? at.difference(record.start!)
          : null;
      final source = connectionEndpoint(record.sourceIP, record.sourcePort);
      final info = {
        if (record.host.isNotEmpty && record.destinationIP.isNotEmpty)
          _ConnectionInfoField.targetIp: record.destinationIP,
        if (record.sourceIP.isNotEmpty)
          _ConnectionInfoField.sourceAddress: source,
        if (record.type.isNotEmpty) _ConnectionInfoField.inbound: record.type,
      };
      for (final field in info.keys) {
        if (!_infoFields.contains(field)) _infoFields.add(field);
      }
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () {
              if (_live) widget.onClose();
            },
          ),
          title: Text(strings.connectionDetails),
          actions: [
            ChoiceMenuButton<String>(
              key: _actionsMenu,
              identity: (
                _lease,
                controller.app.storageEpoch,
                controller.app.state.generation,
                controller.app.state.core.identity,
              ),
              enabled: _live,
              tooltip: strings.moreActions,
              icon: Icons.more_vert_rounded,
              options: {
                'connection-disconnect': controller.closing
                    ? strings.disconnecting
                    : strings.disconnect,
              },
              disabledOptions: {
                if (!controller.canClose) 'connection-disconnect',
              },
              leadingIcon: (_) => Icon(
                Icons.link_off_rounded,
                color: controller.canClose ? colors.error : null,
                size: 20,
              ),
              onOpened: () => widget.onMenuChanged(_actionsMenu, true),
              onClosed: () => widget.onMenuChanged(_actionsMenu, false),
              onSelected: (_) {
                if (!_canPresent) return;
                widget.onMenuChanged(_actionsMenu, false);
                if (controller.canClose) controller.disconnect();
              },
              buttonBuilder: (context, onPressed, focus) => IconButton(
                key: const ValueKey('connection-detail-actions'),
                focusNode: focus,
                onPressed: onPressed,
                tooltip: strings.moreActions,
                icon: controller.closing
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.error,
                        ),
                      )
                    : const Icon(Icons.more_vert_rounded),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SingleChildScrollView(
          key: const ValueKey('connection-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailValue(
                      record.target,
                      style: text.titleLarge!.copyWith(
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final statusSize = _StatusLabel.measure(context);
                        final painter = TextPainter(
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          locale: Localizations.maybeLocaleOf(context),
                          maxLines: 1,
                        );
                        double width(String value, TextStyle style) {
                          painter.text = TextSpan(
                            text: value,
                            style: DefaultTextStyle.of(context).style
                                .merge(style),
                          );
                          painter.layout();
                          return painter.width;
                        }

                        final metadataWidth =
                            (record.network.isEmpty
                                ? 0.0
                                : width(
                                        record.network.toUpperCase(),
                                        text.labelMedium!.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ) +
                                      12) +
                            (record.host.isEmpty ||
                                    record.destinationPort.isEmpty
                                ? 0.0
                                : width(
                                        strings.portLabel(
                                          record.destinationPort,
                                        ),
                                        text.bodySmall!,
                                      ) +
                                      8);
                        painter.dispose();
                        final stacked =
                            constraints.maxWidth <
                            metadataWidth + statusSize.width + 12;
                        final status = SizedBox(
                          width: statusSize.width.clamp(
                            0.0,
                            constraints.maxWidth,
                          ),
                          height: statusSize.height.clamp(
                            48.0,
                            double.infinity,
                          ),
                          child: _StatusLabel(
                            key: const ValueKey('connection-detail-status'),
                            active:
                                record.active &&
                                controller.closeResult != 'closed' &&
                                controller.closeResult != 'absent',
                            closed: controller.closeResult == 'closed',
                            trailing: true,
                          ),
                        );
                        final metadata = SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (record.network.isNotEmpty)
                                _ProtocolLabel(record.network),
                              if (record.host.isNotEmpty &&
                                  record.destinationPort.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Text(
                                    strings.portLabel(record.destinationPort),
                                    softWrap: false,
                                    style: text.bodySmall!.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                        final lineHeight = (statusSize.height + 4)
                            .clamp(48.0, double.infinity)
                            .toDouble();
                        if (stacked) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: lineHeight,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: metadata,
                                ),
                              ),
                              SizedBox(
                                height: lineHeight,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: status,
                                ),
                              ),
                            ],
                          );
                        }
                        return SizedBox(
                          height: lineHeight,
                          child: Row(
                            children: [
                              Expanded(child: metadata),
                              const SizedBox(width: 12),
                              status,
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              _section(strings.routingResult),
              _Group(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: routeIconHeight,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: StrategyIcon(
                                type: record.strategyType,
                                source: record.strategyIcon,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DetailValue(
                            record.path.isEmpty ? '—' : record.path,
                            minHeight: 36,
                            style: routeStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _field(
                    strings.matchedRule,
                    record.rule.isEmpty ? '—' : record.ruleLabel,
                    stacked: true,
                    actions: _ruleActions(),
                  ),
                ],
              ),
              _section(strings.traffic),
              _Group(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final values = [
                          _TrafficValue(
                            label: strings.download,
                            value: record.download,
                            speed: controller.detailActive
                                ? record.downloadSpeed
                                : null,
                            color: palette.download,
                            icon: Icons.south_west_rounded,
                          ),
                          _TrafficValue(
                            label: strings.upload,
                            value: record.upload,
                            speed: controller.detailActive
                                ? record.uploadSpeed
                                : null,
                            color: palette.upload,
                            icon: Icons.north_east_rounded,
                          ),
                        ];
                        if (constraints.maxWidth < 240 ||
                            MediaQuery.textScalerOf(context)
                                    .scale(text.headlineMedium!.fontSize!) >
                                40) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              values[0],
                              const SizedBox(height: 20),
                              values[1],
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: values[0]),
                            const SizedBox(width: 16),
                            Expanded(child: values[1]),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              _section(strings.connectionInfoTimeTitle),
              _Group(
                children: [
                  _field(strings.startTime, _time(record.start)),
                  _field(
                    strings.durationLabel,
                    duration != null && !duration.isNegative
                        ? _duration(strings, duration)
                        : '—',
                    numeric: true,
                    color: controller.detailActive
                        ? palette.active
                        : colors.onSurfaceVariant,
                  ),
                ],
              ),
              if (_infoFields.isNotEmpty) ...[
                _section(strings.connectionInfo),
                _Group(
                  children: [
                    for (final field in _infoFields)
                      KeyedSubtree(
                        key: ValueKey(field),
                        child: _field(switch (field) {
                          _ConnectionInfoField.targetIp => strings.targetIp,
                          _ConnectionInfoField.sourceAddress =>
                            strings.sourceAddress,
                          _ConnectionInfoField.inbound => strings.inbound,
                        }, info[field] ?? strings.notProvided),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium!
          .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _field(
    String name,
    String value, {
    bool stacked = false,
    bool numeric = false,
    Color? color,
    ({double width, Widget child})? actions,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(
          name,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
        final data = _DetailValue(
          value,
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: color,
            fontFeatures: numeric ? const [FontFeature.tabularFigures()] : null,
          ),
        );
        if (actions case final group?) {
          const gap = 16.0;
          final measure = TextPainter(
            text: TextSpan(
              text: name,
              style: DefaultTextStyle.of(context).style.merge(label.style),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
          )..layout();
          final inline =
              measure.width + gap + group.width <= constraints.maxWidth;
          measure.dispose();
          final buttons = SizedBox(
            key: const ValueKey('connection-rule-actions'),
            width: group.width.clamp(0.0, constraints.maxWidth),
            child: group.child,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (inline)
                Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: gap),
                    buttons,
                  ],
                )
              else
                label,
              const SizedBox(height: 5),
              data,
              if (!inline) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: buttons,
                ),
              ],
            ],
          );
        }
        if (stacked ||
            constraints.maxWidth < 260 ||
            MediaQuery.textScalerOf(context)
                    .scale(Theme.of(context).textTheme.bodyMedium!.fontSize!) >
                20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 5), data],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            label,
            const SizedBox(width: 16),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: data),
            ),
          ],
        );
      },
    ),
  );
}

// Fix the reading area height from the initial content; longer updates can scroll and
// remain selectable inside it.
class _DetailValue extends StatefulWidget {
  const _DetailValue(this.text, {required this.style, this.minHeight = 0});
  final String text;
  final TextStyle style;
  final double minHeight;

  @override
  State<_DetailValue> createState() => _DetailValueState();
}

class _DetailValueState extends State<_DetailValue> {
  final _scroll = ScrollController();
  (double, TextScaler, Locale?, TextDirection)? _geometry;
  TextStyle? _geometryStyle;
  double? _height;
  bool _singleLine = true;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      final direction = Directionality.of(context);
      final locale = Localizations.maybeLocaleOf(context);
      final geometry = (constraints.maxWidth, scaler, locale, direction);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
      )..layout(maxWidth: constraints.maxWidth);
      if (_geometry != geometry ||
          _geometryStyle == null ||
          _geometryStyle!.compareTo(style) == RenderComparison.layout) {
        _geometry = geometry;
        final lineHeight = painter.preferredLineHeight;
        _height = (painter.height.clamp(lineHeight, lineHeight * 6) + 4).clamp(
          widget.minHeight,
          double.infinity,
        );
        _singleLine = painter.computeLineMetrics().length <= 1;
      }
      _geometryStyle = style;
      final overflow = painter.height + 4 > _height!;
      painter.dispose();
      return SizedBox(
        height: _height,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: overflow,
          child: SingleChildScrollView(
            controller: _scroll,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: _height! - 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: _singleLine
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [SelectableText(widget.text, style: style)],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          children[i],
        ],
      ],
    ),
  );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({
    super.key,
    required this.active,
    required this.closed,
    this.trailing = false,
  });
  final bool active;
  final bool closed;
  final bool trailing;

  static Size measure(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final style = DefaultTextStyle.of(context).style.merge(
      Theme.of(context).textTheme.bodySmall!
          .copyWith(fontWeight: FontWeight.w500),
    );
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    var width = 0.0;
    var height = 0.0;
    for (final label in [
      strings.connectionClosed,
      strings.connectionActive,
      strings.connectionInactive,
    ]) {
      painter.text = TextSpan(text: label, style: style);
      painter.layout();
      if (painter.width > width) width = painter.width;
      if (painter.height > height) height = painter.height;
    }
    painter.dispose();
    return Size(width.ceilToDouble(), height.ceilToDouble());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final strings = AppLocalizations.of(context);
    final label = closed
        ? strings.connectionClosed
        : active
        ? strings.connectionActive
        : strings.connectionInactive;
    final color = active ? palette.active : colors.onSurfaceVariant;
    return SizedBox(
      width: measure(context).width,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: trailing,
        child: Text(
          label,
          key: const ValueKey('connection-detail-status-text'),
          softWrap: false,
          style: Theme.of(context).textTheme.bodySmall!
              .copyWith(color: color, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _ProtocolLabel extends StatelessWidget {
  const _ProtocolLabel(this.network);
  final String network;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        network.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium!.copyWith(
          fontWeight: FontWeight.w600,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    required this.label,
    required this.value,
    required this.speed,
    required this.color,
    required this.icon,
  });
  final String label;
  final int? value;
  final double? speed;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final parts = (speed == null ? '—' : '${_bytes(speed!.round())}/s').split(
      ' ',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(icon, color: color, size: 16),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall!
                  .copyWith(color: color, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: parts.first,
                  style: Theme.of(context).textTheme.headlineMedium!
                      .copyWith(fontWeight: FontWeight.w600, color: color),
                ),
                if (parts.length > 1)
                  TextSpan(
                    text: ' ${parts.last}',
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            softWrap: false,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 5),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            AppLocalizations.of(context).cumulative(_bytes(value)),
            softWrap: false,
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

String _duration(AppLocalizations strings, Duration value) {
  if (value.inHours > 0) {
    return strings.durationHoursMinutes(value.inHours, value.inMinutes % 60);
  }
  if (value.inMinutes > 0) {
    return strings.durationMinutesSeconds(
      value.inMinutes,
      value.inSeconds % 60,
    );
  }
  return strings.durationSeconds(value.inSeconds);
}

String _time(DateTime? value) => value == null
    ? '—'
    : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
