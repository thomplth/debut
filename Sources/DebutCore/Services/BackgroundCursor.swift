import CoreGraphics
import Foundation

/// The window server ignores cursor changes from an application that is not active, and Debut
/// opens its overlay from the background without ever activating. Without this connection
/// property, a pointer style over the overlay's cards is silently dropped (KHA-1073).
enum BackgroundCursor {
    private static var key: CFString { "SetsCursorInBackground" as CFString }

    private static let setProperty: (@convention(c) (
        CGSConnectionID, CGSConnectionID, CFString, CFTypeRef?
    ) -> Int32)? = skyLightSymbol("CGSSetConnectionProperty")
    private static let copyProperty: (@convention(c) (
        CGSConnectionID, CGSConnectionID, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> Int32)? = skyLightSymbol("CGSCopyConnectionProperty")
    private static let mainConnection: (@convention(c) () -> CGSConnectionID)? =
        skyLightSymbol("CGSMainConnectionID")

    /// Whether the window server accepted the property.
    @discardableResult
    static func enable() -> Bool {
        guard let setProperty, let mainConnection else { return false }
        let connection = mainConnection()
        return setProperty(connection, connection, key, kCFBooleanTrue) == 0
    }

    static var isEnabled: Bool {
        guard let copyProperty, let mainConnection else { return false }
        let connection = mainConnection()
        var value: Unmanaged<CFTypeRef>?
        guard copyProperty(connection, connection, key, &value) == 0, let value else {
            return false
        }
        return (value.takeRetainedValue() as? Bool) == true
    }
}
