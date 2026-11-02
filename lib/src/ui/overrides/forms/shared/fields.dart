import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../theme/app_theme.dart';
import '../../../components/input/choice_menu_button.dart';
import '../../../components/reading/original_text_view.dart';
import '../../../../l10n/app_localizations.dart';
import 'editor.dart';
import 'form_body.dart';
import 'form_interaction.dart';
import 'save_bar.dart';

part 'scalar_fields.dart';
part 'collection_fields.dart';

const definitionInt64Max = 9223372036854775807;
const definitionInt64Min = -9223372036854775808;
// Fixed Go time.Duration consumers multiply seconds/milliseconds by nanoseconds.
const definitionMaxSeconds = 9223372036;
const definitionMaxMilliseconds = 9223372036854;
const _unset = '\u0000unset';

/// Standard SDK form-field composition.
Widget definitionHeading(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(top: 16, bottom: 12),
  child: Text(text, style: Theme.of(context).textTheme.titleSmall),
);

/// 校验只改变输入边框与语义，不为错误说明增加正文高度。
class DefinitionFieldValidation extends StatelessWidget {
  const DefinitionFieldValidation({
    super.key,
    required this.hasError,
    required this.message,
    required this.child,
  });

  final bool hasError;
  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decoration = theme.inputDecorationTheme;
    final error = theme.colorScheme.error;
    return Semantics(
      validationResult: hasError
          ? SemanticsValidationResult.invalid
          : SemanticsValidationResult.none,
      hint: hasError ? message : null,
      child: Theme(
        data: hasError
            ? theme.copyWith(
                inputDecorationTheme: decoration.copyWith(
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: error),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: error, width: 2),
                  ),
                ),
              )
            : theme,
        child: child,
      ),
    );
  }
}
