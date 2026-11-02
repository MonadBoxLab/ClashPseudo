import 'dart:async';

import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/logic/overrides/loon_converter.dart';

Future<void> openImport(
  BuildContext context,
  AppController controller, {
  String? source,
  int? storageEpoch,
  bool Function()? isCurrent,
}) async {
  final epoch = storageEpoch ?? controller.storageEpoch;
  final originRoute = ModalRoute.of(context);
  ModalRoute<dynamic>? ownedPopup;
  bool eligible() =>
      context.mounted &&
      controller.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
      AppTaskActivity.routeIsActive(originRoute, ownedPopup: ownedPopup) &&
      (isCurrent?.call() ?? true);
  if (!eligible()) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<Map<String, Object?>>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dialogContext) => OperationNoticeHost(
      onDismiss: () {
        if (ownedPopup?.isCurrent == true) {
          Navigator.of(dialogContext).maybePop();
        }
      },
      child: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => ImportDialog(
          source: source,
          storageEpoch: epoch,
          isCurrent: eligible,
          onSubmit: (input) async {
            if (!eligible()) {
              return false;
            }
            final receipt = await controller.submit({
              'action': 'import',
              ...input,
              'storageEpoch': epoch,
            });
            return receipt != null;
          },
        ),
      ),
    ),
  );
  ownedPopup = route;
  try {
    await navigator.push(route);
  } finally {
    ownedPopup = null;
  }
}

class ImportDialog extends StatefulWidget {
  const ImportDialog({
    super.key,
    this.source,
    this.fragment = false,
    this.editingSource = false,
    this.proxyName = '',
    this.addNoResolve = false,
    this.storageEpoch,
    this.onSubmit,
    this.isCurrent,
  }) : assert(!editingSource || fragment);
  final bool Function()? isCurrent;
  final String? source;
  final bool fragment;
  final bool editingSource;
  final String proxyName;
  final bool addNoResolve;
  final int? storageEpoch;

  /// Returns admission. Refusal preserves the form and input; the global reader
  /// presents the operation error. Download and save completion use their own results.
  final Future<bool> Function(Map<String, Object?> input)? onSubmit;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late final _source = TextEditingController(text: widget.source);
  late final _proxyName = TextEditingController(text: widget.proxyName);
  final _sourceFocus = FocusNode();
  final _proxyFocus = FocusNode();
  late bool _addNoResolve = widget.addNoResolve;
  late final int? _storageEpoch;
  bool _submitting = false;
  final _name = TextEditingController();
  AppMessage? _error;
  AppMessage? _proxyError;
  bool _obscured = true;
  ModalRoute<dynamic>? _route;
  bool get _liveRoute =>
      mounted &&
      (_route?.isActive ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse;
  bool get _eligible =>
      _liveRoute &&
      (_route?.isCurrent ?? true) &&
      AppTaskActivity.isActive(context, ownedPopup: _route) &&
      (widget.isCurrent?.call() ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  int get _nameLength => configNameBytes(_name.text);

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch;
  }

  @override
  void dispose() {
    _sourceFocus.dispose();
    _proxyFocus.dispose();
    _source.dispose();
    _proxyName.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_eligible || _nameLength > maxConfigNameBytes) return;
    final submittedSource = _source.text;
    final submittedName = _name.text;
    final submittedProxy = _proxyName.text;
    final submittedNoResolve = _addNoResolve;
    final Map<String, Object?> input;
    try {
      ConfigDownloader.sourceUri(submittedSource);
      if (submittedName.isNotEmpty && !validConfigName(submittedName)) {
        throw ConfigFailure(messages.nameInvalid);
      }
      if (widget.fragment) checkLoonProxyName(submittedProxy);
      input = {
        'source': submittedSource,
        if (!widget.editingSource) 'name': submittedName,
        if (widget.fragment) ...{
          'proxyName': submittedProxy,
          'addNoResolve': submittedNoResolve,
        },
        if (_storageEpoch != null) 'storageEpoch': _storageEpoch,
      };
    } on ConfigFailure catch (failure) {
      final message = failure.message;
      setState(() => _error = message);
      _showValidation(
        message,
        _sourceFocus,
        _source,
        () => identical(_error, message) && _source.text == submittedSource,
      );
      return;
    } on LoonConversionException {
      final message = messages.loonProxyNameInvalid;
      setState(() => _proxyError = message);
      _showValidation(
        message,
        _proxyFocus,
        _proxyName,
        () =>
            identical(_proxyError, message) &&
            _proxyName.text == submittedProxy,
      );
      return;
    }
    final submit = widget.onSubmit;
    if (submit == null) {
      Navigator.pop(context, input);
      return;
    }
    final route = ModalRoute.of(context);
    setState(() => _submitting = true);
    try {
      final accepted = await submit(input);
      if (!mounted) return;
      if (accepted &&
          _source.text == submittedSource &&
          _name.text == submittedName &&
          _proxyName.text == submittedProxy &&
          _addNoResolve == submittedNoResolve) {
        if (_liveRoute && route != null && route.isActive) {
          final navigator = Navigator.of(context);
          if (route.isCurrent) {
            navigator.pop(input);
          } else {
            // After acceptance, retire only this form's captured route.
            navigator.removeRoute(route, input);
          }
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showValidation(
    AppMessage message,
    FocusNode focus,
    TextEditingController controller,
    bool Function() current,
  ) {
    focus.requestFocus();
    final target = focus.context;
    if (target != null) {
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    }
    unawaited(
      showAppNotice(
        context,
        message,
        error: false,
        persist: true,
        identity: (focus, message),
        eligibilityChanges: controller,
        isCurrent: () => _eligible && current(),
      ),
    );
  }

  InputDecoration _validated(InputDecoration decoration, AppMessage? error) {
    if (error == null) return decoration;
    final theme = Theme.of(context);
    final defaults = decoration.applyDefaults(theme.inputDecorationTheme);
    final border = defaults.border ?? const UnderlineInputBorder();
    return decoration.copyWith(
      enabledBorder: (defaults.enabledBorder ?? border).copyWith(
        borderSide: BorderSide(color: theme.colorScheme.error),
      ),
      focusedBorder: (defaults.focusedBorder ?? border).copyWith(
        borderSide: BorderSide(color: theme.colorScheme.error, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final ownRoute = ModalRoute.of(context);
    final dialog = AlertDialog(
      title: Text(
        widget.editingSource
            ? strings.changeSource
            : widget.fragment
            ? strings.remoteOverride
            : strings.importFullConfig,
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fragment
                    ? strings.overrideNotice
                    : strings.importFullConfigNotice,
              ),
              const SizedBox(height: 20),
              Semantics(
                validationResult: _error == null
                    ? SemanticsValidationResult.none
                    : SemanticsValidationResult.invalid,
                hint: _error?.summary(strings),
                child: TextField(
                  key: const ValueKey('import-source'),
                  controller: _source,
                  focusNode: _sourceFocus,
                  obscureText: _obscured,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  decoration: _validated(
                    InputDecoration(
                      labelText: strings.configUrl,
                      suffixIcon: IconButton(
                        tooltip: _obscured ? strings.showUrl : strings.hideUrl,
                        onPressed: () {
                          if (_eligible) setState(() => _obscured = !_obscured);
                        },
                        icon: Icon(
                          _obscured
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    _error,
                  ),
                  onChanged: (_) {
                    if (_eligible && _error != null) {
                      setState(() => _error = null);
                    }
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (!widget.editingSource) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  onChanged: (_) {
                    if (_eligible) setState(() {});
                  },
                  decoration: InputDecoration(
                    labelText: strings.nameOptional,
                    helperText: strings.nameOptionalHint,
                    counterText: '$_nameLength/$maxConfigNameBytes B',
                  ),
                ),
              ],
              if (widget.fragment) ...[
                const SizedBox(height: 16),
                Semantics(
                  validationResult: _proxyError == null
                      ? SemanticsValidationResult.none
                      : SemanticsValidationResult.invalid,
                  hint: _proxyError?.summary(strings),
                  child: TextField(
                    key: const ValueKey('loon-proxy-name'),
                    controller: _proxyName,
                    focusNode: _proxyFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) {
                      if (_eligible && _proxyError != null) {
                        setState(() => _proxyError = null);
                      }
                    },
                    decoration: _validated(
                      InputDecoration(
                        labelText: strings.loonProxyName,
                        helper: Text(strings.loonProxyNameHint),
                      ),
                      _proxyError,
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('loon-no-resolve'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(strings.loonAddNoResolve),
                  value: _addNoResolve,
                  onChanged: (value) {
                    if (_eligible) setState(() => _addNoResolve = value!);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting || !_eligible
              ? null
              : () {
                  if (_eligible) Navigator.pop(context);
                },
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed:
              _eligible &&
                  !_submitting &&
                  (_name.text.isEmpty || validConfigName(_name.text))
              ? _submit
              : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: _submitting ? 0 : 1,
                alwaysIncludeSemantics: true,
                child: Text(
                  widget.editingSource
                      ? strings.saveAndUpdate
                      : strings.downloadAndSave,
                ),
              ),
              TickerMode(
                enabled: ownRoute?.isCurrent ?? true,
                child: SizedBox.square(
                  dimension: 18,
                  child: _submitting
                      ? CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: strings.statusSubmitting,
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return AnimatedBuilder(
      animation: _route?.animation ?? const AlwaysStoppedAnimation<double>(1),
      builder: (_, child) {
        final active = _eligible;
        return IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child!),
          ),
        );
      },
      child: dialog,
    );
  }
}
