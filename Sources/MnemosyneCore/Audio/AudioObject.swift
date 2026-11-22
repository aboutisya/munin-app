import CoreAudio
import Foundation

/// Ошибка Core Audio с кодом OSStatus и местом, где она случилась.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let what: String

    public init(_ status: OSStatus, _ what: String) {
        self.status = status
        self.what = what
    }

    public var description: String { "\(what): OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status, what()) }
}

/// Четырёхсимвольный код, например `'ispk'`, для логов.
public func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(decoding: bytes, as: UTF8.self)
    }
    return String(value)
}

/// Тонкая обёртка над `AudioObjectGetPropertyData`.
enum AudioObject {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(id, &a)
    }

    static func scalar<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, initial: T) throws -> T {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        try check(status, "get \(fourCC(addr.mSelector)) on \(id)")
        return value
    }

    static func array<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, initial: T) throws -> [T] {
        var a = addr
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "size \(fourCC(addr.mSelector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        let status = values.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "get \(fourCC(addr.mSelector))")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
        var a = addr
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        try check(status, "get string \(fourCC(addr.mSelector))")
        return (ref?.takeRetainedValue() as String?) ?? ""
    }

    /// Аудио-объект процесса по PID. `nil`, если процесс ещё не открывал звук.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &a,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
