import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'status_text.dart';

({String clock, String days}) uptimeText(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  String pair(int value) => value.toString().padLeft(2, '0');
  return (
    clock:
        '${pair(seconds ~/ 3600 % 24)}:${pair(seconds ~/ 60 % 60)}:${pair(seconds % 60)}',
    days: (seconds ~/ 86400).toString(),
  );
}

class SessionUptime extends StatefulWidget {
  const SessionUptime({
    super.key,
    required this.snapshot,
    required this.active,
    required this.showUptime,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.refresh,
    this.onIssue,
    this.clock,
  });

  final AppSnapshot snapshot;
  final bool active;
  final bool showUptime;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback refresh;
  final VoidCallback? onIssue;
  final Stopwatch? clock;

  @override
  State<SessionUptime> createState() => _SessionUptimeState();
}

class _SessionUptimeState extends State<SessionUptime> {
  late final _sinceSample = widget.clock ?? Stopwatch();
  Timer? _timer;
  bool _awaitingSample = false;
  late int _sampleAge;

  @override
  void initState() {
    super.initState();
    _sampleAge = widget.snapshot.uptimeSampleAgeMilliseconds;
    _sinceSample.start();
    _schedule();
  }

  @override
  void didUpdateWidget(SessionUptime oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.snapshot;
    final current = widget.snapshot;
    final newSample =
        current.generation != previous.generation ||
        current.runningSinceElapsedMs != previous.runningSinceElapsedMs ||
        current.elapsedRealtimeMs != previous.elapsedRealtimeMs;
    if (newSample) {
      _sampleAge = current.uptimeSampleAgeMilliseconds;
      _sinceSample.reset();
      _awaitingSample = false;
    }
    if (!oldWidget.active && widget.active && !newSample && current.running) {
      // Stopwatch interpolates while visible; refresh the platform sample to include
      // device sleep.
      _awaitingSample = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active && _awaitingSample) widget.refresh();
      });
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active ||
        !widget.showUptime ||
        _awaitingSample ||
        widget.snapshot.uptimeMilliseconds == null) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final sample = widget.snapshot.uptimeMilliseconds;
    final show = widget.showUptime && sample != null && !_awaitingSample;
    var title = widget.title;
    var subtitle = widget.subtitle;
    if (show) {
      final duration = uptimeText(
        sample + _sampleAge + _sinceSample.elapsedMilliseconds,
      );
      final units = duration.clock.split(':');
      title = strings.uptimeClock(units[0], units[1], units[2]);
      subtitle = duration.days == '0'
          ? strings.uptimeRunning
          : strings.uptimeDays(duration.days);
    } else if (_awaitingSample && widget.showUptime) {
      subtitle = strings.statusPending;
    }
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        key: const ValueKey('status-details'),
        container: widget.onIssue != null,
        explicitChildNodes: true,
        label: widget.onIssue == null ? null : subtitle,
        button: widget.onIssue != null,
        onTap: widget.onIssue,
        child: InkWell(
          onTap: widget.onIssue,
          excludeFromSemantics: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Semantics(
                  container: true,
                  child: StatusText(
                    title,
                    key: const ValueKey('uptime-title'),
                    animate: !show,
                    style: TextStyle(
                      color: widget.color,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ExcludeSemantics(
                  excluding: widget.onIssue != null,
                  child: Semantics(
                    container: true,
                    child: StatusText(
                      subtitle,
                      key: const ValueKey('uptime-subtitle'),
                      emptyText: strings.statusReady,
                      animate: !show,
                      style: TextStyle(
                        color: widget.color,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sinceSample.stop();
    super.dispose();
  }
}
