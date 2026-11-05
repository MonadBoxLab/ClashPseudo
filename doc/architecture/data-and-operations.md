# 数据、操作与恢复contract

ConfigStore校验配置文件，OverrideStore校验插件文件，PreferencesStore校验偏好文件，AppRuntime统一执行写入；平台以operationId保护受理、发布和结果，storageEpoch标识配置、插件和偏好整体恢复后的版本。

| 维护任务 | 需检查的内容 |
| --- | --- |
| 新增保存／更新动作 | Store校验、目标ID／revision、运行输入替换范围、保存及应用结果 |
| 处理异步callback或取消 | operationId、记录版本、core／网络／存储标识，以及相关调用是否仍在执行 |
| 修改正文或表单 | UTF-8及结构预算、局部原文路径、IME整批输入检查和草稿冲突 |
| 修改备份恢复 | 固定条目、备份文件读取及清理、PREPARED／COMMITTED及后续设置／调度／连接结果 |

界面流程见[配置与插件](../product/configurations.md)、[本地定义](../product/local-definitions.md)及[备份恢复](../product/backup.md)。

## 配置、插件和偏好文件的读写

正式业务文件为configurations.json、overrides.json、preferences.json，分别由ConfigStore、OverrideStore与PreferencesStore读取和校验，写入统一由AppRuntime执行。集合损坏、缺字段或格式不支持时，保留原文件及所属集合的读取错误，关闭依赖该集合的写入入口；配置、插件与偏好的读取能力独立，停止、取消及打开系统设置按各自条件继续可用。

记录ID表达对象，正文revision表达并发版本；Android接口按有符号32位整数接受1..2147483647。达到上界后同正文及元数据修改可保留版本，正文变化在写盘前拒绝。备份manifest保留独立格式版本。

正文须可严格表示为UTF-8，允许空白或无效YAML；每份正文含BOM最多16MiB。所属Store检查名称、来源唯一性、选择引用、kind／mode、正文类型、周期及偏好。保存通过原子文件替换完成，并检查同步结果；目录同步未确认与正文未写入分别记录。

普通读写和备份校验共用[application contract](../../contracts/application.json)：

| 数据 | 预算 |
| --- | --- |
| configurations／overrides JSON | 各128MiB、各4096项 |
| preferences JSON | 1MiB |
| 每文件JSON结构 | 深度32、结构节点200000 |
| 单正文 | UTF-8含BOM 16MiB |

[storage_json](../../lib/src/model/storage_json.dart)检查纯JSON格式和结构预算，[storage_files](../../lib/src/logic/storage/storage_files.dart)执行文件流与写入。读取依次检查长度、流式累计字节、严格UTF-8和结构计数，再交SDK JSON解码及Store模型校验。编码按输出分块计字节并复核结构预算。清理临时文件失败时，将其与原写入／发布错误一并返回。

UI先读取storageEpoch，再分别读取配置、插件和偏好；三个文件读取完成后，再次检查storageEpoch。版本相同才一起更新页面，读取失败则保留原显示内容。页面、菜单、表单和编辑器记录打开时的storageEpoch，保存前检查数据是否已被整体恢复。

## 局域网插件与备份

OverrideStore以唯一role=lanProxy条目保存本功能的标准listeners YAML，enabled即开启意图，不另存服务配置或偏好。新建时每个明确地址生成独立稳定名称，默认mixed、udp:true、users:[]；端口、UDP和用户认证沿YAML字段执行。便捷表单只修改本功能管理的已知字段，保留未知字段；正文无法由表单表达时使用原文编辑，不重建默认正文。

业务校验拒绝重复lanProxy角色，disabled条目也参与唯一性检查。保存地址与配置字段，接口瞬时索引、当前可用性和实际监听结果不入业务文件或备份。恢复沿现有插件范围保留正文及enabled，建立监听前按当前设备重新核对地址。其他配置或插件的监听不属于本功能，不随其开关被改写或关闭。

## 保存选择与实际运行输入

已保存正文、所选配置和实际运行输入分别记录。[CoreInput](../../lib/src/platform/core/core_input.dart)保存完整准备参数；[RunningInput](../../lib/src/logic/running_input.dart)由AppRuntime持有，保存实际装载的正文、插件角色与顺序、来源、ID／revision、策略及访问偏好。每次装载分配inputId，平台将不可变记录原子发布到私有noBackup目录；记录保留至所属进程和I/O均结束，不从Go回读正文。

装载回执、[CoreSnapshot](../../lib/src/model/core_snapshot.dart)与后续请求核对processId、generation、inputId、configId、revision、composition及purpose。composition沿完整输入身份，不截断为固定长度字符串。RUNNING另外记录VPN／局域网开启意图与实际资源；运行与所选配置不因名称相同而合并。

默认进程冷启动后，先匹配内核Handshake的inputId与保留记录，再恢复RunningInput。记录缺失或不匹配时保留实际状态，拒绝定向替换；用户可以停止后按完整保存组合启动。页面另外核对自己的请求编号、查询watermark及可见性，旧结果不改变新进程或新页面。

| 操作 | 输入来源与变化范围 |
| --- | --- |
| 显式启动／切配置／正常Always-on启动／用户异常恢复 | 最新完整保存组合；异常待恢复时系统入口不装载 |
| VPN／局域网切换、网络变化、Builder规格变化 | 保留实际运行输入，只改变本次意图或平台snapshot，用新进程装载 |
| 主正文应用 | 只替换实际运行组合中对应主配置 |
| 插件正文应用 | 替换对应正文，保留实际位置／模式 |
| 启停／删除／新增插件 | 只改变该ID；新增按保存列表中最近后续实际成员前插，没有该成员时追加到末尾 |
| 插件排序 | 只重排提交与实际成员的交集，其余成员保留原位置 |
| 模式／策略／访问等内部重连 | 只替换本次触及内容，其余字段沿用实际运行值 |

URL、选项与正文在下载、转换及身份复核成功后一起发布。同正文改源保留revision，实际输入一致时保留运行；手动可明确重试应用差异，周期按新内容应用。保存、调度、应用分别反馈。

### 模式与策略偏好

普通启动模式为合成显式mode→保存的可空回退→rule。当前会话明确选择的模式保存为以后缺省回退，YAML保持原值；仅策略、访问或路由的内部重连保留实际模式，正文／插件应用重新采用本次合成显式值。

每个配置的choices保存组类型及手动／自动意图，member:null表示自动，临时now属于运行状态。AppRuntime在发布新运行输入、结束旧进程及Handshake前校验整份saved choices；无效结构不发布输入或认领新context。default-selected维持上游初始语义；显式profile.store-selected启用时，先保留内核缓存，再由AppRuntime恢复有效应用选择并读回。恢复通过单项StrategySelect携restore:true执行，不写上游selected cache；显式用户选择成功且store-selected启用时才更新该cache。组缺失、类型不符及成员消失分别保留未恢复记录，显式选择成功后只清除对应组的记录。

## 操作身份与结果

| 身份 | 约束 |
| --- | --- |
| owner／operationId | 标识本次命令，关联执行、文件写入、结果及结果显示 |
| configId／revision | 捕获的记录与正文版本 |
| processId／generation／inputId／composition／purpose | 随机process identity、进程内context、不可变输入记录、完整组合及用途；PID不能替代这些身份 |
| VPN／局域网实际资源 | 分别记录TUN接管、逐地址监听、连接与累计流量基线 |
| networkRevision／networkEpoch／queryOwner／requestId | 捕获的平台网络版本、业务查询watermark及单次调用归属；用于取消及迟到隔离 |
| storageEpoch | 配置、插件和偏好整体恢复后的版本标识 |
| 来源token／定义路径／嵌套记录ID | provider分页、直接定义和集合子编辑的精确对象 |

操作被受理后，平台为其记录身份；保存结果通过targetId与savedRevision关联具体记录。Android唯一的[OperationState](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/operation/OperationState.kt)保存operationId、受理时的单调时点、授权、写入锁、结果和未完成任务；backup与runtime协调器共用该实例。执行前退出时记录未保存／未恢复，执行或文件替换已开始后，继续依据对应调用的回执确认结果。

[AppController](../../lib/src/ui/app/app_controller.dart)的 `submitForReceipt(command, {required feedbackOwner})` 与submit使用同一提交方法。第一次通知前，将feedbackOwner关联到实际command；等Android受理并第一次读回状态后，返回 `(command, operationId, error)`。command为实际提交命令，error为本次提交错误。submitAndWait继续等待操作结束；收到receipt后，调用者负责确认结果已显示或释放feedbackOwner。

提交后的反馈按受理结果交接：

- **已受理**：调用者关闭表单并释放feedbackOwner，操作结束后的结果由全局结果显示逻辑处理。
- **拒绝**：仍有效的原页面使用floating SnackBar显示本次error；实际呈现后复核command身份，再调用acknowledgeLocalFeedback，不在排队时确认，也不等用户打开详情。
- **未呈现或提前退场**：释放feedbackOwner，保留尚未显示的最终结果。

页面关闭或释放feedbackOwner后，已提交Future继续等待操作结果。Stop或对象替换后的callback仍使用原command和owner核对归属。

| 保存结果 | 含义 |
| --- | --- |
| notSaved | 正文未保存，草稿可继续 |
| saved | 已保存，未要求或尚未确认实际应用 |
| applied | 已保存并确认本次应用 |
| applyFailed | 已保存，释放或启动／应用失败 |
| unconfirmed／缺失 | 无法确认最终结果，应读取核实 |

新建正文已保存而应用失败时，重试使用已创建记录的ID和revision。rename完成但目录同步未确认时，显示已保存及同步警告。删除后的重试只应用已保存结果。owner被替换后旧操作停止后续写入，原结果仍保留对应ID及状态。

AppRuntime的异常分支同时合并ConfigActions、OverrideActions与ScheduleActions已经形成的结果。`ScheduleActions.result`只携带saved／applied／applyFailed／targetId／savedRevision；整体success及message由runtime按实际完成或异常生成。

已发出的平台调用根据返回值记录结果。原operation取消或期限到达后，仍可通过只读snapshot()确认结果；读取继续绑定同一runtime、operation与storageEpoch。使用读取结果前检查confirmed及所需运行标识，写入或发起后续动作前再检查owner和剩余时间。

内核磁盘清理在受理时和发布清理记录前分别复核storageEpoch与owner。候选由PATHS查询公开Cache、GeoIP、MMDB、ASN、GeoSite路径，保留实际名称及大小写；AppRuntime只将内核根内的路径去重为相对清单，请求字段为paths，不接受整目录清理意图。平台持久记录每项path、completed及error并阻止新装载，确认旧内核死亡及本地I/O结束后，在同一资源门禁内逐项检查、删除文件、同步目录并更新结果。中途失败保留已完成项目、当前错误及剩余清单，重试跳过已经完成的项；全部完成后才允许按最新完整保存组合重新启动。清理不结束UI或默认进程，不删除协议身份或provider自定义文件。lifecycle、资源锁和具体检查见[Android清理接入](android.md#内核数据清理)。

## 期限、取消与执行结束

| 操作 | 业务期限 | UI等待 |
| --- | --- | --- |
| 普通业务 | 120秒 | 125秒 |
| 备份准备／覆盖 | 300秒 | 305秒 |

系统选择器等待独立计时。业务受理时Android记录单调时点，回执携带operationId和remainingMs；UI立即用剩余预算及UI余量安排等待，状态回读、Service启动和Engine准备均计入该次期限。下载开始时读取owner当前阶段的剩余预算，根证书加载、连接和全部重定向共用这一下载期限。

取消或超时后停止后续保存和启动，等待Dart任务、文件读取、网络及内核调用返回后，才允许下一次冲突操作。尚未提交native的queued调用可先且仅一次向调用方返回取消或期限错误，但原work仍受跟踪，实际drain前不释放slot或writer、不受理替代work，迟到结果不重复回复。已提交native的结果、receipt和实际退出继续按原身份等待。保存或恢复已经进入文件替换步骤时，继续等待平台结果，记录文件是否已提交；停止、撤权和文件替换使用同一锁同步。

内核请求分别记录accepted、结果／原始错误、cancelError、stale及exited。结果FD、native receipt、取消请求回执及真实调用退出分别确认；结果读取失败时仍等待对应退出，并保留读取错误、完整nativeReceipt、取消结果及cancelError。typed cause、RawCause、errors.Join的各原始cause、suppressed、stack和未知字段保持结构。取消传输不等于原调用退出；通信断开保持未确认，不能当作process death。DeathRecipient确认旧process death后终结该进程请求，不再等旧callback；默认进程中已经开始的文件发布仍等自己的实际回执。停止和IPC交接沿原受理时钟，不重新获得期限。

系统revoke捕获原process、input、generation及networkRevision，旧身份事件不改变新context。Android建立新的revoke owner并沿用原受理时点和deadline，先撤销旧owner，等待原业务executor、core请求及文件I/O真实drain。READY且仍有局域网开启意图、原实际输入可确认时，AppRuntime在旧进程退出后以新inputId装载LAN-only，只将vpnIntent置false，保留原正文、插件顺序和其余意图。等待超过原期限时记录未完成并请求旧进程退出；STARTING或无可保留局域网服务时不重新装载。

DNS、普通查询和业务写入分别限制并发。切换页面只改变显示，相关I/O结束后才允许下一次同类操作。

## 后台更新交接

周期更新保存正文后，准备完整私有运行输入，并检查实际 core context 的 processId、inputId、composition及记录版本，分别保留 VPN／局域网运行意图。在内部 Stop 前，将已保存结果返回网络 Worker；AppRuntime 继续使用同一 operationId 应用保存内容，分别记录应用结果和任务是否结束。

交接前Worker停止时撤销owner；交接后，AppRuntime使用原owner继续应用。CONNECTED网络约束只管理交接前阶段，用户Stop、撤权和原期限仍可取消后续动作。该次执行结束前不接受冲突写入。110秒网络阶段与120秒总预算见[Android周期更新](android.md#周期更新)。

## 来源与本地编辑

Go在合成时计算字段来源，provenance保留源ID／revision、加载名称、role和原文路径。值被后续片段完全覆盖后，不再列出旧来源；provider定义与下载成员分别记录。来源用于精确关联和写入检查，不建立额外的UI分类或来源专区。

`LocalDefinitions`提供按正文版本解析的直接定义及捕获的编辑目标，分类共用同一renderer。运行记录与本地定义仅在entry ID、revision和section/path匹配时合成一项；仅同名、旧revision或缺失provenance不能绑定。provider还核对kind，下载成员不取得定义的编辑权。未关联的停用、被覆盖或尚未加载定义仍作为同类普通条目保留，不伪造运行属性。

节点、规则通过`CoreCollectionPage.read`对公开stream逐条关联，再补入未关联本地定义，统一搜索、计数及分页，只保留当前页、必要计数和本地关联集合。分页身份包含native token及本地snapshot，原文变化使旧页失效；记录保留业务字段和来源身份。运行规则保留实际顺序和原始index，未装载本地规则保留原文顺序，顶层rules只进入main scope。

编辑本地定义时捕获“本地自定义”插件的ID／revision／storageEpoch、完整正文及确切路径，提交前重新核对，运行属性不写回正文。同一正文版本复用解析结果并检查容量，大正文通过SDK compute解析；异步完成后检查记录版本，等待期间保留原显示内容并禁用旧表单保存。查看或保存不自动启用原停用内容。

原文局部修改使用hosted yaml_edit／yaml公开API，按所修改的路径保留其他字段、注释和格式。键改名通过公开scalar span替换，并检查重名、BOM／换行、容量和记录身份。目标使用alias或继承等结构、无法局部编辑时，返回具体原因；无关分支仍可按各自路径编辑。

针对两端YAML库的标量转义／flow plain差异，仅适配replacement覆盖的公开AST标量并核查值等价；原正文保持。重复规则按索引、provider改名保留位置，子编辑归父草稿；语义见[本地定义](../product/local-definitions.md)。

## 文本编辑适配

正文页使用[ConfigTextPage](../../lib/src/ui/configs/editor/config_text_page.dart)。SDK file_selector返回单个XFile后，应用在大小限制内读取实际字节并严格解码；返回XFile前的缓存由文件插件管理。备份的SAF读写使用独立通道。

saveLocal／saveOverride正文采用UTF-8 bytes传通道，GUI嵌套定义及replacement采用UTF-8 JSON bytes；外层保留action／storageEpoch等受理信息，owner由平台受理链固定。JSON传输预算与最终YAML预算各自核验。

CodeLines／controller创建前检查行长。[编辑内容检查](../../lib/src/ui/configs/editor/config_editor_limits.dart)与CodeLineValueAcceptance在改变preValue、历史和监听器前核查逻辑行、折叠子行、记录／revision／epoch及可写状态；有效共享segment复用。

IME按整批检查oldText连续性、范围及原子性，保留U+200B前缀和composing，检查通过后只更新一次最终输入值。拒绝时向输入法同步应用保留的值；Undo／Redo通过检查后才移动历史位置。剪贴板异步写回以值、callback、页面与记录身份仍有效为前提。

查找通过公开控制器合并待处理查询，按顺序扫描偏移，并检查正文与查询版本。输入formatter、程序赋值和从选区预填都先检查完整新值。长字面查询拆为长度受限的SDK正则片段，按所需偏移求交；保留大小写、UTF-16偏移及非重叠匹配规则。

re_editor适配包含lifecycle、新输入值检查、IME同步及移动快捷键，来源见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)。移动端KeyEvent处理普通Backspace／Enter并执行只读检查；其他编辑快捷键复用原Actions，查找、保存与Escape交由页面任务动作。选区与composing变化更新当前历史节点，实际正文修改建立新分支。正文页持有同一选择菜单控制器，来源失效和退出时关闭所属浮层。检查方法见[编辑器与输入](../development/verification.md#编辑器与输入)。

## 归档格式与大小限制

ZIP固定包含manifest.json、configurations.json、overrides.json、preferences.json。manifest记录格式、版本、时间、长度与SHA-256；CRC和hash用于完整性检查，业务文件按原字节归档。

| 检查对象 | 上限 |
| --- | --- |
| 归档文件 | 258MiB＋64KiB |
| 实际展开总量 | 257MiB＋64KiB |
| configurations／overrides JSON | 各128MiB |
| preferences JSON | 1MiB |
| manifest | 64KiB |
| 配置／插件记录 | 各4096项 |
| JSON深度／结构节点 | 32／200000 |
| 单正文 | UTF-8含BOM 16MiB |

归档复制时累计实际字节，超过归档上限即拒绝。SDK ZipInputStream顺序展开四个固定条目，支持stored／deflated、data descriptor及manifest位于首项或末项；额外条目、目录、重复或缺项均拒绝。每项读至结束，核查实际CRC与长度，再将三个业务文件的长度、SHA-256与manifest比较。

Android负责文件、manifest、完整性和流式预算；三个业务文件由[BackupActions](../../lib/src/logic/backup/backup_actions.dart)复用ConfigStore、OverrideStore、PreferencesStore及[JSON格式预算](../../lib/src/model/storage_json.dart)／[文件I/O](../../lib/src/logic/storage/storage_files.dart)进行校验并生成摘要。正文、未知字段和显式空值按Storecontract处理。备份token对应三个固定私有文件路径。

## 配置、插件和偏好的恢复事务

普通写入和整体恢复使用同一平台file lock。Application在启动recover恢复文件结束前禁止读写，UI、业务、Worker、系统启动与本地化初始化都遵守ready／restoring／epoch。

恢复的提交顺序：

1. ConfigStore、OverrideStore和PreferencesStore检查备份中的三个文件，用户确认一次覆盖范围。
2. 暂停其他业务写入，结束原VPN／局域网／PREVIEW所属core process，并等待默认进程所属I/O退出。
3. 持有进程内file lock时，准备三个新文件、保持原字节的旧文件副本，以及原文件是否存在的标记，完成同步。旧文件按原字节保留，包含损坏或超预算内容。
4. 发布PREPARED，持有owner对应锁、检查其有效后进入安装，逐份rename并核查文件／目录同步。
5. 全部安装完成后发布COMMITTED。用备份文件的指纹关联已经检查的文件，结果根据提交标记及恢复结论记录。

PREPARED中断恢复旧数据，COMMITTED中断恢复新数据；回滚副本可重复恢复。材料或日志缺项时保留原文件并禁止读写，待状态核实后处理。应用事务协调配置、插件和偏好文件的整体替换。

原生返回路径后，应用继续记录仍在读取备份文件的Store任务。UI取消或放弃文件时标记retired，禁止新的读取或恢复；等最后一个使用者调用executorDrained后，再删除私有文件并返回清理结果。执行任务自己的读取已经返回时，先标记自身读取结束再等待discard；清理错误单独保留。迟到capture先等待私有文件清理，再返回实际内容及retired标记。

原生committed=true表示文件已提交。整体resultSuccess还要求设置应用、调度及按最新意图重连完成；这些步骤分别保留状态和错误，失败、取消或未完成时resultSuccess为false，已提交文件仍记录为已提交。恢复前停止时保持停止，恢复前运行时则按恢复数据和最新用户意图决定是否重连。系统逐文件恢复见[Android机制](android.md#归档与文件访问)。

## 读取与反馈

读取complete terminal frame后核对processId、inputId、请求编号、来源token及网络／存储版本，匹配后更新页面。完整集合由FD逐条导出，AppRuntime执行搜索并只保留当前页及必要计数；单条记录沿独立预算，不将8MiBframe预算用作集合总量上限。无complete terminal frame、来源变化或传输中断时保留已读内容并标明不完整，不发布完整页。换成新对象后重新读取其标识，后续读写使用新对象参数。

原页面负责显示本次结果，SnackBar实际呈现后确认已读；页面关闭时释放feedbackOwner，由全局结果显示逻辑继续处理未显示结果。`OperationFeedback`与`AppFeedbackOwnership`保留command、operation identity和本地反馈归属；统一的floating SnackBar只负责呈现，不结束业务操作，不建立第二份业务状态。自动读取异常按来源和连续失败周期去重，成功读取后才允许下一轮；旧页面、旧来源和失效操作不能继续执行action。反馈数据按层组织：

| 层／接口 | 内容 |
| --- | --- |
| model/messages | 稳定消息ID、参数及详情 |
| [PlatformFailure](../../lib/src/model/platform_failure.dart)／[MethodChannelPort](../../lib/src/platform/channel/method_channel_port.dart) | 纯Dart错误模型及Flutter通道异常适配，保留code、message、details、stacktrace和完整嵌套结构 |
| [message_text](../../lib/src/ui/locale/message_text.dart)的summary | 当前语言的操作结果、保存／应用影响及下一步 |
| technicalDetail | 原始detail、嵌套消息的技术详情及其中的cause／suppressed；resolve另提供完整消息文本 |
| [反馈组件](../../lib/src/ui/components/feedback/operation_feedback.dart) | floating SnackBar呈现首层摘要；用户点击后打开技术详情并完整复制 |

摘要通过消息结构生成，技术原文独立保留。反馈不增加正文提示行或工具栏警告占位，进度显示在原控件内；字段校验沿完整草稿检查、错误样式／语义及首错定位反馈。技术详情只由用户打开，真实确认Dialog保留，路由动作继续检查所属任务和操作身份。

内存读取与流量读取分别进行；应用与内核各自返回valid、processRssBytes及sampledAt，内核另带processId。两项分别校验5秒有效期、请求身份和错误，不合计RSS；内核停止、替换或读取失败只使对应内核采样失效，不停止应用内存刷新，也不为采样创建core process。

SAF暂时遮住应用时，保留本次备份文件和结果。初始化、snapshot及配置读取各等待5秒；前台读取失败按1／2／5／10／30秒退避，成功后结束重试。命令错误单独保留。
