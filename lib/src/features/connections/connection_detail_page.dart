part of 'connections_page.dart';

class _ConnectionDetail extends StatefulWidget {
  const _ConnectionDetail({
    super.key,
    required this.controller,
    required this.active,
    required this.onClose,
  });
  final ConnectionController controller;
  final bool active;
  final VoidCallback onClose;
  @override
  State<_ConnectionDetail> createState() => _ConnectionDetailState();
}

enum _ConnectionInfoField { targetIp, sourceAddress, inbound }

class _ConnectionDetailState extends State<_ConnectionDetail> {
  bool? _visible;
  AppMessage? _shownError;
  final _infoFields = <_ConnectionInfoField>[];
  final _ruleActionsKey = GlobalKey();
  bool _ruleOpening = false;
  bool _ruleFormOpen = false;
  bool _ruleMenuOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resultChanged);
  }

  void _resultChanged() {
    final message = widget.controller.closeMessageDescription;
    if (message == _shownError) return;
    _shownError = message;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        showAppMessage(
          context,
          message,
          title: (strings) => strings.disconnectFailedTitle,
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
    _syncVisibility();
  }

  @override
  void didUpdateWidget(_ConnectionDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncVisibility();
  }

  void _syncVisibility() {
    if (!mounted) return;
    final visible =
        widget.active &&
        (_ruleFormOpen ||
            _ruleMenuOpen ||
            (ModalRoute.of(context)?.isCurrent ?? true));
    if (_visible == visible) return;
    _visible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setVisible(_visible!);
    });
  }

  void _closeRuleMenu() {
    _ruleMenuOpen = false;
    if (mounted) _syncVisibility();
  }

  Future<void> _createRule(
    ConnectionRuleCandidate candidate, {
    ConnectionRuleSuggestions? expectedSource,
    int? expectedEpoch,
  }) async {
    if (_ruleOpening) return;
    final controller = widget.controller;
    final source = expectedSource ?? controller.ruleSuggestions;
    final epoch = expectedEpoch ?? controller.detailStorageEpoch;
    if (!controller.canCreateRule ||
        source == null ||
        epoch == null ||
        !controller.isRuleSourceCurrent(source, epoch, candidate: candidate)) {
      await showLocalizedOperationMessage(
        context,
        (strings) => strings.popupExpiredShort,
        title: (strings) => strings.ruleFormTitle,
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
      if (!mounted) return;
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
        isContextCurrent: () =>
            controller.isRuleSourceCurrent(
              source,
              epoch,
              candidate: candidate,
            ) &&
            targets.matches(controller.app.state.core),
      );
    } on ConfigFailure catch (error) {
      if (mounted) setState(() => _ruleOpening = false);
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        await showAppMessage(
          context,
          error.message,
          title: (strings) => strings.ruleFormTitle,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _ruleOpening = false);
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        await showLocalizedOperationMessage(
          context,
          (strings) => strings.connectionRuleTargetsFailed,
          title: (strings) => strings.ruleFormTitle,
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
    final enabled = controller.canCreateRule && !_ruleOpening;
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
      final record = controller.detail!;
      final strings = AppLocalizations.of(context);
      final colors = Theme.of(context).colorScheme;
      final palette = ConnectionPalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      final at = controller.detailAt;
      final duration = at != null && record.start != null
          ? at.difference(record.start!)
          : null;
      final source = ConnectionRecord.endpoint(
        record.sourceIP,
        record.sourcePort,
      );
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
          leading: BackButton(onPressed: widget.onClose),
          title: Text(strings.connectionDetails),
          actions: [
            IconButton(
              onPressed: controller.canClose ? controller.disconnect : null,
              tooltip: controller.closing
                  ? strings.disconnecting
                  : strings.disconnect,
              color: colors.error,
              icon: controller.closing
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.error,
                      ),
                    )
                  : const Icon(Icons.link_off_rounded),
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
                      style: const TextStyle(
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fontSize = MediaQuery.textScalerOf(context)
                            .scale(13);
                        final stacked = constraints.maxWidth < fontSize * 25;
                        final status = InkWell(
                          onTap:
                              controller.closeMessage != null ||
                                  controller.error != null ||
                                  record.fieldsTruncated
                              ? () => showLocalizedOperationMessage(
                                  context,
                                  (strings) => [
                                    if (controller.closeMessageDescription
                                        case final message?)
                                      message.resolve(strings),
                                    if (controller.errorMessage
                                        case final message?)
                                      message.resolve(strings),
                                    if (record.fieldsTruncated)
                                      strings.fieldsTruncated,
                                  ].join('\n\n'),
                                  title: (strings) => strings.connectionStatus,
                                  error:
                                      controller.closeMessage != null ||
                                      controller.error != null,
                                )
                              : null,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _StatusLabel(
                                  key: const ValueKey(
                                    'connection-detail-status',
                                  ),
                                  status: controller.detailStatus,
                                  trailing: true,
                                ),
                                SizedBox.square(
                                  dimension: 18,
                                  child: record.fieldsTruncated
                                      ? Tooltip(
                                          message: strings.fieldsTruncated,
                                          child: Icon(
                                            Icons.info_outline,
                                            size: 16,
                                            color: palette.warning,
                                          ),
                                        )
                                      : null,
                                ),
                              ],
                            ),
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
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                        final lineHeight = (fontSize * 2 + 4)
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
                          height:
                              (MediaQuery.textScalerOf(context).scale(16) * 1.4)
                                  .ceilToDouble()
                                  .clamp(32, double.infinity) +
                              4,
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
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.4,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
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
                            MediaQuery.textScalerOf(context).scale(14) > 20) {
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
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _field(
    String name,
    String value, {
    bool stacked = false,
    Color? color,
    ({double width, Widget child})? actions,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(
          name,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
        final data = _DetailValue(
          value,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
        if (actions case final group?) {
          const gap = 16.0;
          final measure = TextPainter(
            text: TextSpan(text: name, style: label.style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
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
            MediaQuery.textScalerOf(context).scale(14) > 20) {
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

// Fix reading height from the first visible value; later longer values remain
// selectable and scroll within it.
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
  (double, double)? _geometry;
  double? _height;
  bool _singleLine = true;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      final geometry = (
        constraints.maxWidth,
        scaler.scale(style.fontSize ?? 14),
      );
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: constraints.maxWidth);
      if (_geometry != geometry) {
        _geometry = geometry;
        _height = (painter.height.clamp(geometry.$2, geometry.$2 * 6) + 4)
            .clamp(widget.minHeight, double.infinity);
        _singleLine = painter.computeLineMetrics().length <= 1;
      }
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
  const _StatusLabel({super.key, required this.status, this.trailing = false});
  final ConnectionViewStatus status;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final strings = AppLocalizations.of(context);
    final (label, icon, color) = switch (status) {
      ConnectionViewStatus.active => (
        strings.connectionActive,
        Icons.circle,
        palette.active,
      ),
      ConnectionViewStatus.updating => (
        strings.connectionUpdating,
        Icons.sync_rounded,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.failed => (
        strings.connectionRefreshFailed,
        Icons.error_outline_rounded,
        palette.warning,
      ),
      ConnectionViewStatus.closed => (
        strings.connectionClosed,
        Icons.link_off_rounded,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.inactive => (
        strings.connectionInactive,
        Icons.circle_outlined,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.stopped => (
        strings.takeoverStopped,
        Icons.stop_circle_outlined,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.unknown => (
        strings.statusUnconfirmed,
        Icons.help_outline_rounded,
        palette.warning,
      ),
      ConnectionViewStatus.replaced => (
        strings.connectionReplaced,
        Icons.swap_horiz_rounded,
        colors.onSurfaceVariant,
      ),
    };
    return SizedBox(
      width: 20 + MediaQuery.textScalerOf(context).scale(13) * 5,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: trailing,
        child: Row(
          children: [
            SizedBox.square(
              dimension: 15,
              child: Icon(
                icon,
                size: status == ConnectionViewStatus.active ? 8 : 15,
                color: color,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              softWrap: false,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
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
        style: TextStyle(
          fontSize: 11,
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
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w500,
              ),
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
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (parts.length > 1)
                  TextSpan(
                    text: ' ${parts.last}',
                    style: TextStyle(
                      fontSize: 13,
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
            style: TextStyle(
              fontSize: 13,
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
