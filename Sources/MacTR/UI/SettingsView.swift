// SettingsView.swift — Settings window (SwiftUI)
//
// Tabs: General | Display | magpie | Device | About

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hardwareJPEG = JPEGEncoder.useHardware

    // magpie gateway — edited as drafts, applied on 保存. The key is read off
    // the main thread (loadAPIKey): the first read may wait on a Keychain prompt
    @State private var gatewayURL = MagpieConfig.savedURL
    @State private var apiKey = ""
    @State private var savedGatewayURL = MagpieConfig.savedURL
    @State private var savedAPIKey = ""
    @State private var keyLoaded = false
    @State private var probing = false
    @State private var gatewayStatus: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }

            Tab("Display", systemImage: "display") {
                displaySettings
            }

            Tab("magpie", systemImage: "point.3.connected.trianglepath.dotted") {
                magpieSettings
            }

            Tab("Device", systemImage: "cable.connector") {
                deviceSettings
            }

            Tab("About", systemImage: "info.circle") {
                aboutView
            }
        }
        .frame(width: 480, height: 380)
    }

    // MARK: - General Tab

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Text("Requires .app bundle to work (not available in debug builds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Interval", selection: $state.refreshInterval) {
                    Text("0.5s (default)").tag(0.5)
                    Text("1.0s").tag(1.0)
                    Text("2.0s").tag(2.0)
                }
                .onChange(of: state.refreshInterval) {
                    state.applySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display Tab

    private var displaySettings: some View {
        Form {
            Section("Brightness") {
                HStack {
                    Slider(value: brightnessBinding, in: 1...10, step: 1) {
                        Text("Level")
                    }
                    Text("\(state.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: state.brightness) {
                    state.applySettings()
                }
                Text("1 = original, 10 = maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rotation") {
                Toggle("Rotate 180°", isOn: $state.rotateDisplay)
                    .onChange(of: state.rotateDisplay) {
                        state.applySettings()
                    }
                Text("Enable if display appears upside down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Encoding") {
                Toggle("Hardware JPEG encoding", isOn: $hardwareJPEG)
                    .onChange(of: hardwareJPEG) { _, on in
                        JPEGEncoder.useHardware = on
                        UserDefaults.standard.set(on, forKey: "hardwareJPEG")
                    }
                Text("Encode frames on Apple silicon's media engine: about half the CPU. Turn off if the display shows glitches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - magpie Tab

    private var magpieSettings: some View {
        Form {
            Section("magpie 网关") {
                TextField("网关地址", text: $gatewayURL, prompt: Text(MagpieConfig.defaultURL))
                    .textContentType(.URL)
                SecureField("API Key", text: $apiKey, prompt: Text(keyLoaded ? "本机网关可留空" : "读取钥匙串…"))
                    .disabled(!keyLoaded)
                HStack {
                    Button("测试连接", action: probeGateway)
                        .disabled(probing || !keyLoaded)
                    Button("保存", action: saveGateway)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!keyLoaded || (gatewayURL == savedGatewayURL && apiKey == savedAPIKey))
                    Spacer()
                    if probing {
                        ProgressView().controlSize(.small)
                    }
                }
                if let gatewayStatus {
                    Text(gatewayStatus)
                        .font(.caption)
                        .foregroundStyle(gatewayStatus.hasPrefix("✗") ? .red : .green)
                }
            }

            Section {
                Text("地址留空即本机网关 \(MagpieConfig.defaultURL)。远程网关填网页 Key（magpie web 登录链接里 k= 的值）才有路由和用量；只填网关 Key 时只有订阅用量。Key 类型自动识别，保存在系统钥匙串中。保存后副屏约 1 秒内切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadAPIKey() }
    }

    private func loadAPIKey() async {
        guard !keyLoaded else { return }
        let key = await Task.detached { MagpieConfig.apiKey }.value
        apiKey = key
        savedAPIKey = key
        keyLoaded = true
    }

    // MARK: - Device Tab

    private var deviceSettings: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(state.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if let info = state.deviceInfo {
                    LabeledContent("Resolution", value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected {
                    Button("Reconnect") {
                        state.connect()
                    }
                }
            }

            Section("Statistics") {
                LabeledContent("Frames Sent", value: "\(state.frameCount)")
                LabeledContent("Last Frame", value: "\(state.lastFrameSize / 1024) KB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MacTR")
                .font(.title)
                .fontWeight(.semibold)

            Text("macOS driver for Thermalright Trofeo Vision 9.16 LCD")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Built with Swift 6.3 + libusb")
                Text("Protocol: LY Bulk (thermalright-trcc-linux)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func probeGateway() {
        probing = true
        gatewayStatus = nil
        let url = gatewayURL, key = apiKey
        Task {
            let result = await Task.detached { MagpieCollector.probe(url: url, apiKey: key) }.value
            gatewayStatus = result
            probing = false
        }
    }

    private func saveGateway() {
        MagpieConfig.save(url: gatewayURL, apiKey: apiKey)
        gatewayURL = MagpieConfig.savedURL
        apiKey = MagpieConfig.apiKey
        savedGatewayURL = gatewayURL
        savedAPIKey = apiKey
        gatewayStatus = "已保存 · 正在切换到 \(MagpieConfig.baseURL)"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[Settings] Launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(state.brightness) },
            set: { state.brightness = Int($0) }
        )
    }
}
