# OneBar

macOS 菜单栏工具：内存、剪贴板、风扇（自动 / 固定转速 / 温度曲线）。
另支持 macOS 27 的第三方菜单栏图标收纳：下拉勾选需要常驻显示的应用。

## 使用说明

Apple Silicon、macOS 14+。打开「终端」，粘贴下面这一行，回车，按提示输入 Mac 管理员密码：

```sh
curl -fsSL https://raw.githubusercontent.com/ai-evolution-lab/OneBar/master/Scripts/install.sh | bash
```

脚本会下载 GitHub Releases 里的预编译包，去掉隔离属性，装到 `/Applications/OneBar.app`，写入风扇授权，然后启动。

装好后就是一个普通的 `.app`：打开 **Finder → 应用程序 → OneBar**，双击即可启动。没有开「开机启动」也没关系，下次还是去这里双击。

**退出 / 重新启动：** 右键菜单栏上任意 OneBar 图标（内存、风扇、剪贴板），选「退出」或「重新启动」。内存和风扇面板底部也有这两个按钮。

**菜单栏收纳（macOS 27+）：** 点击 OneBar 的托盘图标，或右键任一 OneBar 图标 →「菜单栏收纳…」，在下拉面板勾选常驻显示的应用。例如 10 个应用只勾选 3 个，其余 7 个即收纳；重新勾选即可单独恢复，重启后保留选择。首次需在「系统设置 → 隐私与安全性 → 辅助功能」允许 OneBar，授权后列表自动更新。「全部显示」清除收纳选择。

收纳按应用生效，同一应用的多个图标一起切换；OneBar 与系统图标始终保留，新应用默认显示。macOS 27 的收纳接口要求应用安装在 `/Applications`，请从 `/Applications/OneBar.app` 运行；系统设置已禁止显示的图标仍需去系统设置中开启。此功能动态调用系统私有接口，接口缺失或激活失败时会显示原因并释放收纳。退出 OneBar 时恢复显示，下次启动重新应用选择。macOS 14–26 的原有功能仍可使用。

## 项目介绍

三个模块都在菜单栏：

- **内存**：占用百分比与压力，点开看已用 / 应用 / 已联动 / 压缩 / 交换，以及进程内存占用 Top 10（与活动监视器"内存"列同口径）。
- **剪贴板**：记录文本、图片、文件。点菜单栏图标或默认快捷键 **⌥⌘V** 弹出窗口；支持全部 / 文本 / 图片 / 文件 / 收藏筛选，点条目写回剪贴板后再 Cmd+V。↑↓ 选择、↩ 复制、空格预览大图、⌘⌫ 删除；重复复制会合并到顶部；图片文字经 OCR 后可搜索，也能一键复制文字，图片可直接拖到其他应用。保留时长可选当天 / 1 个月 / 3 个月（默认）/ 半年 / 永久，收藏条目不过期。历史在 `~/Library/Application Support/OneBar/`。
- **风扇**：自动（交还系统）、固定转速（两颗风扇共用一个目标 RPM，超出各自上下限会钳位），或按温度曲线调速：控制温度取平滑后的 CPU / GPU 较高值，在曲线点之间插值并限制升降速率；低于最低点 3° 交还系统（可停转），实测连续 ≥90° 立即满速。退出、睡眠或 App 异常退出时都会交还系统自动。不要把转速长期锁死在过低值。请先退出 **Macs Fan Control**，否则会抢控制。

## 页面展示

菜单栏从左到右大致是：剪贴板 SF Symbol、`FAN 48° 1800`、`MEM 42%`，再往右是系统时钟。

- **内存面板**：大号占用百分比、压力文案、若干用量行、进程占用 Top 10；底部「开机启动」「重新启动」「退出」。
- **风扇面板**：CPU / GPU / 全机最高温度、每颗风扇当前转速与上下限；「自动 / 固定 / 曲线」分段；固定时有滑杆和 RPM 输入；曲线可添加多个温度点，并显示当前控制温度与目标转速；未授权时有「授权风扇控制（仅一次）」；底部同样可以重新启动或退出。
- **剪贴板窗口**：深色列表，顶部可改快捷键、筛选胶囊、搜索框；图片有缩略图与像素尺寸，支持大图预览；右上角 ⋯ 可重新启动或退出。

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

选择逻辑自测：`build/OneBar.app/Contents/MacOS/OneBar selftest-menu-bar`。

打 Release zip：`Scripts/package.sh`，产物在 `build/OneBar.app.zip`。
