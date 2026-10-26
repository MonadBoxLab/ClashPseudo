import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/definition_provenance.dart';

/// Compact plugin contribution text; ordered names remain readable in the details
/// surface.
String? provenanceSummary(
  AppLocalizations strings,
  DefinitionProvenance? provenance,
) {
  final plugins = provenance?.plugins.toList(growable: false) ?? const [];
  if (plugins.isEmpty) return null;
  if (plugins.length > 1) return strings.provenancePlugins(plugins.length);
  final source = plugins.single;
  final name = source.name!;
  return source.isLocalCustom && name != strings.localCustomTitle
      ? '$name · ${strings.localCustomTitle}'
      : name;
}

/// Localized text for the existing information dialog.
String? provenanceDescription(
  AppLocalizations strings,
  DefinitionProvenance? provenance, {
  bool providerDefinition = false,
}) {
  final plugins = provenance?.plugins.toList(growable: false) ?? const [];
  if (plugins.isEmpty) return null;
  return [
    providerDefinition
        ? strings.provenanceProviderHeading
        : strings.provenanceHeading,
    for (var index = 0; index < plugins.length; index++)
      '${plugins.length > 1 ? '${index + 1}. ' : ''}${plugins[index].name}'
          '${plugins[index].isLocalCustom && plugins[index].name != strings.localCustomTitle ? ' · ${strings.localCustomTitle}' : ''}',
  ].join('\n');
}

/// Shows plugin participation using the content's actual provenance.
class ProvenanceDetails extends StatelessWidget {
  const ProvenanceDetails({
    super.key,
    required this.provenance,
    this.providerDefinition = false,
  });

  final DefinitionProvenance? provenance;
  final bool providerDefinition;

  @override
  Widget build(BuildContext context) {
    final plugins = provenance?.plugins.toList(growable: false) ?? const [];
    if (plugins.isEmpty) return const SizedBox.shrink();
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            providerDefinition
                ? strings.provenanceProviderHeading
                : strings.provenanceHeading,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < plugins.length; index++)
            Padding(
              padding: EdgeInsets.only(
                bottom: index + 1 < plugins.length ? 8 : 0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (plugins.length > 1) ...[
                    Text('${index + 1}.'),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(plugins[index].name!),
                        if (plugins[index].isLocalCustom &&
                            plugins[index].name != strings.localCustomTitle)
                          Text(
                            strings.localCustomTitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
