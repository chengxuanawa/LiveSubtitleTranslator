import SwiftUI
import UIKit

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
                permissionSection
                aboutSection
            }
            .navigationTitle("设置")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - 识别

    private var recognitionSection: some View {
        Section {
            Toggle("仅在本机识别（离线）", isOn: $settings.requiresOnDeviceRecognition)
        } header: {
            Text("识别")
        } footer: {
            Text("开启后语音不上传；语言不支持离线识别时请关闭。")
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

    // MARK: - 灵动岛

    private var liveActivitySection: some View {
        Section {
            Toggle("录制开始时自动开启灵动岛字幕", isOn: $settings.autoStartLiveActivity)
        } header: {
            Text("灵动岛 / 锁屏字幕")
        } footer: {
            Text("录制中也可点击按钮手动开启；需允许实时活动。")
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
            Text("「位置」显示首句字幕；「AI 标题」使用已有摘要首行，无摘要时显示时间。")
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section("权限") {
            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                Label("打开应用权限设置", systemImage: "lock.shield")
            }
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