import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/messages.dart';

import '../../../app/app_controller.dart';
import '../config_downloader.dart';
import '../config_entry.dart';
import '../config_text.dart';
import '../../overrides/loon_converter.dart';
import 'confirm_action.dart';

Future<void> openImport(
  BuildContext context,
  AppController controller, {
  String? source,
  int? storageEpoch,
}) async {
  final epoch = storageEpoch ?? controller.storageEpoch;
  await showDialog<Map<String, Object?>>(
    context: context,
    builder: (_) => ImportDialog(
      source: source,
      storageEpoch: epoch,
      onSubmit: (input) async {
        if (!context.mounted) return false;
        final uri = ConfigDownloader.sourceUri(input['source'] as String);
        final existing = controller.collection.entries
            .where((e) => e.source == uri.toString())
            .firstOrNull;
        if (existing != null) {
          final state = controller.state;
          final accepted = await confirmAction(
            context,
            title: (strings) => strings.overwriteConfigTitle,
            subject: existing.name,
            message: (strings) {
              final consequence = !state.confirmed
                  ? strings.overwriteUnconfirmed
                  : state.running && state.configId == existing.id
                  ? strings.overwriteStopTunnel
                  : state.running
                  ? strings.overwriteNoOtherTunnel
                  : strings.overwriteNotStart;
              return '${strings.overwriteConfigMessage}'
                  '\n\n${strings.overwriteKeepsOnFailure}\n$consequence';
            },
            confirmLabel: (strings) => strings.overwrite,
          );
          if (!accepted || !context.mounted) return false;
        }
        final receipt = await controller.submit({
          'action': 'import',
          ...input,
          'source': uri.toString(),
          'replace': existing != null,
          'storageEpoch': epoch,
        });
        return receipt != null;
      },
    ),
  );
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
  }) : assert(!editingSource || fragment);
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
  late bool _addNoResolve = widget.addNoResolve;
  late final int? _storageEpoch;
  bool _submitting = false;
  final _name = TextEditingController();
  AppMessage? _error;
  AppMessage? _proxyError;
  bool _obscured = true;
  int get _nameLength => configNameBytes(_name.text);

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch;
  }

  @override
  void dispose() {
    _source.dispose();
    _proxyName.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _nameLength > maxConfigNameBytes) return;
    final submittedSource = _source.text;
    final submittedName = _name.text;
    final submittedProxy = _proxyName.text;
    final submittedNoResolve = _addNoResolve;
    final Map<String, Object?> input;
    try {
      final uri = ConfigDownloader.sourceUri(submittedSource);
      if (widget.fragment) checkLoonProxyName(submittedProxy);
      input = {
        'source': uri.toString(),
        if (!widget.editingSource) 'name': submittedName.trim(),
        if (widget.fragment) ...{
          'proxyName': submittedProxy.trim(),
          'addNoResolve': submittedNoResolve,
        },
        if (_storageEpoch != null) 'storageEpoch': _storageEpoch,
      };
    } on ConfigFailure catch (failure) {
      setState(() => _error = failure.message);
      return;
    } on LoonConversionException {
      setState(() => _proxyError = messages.loonProxyNameInvalid);
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
        if (route != null && route.isActive) {
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

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final ownRoute = ModalRoute.of(context);
    return AlertDialog(
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
              TextField(
                key: const ValueKey('import-source'),
                controller: _source,
                obscureText: _obscured,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  label: Semantics(
                    liveRegion: true,
                    label: _error == null
                        ? strings.configUrl
                        : strings.configUrlInvalid,
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              strings.configUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox.square(
                            dimension: 16,
                            child: _error == null
                                ? null
                                : Icon(
                                    Icons.error_outline,
                                    size: 16,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  helper: SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(12) * 2.4,
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
                  suffixIcon: IconButton(
                    tooltip: _obscured ? strings.showUrl : strings.hideUrl,
                    onPressed: () => setState(() => _obscured = !_obscured),
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              if (!widget.editingSource) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: strings.nameOptional,
                    helperText: strings.nameOptionalHint,
                    counterText: '$_nameLength/$maxConfigNameBytes B',
                  ),
                ),
              ],
              if (widget.fragment) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('loon-proxy-name'),
                  controller: _proxyName,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) {
                    if (_proxyError != null) setState(() => _proxyError = null);
                  },
                  decoration: InputDecoration(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(strings.loonProxyName)),
                        const SizedBox(width: 6),
                        SizedBox.square(
                          dimension: 16,
                          child: _proxyError == null
                              ? null
                              : Icon(
                                  Icons.error_outline,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                        ),
                      ],
                    ),
                    helper: Semantics(
                      liveRegion: _proxyError != null,
                      child: SizedBox(
                        height:
                            MediaQuery.textScalerOf(context).scale(12) * 3.6,
                        child: SingleChildScrollView(
                          child: Text(
                            _proxyError?.resolve(strings) ??
                                strings.loonProxyNameHint,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: _proxyError == null
                                  ? null
                                  : Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('loon-no-resolve'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(strings.loonAddNoResolve),
                  value: _addNoResolve,
                  onChanged: (value) => setState(() => _addNoResolve = value!),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: !_submitting && _nameLength <= maxConfigNameBytes
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
  }
}
