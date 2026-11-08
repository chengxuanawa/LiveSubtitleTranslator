import SwiftUI

/// 设置页（精简版：不含 AI 配置）
struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                recognitionSection
                audioSourceSection
                liveActivitySection
                recordSection
                aboutSection
            }
            .navigationTitle("设置")
            .softTopEdgeEffect()
        }
    }

    // MARK: - 识别

    private var recognitionSection: some View {
        Section {
            LabeledContent("识别引擎", value: "Apple SpeechAnalyzer")
            LabeledContent("运行方式", value: "本机识别（音频不上传）")
        } header: {
            Text("识别")
        } footer: {
            Text("iOS 26 起使用苹果新一代本机语音模型，自动断句、标点与上下文纠错；首次使用某语言时会自动下载对应模型。")
        }
    }

    // MARK: - 音频来源

    private var audioSourceSection: some View {
        Section {
            Picker("音频来源", selection: Binding(
                get: { settings.audioSourceMode.rawValue },
                set: { settings.audioSourceMode = AudioSourceMode(rawValue: $0) ?? .microphone }
            )) {
                ForEach(AudioSourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        } header: {
            Text("音频来源")
        } footer: {
            Text("系统共享音频可转写设备播放的声音。")
        }
    }

    // MARK: - 灵动岛与小窗口

    private var liveActivitySection: some View {
        Section {
            Picker("显示方式", selection: Binding(
                get: { settings.visualMode.rawValue },
                set: { settings.visualMode = VisualMode(rawValue: $0) ?? .auto }
            )) {
                ForEach(VisualMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Toggle("录制开始时自动开启字幕浮窗", isOn: $settings.autoStartLiveActivity)
        } header: {
            Text("灵动岛与小窗口")
        } footer: {
            Text("自动模式：有灵动岛的 iPhone 使用灵动岛，iPad 等机型默认使用画中画小窗口。")
        }
    }

    // MARK: - 字幕记录

    private var recordSection: some View {
        Section {
            Picker("记录标题", selection: Binding(
                get: { settings.recordTitleStyle.rawValue },
                set: { settings.recordTitleStyle = RecordTitleStyle(rawValue: $0) ?? .time }
            )) {
                ForEach(RecordTitleStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
        } header: {
            Text("字幕记录")
        } footer: {
            Text("「位置」显示录制地点（需定位权限），无法定位时显示首句字幕；「AI 标题」使用已有摘要首行，无摘要时显示时间。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            Link(destination: URL(string: "https://github.com/chengxuanawa")!) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("chengxuanawa")
                        Text("github.com/chengxuanawa")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("关于")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}