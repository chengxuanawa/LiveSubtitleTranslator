# LiveSubtitleTranslator（实时字幕翻译）

[![CI](https://github.com/chengxuanawa/LiveSubtitleTranslator/actions/workflows/build.yml/badge.svg)](https://github.com/chengxuanawa/LiveSubtitleTranslator/actions/workflows/build.yml)

一款完全基于 Apple 原生框架的 iOS 实时字幕 + 翻译 + AI 增强应用。麦克风收音 → 系统 Speech 框架流式识别 → SwiftUI 实时上屏 → 系统 Translation 框架逐句翻译；在支持 Apple Intelligence 的设备上还可直连苹果设备端大模型（Foundation Models）做 AI 摘要与译文润色，灵动岛 / 锁屏同步显示字幕。无第三方依赖，MIT 协议，适合作为二次开发基座。

## 功能特性

- 实时字幕：流式语音识别，边说边出字（部分结果实时预览）
- 实时翻译：每句识别完成后自动翻译，原文 + 译文双语显示
- 后台聆听 + 灵动岛/锁屏：识别中切到后台仍继续聆听，最新字幕按句同步到灵动岛与锁屏（ActivityKit Live Activity）
- AI 引擎自动选择：首次启动检测设备能力——支持 Apple Intelligence（iOS 26+）则推荐苹果设备端大模型；不可用则引导配置自定义 OpenAI 兼容 API；后期随时在设置中切换
- 会话 AI 摘要：对历史会话一键生成要点摘要（设备端或自定义 API，随记录持久化、随导出文本输出）
- 译文润色：对任一条译文一键改写得更自然口语化（长按字幕行 → AI 润色译文）
- 设备端优先：语音识别可强制离线；翻译默认系统“灵活模式”（优先设备端模型）
- 16 种语言可选（含简繁中文、英语、日语、韩语等），语言对自由组合
- 会话记录：自动保存 JSON，可回看、左滑删除、纯文本分享导出
- 原生体验：SwiftUI + SF Symbols，深色模式、横屏、动态字体、VoiceOver，API Key 存系统钥匙串
- 遵循 Apple HIG：权限文案、首启引导、ContentUnavailableView 空态、Form 分组设置、系统材质

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | iOS 18.0+（AI 功能需 iOS 26+ 且设备支持 Apple Intelligence） |
| 开发环境 | macOS + Xcode 16+；**苹果智能路径需 Xcode 26 编译**（用 Xcode 16 编译时 AI 自动降级为自定义 API / 关闭） |
| 运行 | 真机（模拟器无麦克风输入） |
| 签名 | 个人免费开发者账号即可；发布请修改 Bundle ID |

## 技术架构

```
LiveSubtitleTranslator/
├── project.yml                     # XcodeGen 工程描述
└── Sources/
    ├── App/                        # 入口（依赖注入、首启引导 sheet）+ 根 TabView
    ├── Models/                     # LanguageOption / CaptionSegment / TranscriptSession（Codable）
    ├── Services/
    │   ├── SpeechRecognizerService # Speech 框架流式识别（协议：SpeechRecognizing）
    │   ├── TranslationService      # Translation 框架翻译（协议：TextTranslating）
    │   ├── AIProvider              # AIProviderMode + TextAIProviding 协议
    │   ├── AppleIntelligenceProvider # iOS 26 Foundation Models（设备端大模型，#if canImport 门控）
    │   ├── OpenAICompatibleProvider  # 自定义 OpenAI 兼容 API（URLSession）
    │   ├── AIService               # 引擎解析：按设置与设备能力路由
    │   ├── LiveActivityService     # ActivityKit 灵动岛 / 锁屏字幕
    │   ├── TranscriptStore         # JSON 持久化
    │   ├── KeychainStore           # API Key 钥匙串存取
    │   └── SettingsStore           # @AppStorage 设置
    ├── ViewModels/                 # LiveSessionViewModel 会话编排
    ├── Views/                      # 实时字幕 / 记录 / 设置 / 首启引导
    └── Resources/                  # Info.plist（后台音频、Live Activity 开关）+ Assets
```

数据流：

```
麦克风 → AVAudioEngine tap → SFSpeechAudioBufferRecognitionRequest
      → SFSpeechRecognizer（部分/终态结果）
      → LiveSessionViewModel（追加 CaptionSegment → 灵动岛按句同步）
      → TranslationService（串行翻译队列，保证译文顺序）
      → 回填译文 → 会话结束写入 Documents/Transcripts/*.json
      →（可选）AIService → 苹果设备端大模型 / 自定义 API → 摘要、润色
```

## 快速开始

### 方式一：XcodeGen（推荐）

```bash
brew install xcodegen            # 已安装可跳过
xcodegen generate                # 在项目根目录执行
open LiveSubtitleTranslator.xcodeproj
```

### 方式二：手动创建

1. Xcode → New Project → iOS App（SwiftUI，名称 `LiveSubtitleTranslator`，最低部署版本 18.0）
2. 删除模板文件，将本仓库 `Sources` 目录拖入工程（勾选 Create groups）
3. 将 `Sources/Resources/Info.plist` 中的键合并进工程自带的 Info.plist（麦克风/语音识别用途描述、`UIBackgroundModes=audio`、`NSSupportsLiveActivities`、`UILaunchScreen`、`ITSAppUsesNonExemptEncryption`）

### 真机运行

1. Signing & Capabilities 选择你的 Team
2. 真机运行；首次点击开始时授权「麦克风」与「语音识别」
3. 首次启动会弹出 AI 引擎选择：支持苹果智能的设备推荐直接使用；否则填写自定义 API（OpenAI 兼容），或选「关闭 AI 功能」
4. 最新版苹果智能路径建议用 Xcode 26 编译；若使用 Xcode 16，代码中 `#if canImport(FoundationModels)` 会自动剔除苹果模型分支

## 二次开发指引

- **替换识别引擎**：实现 `SpeechRecognizing` 协议即可接入 WhisperKit / sherpa-onnx
- **替换翻译引擎**：实现 `TextTranslating` 协议（如接入在线翻译 API）
- **替换 AI 引擎**：实现 `TextAIProviding` 协议（任何大模型 / 服务）；苹果智能实现本身就是参考样板
- **新增语言**：在 `LanguageOption.all` 追加即可
- **导出 SRT**：`CaptionSegment.startTime` 已记录时间轴，参考 `TranscriptSession.exportText()` 新增生成器
- **AI 提示词调优**：摘要/润色的 Instructions 集中在 `AppleIntelligenceProvider` 与 `OpenAICompatibleProvider` 中，可独立迭代

## 已知限制（iOS 平台约束）

- iOS 沙盒不允许 App 悬浮在其他应用上显示字幕；系统级方案是 设置 → 辅助功能 → 实时字幕，两者互补
- 后台聆听依赖 `UIBackgroundModes=audio`，识别会话在后台的持续时长受系统调度影响；锁屏与灵动岛字幕按句更新（Live Activity 更新频率受系统预算限制，不支持逐字刷新）
- 只能通过麦克风收音（例如对着扬声器/外放听外语视频），无法截取系统内音频
- 设备端语音识别语言支持因机型/系统而异，不支持时会提示关闭“仅在本机识别”
- 翻译与苹果智能模型默认优先设备端，语言包/模型未就绪时可能回退服务器（需联网）
- 苹果智能仅限 iOS 26+ 且已开启 Apple Intelligence 的设备；不满足时自动降级为自定义 API 或关闭 AI 功能

## 隐私说明

- 语音识别与翻译均优先设备端完成；开启“仅在本机识别”后语音绝不上传
- 苹果智能（Foundation Models）在设备端运行，内容不离开设备
- 自定义 API 由用户自行选择服务，API Key 存系统钥匙串；会话记录仅存本机 Documents 目录，无任何内置上报

## 参考

- [Apple: Recognizing Speech in Live Audio（SpokenWord 示例）](https://developer.apple.com/cn/documentation/speech/recognizing-speech-in-live-audio)
- [Apple: TranslationSession（含字幕时间轴对齐说明）](https://developer.apple.com/cn/documentation/translation/translationsession)
- [Apple: Foundation Models 框架（设备端大模型）](https://developer.apple.com/documentation/foundationmodels)
- [Apple: ActivityKit / Live Activity](https://developer.apple.com/documentation/activitykit)
- [WhisperBoard（GPL-3.0 转写参考）](https://github.com/Saik0s/Whisperboard)
- [sherpa-onnx（Apache-2.0 本地识别引擎）](https://github.com/k2-fsa/sherpa-onnx)
- [WhisperKit（MIT 实时转写框架）](https://github.com/argmaxinc/WhisperKit)

## 协议

MIT，见 [LICENSE](LICENSE)。