import Foundation
import IOKit
import CryptoKit
import Security

enum DeviceFingerprintService {
    // SHA-256 of (IOKit serial + non-synced Keychain UUID).
    // Serial prevents reuse across physical Macs; the Keychain UUID
    // persists across reinstalls so resetting the app doesn't get a new slot.
    static var deviceHash: String {
        let serial    = platformSerialNumber() ?? "no-serial"
        let keychainID = persistentDeviceID()
        let combined  = "mira-v1:\(serial):\(keychainID)"
        let digest    = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func platformSerialNumber() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return raw.takeRetainedValue() as? String
    }

    // Stored in the login Keychain with Synchronizable=false so it never
    // copies to iCloud or moves to another Mac.
    private static func persistentDeviceID() -> String {
        let svc = "mira.device"
        let acct = "device_id"
        let readQ: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        svc,
            kSecAttrAccount:        acct,
            kSecAttrSynchronizable: kCFBooleanFalse!,
            kSecReturnData:         true,
        ]
        var item: AnyObject?
        if SecItemCopyMatching(readQ as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let id = String(data: data, encoding: .utf8) {
            return id
        }
        let newID = UUID().uuidString
        let addQ: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        svc,
            kSecAttrAccount:        acct,
            kSecAttrSynchronizable: kCFBooleanFalse!,
            kSecValueData:          Data(newID.utf8),
            kSecAttrAccessible:     kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQ as CFDictionary, nil)
        return newID
    }
}
