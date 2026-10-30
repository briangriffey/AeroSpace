import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                    case .staircase:
                        try await container.layoutStaircase(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

/// Every window behind the focused one leaves a visible strip, so any of them can be clicked.
/// Strip size is `staircase-padding`, shrunk so that the cascade never takes more than
/// `staircase-max-percent` of the container.
func staircaseStep(sideCount: Int, length: CGFloat, padding: CGFloat, maxPercent: CGFloat) -> CGFloat {
    if sideCount <= 0 { return 0 }
    return min(padding, length * maxPercent / 100 / CGFloat(sideCount))
}

/// Bookkeeping that stops a raise macOS ignores from being retried (and flickering) forever
private struct StaircaseRaiseState {
    let windowIds: [UInt32] // children order, flattened
    let peak: Int // index of the focused child
    var repairs: Int
}

private let maxStaircaseRepairs = 2

@MainActor private var staircaseRaiseStates: [ObjectIdentifier: StaircaseRaiseState] = [:]
@MainActor private var staircaseRaiseTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

/// Window server's front-to-back order: CGWindowID -> position, 0 is frontmost
private func currentWindowServerOrder() -> [UInt32: Int] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var result: [UInt32: Int] = [:]
    for (position, window) in info.enumerated() {
        if let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value { result[number] = position }
    }
    return result
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }

    /// A static staircase: every child has the same size and child `i` is offset by `i * step`, so no layout
    /// depends on which child is focused and focus changes move nothing. With the stacking peaking at the focused
    /// child, children before it show their start edge and children after it show their end edge.
    @MainActor
    fileprivate func layoutStaircase(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        let length = orientation == .h ? width : height
        let step = staircaseStep(
            sideCount: children.count - 1, length: length,
            padding: CGFloat(config.staircasePadding), maxPercent: CGFloat(config.staircaseMaxPercent),
        )
        let childLength = length - CGFloat(children.count - 1) * step
        for (index, child) in children.enumerated() {
            let offset = CGFloat(index) * step
            switch orientation {
                case .h:
                    try await child.layoutRecursive(point + CGPoint(x: offset, y: 0), width: childLength, height: height, virtual: virtual, context)
                case .v:
                    try await child.layoutRecursive(point + CGPoint(x: 0, y: offset), width: width, height: childLength, virtual: virtual, context)
            }
        }
        raiseStaircase(children, mruIndex)
    }

    /// macOS decides z-order, not us. The stacking has to peak at the focused child and fall off to both sides.
    /// Focusing a child already raises it natively, so moving focus to a neighbor usually needs nothing from us.
    /// Anything else (wrapping around, jumping over several children, fast cycling) is found by reading the real
    /// stacking order, and only the children that are out of order get raised, one after another.
    @MainActor
    fileprivate func raiseStaircase(_ children: [TreeNode], _ peak: Int) {
        let id = ObjectIdentifier(self)
        let childWindows = children.map { $0.allLeafWindowsRecursive }
        let windowIds = childWindows.flatMap { $0 }.map(\.windowId)
        let sameState = staircaseRaiseStates[id].map { $0.windowIds == windowIds && $0.peak == peak } ?? false
        if sameState && staircaseRaiseTasks[id] != nil { return } // already being fixed
        var state = sameState ? staircaseRaiseStates[id]! : StaircaseRaiseState(windowIds: windowIds, peak: peak, repairs: 0)
        staircaseRaiseTasks[id]?.cancel()
        staircaseRaiseTasks[id] = nil

        let order: [Int] // children to raise in order, focused one last
        let serverOrder = currentWindowServerOrder()
        // How far back a child is: the frontmost of its windows
        let depth: [Int] = childWindows.map { windows in
            windows.compactMap { serverOrder[$0.windowId] }.min() ?? Int.max
        }
        if depth.contains(Int.max) && !sameState {
            // Can't read the order, so build the whole stack once, farthest first
            order = children.indices.filter { $0 != peak }.sorted { abs($0 - peak) > abs($1 - peak) } + [peak]
        } else if depth.contains(Int.max) {
            order = []
        } else {
            let firstBadBefore = (0 ..< peak).first { depth[$0] < depth[$0 + 1] } // should be further back than the next one
            let lastBadAfter = (peak + 1 ..< children.count).last { depth[$0] < depth[$0 - 1] }
            var fix: [Int] = []
            if let firstBadBefore { fix += Array(firstBadBefore ..< peak) }
            if let lastBadAfter { fix += (peak + 1 ... lastBadAfter).reversed() }
            order = fix.isEmpty ? [] : fix + [peak]
        }
        if order.isEmpty { staircaseRaiseStates[id] = state; return }
        if state.repairs >= maxStaircaseRepairs { staircaseRaiseStates[id] = state; return }
        state.repairs += 1
        staircaseRaiseStates[id] = state

        let windows = order.flatMap { childWindows[$0] }
        staircaseRaiseTasks[id] = Task { @MainActor in
            for window in windows {
                if Task.isCancelled { return }
                await window.nativeRaise()
            }
            staircaseRaiseTasks[id] = nil
        }
    }
}
