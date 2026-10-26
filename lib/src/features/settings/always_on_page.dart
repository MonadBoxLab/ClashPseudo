import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../l10n/app_localizations.dart';

class AlwaysOnPage extends StatefulWidget {
  const AlwaysOnPage({super.key, required this.app});
  final AppController app;
  @override
  State<AlwaysOnPage> createState() => _AlwaysOnPageState();
}

class _AlwaysOnPageState extends State<AlwaysOnPage> {
  bool _loading = true;
  bool? _alwaysOn;
  bool? _lockdown;
  int _request = 0;
  late bool _foreground;
  late (int, String) _session;

  @override
  void initState() {
    super.initState();
    _foreground = widget.app.foreground;
    _session = (widget.app.state.generation, widget.app.state.phase);
    widget.app.addListener(_appChanged);
    unawaited(_load());
  }

  void _appChanged() {
    final foreground = widget.app.foreground;
    final session = (widget.app.state.generation, widget.app.state.phase);
    if (_foreground == foreground && _session == session) return;
    _foreground = foreground;
    _session = session;
    if (foreground) {
      unawaited(_load());
    } else {
      _request++;
      setState(() {
        _loading = false;
        _alwaysOn = null;
        _lockdown = null;
      });
    }
  }

  @override
  void dispose() {
    _request++;
    widget.app.removeListener(_appChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.app.foreground) return;
    final request = ++_request;
    setState(() => _loading = true);
    try {
      final value = await widget.app.platform.vpnStatus().timeout(
        const Duration(seconds: 5),
      );
      if (!mounted || request != _request || !widget.app.foreground) return;
      setState(() {
        _alwaysOn = value['alwaysOn'] as bool?;
        _lockdown = value['lockdown'] as bool?;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request || !widget.app.foreground) return;
      setState(() {
        _alwaysOn = null;
        _lockdown = null;
        _loading = false;
      });
    }
  }

  Future<void> _open() async {
    try {
      await widget.app.platform.openVpnSettings();
      if (mounted && widget.app.foreground) unawaited(_load());
    } catch (_) {
      if (!mounted) return;
      await showLocalizedOperationMessage(
        context,
        (strings) => strings.alwaysOnOpenFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final icons = SettingsPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    String state(bool? value, {required String on, required String off}) =>
        _loading
        ? strings.runtimeConfigLoading
        : value == null
        ? strings.alwaysOnUnknown
        : value
        ? on
        : off;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.alwaysOnTitle),
        actions: [
          IconButton(
            tooltip: strings.refresh,
            onPressed: _loading || !widget.app.foreground ? null : _load,
            color: HomePalette.of(context).syncAction,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  strings.alwaysOnNotice,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(height: 1.5),
                ),
                const SizedBox(height: 20),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.shield_outlined,
                          color: icons.network,
                        ),
                        title: Text(strings.alwaysOnTitle),
                        subtitle: _StableStatus(
                          text: state(
                            _alwaysOn,
                            on: strings.alwaysOnEnabled,
                            off: strings.alwaysOnDisabled,
                          ),
                          candidates: [
                            strings.runtimeConfigLoading,
                            strings.alwaysOnUnknown,
                            strings.alwaysOnEnabled,
                            strings.alwaysOnDisabled,
                          ],
                        ),
                      ),
                      ListTile(
                        leading: Icon(
                          Icons.lock_outline,
                          color: icons.extension,
                        ),
                        title: Text(strings.lockdownTitle),
                        subtitle: _StableStatus(
                          text: state(
                            _lockdown,
                            on: strings.lockdownEnabled,
                            off: strings.lockdownDisabled,
                          ),
                          candidates: [
                            strings.runtimeConfigLoading,
                            strings.alwaysOnUnknown,
                            strings.lockdownEnabled,
                            strings.lockdownDisabled,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  strings.lockdownNotice,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Text(
                  strings.alwaysOnRestoreNotice,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('always-on-settings'),
                  onPressed: _open,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(strings.openVpnSettings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reserve the lines needed by all states at the actual width and text scale.
class _StableStatus extends StatelessWidget {
  const _StableStatus({required this.text, required this.candidates});

  final String text;
  final List<String> candidates;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        var height = 0.0;
        for (final candidate in candidates) {
          final painter = TextPainter(
            text: TextSpan(text: candidate, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          height = math.max(height, painter.height);
          painter.dispose();
        }
        return SizedBox(
          height: height,
          child: Align(
            alignment: AlignmentDirectional.topStart,
            child: Text(text, style: style),
          ),
        );
      },
    );
  }
}
