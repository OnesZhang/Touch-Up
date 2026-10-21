//
//  DebugOverlay.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//


import Cocoa
import SwiftUI
import Combine
import TouchUpCore

class DebugOverlay: NSWindow {
    
    var model: TouchUp?
    static var completion: (()->Void)?
    
    private static func constructView(model: TouchUp, locationID: HIDLocationID?) -> DebugView {
        DebugView(model:model, locationID: locationID, closeAction: {
            DebugOverlay.completion?()
        })
    }
    
    static func overlay(model: TouchUp) -> DebugOverlay {
        let vc = NSHostingController(rootView: Self.constructView(model: model, locationID: nil))
        
        let window = DebugOverlay(contentRect: .zero,
                                    styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "Touches"
        window.tabbingMode = .disallowed
        window.model = model
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        
        return window
    }
    
    
    func makeVisible(onScreen targetScreen: TUCScreen, digitizerLocationID: HIDLocationID?) {
        // create new SwiftUI view for the new digitizerLocationId
        if let host = self.windowController?.contentViewController as? NSHostingController<DebugView>,
           let model = self.model {
            host.rootView = Self.constructView(model: model, locationID: digitizerLocationID)
        }
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        if let controller = self.contentViewController {
            if let screen = targetScreen.systemScreen() {
                self.level = .screenSaver // prevents notifications from coming in
                let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
                
                let options: [NSView.FullScreenModeOptionKey : NSNumber] = [
                    .fullScreenModeApplicationPresentationOptions : NSNumber(value: presentationOptions.rawValue),
                    .fullScreenModeWindowLevel : NSNumber(value: kCGPopUpMenuWindowLevel),
                    .fullScreenModeAllScreens : NSNumber(booleanLiteral: false)
                ]
                self.setIsVisible(false)
                controller.view.enterFullScreenMode(screen, withOptions: options)
            }
        }
    }
    
    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }
        super.close()
    }
}


// MARK: - Touch Position Indicators

/// Draws a translucent circle at every finger currently touching the touchscreen.
/// The overlay is driven purely by touch data, so mouse clicks never produce an
/// indicator. Intended for screen recordings and presentations.
final class TouchIndicatorOverlay {

    private let model: TouchUp
    private var windows: [NSNumber: NSWindow] = [:]   // keyed by NSScreen number
    private var views: [NSNumber: TouchIndicatorView] = [:]
    private var observers = [AnyCancellable]()
    private var cursorHidden = false

    init(model: TouchUp) {
        self.model = model

        // One sink for both triggers: touches moving, or the toggle flipping.
        let touchUpdates = model.$touches.map { _ in () }
        let toggleUpdates = model.$isTouchIndicatorEnabled.map { _ in () }

        observers.append(
            Publishers.Merge(touchUpdates, toggleUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refresh() }
        )
    }

    private func refresh() {
        let activeCount = model.touches.filter { $0.isActive() }.count
        guard model.isTouchIndicatorEnabled else {
            hideAll()
            setCursorHidden(false)
            NSLog("[TI] refresh: off, active=%d", activeCount)
            return
        }

        rebuildWindowsIfNeeded()

        // Group active touches by screen (CG global coords → AppKit coords, y-up).
        var markersByScreen = [NSNumber: [String: CGPoint]]()
        for touch in model.touches where touch.isActive() {
            let cgPoint = model.touchManager.convertScreenPointRelative(toAbsolute: touch.location,
                                                                       locationID: touch.locationID)
            let nsPoint = CGPoint(x: cgPoint.x, y: (NSScreen.screens.first.map { NSMaxY($0.frame) } ?? 0) - cgPoint.y)

            // Prefer the screen the digitizer is mapped to (handles mirroring and
            // multi-display arrangements by construction); fall back to a geometric hit test.
            let screen = model.touchscreen(forLocationID: touch.locationID)?.systemScreen()
                ?? NSScreen.screens.first(where: { NSMouseInRect(nsPoint, $0.frame, false) })

            guard let screen else {
                NSLog("[TI] MISS cg=(%.1f,%.1f) ns=(%.1f,%.1f) locID=%u", cgPoint.x, cgPoint.y, nsPoint.x, nsPoint.y, touch.locationID)
                continue
            }

            let key = screenNumber(of: screen)
            let local = CGPoint(x: nsPoint.x - screen.frame.origin.x,
                                y: nsPoint.y - screen.frame.origin.y)
            markersByScreen[key, default: [:]][touch.uuid.uuidString] = local
            NSLog("[TI] mark cg=(%.1f,%.1f) screen=%@ local=(%.1f,%.1f)",
                  cgPoint.x, cgPoint.y, screen.localizedName ?? "?", local.x, local.y)
        }

        let totalMarkers = markersByScreen.values.reduce(0) { $0 + $1.count }
        NSLog("[TI] refresh: active=%d markers=%d screens=%d windows=%d cursorHidden=%d",
              activeCount, totalMarkers, NSScreen.screens.count, windows.count, cursorHidden ? 1 : 0)

        // Update each window; screens with no touches still get a pass so lifted
        // fingers fade out where they were last seen.
        for (key, view) in views {
            view.apply(markers: markersByScreen[key] ?? [:])
            if let window = windows[key] {
                window.orderFrontRegardless()
            }
        }

        // While a finger is on the screen the pointer itself would jump around under
        // the touch circle — hide it so recordings only show the indicator. (The
        // pointer still moves so clicks land at the touch position; it just isn't drawn.)
        setCursorHidden(!markersByScreen.isEmpty)
    }

    /// Balanced NSCursor hide/unhide so the pointer only disappears while a
    /// finger is actually on the touchscreen. While a finger is down, the hide
    /// state is re-asserted on every update: the driver's cursor warps can make
    /// macOS re-display the pointer mid-drag.
    private func setCursorHidden(_ hidden: Bool) {
        if hidden {
            if cursorHidden {
                NSCursor.unhide()
            }
            NSCursor.hide()
            if !cursorHidden {
                NSLog("[TI] cursor -> hidden")
            }
            cursorHidden = true
        } else if cursorHidden {
            cursorHidden = false
            NSCursor.unhide()
            NSLog("[TI] cursor -> visible")
        }
    }

    private func rebuildWindowsIfNeeded() {
        let currentKeys = Set(NSScreen.screens.map { screenNumber(of: $0) })
        guard Set(windows.keys) == currentKeys else {
            hideAll()
            windows.removeAll()
            views.removeAll()
            for screen in NSScreen.screens {
                let key = screenNumber(of: screen)
                let window = NSWindow(contentRect: screen.frame,
                                      styleMask: .borderless,
                                      backing: .buffered,
                                      defer: false,
                                      screen: screen)
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.isReleasedWhenClosed = false

                let view = TouchIndicatorView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.autoresizingMask = [.width, .height]
                window.contentView = view

                windows[key] = window
                views[key] = view
            }
            NSLog("[TI] rebuilt windows: %d (screens=%d)", windows.count, NSScreen.screens.count)
            return
        }
    }

    private func screenNumber(of screen: NSScreen) -> NSNumber {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) ?? 0
    }

    private func hideAll() {
        for (_, view) in views { view.apply(markers: [:]) }
        for (_, window) in windows { window.orderOut(nil) }
    }
}


/// The layer-hosting view that owns one circle layer per touch and fades a
/// circle out over 0.4 s when its finger lifts.
final class TouchIndicatorView: NSView {

    private var layers: [String: CAShapeLayer] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func apply(markers: [String: CGPoint]) {
        for (id, point) in markers {
            if let layer = layers[id] {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.position = point
                CATransaction.commit()
            } else {
                let layer = makeCircle(at: point)
                layers[id] = layer
                self.layer?.addSublayer(layer)
            }
        }

        // Finger lifted: fade the circle out, then remove it.
        for (id, layer) in layers where markers[id] == nil {
            layers[id] = nil

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = 0.4
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            layer.add(fade, forKey: "fade")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                layer.removeFromSuperlayer()
            }
        }
    }

    private func makeCircle(at point: CGPoint) -> CAShapeLayer {
        let radius: CGFloat = 22
        let layer = CAShapeLayer()
        layer.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius,
                                              width: radius * 2, height: radius * 2),
                            transform: nil)
        layer.position = point
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
        layer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 2
        return layer
    }
}
