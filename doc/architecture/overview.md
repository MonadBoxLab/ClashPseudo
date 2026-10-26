# 应用架构与职责

应用将用户交互、业务执行、平台资源和内核能力分开。产品行为由[功能规范](../product/overview.md)定义；本文说明实现职责与主要调用关系，Android进程承载见[平台接入](android.md)。

## 职责划分

| 层 | 负责内容 | 主要入口 |
| --- | --- | --- |
| Flutter UI | 页面、草稿、焦点、读取与展示判断，提交用户请求 | [App](../../lib/src/app/app.dart)、[AppController](../../lib/src/app/app_controller.dart) |
| Dart业务执行者 | 下载、业务校验、三Store写入、选择／偏好、运行协调、连接观察窗口 | [AppRuntime](../../lib/src/logic/app_runtime.dart) |
| 平台宿主 | Engine／Service／Worker、权限、操作身份与期限、机械文件门、VPN和FD | [Android源码](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo) |
| Go应用衔接 | Compose、所接入内核的公开parser、字段缺省和来源、运行网络资源及公开内核接口 | [native/mihomo](../../native/mihomo) |

AppRuntime是唯一Dart业务执行者及三Store写者。UI负责读取业务文件、平台快照及已有观察窗口，并提交业务请求。平台执行机械文件发布，Dart决定业务内容与语义。

读取按任务分工：内核查看经受检平台查询，连接／流量窗口由业务层持续维护；总览与设置读自身需要的状态。业务执行独立于页面可见性，已受理发布及VPN沿各自生命周期结算。

## 调用与数据流

普通变更由UI提交，平台受理并关联owner／operationId，再由唯一业务执行者完成下载、校验、保存或运行协调。平台在执行和交付边界复核授权，UI读取结果并按所属操作反馈。受理、写入完成、应用完成和真实I/O退出是不同事实，具体协议见[操作身份与结果](data-and-operations.md#操作身份与结果)。

启动使用捕获的完整保存组合，正常释放旧资源后合成、解析并取得同次平台规格，再建立TUN及原生栈；停止先关闭新工作入口，再等待本层实际受理资源退出。数据变化、接管状态、业务写门及core上下文各有身份和生命周期。

Go内核采用进程全局状态，应用保持一个上下文；PREVIEW和VPN分别表达查看与真实接管用途，core lease及VPN session持各自状态和身份。

## 资源所有权

资源在创建／接受时登记owner，部分失败回收已取得项。取消先撤销后续发布／启动权，实际执行结束后开放槽位；关闭及销毁只结算捕获的代次，替代实例保留自己的所有权。

| 所有权 | 作用域 |
| --- | --- |
| 业务operation／writer | 一次保存、选择、更新或恢复，保护业务发布与结果 |
| core lease | 一次配置、revision、composition和用途绑定的内核上下文 |
| VPN session | TUN与实际接管状态，独立于预览 |
| UI任务／表单 | 当前阅读、草稿、回调和呈现；业务写入由AppRuntime执行 |
| 观察与查询 | 特定会话窗口、来源页、网络快照和真实在途槽 |

Store与操作协议见[数据契约](data-and-operations.md)，内核创建／关闭见[内核接入](core-integration.md)，FD和系统组件见[Android资源交接](android.md#fd与jni交接)。

## 目录与模块

Flutter入口位于lib/main.dart，包含UI和后台Engine入口；应用实现归lib/src下的[app](../../lib/src/app)、[features](../../lib/src/features)、[logic](../../lib/src/logic)、[model](../../lib/src/model)、[platform](../../lib/src/platform)及本地化。测试按受测对象组织，共享helper承担真实复用职责；benchmark记录经验指标，tool提供构建／核验能力。第三方修改源码、通知和数据材料分别归sources、notices、data。布局依据见[Dart包约定](https://dart.dev/tools/pub/package-layout)。

Go依赖方向为main→engine→configinput；main也可直接使用输入DTO。JNI、进程信任及RSS入口留main，合成／来源／字段存在性与缺省归configinput，会话、基线及网络资源归engine。Android保持一个应用Gradle模块，内部bridge、logic、schedule、controls、backup按职责组织。Manifest组件、Worker类、JNI前缀、通道和任务名作为独立系统身份保持原值。

当前应用以唯一业务执行者、三Store及单内核上下文协作；其他平台复用产品与业务契约，进程部署、接管及后台承载按平台设计。

## 界面任务与读取

布局选择位于任务状态之下。当前任务以稳定目的地和对象身份表示，保留一份必要控制器、草稿与读取链；Bar／Rail、入口数量、单／双区变化仅调整承载。完整目录和常驻入口是同一任务的不同入口。

UI读取按实际可见性调度，必要业务观察持续；失焦保留读数，需阅读的反馈待可交互时沿原操作呈现，离开页面交既有全局reader。读取形成一致投影后发布，系统动作回执与业务完成分别确认。

共享阅读组件沿[ReadingList](../../lib/src/app/widgets/reading_list.dart)等现有能力保持存活对象与相对偏移。应用级输入、语义与退出保护见[通用交互](../product/interaction.md)，机制与业务身份分别核验。
