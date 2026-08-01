import CoreGraphics

public protocol DesktopSurfacePresenting: AnyObject {
    func orderToFront()
    func orderBehind(windowID: CGWindowID) -> Bool
}
