# 品牌源图与 Android 导出

本目录保存品牌原图及Android资源的导出方法。平台资源按同一轮廓派生，源图替换时重新计算几何与单色提取参数，并同步相应资源。

| 文件 | 用途 |
|---|---|
| [icon.png](icon.png) | 完整彩色图标，供传统 Launcher 图标使用 |
| [foreground.png](foreground.png) | 透明品牌前景，供自适应图标、启动画面及单色轮廓提取 |
| [background.png](background.png) | 与前景配套的背景，自适应图标中铺满图层 |

## Android 资源对应

资源根目录为 [`android/app/src/main/res/`](../../android/app/src/main/res)。表中密度顺序固定为 mdpi、hdpi、xhdpi、xxhdpi、xxxhdpi，倍率分别为 1、1.5、2、3、4。

| 资源 | 尺寸与用途 |
|---|---|
| `mipmap-*/ic_launcher.png` | 48dp；直接缩小完整 `icon.png`，供 API 24 等传统 Launcher 使用 |
| `mipmap-*/ic_launcher_foreground.png` | 108dp；透明前景按实际轮廓居中并缩入自适应安全区 |
| `mipmap-*/ic_launcher_background.png` | 同上；完整背景等比缩小，以Alpha=255铺满图层，裁切由Launcher mask处理 |
| `mipmap-*/ic_launcher_monochrome.png` | 同上；独立的白色Alpha轮廓及眼鼻负形，供系统着色 |
| [`mipmap-anydpi-v26/ic_launcher.xml`](../../android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml) | API 26+ 自适应前景／背景 |
| [`mipmap-anydpi-v33/ic_launcher.xml`](../../android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml) | API 33+ 增加独立 monochrome 图层；是否显示主题图标由 Launcher 和用户系统设置决定 |
| `drawable-*/widget_logo.png` | 48dp；完整 `icon.png` 等比缩小后以抗锯齿圆形 Alpha 遮罩导出，供小组件按圆形轮廓统一显示 |
| `drawable-*/branding_splash.png` | 288dp；透明彩色前景，按透明图标的系统SplashScreen规格独立排布 |
| [`drawable/launch_background.xml`](../../android/app/src/main/res/drawable/launch_background.xml)、[`drawable-v21/launch_background.xml`](../../android/app/src/main/res/drawable-v21/launch_background.xml) | 旧启动窗口：居中并按资源密度显示 `branding_splash` |
| `values/styles.xml`、`values-night/styles.xml` | 旧启动主题及 Flutter 正常窗口底色 |
| `values-v31/styles.xml`、`values-night-v31/styles.xml` | API 31+ 显式设置系统 SplashScreen 的静态图标和底色；窗口背景只显示底色 |
| `values/colors.xml`、`values-night/colors.xml` | 启动及正常窗口底色：浅色 `#F8F6F1`、深色 `#191C1F`，与应用默认表面衔接 |
| [`drawable/ic_vpn_notification.xml`](../../android/app/src/main/res/drawable/ic_vpn_notification.xml) | 24dp单色矢量，使用原图的猫形轮廓，并留出眼鼻孔洞，图形高20dp；VPN与后台工作通知使用同一图标，也可供快捷设置磁贴使用 |

Manifest使用 `@mipmap/ic_launcher`、`@style/LaunchTheme` 和Flutter `NormalTheme`。API24及后续版本的小组件统一使用独立的48dp圆形 `widget_logo`。品牌图表达应用身份，连接、失败和路由模式使用各自状态图形；快捷菜单分别提供连接和断开的动作图。系统入口的布局、刷新与动作由对应平台实现负责。

## 安全区、单色和导出方法

使用JDK ImageIO／Java2D离线导出PNG，ImageIO输出仅包含图像所需元数据。同一JDK、源图和参数用于字节重现；工具链变化时重新核对像素与输出差异。

1. 读取三张正式源图的实际尺寸及Alpha分布，取得Alpha大于0像素的半开边界及轮廓中心；逐像素计算像素中心到轮廓中心的最大距离，作为本次导出的源轮廓半径。尺寸、边界、像素数量与摘要由当前文件计算。
2. 完整图标和背景使用 `Image.SCALE_AREA_AVERAGING` 缩小；透明图采用预乘Alpha处理边缘。前景先按目标比例面积平均缩小整张源图，再用bicubic进行亚像素居中平移，完整保留原Logo轮廓。
3. 自适应图层画布为108dp，目标轮廓半径为31dp。缩放比由目标半径、密度倍率和当前源轮廓半径推导，输出尺寸由实际源图宽高计算，再按真实缩放后的轮廓中心居中平移。包括滤波后非零Alpha像素的四角在内，逐像素核查中心直径66dp的安全圆；圆形、圆角方形、squircle和teardrop等mask分别检查。背景铺满108dp，前景采用原始透明轮廓。
4. 启动图使用同样的轮廓居中方法，但画布为 288dp，目标轮廓半径为 90dp，所有非零 Alpha 必须位于直径 192dp 的安全圆内。启动图使用独立透明画布。旧启动窗口和 API 31+ 系统启动图引用相同的独立启动资源；浅深两套布局／尺寸相同，只更换窗口底色。
5. 单色图从原Alpha轮廓生成。当前源图的眼睛／鼻子负形提取参数为 `y < 700` 且RGB三通道均大于210的浅色区域；其余非透明区域转为白色，胸前三条彩色装饰合入主体白色区域。缩小后保留Alpha，Alpha大于0的像素RGB统一为白色。替换源图后重新核对采样区域、提取阈值及实际生成的负形。
6. 通知矢量沿同一单色像素区域的暴露边缘提取路径，保持一条外轮廓及三条眼鼻孔洞；闭合路径简化容差为原图 1.5px，等比居中到 24dp 画布内，高度 20dp。白色填充配 `evenOdd`，画布保持透明，胸前区域合入主体轮廓。

## 导出检查

导出后重新解码PNG，检查像素与导出前一致，并核查各密度尺寸、透明边缘、背景Alpha值、独立单色层、XML引用与资源限定符、资源名和源文件摘要。使用SDK的aapt2 compile/link检查资源合法性。

在圆形、圆角方形、squircle、teardrop以及浅深底、小尺寸预览中，目视检查耳尖、胡须、底边、眼鼻负形与边缘。Launcher mask、主题图标、启动至Flutter首帧过渡、通知／Tile和小组件的集成检查见[界面验证](../../doc/development/verification.md#界面与自适应)。

## 源图校验

源图由Git管理，导出前可在项目根目录计算文件摘要：

```sh
sha256sum assets/branding/icon.png assets/branding/foreground.png assets/branding/background.png
```

替换素材时重新核对安全区、单色提取参数与各平台导出。
