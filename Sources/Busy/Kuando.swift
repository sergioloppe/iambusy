import Foundation

/// Kuando Busylight (Alpha/Omega) HID protocol.
///
/// A command packet is 64 bytes: seven 64-bit "step" instructions followed by
/// a 64-bit footer, all packed big-endian. Only step 0 is used here. The
/// device dims after `keepAliveTimeout` seconds unless a KeepAlive step is
/// sent, so a repeating refresh is required while the light is on.
enum Kuando {
    struct DeviceID {
        let vendorID: Int
        let productID: Int
    }

    static let deviceIDs: [DeviceID] = [
        .init(vendorID: 0x04D8, productID: 0xF848), // Busylight Alpha
        .init(vendorID: 0x27BB, productID: 0x3BCA), // Busylight Alpha
        .init(vendorID: 0x27BB, productID: 0x3BCB), // Busylight Alpha
        .init(vendorID: 0x27BB, productID: 0x3BCE), // Busylight Alpha
        .init(vendorID: 0x27BB, productID: 0x3BCD), // Busylight Omega
        .init(vendorID: 0x27BB, productID: 0x3BCF), // Busylight Omega
    ]

    /// Keepalive must arrive before the device-side timeout expires,
    /// otherwise the light quiesces (or flashes if the ordering inverts).
    static let refreshInterval: TimeInterval = 10
    static let keepAliveTimeout: UInt64 = 15

    static func jumpPacket(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        packet(step0: jumpStep(red: red, green: green, blue: blue))
    }

    /// Blinking runs on the device: the step jumps back to itself, so the
    /// on/off duty cycle repeats until another packet replaces it.
    static func blinkPacket(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        onTenths: UInt8,
        offTenths: UInt8
    ) -> [UInt8] {
        packet(step0: jumpStep(
            red: red,
            green: green,
            blue: blue,
            onTenths: onTenths,
            offTenths: offTenths
        ))
    }

    static func keepAlivePacket() -> [UInt8] {
        packet(step0: keepAliveStep)
    }

    static func offPacket() -> [UInt8] {
        jumpPacket(red: 0, green: 0, blue: 0)
    }

    // Step bit layout within a big-endian 64-bit word:
    //   opcode[60..63] operand[56..59] repeat[48..55] red[40..47]
    //   green[32..39] blue[24..31] dutyOn[16..23] dutyOff[8..15]
    //   update[7] ringtone[3..6] volume[0..2]
    /// The duty fields are in 0.1s units and are not on the color scale.
    private static func jumpStep(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        onTenths: UInt8 = 0,
        offTenths: UInt8 = 0
    ) -> UInt64 {
        let opcodeJump: UInt64 = 0x1
        return opcodeJump << 60
            | scaled(red) << 40
            | scaled(green) << 32
            | scaled(blue) << 24
            | UInt64(onTenths) << 16
            | UInt64(offTenths) << 8
    }

    private static var keepAliveStep: UInt64 {
        let opcodeKeepAlive: UInt64 = 0x8
        return opcodeKeepAlive << 60 | (keepAliveTimeout & 0xF) << 56
    }

    /// The device uses a 0-100 internal color scale; the public API is 0-255.
    private static func scaled(_ value: UInt8) -> UInt64 {
        UInt64(value) * 100 / 255
    }

    // Footer bit layout: sensitivity[56..63] timeout[48..55] trigger[40..47]
    // pad[16..39]=0xFFF checksum[0..15]. The checksum is the byte sum of the
    // seven steps plus the footer's own leading six bytes.
    private static func packet(step0: UInt64) -> [UInt8] {
        var words = [UInt64](repeating: 0, count: 8)
        words[0] = step0

        let pad: UInt64 = 0xFFF << 16
        let checksum = words.reduce(byteSum(pad)) { $0 + byteSum($1) }
        words[7] = pad | (checksum & 0xFFFF)

        return words.flatMap { word in
            (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
    }

    private static func byteSum(_ word: UInt64) -> UInt64 {
        (0..<8).reduce(0) { $0 + (word >> ($1 * 8)) & 0xFF }
    }
}

extension Kuando {
    /// Print packet hex dumps for cross-checking against the Python
    /// busylight-core implementation. Invoked with `Busy --dump`.
    static func dumpPackets() {
        let dumps: [(String, [UInt8])] = [
            ("on-red   ", jumpPacket(red: 255, green: 0, blue: 0)),
            ("blink-grn", blinkPacket(red: 0, green: 255, blue: 0, onTenths: 5, offTenths: 5)),
            ("off      ", offPacket()),
            ("keepalive", keepAlivePacket()),
        ]
        for (name, bytes) in dumps {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            print("\(name) \(hex)")
        }
    }
}
