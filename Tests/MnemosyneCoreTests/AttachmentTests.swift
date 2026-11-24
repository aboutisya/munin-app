import Foundation
import Testing
@testable import MnemosyneCore

struct AttachmentTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-att-\(UUID().uuidString)")

    @Test func copiesAndKeepsSource() throws {
        let meeting = tmp.appending(path: "meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let src = tmp.appending(path: "скрин.png")
        try Data([1, 2, 3]).write(to: src)

        let a = try Attachments.add(src, to: meeting)
        let b = try Attachments.add(src, to: meeting)
        #expect(a.lastPathComponent == "скрин.png")
        #expect(b.lastPathComponent == "скрин 2.png")
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(Set(Attachments.list(meeting).map(\.lastPathComponent)) == ["скрин.png", "скрин 2.png"])
    }

    @Test func emptyWhenNoFolder() {
        #expect(Attachments.list(tmp.appending(path: "nothing")).isEmpty)
    }

    @Test func longNameKeepsExtension() {
        let name = String(repeating: "а", count: 120) + ".pdf"
        let url = Attachments.uniqueName(name, in: tmp)
        #expect(url.pathExtension == "pdf")
        #expect(url.lastPathComponent.count <= MeetingStore.maxTitleLength + 4)
    }

    @Test func dataWithForbiddenChars() throws {
        let meeting = tmp.appending(path: "m2")
        let url = try Attachments.add(data: Data([0]), named: "a/b:c.png", to: meeting)
        #expect(url.lastPathComponent == "a b c.png")
    }

    @Test func audioRetentionIgnoresAttachments() throws {
        let meeting = tmp.appending(path: "m3")
        let src = tmp.appending(path: "voice.m4a")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data([1]).write(to: src)
        try Attachments.add(src, to: meeting)
        #expect(AudioRetention.audioFiles(meeting).isEmpty)
    }
}
