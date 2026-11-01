import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String {
        let be = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: be) { Array($0) }
        let fourCC = bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F })
            ? " '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : ""
        return "\(what) failed (OSStatus \(status)\(fourCC))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Reads a fixed-size (POD) property.
func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "AudioObjectGetPropertyData(\(selector))")
    return value
}

/// Reads an array-of-AudioObjectID property.
func getObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "GetPropertyDataSize(\(selector))")
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list), "GetPropertyData(\(selector))")
    return list
}

/// Reads a CFString property.
func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &ref) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

/// Name of the device the user is currently listening on (AirPods, interface, ...).
func defaultOutputDeviceName() -> String {
    guard let dev = try? getValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
          dev != kAudioObjectUnknown else { return "?" }
    return getString(dev, kAudioObjectPropertyName) ?? "?"
}
