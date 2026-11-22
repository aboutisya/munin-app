import CoreAudio
import Foundation

/// Следит за устройствами: смена вывода по умолчанию, подключение и отключение
/// устройств, переключение встроенного выхода между динамиками и джеком.
@MainActor
public final class DeviceMonitor {
    public struct Snapshot: Equatable, Sendable {
        public var output: AudioDevice?
        public var outputKind: OutputKind
        public var outputTitle: String
        public var inputs: [AudioDevice]
    }

    public private(set) var snapshot: Snapshot
    public var onChange: ((Snapshot) -> Void)?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var systemBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var dataSourceBlock: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    private var pending = false

    public init() {
        snapshot = Self.read()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObject.address(selector)
            if AudioObjectAddPropertyListenerBlock(system, &addr, .main, block) == noErr {
                systemBlocks.append((addr, block))
            }
        }
        watchDataSource()
    }

    public func refresh() {
        let new = Self.read()
        let changed = new != snapshot
        snapshot = new
        watchDataSource()
        if changed { onChange?(new) }
    }

    // Несколько уведомлений приходят пачкой — собираем их в одно обновление.
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.refresh()
            }
        }
    }

    private func watchDataSource() {
        if let (id, block) = dataSourceBlock {
            var addr = AudioObject.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
            dataSourceBlock = nil
        }
        guard let output = snapshot.output else { return }
        var addr = AudioObject.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(output.id, &addr) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(output.id, &addr, .main, block) == noErr {
            dataSourceBlock = (output.id, block)
        }
    }

    nonisolated private static func read() -> Snapshot {
        let output = AudioDevices.defaultOutput()
        return Snapshot(
            output: output,
            outputKind: output.map(AudioDevices.outputKind) ?? .unknown,
            outputTitle: output.map(AudioDevices.outputTitle) ?? "нет вывода",
            inputs: AudioDevices.inputs())
    }
}
