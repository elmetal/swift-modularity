enum Log {
    static func write(_ message: String) {
        print(Format.line(message))
    }
}
