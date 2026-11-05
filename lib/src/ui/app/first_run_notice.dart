import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/messages.dart';
import '../components/feedback/operation_notice.dart';
import '../legal/app_legal.dart';
import '../navigation/route_observer.dart';
import '../navigation/task_activity.dart';
import 'app_controller.dart';

class FirstRunNotice extends StatefulWidget {
  const FirstRunNotice({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  State<FirstRunNotice> createState() => _FirstRunNoticeState();
}

class _FirstRunNoticeState extends State<FirstRunNotice> {
  final _noticeChanges = ValueNotifier(0);
  bool _needed = false;
  bool _opened = false;
  bool _queued = false;
  bool _markAttempted = false;
  bool _reading = false;
  bool _readAgain = false;
  bool _marking = false;
  bool _readNoticed = false;
  bool _writeNoticed = false;
  bool _readNotifying = false;
  bool _writeNotifying = false;
  int _readFailures = 0;
  int _readVersion = 0;
  int _writeVersion = 0;
  Object? _readFailure;
  AppMessage? _writeFailure;
  Timer? _readDeadline;
  Timer? _readRetry;
  BuildContext? _hostContext;
  BuildContext? _dialogContext;
  Animation<double>? _dialogAnimation;
  Listenable? _routeChanges;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    unawaited(_read());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final changes = AppTaskNavigatorObserver.changesFor(ModalRoute.of(context));
    if (!identical(_routeChanges, changes)) {
      _routeChanges?.removeListener(_schedule);
      _routeChanges = changes;
      _routeChanges?.addListener(_schedule);
    }
    _schedule();
  }

  Future<void> _read({bool reportFailure = false}) async {
    if (_reading) {
      _readAgain |= reportFailure;
      return;
    }
    _readRetry?.cancel();
    _readRetry = null;
    _reading = true;
    var failed = false;
    void failure(Object error) {
      if (!mounted) return;
      if (!failed) _readFailures++;
      failed = true;
      if (_readFailure?.toString() != error.toString() || reportFailure) {
        _readFailure = error;
        _readVersion++;
        _readNoticed = false;
        _noticeChanges.value++;
      }
      _schedule();
    }

    _readDeadline = Timer(const Duration(seconds: 5), () {
      failure(
        TimeoutException('Reading privacy notice status is still in progress'),
      );
    });
    try {
      final shown = await widget.controller.platform.privacyNoticeShown();
      if (!mounted) return;
      _needed = !shown;
      _readFailures = 0;
      _readAgain = false;
      if (_readFailure != null) {
        _readFailure = null;
        _readVersion++;
        _noticeChanges.value++;
      }
    } catch (error) {
      failure(error);
    } finally {
      _readDeadline?.cancel();
      _readDeadline = null;
      _reading = false;
      if (mounted) {
        if (_readAgain &&
            _readFailure != null &&
            widget.controller.interactive) {
          _readAgain = false;
          unawaited(_read(reportFailure: true));
        } else {
          _schedule();
        }
      }
    }
  }

  void _scheduleRetry() {
    if (!widget.controller.interactive) {
      _readRetry?.cancel();
      _readRetry = null;
      return;
    }
    if (_readFailure == null || _reading || _readRetry?.isActive == true) {
      return;
    }
    if (_readAgain) {
      _readAgain = false;
      unawaited(_read(reportFailure: true));
      return;
    }
    const seconds = [1, 2, 5, 10, 30];
    final delay = seconds[(_readFailures - 1).clamp(0, seconds.length - 1)];
    _readRetry = Timer(Duration(seconds: delay), () {
      _readRetry = null;
      if (mounted && widget.controller.interactive) unawaited(_read());
    });
  }

  Future<void> _showReadFailure(
    BuildContext target,
    Object failure,
    int version,
  ) async {
    _readNotifying = true;
    final route = ModalRoute.of(target);
    bool current({ModalRoute<dynamic>? popup}) =>
        mounted &&
        target.mounted &&
        widget.controller.interactive &&
        _readFailure != null &&
        version == _readVersion &&
        AppTaskActivity.routeIsActive(route, ownedPopup: popup);
    final shown = await showLocalizedOperationNotice(
      target,
      (strings) => strings.privacyNoticeReadFailed,
      technicalDetail: (_) => failure.toString(),
      title: (strings) => strings.privacyNoticeTitle,
      eligibilityChanges: Listenable.merge([widget.controller, _noticeChanges]),
      isCurrent: current,
      isCurrentWithPopup: (popup) => current(popup: popup),
      onRetry: () => _read(reportFailure: true),
      identity: ('privacy-notice-read', version),
    );
    _readNotifying = false;
    if (!mounted) return;
    if (shown && version == _readVersion) _readNoticed = true;
    _schedule();
  }

  Future<void> _showWriteFailure(
    BuildContext target,
    AppMessage failure,
    int version,
  ) async {
    _writeNotifying = true;
    final route = ModalRoute.of(target);
    bool current({ModalRoute<dynamic>? popup}) =>
        mounted &&
        target.mounted &&
        widget.controller.interactive &&
        _writeFailure != null &&
        version == _writeVersion &&
        AppTaskActivity.routeIsActive(route, ownedPopup: popup);
    final shown = await showAppNotice(
      target,
      failure,
      title: (strings) => strings.privacyNoticeTitle,
      eligibilityChanges: Listenable.merge([widget.controller, _noticeChanges]),
      isCurrent: current,
      isCurrentWithPopup: (popup) => current(popup: popup),
      onRetry: _mark,
      identity: ('privacy-notice-write', version),
    );
    _writeNotifying = false;
    if (!mounted) return;
    if (shown && version == _writeVersion) _writeNoticed = true;
    _schedule();
  }

  void _schedule() {
    if (!mounted) return;
    _scheduleRetry();
    if (_queued ||
        (!_needed &&
            (_readFailure == null || _readNoticed || _readNotifying) &&
            (_writeFailure == null || _writeNoticed || _writeNotifying))) {
      return;
    }
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || !widget.controller.interactive) return;
      final host = _hostContext;
      final hostRoute = host == null || !host.mounted
          ? null
          : ModalRoute.of(host);
      if (_readFailure case final failure?) {
        if (!_readNoticed && !_readNotifying && hostRoute?.isCurrent == true) {
          unawaited(_showReadFailure(host!, failure, _readVersion));
        }
      }
      final dialog = _dialogContext;
      final dialogRoute = dialog == null || !dialog.mounted
          ? null
          : ModalRoute.of(dialog);
      if (_writeFailure case final failure?) {
        if (!_writeNoticed && !_writeNotifying) {
          if (dialogRoute?.isCurrent == true &&
              dialogRoute?.animation?.status != AnimationStatus.reverse) {
            unawaited(_showWriteFailure(dialog!, failure, _writeVersion));
          } else if (hostRoute?.isCurrent == true) {
            unawaited(_showWriteFailure(host!, failure, _writeVersion));
          }
        }
      }
      if (!_needed) return;
      if (!_opened) {
        if (hostRoute?.isCurrent != true) return;
        _opened = true;
        unawaited(
          showDialog<void>(
            context: host!,
            animationStyle: MediaQuery.disableAnimationsOf(host)
                ? AnimationStyle.noAnimation
                : null,
            builder: (dialogContext) => OperationNoticeHost(
              onDismiss: () => Navigator.of(dialogContext).maybePop(),
              child: Builder(
                builder: (context) {
                  _dialogContext = context;
                  final animation = ModalRoute.of(context)?.animation;
                  if (!identical(animation, _dialogAnimation)) {
                    _dialogAnimation?.removeListener(_schedule);
                    _dialogAnimation = animation;
                    animation?.addListener(_schedule);
                  }
                  _schedule();
                  return const PrivacyNoticeDialog();
                },
              ),
            ),
          ).whenComplete(() {
            _dialogAnimation?.removeListener(_schedule);
            _dialogAnimation = null;
            _dialogContext = null;
            _needed = false;
            _schedule();
          }),
        );
      } else if (!_markAttempted &&
          dialogRoute?.isCurrent == true &&
          dialogRoute?.animation?.status != AnimationStatus.reverse &&
          (dialogRoute?.animation?.value ?? 0) > 0) {
        _markAttempted = true;
        _dialogAnimation?.removeListener(_schedule);
        unawaited(_mark());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _mark() async {
    if (_marking) return;
    _marking = true;
    try {
      await widget.controller.platform.markPrivacyNoticeShown();
      if (!mounted) return;
      if (_writeFailure != null) {
        _writeFailure = null;
        _writeVersion++;
        _noticeChanges.value++;
      }
    } catch (failure) {
      if (!mounted) return;
      _writeFailure = messages.privacyNoticeNotSaved.withDetail(failure);
      _writeVersion++;
      _writeNoticed = false;
      _noticeChanges.value++;
    } finally {
      _marking = false;
      if (mounted) _schedule();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_schedule);
    _routeChanges?.removeListener(_schedule);
    _dialogAnimation?.removeListener(_schedule);
    _readDeadline?.cancel();
    _readRetry?.cancel();
    _noticeChanges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return OperationNoticeHost(
      shrinkWrap: true,
      child: Builder(
        builder: (context) {
          _hostContext = context;
          return widget.child;
        },
      ),
    );
  }
}
