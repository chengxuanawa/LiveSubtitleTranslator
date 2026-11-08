# SubLingo（译幕）

[![CI](https://github.com/chengxuanawa/LiveSubtitleTranslator/actions/workflows/build.yml/badge.svg)](https://github.com/chengxuanawa/LiveSubtitleTranslator/actions/workflows/build.yml)

一款完全基于 Apple 原生框架的 iOS 实时字幕 + 翻译 + AI 增强应用。支持两种音频来源：麦克风直录、或通过 **ReplayKit 屏幕录制广播扩展捕获系统音频**（可转写其他 App 播放的视频/播客）。识别用 Speech 框架，翻译用 Translation 框架，AI 增强在支持 Apple Intelligence 的设备上直连设备端大模型（Foundation Models），灵动岛 / 锁屏同步字幕。无第三方依赖，MIT 协议，适合作为二次开发基座。

## 功能特性

- 实时字幕：流式语音识别，边说边出字（部分结果实时预览）
- 实时翻译：每句识别完成后自动翻译，原文 + 译文双语显示
- 双音频来源：麦克风直录 / 系统共享音频（广播扩展捕获设备播放的声音）
- 灵动岛 / 锁屏字幕：录制中可随时手动开启（默认不自动开启），按句 + 约每秒一次的部分结果同步
- 画中画字幕：点击画中画按钮把最新字幕送入系统 PiP 窗口（需用户手动触发，系统不允许启动即进入画中画）
- AI 引擎自动选择：首次启动检测设备能力——支持 Apple Intelligence（iOS 26+）则推荐苹果设备端大模型；不可用则引导配置自定义 OpenAI 兼容 API；后期随时在设置中切换
- 会话 AI 摘要 + 译文润色（长按字幕行）
- 设备端优先：语音识别可强制离线；翻译在设备端完成（需已安装语言包）
- 16 种语言可选，语言对自由组合
- 会话记录：自动保存 JSON，可回看、左滑删除、纯文本分享导出
- iPad 适配：支持分屏 / 台前调度自由调节窗口，宽屏内容居中布局
- 原生体验：SwiftUI + SF Symbols，深色模式、动态字体、VoiceOver，API Key 存系统钥匙串

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | iOS 18.0+（AI 功能需 iOS 26+ 且设备支持 Apple Intelligence） |
| 开发环境 | macOS + Xcode 26/27（苹果智能路径需 Xcode 26+ 编译） |
| 运行 | 真机（模拟器无麦克风输入，广播扩展也需真机调试） |
| 签名 | 个人免费开发者账号即可（广播扩展与 Widget 均为自包含，无需 App Group） |

## 技术架构

```
SubLingo/
├── project.yml                     # XcodeGen：主 App + Widget 扩展 + 广播扩展
├── Broadcast/                      # ReplayKit 广播上传扩展（系统音频捕获）
│   ├── SampleHandler.swift         # 捕获 .audioApp/.audioMic 采样，转 44.1k/16bit/单声道
│   └── Info.plist                  # NSExtensionPointIdentifier = broadcast-services-upload
├── Widget/                         # Live Activity 扩展（灵动岛 / 锁屏 UI）
│   ├── LiveSubtitleWidget.swift
│   └── Info.plist                  # widgetkit-extension
└── Sources/
    ├── App/                        # 入口（依赖注入、首启引导）+ 根 TabView
    ├── Models/                     # LanguageOption / CaptionSegment / TranscriptSession / AudioSourceMode
    ├── Shared/                     # 主 App 与扩展共享
    │   ├── LiveCaptionAttributes.swift   # Live Activity 属性
    │   └── AudioStreamProtocol.swift     # 本地音频流协议（端口 / 格式）
    ├── Services/
    │   ├── SpeechRecognizerService       # Speech 流式识别（麦克风 + 外部音频）
    │   ├── SystemAudioStreamServer       # 接收广播扩展的 localhost TCP 音频 → PCM Buffer
    │   ├── TranslationService            # Translation 框架（SwiftUI translationTask 注入会话）
    │   ├── AIProvider / AppleIntelligenceProvider / OpenAICompatibleProvider / AIService
    │   ├── LiveActivityService            # ActivityKit 灵动岛字幕
    │   ├── TranscriptStore / KeychainStore / SettingsStore
    ├── ViewModels/                 # LiveSessionViewModel 会话编排（双音频源）
    ├── Views/                      # 实时字幕 / 记录 / 设置 / 首启引导 / 广播选择器
    └── Resources/                  # Info.plist（后台音频、Live Activity、多场景）+ Assets
```

系统音频数据流：

```
系统音频（其他 App 播放）
  → ReplayKit Broadcast Upload Extension（SampleHandler）
  → CMSampleBuffer 转 PCM（44.1k / 16bit / mono）
  → localhost TCP（127.0.0.1:51234，长度前缀分包）
  → 主 App SystemAudioStreamServer → AVAudioPCMBuffer
  → SFSpeechAudioBufferRecognitionRequest（手动喂入，无麦克风引擎）
  → 识别 → 翻译 → 灵动岛 / 锁屏（可选）
```

## 快速开始

### 方式一：XcodeGen（推荐）

```bash
brew install xcodegen            # 如未安装
xcodegen generate                # 生成主 App + 两个扩展 target
open SubLingo.xcodeproj
```

### 方式二：手动创建

1. Xcode → New Project → iOS App（SwiftUI，`SubLingo`，最低 18.0）
2. 将 `Sources` 拖入主 target，将 `Sources/Shared/` 同时加入扩展 target
3. 新建 Widget Extension target（勾选 Live Activities）与 Broadcast Upload Extension target，分别用 `Widget/`、`Broadcast/` 目录
4. 主 target Info.plist 合并 `Sources/Resources/Info.plist` 键（麦克风/语音识别用途、`UIBackgroundModes=audio`、`NSSupportsLiveActivities`、`UIApplicationSceneManifest`、`UIRequiresFullScreen=false`）

### 真机运行

1. Signing & Capabilities 选择 Team（免费账号即可）
2. 首次启动会弹出 AI 引擎选择；随后授权麦克风 / 语音识别
3. 系统音频模式：点击字幕页下方广播按钮 → 系统弹窗选择「译幕」→ 开始共享，再播放需要字幕的音频；停止请在控制中心点击红点

## 二次开发指引

- **替换识别引擎**：实现 `SpeechRecognizing`（默认已提供外部音频的空实现，可按需实现 `startExternalAudio` / `appendExternalBuffer`）
- **替换翻译引擎**：实现 `TextTranslating`
- **替换 AI 引擎**：实现 `TextAIProviding`
- **系统音频流协议**：见 `AudioStreamProtocol`，分包为「4 字节大端长度 + PCM(Int16 mono 44.1k)」
- **新增语言**：在 `LanguageOption.all` 追加

## 已知限制（iOS 平台约束）

- iOS 沙盒不允许 App 悬浮在其他应用上显示字幕；系统级方案是 设置 → 辅助功能 → 实时字幕
- 系统共享音频通过 ReplayKit 广播扩展捕获，必须由用户在系统弹窗确认；App 使用静音音频保持后台运行以持续接收广播
- 画中画字幕需用户手动点击进入；灵动岛按句更新，不支持逐字刷新
- 设备端语音识别语言支持因机型而异；翻译要求设备已安装对应语言包
- 苹果智能仅限 iOS 26+ 且已开启 Apple Intelligence 的设备；不满足时自动降级为自定义 API 或关闭 AI

## 隐私说明

- 语音识别与翻译均优先设备端；开启“仅在本机识别”后音频不上传
- 系统共享音频仅在设备本地进程间传输（localhost TCP），不经过网络
- 苹果智能（Foundation Models）在设备端运行；自定义 API Key 存系统钥匙串；会话记录仅存本机

## CI

GitHub Actions 使用官方 `xcode-27` 镜像（macOS 27 + Xcode 27）编译验证，并产出**未签名 IPA** 作为构建制品（Artifacts 下载）。未签名 IPA 需 Sideloadly / AltStore 自签后安装。

## 参考

- [Apple: Recognizing Speech in Live Audio（SpokenWord 示例）](https://developer.apple.com/cn/documentation/speech/recognizing-speech-in-live-audio)
- [Apple: TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Apple: ReplayKit](https://developer.apple.com/documentation/replaykit)
- [Apple: ActivityKit / Live Activity](https://developer.apple.com/documentation/activitykit)
- [WhisperBoard（GPL-3.0 转写参考）](https://github.com/Saik0s/Whisperboard)
- [sherpa-onnx（Apache-2.0 本地识别引擎）](https://github.com/k2-fsa/sherpa-onnx)
- [WhisperKit（MIT 实时转写框架）](https://github.com/argmaxinc/WhisperKit)

## 协议

MIT，见 [LICENSE](LICENSE)。