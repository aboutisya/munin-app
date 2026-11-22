import CoreAudio
import Foundation
import Testing
@testable import MnemosyneCore

struct AudioPolicyTests {
    @Test func classifyOutputs() {
        typealias K = OutputKind
        #expect(K.classify(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .bluetooth)
        #expect(K.classify(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil) == .bluetooth)
        #expect(K.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: K.DataSource.internalSpeaker) == .speakers)
        #expect(K.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: K.DataSource.headphones) == .wiredHeadphones)
        #expect(K.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .speakers)
        #expect(K.classify(transport: kAudioDeviceTransportTypeUSB, dataSource: nil) == .wiredHeadphones)
        #expect(K.classify(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil) == .speakers)
        #expect(K.classify(transport: kAudioDeviceTransportTypeAirPlay, dataSource: nil) == .speakers)
        #expect(K.classify(transport: kAudioDeviceTransportTypeVirtual, dataSource: nil) == .unknown)
    }

    @Test func leaks() {
        #expect(OutputKind.speakers.leaksIntoMic)
        #expect(OutputKind.unknown.leaksIntoMic)
        #expect(!OutputKind.bluetooth.leaksIntoMic)
        #expect(!OutputKind.wiredHeadphones.leaksIntoMic)
    }

    private func device(_ uid: String, _ transport: UInt32) -> AudioDevice {
        AudioDevice(id: 1, uid: uid, name: uid, transport: transport, inputChannels: 1, outputChannels: 0)
    }

    @Test func micDefaultsToBuiltInNotAirPods() {
        let airpods = device("airpods", kAudioDeviceTransportTypeBluetooth)
        let builtIn = device("builtin", kAudioDeviceTransportTypeBuiltIn)
        #expect(Recorder.chooseMic(preferredUID: nil, inputs: [airpods, builtIn])?.uid == "builtin")
    }

    @Test func micRespectsExplicitChoiceEvenBluetooth() {
        let airpods = device("airpods", kAudioDeviceTransportTypeBluetooth)
        let builtIn = device("builtin", kAudioDeviceTransportTypeBuiltIn)
        #expect(Recorder.chooseMic(preferredUID: "airpods", inputs: [airpods, builtIn])?.uid == "airpods")
    }

    @Test func micFallbacksWhenLidClosed() {
        let airpods = device("airpods", kAudioDeviceTransportTypeBluetooth)
        let usb = device("usb", kAudioDeviceTransportTypeUSB)
        // Выбранный отключён, встроенного нет (крышка закрыта): берём не-BT.
        #expect(Recorder.chooseMic(preferredUID: "gone", inputs: [airpods, usb])?.uid == "usb")
        // Только AirPods: nil, то есть системный по умолчанию.
        #expect(Recorder.chooseMic(preferredUID: nil, inputs: [airpods]) == nil)
    }

    @Test func voiceProcessingOnlyForSpeakers() {
        #expect(Recorder.needsVoiceProcessing(enabled: true, output: .speakers, mode: .online))
        #expect(Recorder.needsVoiceProcessing(enabled: true, output: .speakers, mode: .hybrid))
        #expect(!Recorder.needsVoiceProcessing(enabled: true, output: .speakers, mode: .offline))
        #expect(!Recorder.needsVoiceProcessing(enabled: true, output: .bluetooth, mode: .online))
        #expect(!Recorder.needsVoiceProcessing(enabled: true, output: .wiredHeadphones, mode: .online))
        #expect(!Recorder.needsVoiceProcessing(enabled: false, output: .speakers, mode: .online))
    }

    @Test func timerFormat() {
        #expect(Format.timer(0) == "0:00")
        #expect(Format.timer(1421) == "23:41")
        #expect(Format.timer(3727) == "1:02:07")
        #expect(Format.duration(44 * 60) == "44 мин")
        #expect(Format.duration(9.4) == "9 с")
        #expect(Format.duration(59.7) == "1 мин")
        #expect(Format.duration(65 * 60) == "1 ч 05 мин")
    }

    @Test func fourCCFormatting() {
        #expect(fourCC(OutputKind.DataSource.internalSpeaker) == "ispk")
        #expect(fourCC(OutputKind.DataSource.headphones) == "hdpn")
    }
}
