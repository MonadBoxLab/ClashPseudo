import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../legal/app_legal.dart';
import '../locale/message_text.dart';
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
  final _writeFailure = ValueNotifier<AppMessage?>(null);
  bool _needed = false;
  bool _opened = false;
  bool _queued = false;
  bool _markAttempted = false;
  AppMessage? _pendingFailure;
  BuildContext? _dialogContext;
  Animation<double>? _dialogAnimation;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      // Unknown is not absence. File work never gates application startup.
      _needed = !await widget.controller.platform.privacyNoticeShown();
    } catch (failure) {
      _pendingFailure = messages.privacyNoticeNotSaved.withDetail(failure);
    }
    _schedule();
  }

  void _schedule() {
    if (!mounted || _queued || (!_needed && _pendingFailure == null)) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || !widget.controller.interactive) return;
      if (_pendingFailure != null &&
          ModalRoute.of(context)?.isCurrent == true) {
        final failure = _pendingFailure!;
        _pendingFailure = null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Builder(
              builder: (context) =>
                  Text(failure.resolve(AppLocalizations.of(context))),
            ),
          ),
        );
      }
      if (!_needed) return;
      if (!_opened) {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        _opened = true;
        unawaited(
          showDialog<void>(
            context: context,
            animationStyle: MediaQuery.disableAnimationsOf(context)
                ? AnimationStyle.noAnimation
                : null,
            builder: (context) {
              _dialogContext = context;
              final animation = ModalRoute.of(context)?.animation;
              if (!identical(animation, _dialogAnimation)) {
                _dialogAnimation?.removeListener(_schedule);
                _dialogAnimation = animation;
                animation?.addListener(_schedule);
              }
              _schedule();
              return ValueListenableBuilder<AppMessage?>(
                valueListenable: _writeFailure,
                builder: (_, failure, _) =>
                    PrivacyNoticeDialog(persistenceFailure: failure),
              );
            },
          ).whenComplete(() {
            _dialogAnimation?.removeListener(_schedule);
            _dialogAnimation = null;
            _dialogContext = null;
            _needed = false;
            _schedule();
          }),
        );
      } else {
        final dialog = _dialogContext;
        final route = dialog == null || !dialog.mounted
            ? null
            : ModalRoute.of(dialog);
        if (!_markAttempted &&
            route?.isCurrent == true &&
            route?.animation?.status != AnimationStatus.reverse &&
            (route?.animation?.value ?? 0) > 0) {
          // A real foreground frame has painted the prompt. No button or
          // completed entrance animation is required; dismissal never cancels I/O.
          _markAttempted = true;
          _dialogAnimation?.removeListener(_schedule);
          unawaited(_mark());
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _mark() async {
    try {
      await widget.controller.platform.markPrivacyNoticeShown();
    } catch (failure) {
      if (!mounted) return;
      final message = messages.privacyNoticeNotSaved.withDetail(failure);
      final dialog = _dialogContext;
      final route = dialog == null || !dialog.mounted
          ? null
          : ModalRoute.of(dialog);
      if (route != null && route.animation?.status != AnimationStatus.reverse) {
        _writeFailure.value = message;
      } else {
        _pendingFailure = message;
        _schedule();
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_schedule);
    _dialogAnimation?.removeListener(_schedule);
    _writeFailure.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ModalRoute eligibility changes also rebuild this host on a return.
    _schedule();
    return widget.child;
  }
}
