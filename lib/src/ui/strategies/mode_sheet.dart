import 'dart:async';

import '../locale/model_text.dart';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../theme/app_theme.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';
import '../navigation/route_observer.dart';
import '../navigation/task_activity.dart';
import '../../model/app_snapshot.dart';
import '../../model/application_contract.dart';
import '../../model/core_snapshot.dart';
import '../../model/messages.dart';
import '../../model/tunnel_mode.dart';

class ModeSheet extends StatefulWidget {
  const ModeSheet({super.key, required this.controller, this.storageEpoch});
  final AppController controller;
  final int? storageEpoch;

  @override
  State<ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<ModeSheet> {
  TunnelMode? _target;
  Object? _modeNotice;
  final _feedbackOwner = ValueNotifier<bool>(false);
  bool _feedbackPresented = false;
  CoreSnapshot? _submissionCore;
  bool Function()? _sourceCurrent;
  Map<String, Object?>? _command;
  AppSnapshot? _result;
  Timer? _confirmation;
  bool _closing = false;
  ModalRoute<dynamic>? _route;
  Listenable? _routeChanges;
  late final int _storageEpoch;

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? widget.controller.storageEpoch;
    widget.controller.addListener(_changed);
  }

  bool get _eligible => _eligibleWithPopup(null);

  bool _eligibleWithPopup(ModalRoute<dynamic>? feedback) {
    if (!mounted || !widget.controller.foreground) return false;
    final route = ModalRoute.of(context);
    return AppTaskActivity.isActive(context, ownedPopup: feedback ?? route) &&
        AppTaskActivity.routeIsActive(route, ownedPopup: feedback);
  }

  bool _sameContext(AppController owner, int epoch, CoreSnapshot core) {
    if (!identical(widget.controller, owner) || owner.storageEpoch != epoch) {
      return false;
    }
    final current = owner.state.core;
    return core.hasIdentity
        ? core.matchesIdentity(current)
        : core.phase == 'EMPTY' &&
              current.phase == 'EMPTY' &&
              !current.hasIdentity &&
              core.identity == current.identity;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final changes = AppTaskNavigatorObserver.changesFor(_route);
    if (!identical(_routeChanges, changes)) {
      _routeChanges?.removeListener(_syncFeedbackOwner);
      _routeChanges = changes;
      _routeChanges?.addListener(_syncFeedbackOwner);
    }
    _syncFeedbackOwner();
    _confirmProjection();
  }

  void _syncFeedbackOwner() {
    if (!_feedbackOwner.value || _feedbackPresented || !mounted) return;
    if (_sourceCurrent?.call() != true ||
        _route?.isActive == false ||
        _storageEpoch != widget.controller.storageEpoch ||
        (_command != null &&
            !identical(_command, widget.controller.lastCommand))) {
      _feedbackOwner.value = false;
      _confirmation?.cancel();
      _result = null;
      _target = null;
    }
  }

  void _confirmProjection() {
    final result = _result;
    final mode = _target;
    final controller = widget.controller;
    if (result == null || mode == null || !_feedbackOwner.value || _closing) {
      return;
    }
    final receipt = result.modeResult;
    if (receipt == null ||
        receipt['mode'] != mode.name ||
        receipt['storageEpoch'] != _storageEpoch) {
      return;
    }
    final state = controller.state;
    final applied = receipt['status'] == 'applied';
    if (applied &&
        state.core.hasIdentity &&
        !state.core.matchesWireIdentity(receipt) &&
        _submissionCore?.matchesIdentity(state.core) != true) {
      _feedbackOwner.value = false;
      _confirmation?.cancel();
      _result = null;
      _target = null;
      return;
    }
    bool projectionConfirmed() {
      final latest = controller.state;
      final savedSource =
          latest.core.matchesWireIdentity(receipt) ||
          (receipt['processId'] == null &&
              _submissionCore != null &&
              _sameContext(controller, _storageEpoch, _submissionCore!));
      return controller.configsCurrent &&
          controller.collection.mode == mode &&
          latest.confirmed &&
          (applied
              ? latest.forwarding &&
                    latest.core.matchesWireIdentity(receipt) &&
                    latest.mode == mode
              : receipt['status'] == 'saved' &&
                    !latest.usesRuntimeMode &&
                    savedSource);
    }

    if (!projectionConfirmed() || !_eligible) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _eligible &&
          _feedbackOwner.value &&
          identical(_result, result) &&
          projectionConfirmed()) {
        _confirmation?.cancel();
        controller.acknowledgeLocalFeedback(_feedbackOwner, result: result);
        Navigator.of(context).pop();
      } else {
        _closing = false;
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    _syncFeedbackOwner();
    _confirmProjection();
    setState(() {});
  }

  Future<void> _choose(TunnelMode mode, BuildContext noticeContext) async {
    final controller = widget.controller;
    if (!_eligible || !controller.canChangeMode || _target != null) return;
    if (_storageEpoch == controller.storageEpoch &&
        controller.collection.mode == mode &&
        (!controller.state.usesRuntimeMode || controller.state.mode == mode)) {
      Navigator.of(context).pop();
      return;
    }
    final core = controller.state.core;
    _feedbackOwner.value = false;
    _feedbackPresented = false;
    _submissionCore = core;
    _sourceCurrent = AppTaskActivity.captureSource(context);
    _command = null;
    _result = null;
    _confirmation?.cancel();
    _feedbackOwner.value = true;
    setState(() => _target = mode);
    final pending = controller.submitAndWait({
      'action': 'setMode',
      'mode': mode.name,
      'storageEpoch': _storageEpoch,
    }, feedbackOwner: _feedbackOwner);
    final command = _command = controller.lastCommand;
    final result = await pending;
    if (!mounted) return;
    bool current({ModalRoute<dynamic>? popup}) =>
        mounted &&
        noticeContext.mounted &&
        _feedbackOwner.value &&
        identical(controller.lastCommand, command) &&
        _storageEpoch == controller.storageEpoch &&
        _sourceCurrent?.call() == true;
    if (!current()) {
      _feedbackOwner.value = false;
      setState(() => _target = null);
      return;
    }
    if (result?.resultSuccess == true) {
      _result = result;
      _confirmProjection();
      if (_target != null) {
        _confirmation = Timer(
          const Duration(milliseconds: ApplicationContract.operationUiGraceMs),
          () async {
            if (!current()) return;
            setState(() {
              _target = null;
              _result = null;
            });
            controller.acknowledgeLocalFeedback(_feedbackOwner, result: result);
            final presented = await showAppNotice(
              noticeContext,
              messages.temporaryModeUnknown,
              eligibilityChanges: controller,
              isCurrent: current,
              isCurrentWithPopup: (popup) => current(popup: popup),
              identity: ('mode-projection', command, result!.resultId),
              onRetry: controller.refreshMode,
            );
            if (!presented && mounted) _feedbackOwner.value = false;
          },
        );
      }
      setState(() {});
      return;
    }
    setState(() => _target = null);
    final message =
        result?.resultMessageDescription ??
        controller.commandErrorMessage ??
        (result == null ? null : messages.operationFailed);
    if (message == null) {
      _feedbackOwner.value = false;
      return;
    }
    bool sameResult({ModalRoute<dynamic>? popup}) =>
        current(popup: popup) &&
        (result == null
            ? identical(controller.commandErrorMessage, message)
            : controller.state.resultId == result.resultId);
    if (!noticeContext.mounted) {
      _feedbackOwner.value = false;
      return;
    }
    final presented = await showAppNotice(
      noticeContext,
      message,
      eligibilityChanges: controller,
      isCurrent: sameResult,
      isCurrentWithPopup: (popup) => sameResult(popup: popup),
      identity: ('mode-operation', command, result?.resultId),
      onPresented: () {
        _feedbackPresented = true;
        controller.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      },
    );
    if (!presented && mounted) _feedbackOwner.value = false;
  }

  void _readFeedback(BuildContext feedbackContext) {
    final controller = widget.controller;
    final error = controller.state.modeErrorMessage;
    if (error == null) {
      _modeNotice = null;
      return;
    }
    if (!_eligible || _storageEpoch != controller.storageEpoch) return;
    final core = controller.state.core;
    final epoch = controller.storageEpoch;
    final notice = (controller, epoch, core.identity, error);
    if (_modeNotice == notice) return;
    _modeNotice = notice;
    bool current() =>
        mounted &&
        _modeNotice == notice &&
        _storageEpoch == controller.storageEpoch &&
        _sameContext(controller, epoch, core) &&
        controller.state.modeErrorMessage == error;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current() || !_eligible || !feedbackContext.mounted) {
        if (current()) _modeNotice = null;
        return;
      }
      final presented = await showAppNotice(
        feedbackContext,
        error,
        eligibilityChanges: controller,
        isCurrent: current,
        isCurrentWithPopup: (_) => current(),
        identity: ('mode-read', notice),
        onRetry: () async {
          if (!current() || !_eligible) return;
          _modeNotice = null;
          await controller.refreshMode();
          if (mounted) setState(() {});
        },
      );
      if (!presented && current()) _modeNotice = null;
    });
  }

  @override
  Widget build(BuildContext context) => OperationNoticeHost(
    shrinkWrap: true,
    child: Builder(
      builder: (context) {
        _readFeedback(context);
        return _buildContent(context);
      },
    ),
  );

  Widget _buildContent(BuildContext context) {
    final controller = widget.controller;
    final state = controller.state;
    final epoch = controller.storageEpoch;
    final strings = AppLocalizations.of(context);
    final current = state.usesRuntimeMode
        ? state.mode
        : state.phase == 'STOPPED' && controller.configsCurrent
        ? controller.collection.mode
        : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = ModePalette(theme.brightness == Brightness.dark);
    final enabled = _eligible && controller.canChangeMode && _target == null;
    final differs =
        state.usesRuntimeMode &&
        state.mode != null &&
        controller.configsCurrent &&
        controller.collection.mode != null &&
        state.mode != controller.collection.mode;
    Color categoryColor(TunnelMode mode) => switch (mode) {
      TunnelMode.rule => palette.rule,
      TunnelMode.global => palette.global,
      TunnelMode.direct => palette.direct,
    };
    final descriptionStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.45,
    );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  strings.modeTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.modeHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            for (final mode in TunnelMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  selected: current == mode,
                  child: OutlinedButton(
                    key: ValueKey('mode-${mode.name}'),
                    onPressed: enabled
                        ? () {
                            if (_sameContext(controller, epoch, state.core)) {
                              _choose(mode, context);
                            }
                          }
                        : null,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      backgroundColor: current == mode
                          ? colors.surfaceContainer
                          : colors.surface,
                      foregroundColor: colors.onSurface,
                      disabledForegroundColor: colors.onSurface.withValues(
                        alpha: .65,
                      ),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: categoryColor(mode)
                                .withValues(alpha: enabled ? .10 : .04),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            switch (mode) {
                              TunnelMode.rule => Icons.alt_route_rounded,
                              TunnelMode.global => Icons.public_outlined,
                              TunnelMode.direct => Icons.arrow_forward_rounded,
                            },
                            size: 22,
                            color: categoryColor(mode)
                                .withValues(alpha: enabled ? 1 : .38),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Text(
                                  [
                                    mode.label(strings),
                                    if (differs &&
                                        controller.collection.mode == mode)
                                      strings.modeFallbackLabel,
                                  ].join(' · '),
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: current == mode
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                mode.description(strings),
                                style: descriptionStyle,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _routeChanges?.removeListener(_syncFeedbackOwner);
    _confirmation?.cancel();
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    super.dispose();
  }
}
