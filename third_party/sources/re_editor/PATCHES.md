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

本目录取自上述归档，保留lib、pubspec.yaml、LICENSE和CHANGELOG.md。应用修改涉及七个原Dart文件，范围如下；其余保留文件与归档相同，pubspec.yaml、LICENSE和CHANGELOG.md保持原字节。

## 修改文件

| 文件 | 修改内容 |
| --- | --- |
| [lib/src/_code_editable.dart](lib/src/_code_editable.dart) | 可取消的延迟光标Timer |
| [lib/src/_code_selection.dart](lib/src/_code_selection.dart) | PR #118的三处mounted／render有效性检查 |
| [lib/src/code_editor.dart](lib/src/code_editor.dart) | 移动端共享快捷键／Actions及KeyEvent处理 |
| [lib/src/_code_shortcuts.dart](lib/src/_code_shortcuts.dart) | Android显式编辑动作先提交现有composing |
| [lib/src/code_line.dart](lib/src/code_line.dart)、[lib/src/_code_line.dart](lib/src/_code_line.dart) | 可选候选准入、接受后历史移动、异步粘贴身份及最终输入窗口映射 |
| [lib/src/_code_input.dart](lib/src/_code_input.dart) | 整批delta连续性／范围检查、一次发布和拒绝回同步 |

## 生命周期

_CodeCursorBlinkController原用Future.delayed(100ms)显示移动端光标。补丁将这一次延迟改为有句柄的Timer：重启取消旧句柄，停闪取消并清空，dispose沿stopBlink完成取消，触发后清空句柄；原周期闪烁继续保留。

拖拽部分采用上游已合并[PR #118](https://github.com/reqable/re-editor/pull/118)的三处检查，提交为dc27ee5083967100c9d4958a2461e63431b4cc45，合并提交为9bb470c8016c558a3f7cc40527e708b021969b5d。选择拖拽的延迟循环先查mounted和render类型，起始／结束手柄分别检查实际render类型，再访问字段。

## 候选准入与IME

CodeLineValueAcceptance为可选同步回调，默认null沿上游接受行为。候选在_preValue、历史分组／节点、value与监听器改变前决定；Undo／Redo在接受后移动历史。选区与composing变化只更新当前历史节点，新的正文修改建立新分支。异步剪贴板复核发起时的value、回调身份及dispose。最终跨行selection／有效composing映射为一次候选，普通换行清旧composing。

输入通道按delta.oldText和操作／selection／composing范围检查整批连续性，局部变换完成后一次准入。移动端前缀删除沿原backspace／edit变换，U+200B合成前缀与正文分别计量，前缀前方的普通非文本选择保持正文。拒绝时显式回同步实际接受值，保留合法composing和系统剪贴板。

应用通过回调提供行长、页面、记录、revision、epoch和可写状态等规则，集成机制见[文本编辑适配](../../../doc/architecture/data-and-operations.md#文本编辑适配)。

## 移动端硬件键盘

移动端与桌面共享原有Shortcuts／Actions，复用公开的activator builder、只读检查、剪贴板及撤销重做。Android显式剪切、粘贴、撤销和重做先清除已接受文字的composing范围，再沿原控制器与候选准入执行；其他组合保留原IME处理。应用通过activator builder将查找、保存和Escape交还页面的任务动作，保持按钮相同的身份与提交条件。

移动端保留原Focus、选择手柄和IME通道，普通Backspace／Enter通过KeyDown／KeyRepeat各处理一次；带Control／Meta／Alt的组合交由快捷键匹配，只读时保持正文。Android回归明确选择移动平台并检查实际移动Focus处理器，覆盖复制、剪切、粘贴、撤销重做、只读、重复按键及页面动作，见[移动快捷键测试](../../../test/features/configs/editor_android_shortcuts_test.dart)。

## 回归入口

[生命周期测试](../../../test/features/configs/editor_cursor_lifecycle_test.dart)、[拖拽测试](../../../test/features/configs/editor_drag_lifecycle_test.dart)、[页面测试](../../../test/features/configs/config_text_lifecycle_test.dart)覆盖取消与销毁；[值准入](../../../test/features/configs/editor_value_admission_test.dart)与[IME准入](../../../test/features/configs/editor_ime_admission_test.dart)覆盖发布、批次连续性及输入回同步。应用侧限额、草稿身份、查找及反馈测试位于同一[配置测试目录](../../../test/features/configs)。

运行命令见[自动化测试](../../../doc/development/build-and-test.md#自动化测试)，行为与设备检查见[编辑器与输入](../../../doc/development/verification.md#编辑器与输入)。
