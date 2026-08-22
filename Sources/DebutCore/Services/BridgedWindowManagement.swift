import CoreGraphics
import Foundation
import MachO
import ObjectiveC.runtime

// Reassigning a foreign window's Space, without a drag and without disabling SIP.
//
// Measured on macOS 26.5.2 arm64: the call returns in ~0.04ms and the window server settles
// the new assignment in ~3ms, against another process's window, with no cursor movement and
// no desktop transition. The plain private writes it replaces (SLSMoveWindowsToManagedSpace,
// CGSAddWindowsToSpaces, SLSSetWindowListWorkspace) all silently refuse foreign windows
// because the window server checks which connection owns them.
//
// macOS 26 ships ~100 `SLSBridged*Operation` classes describing window-management requests.
// Performing one takes three steps, and getting any of them wrong produces a no-op rather
// than an error:
//
//   1. Build the operation. It is an inert value object; messaging it does nothing useful.
//      In particular `-performWithWMBridgeDelegate` is the *receiving* side and returns
//      immediately in a process that is not the window manager.
//   2. Call SLSPerformAsynchronousBridgedWindowManagementOperation. It has internal linkage,
//      so dlsym cannot see it and it has to be read out of SkyLight's symbol table.
//   3. Make the bridge live. That function is a one-liner forwarding to SkyLight's bridge
//      delegate, which by default is a fallback object whose own forwarding target is nil —
//      so the request is sent to nil and vanishes. Loading the WindowManager frameworks
//      populates it.

/// Which of the bridge's silent preconditions currently hold.
///
/// Worth reporting rather than collapsing to one flag: each of these fails independently, on
/// a different OS change, and none of them surfaces as an error at the call site.
public struct BridgedWindowManagementReadiness: Equatable, Sendable {
    public let operationClassAvailable: Bool
    public let performSymbolResolved: Bool
    public let bridgeDelegateLive: Bool

    public var isReady: Bool {
        operationClassAvailable && performSymbolResolved && bridgeDelegateLive
    }
}

public enum BridgedWindowManagement {

    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

    /// The client-side entry point, mangled as a file-local C++ symbol.
    private static let performSymbolName =
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperation"
        + "P47SLSAsynchronousBridgedWindowManagementOperation"

    private typealias PerformFunction = @convention(c) (AnyObject) -> Void
    private typealias AllocFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias InitFunction =
        @convention(c) (AnyObject, Selector, NSArray, CGSSpaceID) -> Unmanaged<AnyObject>?

    /// Loading these is what turns the bridge from a nil-forwarding stub into a live one.
    /// Both are needed: WindowManager alone does not install the delegate.
    private static let bridgeLoaded: Bool = {
        let frameworks: [String] = [
            "/System/Library/PrivateFrameworks/WindowManagement.framework/WindowManagement",
            "/System/Library/PrivateFrameworks/WindowManager.framework/WindowManager",
        ]
        return frameworks.allSatisfy { dlopen($0, RTLD_LAZY) != nil }
    }()

    private static let performOperation: PerformFunction? = {
        _ = bridgeLoaded
        return machOLocalSymbol(image: skyLightPath, named: performSymbolName)
            .map { unsafeBitCast($0, to: PerformFunction.self) }
    }()

    private static let moveOperationClass: AnyClass? =
        NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")

    private nonisolated(unsafe) static let objcMsgSend: UnsafeMutableRawPointer? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    public static var readiness: BridgedWindowManagementReadiness {
        BridgedWindowManagementReadiness(
            operationClassAvailable: moveOperationClass != nil && objcMsgSend != nil,
            performSymbolResolved: performOperation != nil,
            bridgeDelegateLive: isBridgeDelegateLive()
        )
    }

    public static var isAvailable: Bool { readiness.isReady }

    /// Asks the window server to put `windowIDs` on `space`.
    ///
    /// Returns whether the request was dispatched, which is not the same as landed: the
    /// operation is asynchronous and the window server may still refuse it. Callers that need
    /// certainty read the assignment back.
    @discardableResult
    public static func moveWindows(_ windowIDs: [CGWindowID], toSpace space: CGSSpaceID) -> Bool {
        guard !windowIDs.isEmpty,
              let operationClass = moveOperationClass,
              let msgSend = objcMsgSend,
              let perform = performOperation,
              isBridgeDelegateLive()
        else { return false }

        let allocate = unsafeBitCast(msgSend, to: AllocFunction.self)
        let initialize = unsafeBitCast(msgSend, to: InitFunction.self)

        guard let allocated = allocate(operationClass, NSSelectorFromString("alloc")),
              let initialized = initialize(
                allocated.takeUnretainedValue(),
                NSSelectorFromString("initWithWindows:spaceID:"),
                windowIDs.map { NSNumber(value: $0) } as NSArray,
                space
              )
        else { return false }

        // `alloc` and `init` each return +1 and `init` consumes the one it was given, so this
        // is the single balancing release.
        perform(initialized.takeRetainedValue())
        return true
    }

    // MARK: - Preconditions

    /// True when SkyLight's bridge delegate will actually forward an operation.
    ///
    /// The default delegate is `SLSWindowManagementFallbackBridge`, which forwards to a
    /// `_manager` that is nil until the WindowManager frameworks are loaded. Messaging nil is
    /// legal in Objective-C, so an inert bridge accepts every operation and performs none.
    private static func isBridgeDelegateLive() -> Bool {
        guard bridgeLoaded,
              let getter: (@convention(c) () -> UnsafeRawPointer?) =
                machOLocalSymbol(image: skyLightPath, named: "__ZL19SLSWMBridgeDelegatev")
                .map({ unsafeBitCast($0, to: (@convention(c) () -> UnsafeRawPointer?).self) }),
              let delegatePointer = getter()
        else { return false }

        let delegate = Unmanaged<AnyObject>.fromOpaque(delegatePointer).takeUnretainedValue()
        guard let fallbackClass = NSClassFromString("SLSWindowManagementFallbackBridge"),
              object_getClass(delegate) === fallbackClass
        else {
            // Some other delegate is installed, which is the live case this stub stands in for.
            return true
        }
        guard let manager = class_getInstanceVariable(fallbackClass, "_manager") else {
            return false
        }
        return object_getIvar(delegate, manager) != nil
    }
}

// MARK: - Symbol lookup

/// Finds a symbol with internal linkage in a loaded image.
///
/// `dlsym` only searches export tables, and the bridge entry point is file-local, so it is
/// absent from SkyLight's. It is still described by `LC_SYMTAB`, which survives in the dyld
/// shared cache, so the symbol table is walked directly.
private func machOLocalSymbol(image: String, named symbol: String) -> UnsafeMutableRawPointer? {
    for index in 0..<_dyld_image_count() {
        guard let namePointer = _dyld_get_image_name(index),
              String(cString: namePointer) == image,
              let header = _dyld_get_image_header(index)
        else { continue }

        let slide = _dyld_get_image_vmaddr_slide(index)
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var linkEditBase: UInt = 0
        var symbolTable: UnsafePointer<symtab_command>?

        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self)
            // Unsigned throughout: commands carrying LC_REQ_DYLD have bit 31 set.
            switch load.pointee.cmd {
            case UInt32(LC_SEGMENT_64):
                let segment = command.assumingMemoryBound(to: segment_command_64.self)
                var raw = segment.pointee.segname
                let name = withUnsafeBytes(of: &raw) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == SEG_LINKEDIT {
                    linkEditBase = UInt(segment.pointee.vmaddr)
                        - UInt(segment.pointee.fileoff)
                        + UInt(bitPattern: slide)
                }
            case UInt32(LC_SYMTAB):
                symbolTable = UnsafePointer(command.assumingMemoryBound(to: symtab_command.self))
            default:
                break
            }
            command = command.advanced(by: Int(load.pointee.cmdsize))
        }

        guard let symbolTable, linkEditBase != 0,
              let symbols = UnsafeRawPointer(bitPattern: linkEditBase + UInt(symbolTable.pointee.symoff))?
                .assumingMemoryBound(to: nlist_64.self),
              let strings = UnsafeRawPointer(bitPattern: linkEditBase + UInt(symbolTable.pointee.stroff))?
                .assumingMemoryBound(to: CChar.self)
        else { return nil }

        for entry in 0..<Int(symbolTable.pointee.nsyms) {
            let offset = Int(symbols[entry].n_un.n_strx)
            guard offset != 0, symbols[entry].n_value != 0,
                  String(cString: strings.advanced(by: offset)) == symbol
            else { continue }
            return UnsafeMutableRawPointer(
                bitPattern: UInt(symbols[entry].n_value) + UInt(bitPattern: slide)
            )
        }
        return nil
    }
    return nil
}
