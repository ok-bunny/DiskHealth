# DiskHealth

[English](README.md) · [项目官网](https://ok-bunny.github.io/DiskHealth/) · [发行版本](https://github.com/ok-bunny/DiskHealth/releases)

DiskHealth 是一款只读的 macOS 菜单栏监控工具，适用于搭载 **Apple 芯片、运行 macOS 14 或更高版本**的 Mac。点按菜单栏的磁盘图标，即可查看内置 SSD 或外接硬盘的健康状态、CPU、内存和交换空间用量，也能打开常驻桌面的小组件。应用界面为简体中文。

## 下载安装

1. 下载 [DiskHealth 1.0.6 macOS arm64 压缩包](https://github.com/ok-bunny/DiskHealth/releases/download/v1.0.6/DiskHealth-1.0.6-macOS-arm64.zip)。
2. 解压后，将 `DiskHealth.app` 移到「应用程序」文件夹并打开。
3. 点按菜单栏的磁盘图标。想在桌面查看读数时，打开「桌面小组件」开关。

发行包使用临时签名（ad-hoc），未经 Apple 公证。首次打开时，macOS 可能要求确认。如果你信任下载来源并决定继续，可按 Apple 的说明，在「系统设置 → 隐私与安全性」中选择「仍要打开」。日常监控无需 root 权限，也无需安装第三方工具或驱动。[Apple 关于打开下载应用的说明](https://support.apple.com/zh-cn/102445)

## 监控内容

| 视图 | 可查看的内容 |
| --- | --- |
| 磁盘健康 | 读取 NVMe 和 ATA/SATA 磁盘开放的 SMART 数据。展开「详细数据」可查看型号、序列号、固件，以及设备支持的寿命、可用备件、温度、通电时间或扇区错误等指标。 |
| 系统资源 | 显示整机 CPU 占用率、已用物理内存估算值，以及已用交换空间占 macOS 当前分配总量的比例。 |
| 桌面小组件 | 展开时显示各盘状态及存储用量，收拢时用三个圆环显示 CPU、内存和交换空间。点箭头切换视图，点图钉可让小组件置顶。位置、收拢状态和置顶设置都会保存。 |

应用启动时先读取一次数据，两个自动刷新开关默认关闭。「磁盘自动刷新」负责 SMART 和存储用量，间隔可选 10 秒、30 秒、1 分钟、5 分钟或 1 小时。系统资源有独立开关，开启后每 2 秒刷新 CPU、内存和交换空间。两组数据也可以分别手动刷新。

能读到哪些 SMART 指标取决于磁盘和硬盘盒。有些 USB 桥接芯片只提供设备标识或总体状态。缺失的读数显示为「—」，无法判断健康等级时显示「未知」。存储用量覆盖本机可见的 APFS 和 HFS+ 卷，属于同一 APFS 容器的卷合并统计，避免重复计算共享空间。

## 本地数据与外观

应用通过 IOKit 读取磁盘标识和 SMART，通过 Mach 读取 CPU、内存计数，通过 `vm.swapusage` 读取交换空间。采样和健康判断都在本机完成，磁盘标识、读数和壁纸均不会上传。刷新设置和小组件偏好保存在本机。

小组件可以从本机静态壁纸生成缩略图，取小组件所在区域的亮度来调整明暗。使用动态壁纸或无法读取壁纸时，会跟随系统外观。macOS 26.4 及以上使用原生 Liquid Glass，较早的受支持版本使用 AppKit 毛玻璃材质。开启系统的「减少动态效果」后，收拢和展开会直接切换。

## 从源码构建

使用带 Swift、Clang 和 **macOS 26 或更新版本 SDK** 的 Xcode 或 Apple Command Line Tools。SDK 需要包含 AppKit 的 `NSGlassEffectView` 声明。生成的 arm64 应用可在 macOS 14 及以上系统运行。

```sh
git clone https://github.com/ok-bunny/DiskHealth.git
cd DiskHealth/app
./build.sh
open build/DiskHealth.app
```

构建脚本会编译 Swift 应用及 C 桥接层，并对应用包进行临时签名和校验。[probe 目录](probe/) 提供可独立编译的 NVMe 和 ATA SMART 诊断源码，以及实验性的 SAT 透传探针。构建应用时直接使用 [IOKit 桥接层](app/Sources/smart_bridge.c)。

## 许可证

版权所有 © 2026 DiskHealth contributors。项目采用 GNU 通用公共许可证，仅限第 3 版（`GPL-3.0-only`）。[许可证全文](LICENSE)
