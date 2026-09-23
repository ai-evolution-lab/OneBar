# OneBar

macOS 菜单栏工具：内存、剪贴板、风扇（自动 / 固定转速 / 温度曲线）。

## 使用说明

Apple Silicon、macOS 14+。打开「终端」，粘贴下面这一行，回车，按提示输入 Mac 管理员密码：

```sh
curl -fsSL https://raw.githubusercontent.com/ai-evolution-lab/OneBar/master/Scripts/install.sh | bash
```

脚本会下载 GitHub Releases 里的预编译包，去掉隔离属性，装到 `/Applications/OneBar.app`，写入风扇授权，然后启动。

装好后就是一个普通的 `.app`：打开 **Finder → 应用程序 → OneBar**，双击即可启动。没有开「开机启动」也没关系，下次还是去这里双击。

**退出 / 重新启动：** 右键菜单栏上任意 OneBar 图标（内存、风扇、剪贴板），选「退出」或「重新启动」。内存和风扇面板底部也有这两个按钮。

## 项目介绍

三个模块都在菜单栏：

- **内存**：占用百分比与压力，点开看已用 / 应用 / 已联动 / 压缩 / 交换，以及进程内存占用 Top 10（与活动监视器"内存"列同口径）。
- **剪贴板**：记录文本、图片、文件。点菜单栏图标或默认快捷键 **⌥⌘V** 弹出窗口；支持全部 / 文本 / 图片 / 文件 / 收藏筛选，点条目写回剪贴板后再 Cmd+V。保留时长可选当天 / 1 个月 / 3 个月（默认）/ 半年 / 永久，收藏条目不过期。历史在 `~/Library/Application Support/OneBar/`。
- **风扇**：自动（交还系统）、固定转速（两颗风扇共用一个目标 RPM，超出各自上下限会钳位），或按 CPU 温度设置多条「≥ 某温度 → 某转速」条件。退出时尽量静默恢复自动。不要把转速长期锁死在过低值。请先退出 **Macs Fan Control**，否则会抢控制。

## 页面展示

菜单栏从左到右大致是：剪贴板 SF Symbol、`FAN 48° 1800`、`MEM 42%`，再往右是系统时钟。

- **内存面板**：大号占用百分比、压力文案、若干用量行、进程占用 Top 10；底部「开机启动」「重新启动」「退出」。
- **风扇面板**：CPU / 最高温度、每颗风扇当前转速与上下限；「自动 / 固定 / 曲线」分段；固定时有滑杆和 RPM 输入；曲线可添加多条温度阈值；未授权时有「授权风扇控制（仅一次）」；底部同样可以重新启动或退出。
- **剪贴板窗口**：深色列表，顶部可改快捷键、筛选胶囊、搜索框；图片有缩略图；右上角 ⋯ 可重新启动或退出。

## 系统要求

- Apple Silicon（arm64）
- macOS 14 或更高
- 预编译包为 ad-hoc 签名、未公证。安装脚本会去掉 quarantine，一般可直接打开。

## 权限

第一次风扇授权会把当前用户、且仅 `/Applications/OneBar.app/Contents/MacOS/OneBar` 写入 `/etc/sudoers.d/onebar`。之后切换策略不再要密码。App 必须放在 `/Applications/OneBar.app`，换位置后要再授权一次。

## 许可

MIT。第三方来源见 [NOTICE.md](NOTICE.md)。

致谢：[Stats](https://github.com/exelban/stats)、[Maccy](https://github.com/p0deje/Maccy)、[MacsFan](https://github.com/matejrondzik/macsfan)（机制说明另见 [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan)）。

## 从源码编译

给要改代码的人。需要本机已装 Xcode Command Line Tools。

```sh
chmod +x Scripts/build.sh
Scripts/build.sh
open build/OneBar.app
```

或直接装到应用程序：

```sh
Scripts/build.sh /Applications/OneBar.app
open /Applications/OneBar.app
```

打 Release zip：`Scripts/package.sh`，产物在 `build/OneBar.app.zip`。
