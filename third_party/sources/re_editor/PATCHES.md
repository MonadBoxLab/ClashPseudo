# re_editor来源与应用补丁

## 来源

| 项目 | 记录 |
| --- | --- |
| 上游包 | re_editor 0.10.0 |
| 发布页 | https://pub.dev/packages/re_editor/versions/0.10.0 |
| 官方归档 | https://pub.dev/api/archives/re_editor-0.10.0.tar.gz |
| 归档SHA-256 | 66671c4774a6b4c5254c9a53ab35a083e7e7da9ae371c519bcf491c70a2a4e56 |
| 上游仓库 | https://github.com/reqable/re-editor |
| 许可 | MIT，Copyright (c) 2024 Reqable，原文见[LICENSE](LICENSE) |

本目录取自上述归档，保留lib、pubspec.yaml、LICENSE和CHANGELOG.md。应用修改见下表；移除未使用的私有计时文件lib/src/debug/_trace.dart。pubspec.yaml、LICENSE和CHANGELOG.md保持原字节。

## 修改文件

| 文件 | 修改内容 |
| --- | --- |
| [lib/src/_code_editable.dart](lib/src/_code_editable.dart) | 使用可取消的Timer延迟显示光标 |
| [lib/src/_code_selection.dart](lib/src/_code_selection.dart) | PR #118的三处mounted与渲染对象检查；选区菜单开始淡出时停止接收点击、焦点与无障碍操作 |
| [lib/src/code_editor.dart](lib/src/code_editor.dart) | 移动端共享快捷键与Actions，处理KeyEvent；默认选区与高亮色使用withAlpha(102)，保留原0.4透明度的8位值 |
| [lib/src/_code_shortcuts.dart](lib/src/_code_shortcuts.dart) | Android编辑快捷键先提交当前输入法组合文本 |
| [lib/src/code_line.dart](lib/src/code_line.dart)、[lib/src/_code_line.dart](lib/src/_code_line.dart) | 编辑值接受回调、接受后移动撤销历史、异步粘贴完成检查，以及输入窗口中的选区与组合文本映射 |
| [lib/src/_code_input.dart](lib/src/_code_input.dart) | 检查整批delta的连续性和范围，整批处理后更新一次编辑值；拒绝修改时将当前值同步回输入法；添加onFocusReceived的覆盖标注 |
| [lib/src/re_editor.dart](lib/src/re_editor.dart)及其33个part文件 | part-of改用相对URI；移除未使用的私有计时类、part入口与注释调用 |
| [lib/src/_code_field.dart](lib/src/_code_field.dart) | 使用Color.a读取透明度，保留8位舍入与范围截断 |
| [lib/src/_code_scroll.dart](lib/src/_code_scroll.dart) | child与scrollbarOrientation改用super参数 |

## 生命周期

_CodeCursorBlinkController原用Future.delayed(100ms)显示移动端光标。补丁改用Timer：重启时取消旧计时，停止闪烁时取消并清空计时器，dispose通过stopBlink完成取消，回调触发后清空计时器；周期闪烁保持原实现。

拖拽部分采用上游已合并[PR #118](https://github.com/reqable/re-editor/pull/118)的三处检查，提交为dc27ee5083967100c9d4958a2461e63431b4cc45，合并提交为9bb470c8016c558a3f7cc40527e708b021969b5d。选区拖拽的延迟循环先检查mounted和渲染对象类型，起始与结束手柄分别检查实际渲染对象类型，再访问字段。

选区菜单使用原有淡入淡出动画。visibility变为false时，IgnorePointer、ExcludeFocus与ExcludeSemantics立即停止菜单的点击、焦点与无障碍操作。页面菜单回调检查当前页面和编辑内容是否仍对应发起操作时的对象；页面退出后，旧回调停止复制或重新打开选区。

## 编辑值与输入法

CodeLineValueAcceptance是可选的同步回调。默认null时使用上游的接受行为；设置回调后，在修改_preValue、历史分组与节点、value以及通知监听器之前，先决定是否接受新值。撤销与重做在新值被接受后移动历史位置。选区与composing范围变化只更新当前历史节点，正文修改建立新分支。异步粘贴完成时，检查发起时的value、接受回调是否仍相同，以及控制器是否已销毁。跨行selection与有效composing范围合并到同一个编辑值中，普通换行清除旧composing范围。

输入通道根据delta.oldText以及操作、selection、composing范围检查整批修改的连续性；完成整批变换后调用一次接受回调。移动端前缀删除使用原有backspace与edit变换，U+200B合成前缀与正文分别计算长度，前缀前方的普通选区变化保持正文。修改被拒绝时，将已接受的当前值同步回输入法，保留合法composing范围和系统剪贴板。

应用通过回调检查行长、页面、记录、revision、epoch与可写状态，见[文本编辑适配](../../../doc/architecture/data-and-operations.md#文本编辑适配)。

## 移动端硬件键盘

移动端与桌面共享原有Shortcuts与Actions，复用公开的activator builder、只读检查、剪贴板和撤销重做。Android剪切、粘贴、撤销与重做快捷键先清除已接受文字的composing范围，再调用原控制器和接受回调；其他按键组合使用原输入法处理。应用通过activator builder将查找、保存和Escape交给页面处理，与页面按钮使用相同的对象检查和提交条件。

移动端保留原Focus、选择手柄和输入法通道，普通Backspace与Enter在每次KeyDown或KeyRepeat中处理一次；带Control、Meta或Alt的组合交给快捷键匹配，只读时保持正文。Android回归选择移动平台并检查实际Focus处理器，覆盖复制、剪切、粘贴、撤销重做、只读、重复按键及页面动作，见[移动快捷键测试](../../../test/ui/configs/editor/editor_android_shortcuts_test.dart)。

## 回归入口

[光标生命周期测试](../../../test/ui/configs/editor/editor_cursor_lifecycle_test.dart)、[拖拽测试](../../../test/ui/configs/editor/editor_drag_lifecycle_test.dart)、[页面生命周期测试](../../../test/ui/configs/editor/config_text_lifecycle_test.dart)覆盖取消与销毁；[选区菜单测试](../../../test/ui/configs/editor/editor_toolbar_lifecycle_test.dart)覆盖淡出期间的点击、焦点、无障碍操作及旧页面回调。[编辑值测试](../../../test/ui/configs/editor/editor_value_admission_test.dart)与[输入法测试](../../../test/ui/configs/editor/editor_ime_admission_test.dart)覆盖值更新、批次连续性和向输入法同步当前值。输入法测试通过测试通道注入delta；移动快捷键测试通过测试绑定注入键盘事件。应用侧限额、草稿、查找与反馈测试位于同一[编辑器测试目录](../../../test/ui/configs/editor/)。

运行命令见[自动化测试](../../../doc/development/build-and-test.md#自动化测试)，行为与设备检查见[编辑器与输入](../../../doc/development/verification.md#编辑器与输入)。
