# 数据、操作与恢复契约

本文定义业务保存、运行输入、异步身份、结果、原文编辑和三库恢复的工程契约。用户流程分别见[配置与插件](../product/configurations.md)、[本地定义](../product/local-definitions.md)与[备份恢复](../product/backup.md)。

## 三Store与存储身份

正式业务文件为configurations.json、overrides.json、preferences.json，由所属Store校验。损坏、缺字段或不支持格式时关闭写门，保留原数据并报告原因；当前数据格式按开发阶段的完整契约管理。

记录ID表达对象，正文revision表达并发版本；Android接口按有符号32位整数接受1..2147483647。达到上界后同正文及元数据修改可保留版本，正文变化在写盘前拒绝。备份manifest保留独立格式版本。

正文为严格UTF-8可表示字符串，可空白或无效YAML，每份正文按实际UTF-8含BOM最多16MiB。名称和来源唯一性、选择引用、kind／mode／正文类型、周期及偏好由所属Store完整检查。保存以原子文件发布并核查同步结果，目录同步未确认与正文未写入分别结算。

UI一致读先捕获稳定storage epoch，局部完成三库读取，再核查同一epoch后整体发布，失败保留旧投影。页面、菜单、表单及编辑器沿数据所属epoch持有身份。

## 保存选择与实际运行输入

正文、选择与实际运行分别记录。[CoreInput](../../lib/src/platform/core_input.dart)承载完整准备，[RunningInput](../../lib/src/logic/running_input.dart)保留实际lease输入，包含ID／revision／正文、加载名称、角色、顺序／模式、策略与访问偏好；准备写入与运行回读共用CoreInput中的composition编码。[CoreSnapshot](../../lib/src/model/core_snapshot.dart)集中租约身份的完整性、相等性与传输封套核对，阶段、网络epoch、请求代次及可见性由对应消费者分别管理。

| 操作 | 输入来源与变化范围 |
| --- | --- |
| 显式启动／切配置／Always-on | 最新完整保存组合 |
| 主正文应用 | 只替换实际运行组合中对应主配置 |
| 插件正文应用 | 替换对应正文，保留实际位置／模式 |
| 启停／删除／新增插件 | 只改变该ID；新增按保存列表中最近后续实际成员前插，无锚点追加 |
| 插件排序 | 只重排提交与实际成员的交集，其余保留槽位 |
| 模式／策略／访问等内部重连 | 只替换本次触及内容，其余字段沿用实际运行值 |

URL、选项与正文在下载、转换及身份复核成功后一起发布。同正文改源保留revision，实际输入一致时保留运行；手动可明确重试应用差异，周期按新内容应用。保存、调度、应用分别反馈。

### 模式与策略偏好

普通启动模式为合成显式mode→保存的可空回退→rule。当前会话明确选择的模式保存为以后缺省回退，YAML保持原值；仅策略、访问或路由的内部重连保留实际模式，正文／插件应用重新采用本次合成显式值。

每个配置的choices保存组类型及手动／自动意图，member:null表示自动，临时now属于运行状态。default-selected维持上游初始语义；显式profile.store-selected启用时，先保留内核缓存，再恢复有效应用选择。失效偏好保留记录并说明恢复结果。

## 操作身份与结果

| 身份 | 约束 |
| --- | --- |
| owner／operationId | 一次受理与真实执行、发布权、结果和归属反馈 |
| configId／revision | 捕获的记录与正文版本 |
| core generation／composition／purpose | 实际core lease自身的代次、合成及用途 |
| VPN session | 真实接管与单连接、累计基线等会话数据 |
| networkEpoch／queryOwner／requestId | 网络与DNS调用归属、取消水位和迟到隔离 |
| storageEpoch | 三库整体恢复后的内容世代 |
| 来源token／定义路径／嵌套记录ID | provider分页、直接定义和集合子编辑的精确对象 |

受理记录一次已接受操作，保存结果通过实际targetId与savedRevision关联，由所属执行结果和回执确定。执行前退出按未保存／未恢复结算，进入执行与发布后的结果继续依据实际回执核实。

| 保存结果 | 含义 |
| --- | --- |
| notSaved | 正文未保存，草稿可继续 |
| saved | 已保存，未要求或尚未确认实际应用 |
| applied | 已保存并确认本次应用 |
| applyFailed | 已保存，释放或启动／应用失败 |
| unconfirmed／缺失 | 无法确认最终结果，应读取核实 |

新建部分成功后的重试接管实际ID／revision；rename完成但目录同步待确认归已保存警告。删除重试只应用已保存结果。新owner撤销旧写权，原完成结果保留ID、状态和回执配对。

## 期限取消与真实退出

普通业务期限为120秒、UI等待125秒；备份准备／覆盖期限为300秒、UI等待305秒。系统选择器等待独立计时，业务预算自原受理时刻起持续计算。Android在受理时记录单调时点，回执携带operationId与remainingMs；UI收到回执后立即安排剩余预算及UI余量的等待，状态回读参与同一次等待。Service启动与Engine准备继续消费原受理预算。下载开始时读取所属owner当前阶段的剩余预算，根证书加载、连接及全部重定向共用这份下载期限。

取消／超时撤销身份与后续发布权，Dart、reader、网络及native真实退出后开放门。进入短发布仲裁的保存／恢复持续等待原平台返回结果，以实际提交结算；Stop、撤权与发布共用仲裁。

DNS、查询和业务写门各有独立真实在途槽，UI切换只调整展示；执行门随实际I/O收尾开放。

## 后台更新交接

周期更新真实保存、准备完整私有运行输入并复核当前session／core／composition／记录后，内部Stop前交接网络Worker，固定其saved回执；同一Dart writer／operationId继续本地应用，最终应用与执行结束各自结算。

交接前Worker停止仍撤销owner；交接后已接管应用沿原owner继续，本次CONNECTED约束只管理交接前阶段。真正用户Stop、撤权或原期限仍可取消，写门保留至实际执行退出。平台110秒网络阶段和120秒总预算见[Android周期更新](android.md#周期更新)。

## 来源与本地编辑

来源由真实Go合成计算，贡献摘要记录源ID／revision、加载名称、角色和源内路径；完全被覆盖的值退出贡献，provider定义与下载成员分别溯源。运行诊断供脱敏阅读，写权由原文身份取得。

本地定义捕获专用项ID／revision／epoch、完整正文及路径；同正文身份复用一次有界解析，大正文使用SDK compute。发布解析结果时核查身份，等待期间保留阅读投影并关闭旧写入口。

原文局部修改使用hosted yaml_edit／yaml公开API，按实际路径保留未知字段、注释和格式。键改名以公开scalar span替换，检查冲突、BOM／换行、容量及身份；alias／继承等形状由安全编辑检查具体反馈，无关分支按正常路径处理。

针对两端YAML库的标量转义／flow plain差异，仅适配replacement覆盖的公开AST标量并核查值等价；原正文保持。重复规则按索引、provider改名保留位置，子编辑归父草稿；语义见[本地定义](../product/local-definitions.md)。

## 文本编辑适配

正文页复用[ConfigTextPage](../../lib/src/features/configs/config_text_page.dart)，SDK file_selector单文件取得XFile后再按实际字节有界读和严格解码。应用限额自SDK文件插件交付XFile后执行；交付前缓存由插件管理，备份SAF采用独立通道。

saveLocal／saveOverride正文采用UTF-8 bytes传通道，GUI嵌套定义及replacement采用UTF-8 JSON bytes；外层保留action／storageEpoch等受理信息，owner由平台受理链固定。JSON传输预算与最终YAML预算各自核验。

CodeLines／controller创建前检查行长。[编辑准入](../../lib/src/features/configs/config_editor_limits.dart)与CodeLineValueAcceptance在改变preValue、历史和监听器前核查逻辑行、折叠子行、记录／revision／epoch及可写状态；有效共享segment复用。

IME按整批检查oldText连续性、范围及原子性，保留U+200B前缀和composing，只发布最终候选。拒绝后回同步输入连接，Undo／Redo在准入后移动历史。剪贴板异步写回以值、回调、页面与记录身份仍有效为前提。

查找沿公开控制器合并最新查询，顺序推进偏移并核查正文／查询身份；输入formatter、程序赋值及选区预填均整次预检。长字面查询用有界SDK正则片段按必需偏移求交，保留大小写、UTF-16与非重叠语义。

re_editor适配包含生命周期、候选准入、IME同步及移动快捷键，来源见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)。移动端KeyEvent处理普通Backspace／Enter并执行只读检查；其他编辑快捷键复用原Actions，查找、保存与Escape交由页面任务动作。选区与composing变化更新当前历史节点，实际正文修改建立新分支。正文页持有同一选择菜单控制器，来源失效和退出时关闭所属浮层。检查方法见[编辑器与输入](../development/verification.md#编辑器与输入)。

## 归档格式与准入

ZIP固定包含manifest.json、configurations.json、overrides.json、preferences.json。manifest记录格式、版本、时间、长度与SHA-256；CRC和hash用于完整性检查，业务文件按原字节归档。

| 准入项 | 上限 |
| --- | --- |
| 压缩文件／展开总量 | 各256MiB |
| configurations／overrides JSON | 各128MiB |
| preferences JSON | 1MiB |
| manifest／中央目录 | 各64KiB |
| 配置／插件记录 | 各4096项 |
| JSON深度／结构节点 | 32／200000 |
| 单正文 | UTF-8含BOM 16MiB |

归档先有界复制，核查EOCD／中央目录、条目、实际长度／CRC／hash，再做结构及各Store语义检查；预算作用于归档准入，峰值按目标环境测量。版本、条目、编码、字段或容量错误整体拒绝，候选token只对应固定私有路径。

## 三库恢复事务

普通发布与整体恢复共用平台固定文件门。Application在启动机械recover结束前关闭读写，UI、业务、Worker、系统启动与本地化初始化都遵守ready／restoring／epoch。

覆盖先取得唯一业务写门，并确认原VPN／PREVIEW真实释放。准备新三文件、不可变旧副本及原不存在标记并同步；发布PREPARED，再逐份安装，全部完成后发布COMMITTED，文件与目录同步分别核查结果。

PREPARED中断恢复旧数据，COMMITTED中断恢复新数据；回滚副本可重复恢复。材料或日志缺项时保留原件并关闭读写门，待状态核实后处理。三库完整性由应用事务协调。

候选由执行者持有至实际结束；原停止保持停止，原运行按恢复数据与最新用户意图决定重连。系统逐文件恢复沿独立[Android机制](android.md#归档与文件门)结算。

## 读取与反馈

读取先在局部形成完整投影，再校验身份并发布。请求代次、来源token及网络／存储epoch限定结果归属，新对象由重新捕获的身份建立读写会话。

页面与全局reader中一个承担反馈，真实呈现后acknowledgement，离开页面交全局，路由操作按所属身份完成。SAF临时后台保留候选及结果；初始化、快照和配置读取各5秒，前台失败按1／2／5／10／30秒退避，健康后结束重试，命令错误独立保留。
