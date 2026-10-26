import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState
    @State private var showAdvanced = false
    // Cached: enumerating CoreAudio devices inside body would re-run on every
    // keystroke (stats republish the whole AppState).
    @State private var devices: [AudioDevices.Device] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !state.accessibilityTrusted {
                permissionBanner
            }
            Divider()
            switchPicker
            Divider()
            volumeSection
            Divider()
            toneSection
            Divider()
            advancedSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image(systemName: "keyboard.fill")
                .foregroundStyle(.secondary)
            Text("OpenKlack")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $state.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Toggle sounds (⌘⌃K)")
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("OpenKlack needs Accessibility access to hear your keystrokes. No keystroke data ever leaves your Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Open System Settings") { Permissions.openSystemSettings() }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.1)))
    }

    private var switchPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switches")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(state.packs) { pack in
                Button {
                    state.selectedPackID = pack.id
                } label: {
                    HStack {
                        Image(systemName: state.currentPack?.id == pack.id
                              ? "circle.inset.filled" : "circle")
                            .foregroundStyle(state.currentPack?.id == pack.id
                                             ? Color.accentColor : Color.secondary)
                        Text(pack.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: "speaker.fill").imageScale(.small)
                Slider(value: $state.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").imageScale(.small)
            }
            HStack {
                ForEach(VolumePreset.allCases, id: \.self) { preset in
                    Button(preset.label) { state.volume = preset.value }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(abs(state.volume - preset.value) < 0.01 ? .accentColor : nil)
                }
            }
        }
    }

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tone Pad")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    state.toneX = 0
                    state.toneY = 0
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .opacity(state.toneX == 0 && state.toneY == 0 ? 0 : 1)
            }
            HStack(spacing: 12) {
                TonePadView(x: $state.toneX, y: $state.toneY)
                    .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text("↔ darker / brighter")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("↕ lower / higher pitch")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer().frame(height: 4)
                    Text("Randomize pitch")
                        .font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $state.pitchVariation, in: 0...150)
                        .controlSize(.mini)
                }
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
                if showAdvanced { devices = AudioDevices.outputDevices() }
            } label: {
                HStack {
                    Text("Options")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Mute modifier keys", isOn: $state.muteModifiers)
                    Toggle("Function keys audible", isOn: $state.functionKeysAudible)
                    Toggle("Ding on return", isOn: $state.returnDing)
                    Toggle("Mouse click sounds", isOn: $state.mouseClicks)
                    Toggle("Haptic feedback", isOn: $state.hapticFeedback)
                    Toggle("Notify on switch change", isOn: $state.notifyOnSwitchChange)
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                    outputDevicePicker
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
        }
    }

    private var outputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Output", selection: Binding(
                get: { state.outputDeviceUID ?? "" },
                set: { state.outputDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .font(.callout)
            // Bluetooth headphones buffer ~100–250 ms on their own; say so,
            // since it reads as the app lagging.
            let latencyMs = Int((state.engine.outputLatency * 1000).rounded())
            if latencyMs >= 40 {
                Text("This output delays sound by ~\(latencyMs) ms (typical for Bluetooth). Speakers or wired headphones respond instantly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.todayKeystrokes.formatted()) today · \(state.totalKeystrokes.formatted()) total")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}

enum VolumePreset: CaseIterable {
    case soft, balanced, loud

    var label: String {
        switch self {
        case .soft: "Soft"
        case .balanced: "Balanced"
        case .loud: "Loud"
        }
    }

    var value: Float {
        switch self {
        case .soft: 0.25
        case .balanced: 0.55
        case .loud: 0.9
        }
    }
}
