part of re_editor;

/// Test-build observation only. The default build compiles out both call sites.
/// Observers must not log document text, spans, composing text or input payloads.
class CodeEditorObservation {

  CodeEditorObservation._();

  static const bool enabled = bool.fromEnvironment('RE_EDITOR_OBSERVATION');

  /// Called only for an accepted delta batch which changed the document.
  /// [startedAt] uses Timeline.now at entry, before validation and transformation.
  static void Function(int startedAt, CodeLineEditingValue previous,
    CodeLineEditingValue accepted)? onInput;

  /// Called after actual paragraph.draw calls, inside the text paint path.
  /// [viewport] and paragraph offsets share document coordinates. Consumers must
  /// intersect the changed text's real range rectangles, not just its line index.
  static void Function(CodeLines document, int frameNumber, Rect viewport,
    List<CodeLineRenderParagraph> drawn)? onPaint;
}
