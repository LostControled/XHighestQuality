# XHighestQuality

让 X（Twitter）iOS 版每次播放视频时默认选最高画质（优先 1080p），而不是先走自动 / 低码率。

- **适用版本**：X 12.46（`com.atebits.Tweetie2`）
- **系统要求**：iOS 15+，arm64
- **注入方式**：TrollFools / TrollStore 注入 dylib（已 ad-hoc 签名）
- **下载**：[XHighestQuality-1.0.0.zip](https://github.com/LostControled/XHighestQuality/raw/main/dist/XHighestQuality-1.0.0.zip)（含 dylib 与本说明）

## 原理

X 的播放链路里有多层画质限制，这个插件同时处理：

1. **`TAVVideoQualityState`**：初始化时从播放列表里选最高 endpoint（优先 1080p，其次不超过 1080p 的最高档，最后才是最高档）；`selectedQualityEndpoint` getter 在仍为 auto 时返回最高档。
2. **`TAVPlayerTechnologyQualitySelectionControlState`**：把 auto 选择替换成 1080p endpoint。
3. **`AVPlayerItem`**：把 `preferredPeakBitRate`、`preferredPeakBitRateForExpensiveNetworks` 置 0（不限制码率），`preferredMaximumResolution` 置 `CGSizeZero`（不限制分辨率），并关闭 `startsOnFirstEligibleVariant`，避免起播先选最低档。
4. **`T1VideoBitRateManager`**：绕过 X 内置的 2.5 Mbps 自动播放码率上限。

## 安装（TrollFools / TrollStore）

1. 下载 [XHighestQuality-1.0.0.zip](https://github.com/LostControled/XHighestQuality/raw/main/dist/XHighestQuality-1.0.0.zip)，解压得到 `XHighestQuality.dylib`，传到 iPhone（AirDrop、文件 App、iCloud 都行）。
2. 打开 **TrollFools**，找到已安装的 X。
3. 点「注入」/「添加插件」，选择 `XHighestQuality.dylib`。
4. 重启 X（从多任务里划掉再打开）。

如果你用的是「注入到 IPA 再重装」的方式，把 dylib 放进 `Payload/Twitter.app/Frameworks/`，并确认主二进制的 `LC_LOAD_DYLIB` 指向：

```text
@executable_path/Frameworks/XHighestQuality.dylib
```

和现有 BHTwitter / LoadControl / zxPluginsInject 没有重叠的 hook。

## 验证

重启 X 后打开 Console.app（或 TrollFools 的日志），过滤 `XHighestQuality`，正常应看到：

```text
[XHighestQuality] loading
[XHighestQuality] AVPlayerItem caps hooked
[XHighestQuality] TAVVideoQualityState hooked
[XHighestQuality] TAVPlayerTechnologyQualitySelectionControlState hooked
[XHighestQuality] T1VideoBitRateManager hooked
[XHighestQuality] all hooks installed
```

然后随便打开一个视频，点「质量」，确认默认选中 1080p；理论上不会再先糊后清。

## 从源码构建

需要 Xcode 的 iPhoneOS SDK：

```bash
git clone https://github.com/LostControled/XHighestQuality.git
cd XHighestQuality
./build.sh
```

脚本会编译 `XHighestQuality.m`、链接成 dylib，并自动 ad-hoc 签名，产物是 `XHighestQuality.dylib`。

## 本机逻辑测试

没有 iOS 真机时，可以用 macOS 上的同名假类跑一遍 hook 逻辑（不改 X 的二进制）：

```bash
./tests/run_tests.sh
```

当前 14 项全部通过，覆盖 state 初始化 / getter、control 初始化、AVPlayerItem 五个限制开关、T1VideoBitRateManager 四个返回值。

## 目录结构

```text
.
├── XHighestQuality.m        # 插件源码
├── build.sh                 # 编译 + 签名（iPhoneOS）
├── tests/
│   ├── TestHarness.m        # macOS 假类测试
│   └── run_tests.sh
└── dist/
    └── XHighestQuality-1.0.0.zip
```

## 已知限制

- 优先 1080p；没有 1080p 时选不超过 1080p 的最高档；若连 720p 都没有，则选可用的最高档。
- 不会改「数据节省模式」的 `T1VideoQualitySettings`，那个是省流量开关，不是播放器里的质量菜单。
- 目前没有在 iOS 真机上跑过（开发机只有 macOS 和 IPA），逻辑基于 X 12.46 的类 / 方法 / 字符串逆向；macOS 假类测试已通过。若某个版本改了类名，日志会显示哪一组 hook 没装完，可按日志继续定位。
- 卸载：在 TrollFools 里移除该 dylib，重启 X。

## 免责声明

仅供学习与个人研究使用，使用风险自负。本项目与 X Corp. 无关，请遵守所在地区法律及 X 的服务条款。不要将注入后的应用用于商业分发。

## 许可

仓库暂未附开源许可证，默认保留所有权利；如需转载或复用代码，请先联系作者。
