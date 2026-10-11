import KeyboardShortcuts
import SwiftUI

/// Full-screen overlay: the frozen window in place, markers on top, a note popup beside the marker
/// being edited, and a toolbar under the window. A recording also gets a timeline to pick frames from.
struct OverlayView: View {
    @Bindable var session: AnnotationSession
    let onSend: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void
    /// Steps to an older (+1) or newer (−1) capture in history.
    let onNavigate: (Int) -> Void
    /// An unsaved new capture sits before the newest in Recent, so . can go back to it.
    let hasDraft: Bool

    @State private var hoveredID: UUID?
    @State private var hoveredCorner: Marker.Corner?
    @State private var hoveredCrop = false
    @State private var drag: DragMode?
    @State private var isBackdropShown: Bool
    @State private var popupSize = CGSize(width: NoteBubble.width, height: 44)
    /// The timeline and toolbar under the screenshot.
    @State private var controlsHeight: CGFloat = 52
    /// Showing the whole recorded screen to choose the crop, instead of annotating.
    @State private var isCropping = false
    /// The crop being dragged out, set when the drag ends.
    @State private var cropDraft: CGRect?
    /// The selected marker's popup is always shown; `.note` means its note is being typed into.
    /// Otherwise the canvas holds focus, so Delete removes the marker and Return edits its note.
    @FocusState private var focus: Focus?

    enum Focus: Hashable {
        case canvas
        case note
    }

    /// `animatesIn` fades the backdrop in when the overlay first opens, but not when stepping through history.
    init(session: AnnotationSession, animatesIn: Bool, hasDraft: Bool, onSend: @escaping () -> Void, onCopy: @escaping () -> Void, onSave: @escaping () -> Void,
         onDiscard: @escaping () -> Void, onNavigate: @escaping (Int) -> Void) {
        self.session = session
        self.onSend = onSend
        self.onCopy = onCopy
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.onNavigate = onNavigate
        self.hasDraft = hasDraft
        _isBackdropShown = State(initialValue: !animatesIn)
    }

    private enum DragMode {
        case undecided
        case drawing
        case moving(UUID, original: Marker.Shape, before: [AnnotationSession.Frame])
        case resizing(UUID, Marker.Corner, original: CGRect, before: [AnnotationSession.Frame])
        /// Drawing a new crop from a point, moving the crop, or dragging a corner with the opposite one fixed.
        case newCrop(from: CGPoint)
        case movingCrop(original: CGRect)
        case resizingCrop(anchor: CGPoint)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The desktop blurs and dims behind the screenshot, so it's clear you're annotating a capture.
            ZStack {
                DesktopBlur()
                Color.black.opacity(0.3)
            }
            .opacity(isBackdropShown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.15)) { isBackdropShown = true } }
            .contentShape(Rectangle())
            .onTapGesture(perform: finish)

            canvas
                .offset(x: imageRect.minX, y: imageRect.minY)

            if !isCropping, let id = session.selectedID, let index = session.markers.firstIndex(where: { $0.id == id }) {
                let placement = placement(for: session.markers[index], size: popupSize)
                NoteEditor(note: $session.markers[index].note, focus: $focus)
                    .noteBubble(edge: placement.edge, tailOffset: placement.tailOffset)
                    .id(id)
                    .onGeometryChange(for: CGSize.self, of: \.size) { popupSize = $0 }
                    .offset(placement.offset)
            }

            VStack(spacing: 10) {
                if let recording = session.recording {
                    RecordingTimeline(session: session, recording: recording, isCropping: $isCropping)
                        .frame(width: timelineWidth)
                }
                OverlayToolbar(style: $session.style, history: historyPosition,
                               onNavigate: onNavigate, onCopy: onCopy, onSend: onSend)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { controlsHeight = $0 }
            // Centred by layout rather than a measured offset, so it stays centred while the toolbar grows.
            .frame(width: screenSize.width)
            .offset(y: controlsTop)
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        .ignoresSafeArea()
        .tooltipLayer()
        #if DEBUG
        .onChange(of: imageRect, initial: true) {
            DemoTake.shown = .init(rect: imageRect, zoom: zoom, screen: session.capture.screen.frame)
        }
        #endif
        .background {
            // Invisible buttons for keys whose meaning depends on whether a note is being typed in.
            Group {
                Button("", action: escape).keyboardShortcut(.cancelAction)
                Button("", action: { select(nil) })
                    .keyboardShortcut(.tab, modifiers: [])
                    .disabled(focus != .note)
                // Undo marker changes. Typing in a note is undone by `OverlayPanel`, before these see the key.
                Button("", action: session.undo).keyboardShortcut("z")
                Button("", action: session.redo).keyboardShortcut("z", modifiers: [.command, .shift])
                Button("", action: onDiscard)
                    .globalKeyboardShortcut(.discard)
                    // While typing, ⌘⌫ is left to the note, which deletes to the start of the line.
                    .disabled(focus == .note && KeyboardShortcuts.getShortcut(for: .discard) == .init(.delete, modifiers: .command))
                Button("", action: onSend).globalKeyboardShortcut(.send)
                Button("", action: onCopy).globalKeyboardShortcut(.copy)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .canvas)
        .onAppear {
            // Take the keyboard as soon as the view is in the window, so Delete, Return and arrows work straight away.
            DispatchQueue.main.async { if focus == nil { focus = .canvas } }
        }
        .onKeyPress { press in
            // Backspace arrives as U+007F, which doesn't match SwiftUI's `.delete` (U+0008).
            let isDelete = press.key == .delete || press.key == .deleteForward || press.characters == "\u{7F}"
            guard isDelete, focus != .note, !isCropping, let id = session.selectedID else { return .ignored }
            session.remove(id)
            focus = .canvas
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-_")) { press in
            guard focus != .note else { return .ignored }
            session.style = session.style.resized(by: "+=".contains(press.characters) ? 1 : -1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: ",.")) { press in
            // , older and . newer, matching the toolbar's arrows.
            guard focus != .note else { return .ignored }
            let step = press.characters == "," ? 1 : -1
            guard step == 1 ? historyPosition.hasOlder : historyPosition.hasNewer else { return .handled }
            onNavigate(step)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // A recording's previous and next frame. Arrows move the cursor while typing.
            guard focus != .note, session.recording != nil else { return .ignored }
            session.step(by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            // A recording's previous and next kept frames.
            guard focus != .note, session.recording != nil else { return .ignored }
            session.jumpToKeptFrame(by: press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(.space) {
            guard focus != .note, session.recording != nil, !isCropping else { return .ignored }
            session.toggleKeep()
            return .handled
        }
        .onKeyPress(.return) {
            // Return edits the selected marker's note; with nothing selected it copies the image.
            guard focus != .note else { return .ignored }
            if isCropping {
                isCropping = false
            } else if session.selectedID != nil {
                focus = .note
            } else {
                onCopy()
            }
            return .handled
        }
    }

    private var canvas: some View {
        let markers = session.markers
        let selectedID = session.selectedID
        let hovered = drag == nil ? hoveredID : nil
        let draft = session.draft
        let style = session.style
        let bounds = session.bounds
        let firstNumber = session.firstNumber
        let size = canvasSize
        let isCropping = isCropping
        let crop = cropDraft ?? session.crop
        let zoom = zoom

        return ZStack {
            // While cropping, the whole screen; otherwise just the cropped part.
            Image(decorative: isCropping ? session.image : session.capture.image, scale: session.capture.pixelScale)
                .resizable()
                .interpolation(.high)
            Canvas { context, canvasSize in
                if isCropping {
                    // Markers where they'll be, and everything outside the crop dimmed.
                    context.withCGContext { cg in
                        cg.translateBy(x: session.crop.minX, y: session.crop.minY)
                        style.paint(markers, within: bounds, selectedID: nil, draft: nil, scale: 1, firstNumber: firstNumber, in: cg)
                    }
                    var outside = Path(CGRect(origin: .zero, size: canvasSize))
                    outside.addRect(crop)
                    context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                    context.stroke(Path(crop), with: .color(.white), lineWidth: 2 / zoom)
                    for corner in Self.corners(of: crop) {
                        let handle = 10 / zoom
                        context.fill(Path(CGRect(x: corner.x - handle / 2, y: corner.y - handle / 2, width: handle, height: handle)), with: .color(.white))
                    }
                } else {
                    context.withCGContext { cg in
                        style.paint(markers, within: bounds, selectedID: selectedID, hoveredID: hovered, draft: draft, scale: 1,
                                    firstNumber: firstNumber, in: cg)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(markerGesture)
        .onContinuousHover { phase in
            if case .active(let location) = phase, isCropping {
                hoveredCrop = session.crop.contains(location)
            } else if case .active(let location) = phase {
                hoveredCorner = session.resizeHandle(at: location)?.1
                hoveredID = session.marker(at: location)
            } else {
                hoveredCorner = nil
                hoveredID = nil
            }
        }
        .pointerStyle(pointerStyle)
        // Scaled after the gesture and hover, so they still report window points.
        .scaleEffect(zoom, anchor: .topLeading)
        .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    // MARK: Selection and editing

    /// Selects a marker without typing into its note, or clears the selection.
    private func select(_ id: UUID?) {
        session.selectedID = id
        focus = .canvas
    }

    /// Esc leaves cropping, then closes the selected marker's note popup (even mid-typing), then closes.
    private func escape() {
        if isCropping {
            isCropping = false
        } else if session.selectedID != nil {
            select(nil)
        } else {
            finish()
        }
    }

    /// Closes, saving if there are markers (or frames picked from a recording), so closing never loses work.
    private func finish() {
        if !session.isWorthSaving {
            onDiscard()
        } else {
            onSave()
        }
    }

    // MARK: Pointer

    /// Open hand over a marker that can be moved, closed while moving it, crosshair for adding.
    /// While cropping: open hand inside the crop, crosshair outside to draw a new one.
    private var pointerStyle: PointerStyle {
        switch drag {
        case .moving, .movingCrop: return .grabActive
        case .resizing(_, let corner, _, _): return Self.resizePointer(corner)
        case .resizingCrop: return .frameResize(position: .bottomTrailing)
        default: break
        }
        if isCropping {
            return hoveredCrop ? .grabIdle : .rectSelection
        }
        if let hoveredCorner { return Self.resizePointer(hoveredCorner) }
        return hoveredID != nil ? .grabIdle : .rectSelection
    }

    private static func resizePointer(_ corner: Marker.Corner) -> PointerStyle {
        switch corner {
        case .topRight: .frameResize(position: .topTrailing)
        case .bottomLeft: .frameResize(position: .bottomLeading)
        case .bottomRight: .frameResize(position: .bottomTrailing)
        }
    }

    private var markerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if isCropping {
                    dragCrop(value)
                    return
                }
                if drag == nil {
                    if let (id, corner, rect) = session.resizeHandle(at: value.startLocation) {
                        drag = .resizing(id, corner, original: rect, before: session.frames)
                    } else if let id = session.marker(at: value.startLocation),
                       let marker = session.markers.first(where: { $0.id == id }) {
                        drag = .moving(id, original: marker.shape, before: session.frames)
                        select(id)
                    } else {
                        drag = .undecided
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                switch drag {
                case .moving(let id, let original, _):
                    if let index = session.markers.firstIndex(where: { $0.id == id }) {
                        session.markers[index].shape = original.offset(by: value.translation, within: session.bounds)
                    }
                case .resizing(let id, let corner, let original, _):
                    // The opposite corner stays put; the box never gets smaller than 8pt.
                    let anchor = corner.anchor(of: original)
                    let dragged = CGPoint(x: corner.point(of: original).x + value.translation.width,
                                          y: corner.point(of: original).y + value.translation.height).clamped(to: session.bounds)
                    let x = anchor.x < dragged.x ? anchor.x : min(dragged.x, anchor.x - 8)
                    let y = anchor.y < dragged.y ? anchor.y : min(dragged.y, anchor.y - 8)
                    let rect = CGRect(x: x, y: y,
                                      width: max(abs(dragged.x - anchor.x), 8), height: max(abs(dragged.y - anchor.y), 8))
                    if let index = session.markers.firstIndex(where: { $0.id == id }) {
                        session.markers[index].shape = .box(rect)
                    }
                case .undecided where distance > 4, .drawing:
                    drag = .drawing
                    session.draft = rect(from: value.startLocation, to: value.location)
                default:
                    break
                }
            }
            .onEnded { value in
                switch drag {
                case .newCrop, .movingCrop, .resizingCrop:
                    if let cropDraft { session.setCrop(cropDraft) }
                    cropDraft = nil
                case .moving(_, _, let before), .resizing(_, _, _, let before):
                    if hypot(value.translation.width, value.translation.height) >= 3 {
                        session.recordUndo(before)
                    }
                case .drawing:
                    let box = rect(from: value.startLocation, to: value.location)
                    session.draft = nil
                    create(box.width >= 8 && box.height >= 8 ? .box(box) : .pin(value.startLocation))
                case .undecided:
                    // With a marker selected, a click elsewhere just deselects it.
                    if session.selectedID != nil {
                        select(nil)
                    } else {
                        create(.pin(value.startLocation))
                    }
                case nil:
                    break
                }
                drag = nil
            }
    }

    /// Crop dragging: from a corner resizes, from inside moves, from outside draws a new crop.
    private func dragCrop(_ value: DragGesture.Value) {
        let screen = session.sourceBounds
        if drag == nil {
            let crop = session.crop
            let reach = 14 / zoom
            if let corner = Self.corners(of: crop).first(where: { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) <= reach }) {
                drag = .resizingCrop(anchor: CGPoint(x: corner.x == crop.minX ? crop.maxX : crop.minX, y: corner.y == crop.minY ? crop.maxY : crop.minY))
            } else if crop.contains(value.startLocation) {
                drag = .movingCrop(original: crop)
            } else {
                drag = .newCrop(from: value.startLocation.clamped(to: screen))
            }
        }
        switch drag {
        case .newCrop(let start), .resizingCrop(let start):
            let end = value.location.clamped(to: screen)
            cropDraft = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .movingCrop(let original):
            let origins = CGRect(x: 0, y: 0, width: screen.width - original.width, height: screen.height - original.height)
            let origin = CGPoint(x: original.minX + value.translation.width, y: original.minY + value.translation.height).clamped(to: origins)
            cropDraft = CGRect(origin: origin, size: original.size)
        default:
            break
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// A new marker opens its note ready for typing. A recording keeps at most six frames, so a seventh can't be marked.
    private func create(_ shape: Marker.Shape) {
        guard session.add(shape) != nil else {
            NSSound.beep()
            return
        }
        // The popup's field appears in this update; focus it once it's in the window.
        DispatchQueue.main.async { focus = .note }
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let clamped = end.clamped(to: session.bounds)
        return CGRect(
            x: min(start.x, clamped.x), y: min(start.y, clamped.y),
            width: abs(clamped.x - start.x), height: abs(clamped.y - start.y)
        )
    }

    /// Where this capture sits in Recent, for the toolbar's arrows.
    private var historyPosition: HistoryPosition {
        let captures = CaptureStore.shared.captures
        return HistoryPosition(index: session.savedID.flatMap { id in captures.firstIndex { $0.id == id } }, count: captures.count,
                               hasDraft: hasDraft)
    }

    // MARK: Placement

    private static let margin: CGFloat = 32
    private static let toolbarGap: CGFloat = 16

    /// What the canvas shows, in points: the screenshot, or the whole recorded screen while cropping.
    private var canvasSize: CGSize {
        isCropping ? session.sourceBounds.size : session.capture.frame.size
    }

    /// The screenshot is shown a little smaller than the real window, so it reads as a capture
    /// rather than the live app, and smaller still if it's needed to fit the controls underneath.
    private var zoom: CGFloat {
        let window = canvasSize
        let height = screenSize.height - Self.margin * 2 - Self.toolbarGap - controlsHeight
        let width = screenSize.width - Self.margin * 2
        return min(0.9, height / window.height, width / window.width)
    }

    /// Where the screenshot sits within the overlay, top-left origin: centred in the space above the controls.
    private var imageRect: CGRect {
        let window = canvasSize
        let size = CGSize(width: window.width * zoom, height: window.height * zoom)
        let space = controlsTop - Self.toolbarGap - Self.margin
        return CGRect(x: (screenSize.width - size.width) / 2, y: Self.margin + (space - size.height) / 2, width: size.width, height: size.height)
    }

    /// A point in window points, as shown in the overlay.
    private func onScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * zoom, y: imageRect.minY + point.y * zoom)
    }

    private var screenSize: CGSize { session.capture.screen.frame.size }

    /// Pins sit beside their number. Boxes use the side with room and least overlap with other markers,
    /// or sit inside the box if no side has room. Notes stay clear of the controls. The bubble's tail points back at the marker.
    private func placement(for marker: Marker, size: CGSize) -> (offset: CGSize, edge: Edge, tailOffset: CGFloat) {
        var area = CGRect(origin: .zero, size: screenSize).insetBy(dx: 8, dy: 8)
        area.size.height = controlsTop - 8 - area.minY
        let clampX = { (x: CGFloat) in min(max(x, area.minX), area.maxX - size.width) }
        let clampY = { (y: CGFloat) in min(max(y, area.minY), area.maxY - size.height) }
        switch marker.shape {
        case .pin(let point):
            let center = onScreen(point)
            let reach = session.style.pinRadius * zoom + 4
            let fitsRight = center.x + reach + size.width <= area.maxX
            let x = fitsRight ? center.x + reach : center.x - reach - size.width
            let y = clampY(center.y - size.height / 2)
            return (CGSize(width: x, height: y), fitsRight ? .leading : .trailing, center.y - y)
        case .box(let rect):
            let origin = onScreen(rect.origin)
            let box = CGRect(x: origin.x, y: origin.y, width: rect.width * zoom, height: rect.height * zoom)
            let anchorX = box.minX + min(box.width / 2, 40)
            let anchorY = box.minY + min(box.height / 2, 40)
            let x = clampX(anchorX - 28)
            let y = clampY(anchorY - 28)
            // In order of preference when they overlap other markers equally.
            let candidates: [(frame: CGRect, edge: Edge, tailOffset: CGFloat)] = [
                (CGRect(x: x, y: box.maxY + 4, width: size.width, height: size.height), .top, anchorX - x),
                (CGRect(x: x, y: box.minY - 4 - size.height, width: size.width, height: size.height), .bottom, anchorX - x),
                (CGRect(x: box.maxX + 4, y: y, width: size.width, height: size.height), .leading, anchorY - y),
                (CGRect(x: box.minX - 4 - size.width, y: y, width: size.width, height: size.height), .trailing, anchorY - y),
            ]
            let obstacles = session.markers.filter { $0.id != marker.id }.map { other -> CGRect in
                switch other.shape {
                case .box(let rect):
                    let origin = onScreen(rect.origin)
                    return CGRect(origin: origin, size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
                        .insetBy(dx: -8, dy: -8)
                case .pin(let point):
                    let center = onScreen(point)
                    let radius = session.style.pinRadius * zoom + 8
                    return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                }
            }
            func overlap(_ candidate: CGRect) -> CGFloat {
                obstacles.reduce(0) { total, obstacle in
                    let intersection = candidate.intersection(obstacle)
                    return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
            }
            if let best = candidates.filter({ area.contains($0.frame) }).min(by: { overlap($0.frame) < overlap($1.frame) }) {
                return (CGSize(width: best.frame.minX, height: best.frame.minY), best.edge, best.tailOffset)
            }
            // Inside the top-left corner, pointing up at the box's top edge.
            let insideX = clampX(box.minX + 8)
            let insideY = clampY(box.minY + 4)
            return (CGSize(width: insideX, height: insideY), .top, anchorX - insideX)
        }
    }

    /// At the bottom of the screen, so the toolbar stays put whatever the screenshot's size.
    private var controlsTop: CGFloat {
        screenSize.height - Self.margin - controlsHeight
    }

    /// As wide as the screenshot, within reason.
    private var timelineWidth: CGFloat {
        min(max(imageRect.width, 640), screenSize.width - Self.margin * 2)
    }
}

/// Blurs whatever is behind the overlay window.
private struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
