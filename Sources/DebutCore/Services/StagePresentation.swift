public protocol DesktopSurfacePresenting: AnyObject {
    func orderToFront()
}

public protocol StageTransitionPresenting: AnyObject {
    func beginTransition()
    func completeTransition()
}
