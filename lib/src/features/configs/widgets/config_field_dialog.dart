import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/messages.dart';
import '../config_downloader.dart';
import '../config_entry.dart';
import '../config_text.dart';

class ConfigFieldDialog extends StatefulWidget {
  const ConfigFieldDialog({
    super.key,
    required this.initial,
    this.source = false,
    this.title,
    this.confirmLabel,
    this.onSubmit,
  });
  final Future<bool> Function(String value)? onSubmit;
  final String Function(AppLocalizations)? confirmLabel;
  final String Function(AppLocalizations)? title;
  final String initial;
  final bool source;

  @override
  State<ConfigFieldDialog> createState() => _ConfigFieldDialogState();
}

class _ConfigFieldDialogState extends State<ConfigFieldDialog> {
  late final _text = TextEditingController(text: widget.initial);
  AppMessage? _error;
  bool _obscured = true;
  bool _submitting = false;
  int get _nameLength => configNameBytes(_text.text);

  Future<void> _submit() async {
    if (_submitting) return;
    final original = _text.text;
    final String value;
    if (widget.source) {
      try {
        value = ConfigDownloader.sourceUri(original).toString();
      } on ConfigFailure catch (failure) {
        setState(() => _error = failure.message);
        return;
      }
    } else {
      if (_nameLength == 0 || _nameLength > maxConfigNameBytes) return;
      value = original.trim();
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
      if (accepted && mounted && _text.text == original) {
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
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.title?.call(strings) ??
            (widget.source ? strings.changeConfigSource : strings.renameConfig),
      ),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _text,
          autofocus: true,
          obscureText: widget.source && _obscured,
          autocorrect: !widget.source,
          enableSuggestions: !widget.source,
          keyboardType: widget.source ? TextInputType.url : TextInputType.text,
          onChanged: (_) => setState(() => _error = null),
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
                    onPressed: () => setState(() => _obscured = !_obscured),
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  )
                : null,
            helper: widget.source
                ? SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(12) * 2.4,
                    child: Semantics(
                      liveRegion: _error != null,
                      child: SingleChildScrollView(
                        child: Text(
                          _error?.resolve(strings) ?? strings.configUrlHint,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color: _error == null
                                ? null
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        TextButton(
          onPressed:
              !_submitting &&
                  (widget.source ||
                      (_nameLength > 0 && _nameLength <= maxConfigNameBytes))
              ? _submit
              : null,
          child: Text(
            widget.confirmLabel?.call(strings) ??
                (widget.source ? strings.saveAndUpdate : strings.save),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
