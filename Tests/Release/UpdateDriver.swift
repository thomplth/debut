import AppKit
import ApplicationServices

// Compiled on the host, executed only by the disposable-host harness. All input is
// addressed through AX; no global key or pointer injection is needed.
func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}
func nodes(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [element] + children.flatMap { nodes($0, depth: depth + 1) }
}
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else { exit(2) }
let app = AXUIElementCreateApplication(pid)
let all = nodes(app)
if args[2] == "dump" {
    for node in all {
        print("\(value(node, kAXRoleAttribute) ?? "" as NSString) | \(value(node, kAXTitleAttribute) ?? "" as NSString) | \(value(node, kAXDescriptionAttribute) ?? "" as NSString)")
    }
    exit(0)
}
let target = args[2]
for node in all {
    let title = value(node, kAXTitleAttribute) as? String ?? ""
    let description = value(node, kAXDescriptionAttribute) as? String ?? ""
    if title == target || description == target {
        if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success { exit(0) }
    }
}
exit(1)
