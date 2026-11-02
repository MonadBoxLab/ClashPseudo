import 'dart:async';

import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';

class ConfigFieldDialog extends StatefulWidget {
  const ConfigFieldDialog({
    super.key,
    required this.initial,
    this.source = false,
    this.title,
    this.confirmLabel,
    this.onSubmit,
    this.isCurrent,
  });
  final Future<bool> Function(String value)? onSubmit;
  final bool Function()? isCurrent;
  final String Function(AppLocalizations)? confirmLabel;
  final String Function(AppLocalizations)? title;
  final String initial;
  final bool source;

  @override
  State<ConfigFieldDialog> createState() => _ConfigFieldDialogState();
}

class _ConfigFieldDialogState extends State<ConfigFieldDialog> {
  late final _text = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  AppMessage? _error;
  bool _obscured = true;
  bool _submitting = false;
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

  int get _nameLength => configNameBytes(_text.text);

  Future<void> _submit() async {
    if (_submitting || !_eligible) return;
    final original = _text.text;
    final String value;
    if (widget.source) {
      try {
        ConfigDownloader.sourceUri(original);
        value = original;
      } on ConfigFailure catch (failure) {
        final message = failure.message;
        setState(() => _error = message);
        _focus.requestFocus();
        unawaited(
          showAppNotice(
            context,
            message,
            error: false,
            persist: true,
            identity: (original, message),
            eligibilityChanges: _text,
            isCurrent: () =>
                _eligible &&
                _text.text == original &&
                identical(_error, message),
          ),
        );
        return;
      }
    } else {
      if (!validConfigName(original)) return;
      value = original;
    }
    final submit = widget.onSubmit;
    if (submit == null) {
      Navigator.pop(context, value);
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    setState(() => _submitting = true);
    try {
      final accepted = await submit(value);
      if (accepted && _liveRoute && _text.text == original) {
        if (route?.isCurrent == true) {
          navigator.pop(value);
        } else if (route?.isActive == true) {
          navigator.removeRoute(route!, value);
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final decoration = theme.inputDecorationTheme;
    final border = decoration.border ?? const UnderlineInputBorder();
    final dialog = AlertDialog(
      scrollable: true,
      title: Text(
        widget.title?.call(strings) ??
            (widget.source ? strings.changeConfigSource : strings.renameConfig),
      ),
      content: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            validationResult: _error == null
                ? SemanticsValidationResult.none
                : SemanticsValidationResult.invalid,
            hint: _error?.summary(strings),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              autofocus: true,
              obscureText: widget.source && _obscured,
              autocorrect: !widget.source,
              enableSuggestions: !widget.source,
              keyboardType: widget.source
                  ? TextInputType.url
                  : TextInputType.text,
              onChanged: (_) {
                if (_eligible) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: widget.source
                    ? strings.configUrl
                    : strings.definitionFormName,
                counterText: widget.source
                    ? null
                    : '$_nameLength/$maxConfigNameBytes B',
                suffixIcon: widget.source
                    ? IconButton(
                        tooltip: _obscured ? strings.showUrl : strings.hideUrl,
                        onPressed: () {
                          if (_eligible) setState(() => _obscured = !_obscured);
                        },
                        icon: Icon(
                          _obscured
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      )
                    : null,
                enabledBorder: _error == null
                    ? null
                    : (decoration.enabledBorder ?? border).copyWith(
                        borderSide: BorderSide(color: theme.colorScheme.error),
                      ),
                focusedBorder: _error == null
                    ? null
                    : (decoration.focusedBorder ?? border).copyWith(
                        borderSide: BorderSide(
                          color: theme.colorScheme.error,
                          width: 2,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_eligible) Navigator.pop(context);
          },
          child: Text(strings.cancel),
        ),
        TextButton(
          onPressed:
              _eligible &&
                  !_submitting &&
                  (widget.source || validConfigName(_text.text))
              ? _submit
              : null,
          child: Text(
            widget.confirmLabel?.call(strings) ??
                (widget.source ? strings.saveAndUpdate : strings.save),
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

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }
}
