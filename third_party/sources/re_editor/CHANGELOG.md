## 0.10.0
* Fix a typo, using `leadingDivider` instead of `sperator`.
* Ignore the error when _CodeAutocompleteState is disposed.
* Opt range check code in method `_isWrapedByClosureSymbol`.
* Check whether the viewport is still valid before auto scrolling.
* Fix the keyboard appearance issue.

## 0.9.0
* Disable autocorrection and smart text features in code editor.
* Fix replace match will cause selection locating to the first match.
* Pressing the delete key will no longer delete both the left and right closur
e symbols.
* Fix stale CodeEditor findController listener swap.
* Add "Enter (keypad)" key to newLine.
* Fix the compile error in Flutter 3.44.0.

## 0.8.0
* Add code syntax highlight plugin support.
* Opt mouse cursor display when using the TextSpan with a custom mouse cursor.
* Fix a bug where the highlight span cache was not clean in force repaint.
* Add the fontFamilyFallback param in CodeEditorStyle.
* API makePositionCenterIfInvisible will consider top and bottom padding.
* Fix IME pastes multiline text issue.
* Fix PlatformException issue on new flutter version.

## 0.7.0
* Add callback parameter to CodeLineNumberRenderObject for customizable line number behavior.
* Implement floating cursor feature for iOS.
* Long press will select a word on mobile platform.
* Disable ESC shortcuts when nothing the editor can do.
* Added option for maximum rendering length of single line text.
* Fix makePositionCenterIfInvisible was called infinitely.
* Clamp code line substring.
* Fixed a bug: type 'Null' is not a subtype of type '_CodeFieldRender'.

## 0.6.0
* Check tap down pointer whether is in the valid region.
* Break changes: Change autocomplete behavior to replace user input with complete match to support more pattern match method.

## 0.5.0
* Fix code lint warnings in the example project.
* Fix double newline issue on iOS.
* Allow the gesture pointer overflow when dragging to select text.
* Give an option to tell editor the size of the custom scrollbar.

## 0.4.0
* Feature: add shortcuts for word and line direction deleting.
* Feature: add an option to disable autocomplete closed symbols.
* Feature: add borderRadius and clipBehavior properties to editor settings.
* Feature：allow clearing of CodeLineEditingController's undo and redo stack.
* Opt autocomplete quoted symbol logic.
* Fix `IsolateCallback` might be invoked after the isolate was closed.
* Fix controller delegate memory leak issue.
* Fix issue `xxx is used after being disposed`.
* Fix the bug that the underlying text will be selected when trying to click-drag the scroll bar.

## 0.3.1
* Fix space key not works in PageView.
* Notify delegate listeners when controller was changed.
* Remove editable shortcut actions when read only.

## 0.3.0
* [IMP] Break changes: remove API `CodeLineEditingController.fromFile`.
* Feature: singleline chunks comment.
* Feature: multiline comment formatter
* Feature: moveCursorToWordBoundary and extendSelectionToWordBoundary(forward and backward).

## 0.2.0
* Web support.
* Mobile toolbar widget will be built by user rather than the editor.
* Autocomplete will only update after user input.
* Fix desktop focus issue.

## 0.1.1
* Clamp mode selection handle positions for mobile.
* Add an auto scrolling list for autocomplete example.
* Fix mobile selection handle invisible issue.
* Delete shift key selection logic for mobile.
* Fix newline action not works with some android input methods.
* Fix a bug that the mobile input keyboard does not popup when tapping the editor.

## 0.1.0
* [IMP] Break changes: refactor code autocomplete API.
* [IMP] Break changes: add more params for `CodeLineSpanBuilder`.
* Make `CodeEditorTapRegion` to public.
* Add `MouseTrackerAnnotationTextSpan` for hovering support.
* Add `CodeLineEditingControllerDelegate` for delegating the controller.
* Add an API for editor force repaint.

## 0.0.4

* Update re-highlight version.
* Fix unmounted issue.

## 0.0.3

* Update publisher

## 0.0.2

* Update pubspec.yaml and README.

## 0.0.1

* First Release Version.