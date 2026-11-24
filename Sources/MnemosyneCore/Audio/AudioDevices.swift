import CoreAudio
import Foundation

/// Тип устройства вывода. От него зависит, нужно ли эхоподавление.
public enum OutputKind: String, Codable, Sendable {
    case bluetooth        // AirPods и другие BT-наушники
    case wiredHeadphones  // джек или USB-гарнитура
    case speakers         // встроенные динамики, колонки, HDMI, AirPlay
    case unknown

    /// Звук из этого устройства попадает в микрофон.
    public var leaksIntoMic: Bool {
        switch self {
        case .speakers, .unknown: true
        case .bluetooth, .wiredHeadphones: false
        }
    }

    public var title: String {
        switch self {
        case .bluetooth: "наушники Bluetooth"
        case .wiredHeadphones: "проводные наушники"
        case .speakers: "динамики"
        case .unknown: "неизвестный выход"
        }
    }

    /// Чистая функция классификации, чтобы её можно было покрыть тестами.
    /// - Parameters:
    ///   - transport: `kAudioDevicePropertyTransportType`
    ///   - dataSource: `kAudioDevicePropertyDataSource` на выходе (у встроенного выхода `'ispk'` или `'hdpn'`)
    public static func classify(transport: UInt32, dataSource: UInt32?) -> OutputKind {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            switch dataSource {
            case DataSource.headphones: return .wiredHeadphones
            case DataSource.internalSpeaker: return .speakers
            default: return .speakers
            }
        case kAudioDeviceTransportTypeUSB:
            // Чаще всего USB-гарнитура или ЦАП с наушниками. Ошибка в сторону
            // «без эхоподавления» страхуется дедупликацией на уровне транскрипта.
            return .wiredHeadphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeThunderbolt:
            return .speakers
        default:
            return .unknown
        }
    }

    public enum DataSource {
        public static let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'
        public static let headphones: UInt32 = 0x6864_706E      // 'hdpn'
    }
}

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public let inputChannels: Int
    public let outputChannels: Int

    public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    public var isAggregateOrVirtual: Bool {
        transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual
    }
}

/// Перечисление устройств и свойства текущего вывода.
public enum AudioDevices {
    public static func all() -> [AudioDevice] {
        let ids = (try? AudioObject.array(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyDevices),
            initial: AudioObjectID(0))) ?? []
        return ids.compactMap(device)
    }

    public static func inputs() -> [AudioDevice] {
        all().filter { $0.inputChannels > 0 && !$0.isAggregateOrVirtual }
    }

    public static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = try? AudioObject.string(id, AudioObject.address(kAudioDevicePropertyDeviceUID)) else {
            return nil
        }
        let name = (try? AudioObject.string(id, AudioObject.address(kAudioObjectPropertyName))) ?? uid
        let transport = (try? AudioObject.scalar(
            id, AudioObject.address(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
        return AudioDevice(
            id: id, uid: uid, name: name, transport: transport,
            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput))
    }

    public static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    public static func defaultOutput() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func defaultInput() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Встроенный микрофон MacBook. `nil`, если крышка закрыта.
    public static func builtInMic() -> AudioDevice? {
        inputs().first { $0.isBuiltIn }
    }

    /// Устройством уже пользуется какой-то процесс — например, приложение звонка держит микрофон.
    /// Проверять до запуска своего движка: после запуска сюда попадаем и мы сами.
    public static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        let addr = AudioObject.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        guard AudioObject.has(id, addr) else { return false }
        return ((try? AudioObject.scalar(id, addr, initial: UInt32(0))) ?? 0) != 0
    }

    public static func outputDataSource(_ id: AudioObjectID) -> UInt32? {
        let addr = AudioObject.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        guard AudioObject.has(id, addr) else { return nil }
        return try? AudioObject.scalar(id, addr, initial: UInt32(0))
    }

    public static func outputKind(_ device: AudioDevice) -> OutputKind {
        OutputKind.classify(transport: device.transport, dataSource: outputDataSource(device.id))
    }

    /// Имя для подписи в поповере: «Динамики MacBook», «AirPods Pro».
    public static func outputTitle(_ device: AudioDevice) -> String {
        if device.isBuiltIn {
            return outputDataSource(device.id) == OutputKind.DataSource.headphones
                ? "Наушники (джек)" : "Динамики MacBook"
        }
        return device.name
    }

    // MARK: - private

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        guard let id = try? AudioObject.scalar(
            AudioObjectID(kAudioObjectSystemObject), AudioObject.address(selector),
            initial: AudioObjectID(kAudioObjectUnknown)),
            id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObject.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
