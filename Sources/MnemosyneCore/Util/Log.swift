import os

public enum Log {
    public static let audio = Logger(subsystem: "local.mnemosyne", category: "audio")
    public static let app = Logger(subsystem: "local.mnemosyne", category: "app")
    public static let storage = Logger(subsystem: "local.mnemosyne", category: "storage")
}
