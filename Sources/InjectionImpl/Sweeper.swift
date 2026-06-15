//
//  Sweeper.swift
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  This is how the instance level @objc func injected()
//  method is called. Performs a "sweep" of all reachable
//  live objects in the app to find instances of classes
//  that have been injected to message.
//
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(InjectionImplC)
import InjectionImplC
import DLKitD
#endif
#if os(iOS) || os(tvOS)
import UIKit
#endif

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

public struct Sweeper: Sendable {
    nonisolated(unsafe)
    static var sweepWarned = false
    static let injectedSEL = #selector(SwiftInjected.injected)
    let notification = Notification.Name(INJECTION_BUNDLE_NOTIFICATION)
    let testQueue = DispatchQueue(label: "INTestQueue")

    public func sweepAndRunTests(image: ImageSymbols,
                                 classes: Reloader.ClassInfo) {
        DispatchQueue.main.async {
            let toSweep = classes.old + self.hookedPatch(of: classes.generics, in: image)
            let oldWay = getenv(INJECTION_OF_GENERICS) != nil && toSweep.count == classes.old.count
            self.performSweep(oldClasses: toSweep, oldWay ? classes.generics : [], image: image)

            NotificationCenter.default.post(name: self.notification, object: classes.new)

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass {
                let testClasses = classes.new.filter { Self.isSubclass($0, of: XCTestCase) }

                // Thanks https://github.com/johnno1962/injectionforxcode/pull/234
                if !testClasses.isEmpty {
                    print("\n")
                    self.testQueue.async {
                        self.testQueue.suspend()
                        let timer = Timer(timeInterval: 0, repeats:false, block: { _ in
                            for newClass in testClasses {
                                log("Running test \(_typeName(newClass))")
                                NSObject.runXCTestCase(newClass)
                            }
                            self.testQueue.resume()
                        })
                        RunLoop.main.add(timer, forMode: .common)
                    }
                }
            }
        }
    }

    /// Implement our own as runtime function crashes for generaics.
    static func isSubclass(_ subClass: AnyClass, of aClass: AnyClass) -> Bool {
        var subClass: AnyClass? = subClass
        repeat {
            if subClass == aClass {
                return true
            }
            subClass = class_getSuperclass(subClass)
        } while subClass != nil
        return false
    }

    func performSweep(oldClasses: [AnyClass],
                      _ injectedGenerics: Set<String>, image: ImageSymbols) {
        /// Class level injected() methods
        typealias ClassIMP = @convention(c) (AnyClass, Selector) -> ()
        for cls in oldClasses {
            if let classMethod = class_getClassMethod(cls, Self.injectedSEL) {
                let classIMP = method_getImplementation(classMethod)
                unsafeBitCast(classIMP, to: ClassIMP.self)(cls, Self.injectedSEL)
            }
        }
        /// Instance level injected() methods...
        var injectedClasses = [AnyClass]()
        var viewControllersToReload = [AnyClass]()
        for cls in oldClasses {
            if class_getInstanceMethod(cls, Self.injectedSEL) != nil {
                injectedClasses.append(cls)
                if !Self.sweepWarned {
                    log("""
                        As class \(cls) has an @objc injected() \
                        method, \(APP_NAME) will perform a "sweep" of live \
                        instances to determine which objects to message. \
                        If this fails, subscribe to the notification \
                        "\(INJECTION_BUNDLE_NOTIFICATION)" instead. Set an env var \
                        \(INJECTION_SWEEP_DETAIL) in your scheme for more information.
                        \(APP_PREFIX)(note: notification may not arrive on the main thread)
                        """)
                    Self.sweepWarned = true
                }
                let kvoName = "NSKVONotifying_" + NSStringFromClass(cls)
                if let kvoCls = NSClassFromString(kvoName) {
                    injectedClasses.append(kvoCls)
                }
            } else {
                #if os(iOS) || os(tvOS)
                if let UIViewController = objc_getClass("UIViewController") as? AnyClass,
                   Self.isSubclass(cls, of: UIViewController) {
                    viewControllersToReload.append(cls)
                }
                #endif
            }
        }

        // implement -injected() method using sweep of objects in application
        if !injectedClasses.isEmpty || !viewControllersToReload.isEmpty || !injectedGenerics.isEmpty {
            log("Starting sweep \(injectedClasses), \(viewControllersToReload), \(injectedGenerics)...")
            var patched = Set<UnsafeRawPointer>()
            SwiftSweeper(instanceTask: {
                (instance: AnyObject) in
                if let instanceClass = object_getClass(instance) {
                    if injectedClasses.contains(where: {
                       $0 == instanceClass || $0 === instanceClass }) ||
                    !injectedGenerics.isEmpty &&
                    self.patchGenerics(oldClass: instanceClass, image: image,
                        injectedGenerics: injectedGenerics, patched: &patched) {
                        let proto = unsafeBitCast(instance, to: SwiftInjected.self)
                        proto.injected?()                    } else if viewControllersToReload.contains(where: {
                        $0 == instanceClass || $0 === instanceClass }) {
                        #if os(iOS) || os(tvOS)
                        if let vc = instance as? UIViewController {
                            let nibName = vc.nibName ?? String(describing: type(of: vc))
                            let bundle = Bundle(for: type(of: vc))
                            self.reloadViewControllerView(vc: vc, nibName: nibName, bundle: bundle)
                        }
                        #endif
                    }
                }
            }).sweepValue(SwiftSweeper.seeds)
        }
    }

    public func sweepAndReloadXIB(nibName: String) {
        DispatchQueue.main.async {
            log("Starting sweep to reload XIB: \(nibName)")
            SwiftSweeper(instanceTask: { (instance: AnyObject) in
                #if os(iOS) || os(tvOS)
                if let vc = instance as? UIViewController {
                    let vcNibName = vc.nibName ?? String(describing: type(of: vc))
                    if vcNibName == nibName || vcNibName == nibName.replacingOccurrences(of: ".nib", with: "") {
                        let bundle = Bundle(for: type(of: vc))
                        self.reloadViewControllerView(vc: vc, nibName: vcNibName, bundle: bundle)
                    }
                }
                #endif
            }).sweepValue(SwiftSweeper.seeds)
        }
    }

    #if os(iOS) || os(tvOS)
    /// Reload a view controller's view from its updated NIB on disk.
    ///
    /// Strategy: **full view replacement** — replace `vc.view` entirely
    /// with the freshly-loaded view.  This is fundamentally safer than the
    /// previous "surgical swap" (move subviews + remap constraints) because:
    ///
    ///  1. `UINib.instantiate(withOwner: vc)` connects **all** IBOutlets on the
    ///     VC (including the `view` outlet itself) to objects inside the new view.
    ///     If we keep the old root view, those outlets dangle → nil crashes.
    ///
    ///  2. Internal constraints referencing system layout guides
    ///     (safeAreaLayoutGuide etc.) are set up correctly by UINib.
    ///     Remapping them manually is fragile and loses guide ownership.
    ///
    ///  3. The only constraints we need to recreate are the **superview's**
    ///     constraints that pin `oldView` into its container (navigation
    ///     controller content view, tab bar controller, etc.).
    func reloadViewControllerView(vc: UIViewController, nibName: String, bundle: Bundle) {
        guard let nibPath = bundle.path(forResource: nibName, ofType: "nib") else {
            print("InjectionLite: [DEBUG] NIB not found for '\(nibName)' in bundle \(bundle.bundlePath)")
            return
        }
        guard let nibData = try? Data(contentsOf: URL(fileURLWithPath: nibPath)) else {
            print("InjectionLite: [DEBUG] Failed to read NIB data from \(nibPath)")
            return
        }
        print("InjectionLite: [DEBUG] nibPath = \(nibPath)")
        print("InjectionLite: [DEBUG] bundle = \(bundle.bundlePath)")
        print("InjectionLite: [DEBUG] Loaded NIB data: \(nibData.count) bytes")

        // ⚠️  CRITICAL: save reference to the currently-displayed view BEFORE
        // calling instantiate(withOwner:).  UINib may set vc.view = newView
        // via the XIB's "view" outlet connection, which would make vc.view
        // point to the new (off-screen) view.
        let oldView = vc.view

        guard let newView = UINib(data: nibData, bundle: bundle)
            .instantiate(withOwner: vc, options: nil).first as? UIView else {
            print("InjectionLite: [DEBUG] UINib instantiation returned no UIView")
            return
        }
        print("InjectionLite: [DEBUG] newView created: \(newView.subviews.count) subviews, \(newView.constraints.count) constraints")

        // ── Fast path: no existing view to replace ──
        guard let oldView = oldView, oldView !== newView else {
            if vc.view !== newView { vc.view = newView }
            vc.viewDidLoad()
            print("InjectionLite: Reloaded \(type(of: vc)) from NIB (fresh)")
            return
        }

        // ── Capture superview hierarchy info ──
        let superview = oldView.superview
        let frame = oldView.frame
        let bounds = oldView.bounds
        let autoresizingMask = oldView.autoresizingMask
        let translatesARM = oldView.translatesAutoresizingMaskIntoConstraints
        let insertionIndex = superview?.subviews.firstIndex(of: oldView)

        // Capture superview constraints that pin oldView into its container.
        // These are the ONLY constraints we need to recreate — everything
        // internal to newView is already set up by UINib.
        var superviewConstraints = [NSLayoutConstraint]()
        if let sv = superview {
            for c in sv.constraints
                where c.firstItem === oldView || c.secondItem === oldView {
                superviewConstraints.append(c)
            }
            print("InjectionLite: [DEBUG] Found \(superviewConstraints.count) superview constraints referencing oldView")
        }

        // ── Detach old view ──
        oldView.removeFromSuperview()

        // ── Configure new view with the old view's frame / position ──
        newView.frame = frame
        newView.bounds = bounds
        newView.autoresizingMask = autoresizingMask
        newView.translatesAutoresizingMaskIntoConstraints = translatesARM

        // ── Set vc.view (may already have been set by instantiate) ──
        if vc.view !== newView {
            vc.view = newView
        }

        // ── Re-insert into the superview hierarchy at the same position ──
        if let sv = superview {
            if let idx = insertionIndex, idx <= sv.subviews.count {
                sv.insertSubview(newView, at: idx)
            } else {
                sv.addSubview(newView)
            }

            // Recreate superview constraints, replacing oldView → newView.
            var recreated = [NSLayoutConstraint]()
            for c in superviewConstraints {
                let first: AnyObject  = c.firstItem  === oldView ? newView : c.firstItem!
                let second: AnyObject? = {
                    guard let s = c.secondItem else { return nil }
                    return s === oldView ? newView : s
                }()
                let nc = NSLayoutConstraint(
                    item:       first,
                    attribute:  c.firstAttribute,
                    relatedBy:  c.relation,
                    toItem:     second,
                    attribute:  c.secondAttribute,
                    multiplier: c.multiplier,
                    constant:   c.constant
                )
                nc.priority   = c.priority
                nc.identifier = c.identifier
                recreated.append(nc)
            }
            if !recreated.isEmpty {
                NSLayoutConstraint.activate(recreated)
                print("InjectionLite: [DEBUG] Recreated \(recreated.count) superview constraints")
            }
        }

        // ── Re-run lifecycle & layout ──
        vc.viewDidLoad()
        newView.setNeedsLayout()
        newView.layoutIfNeeded()
        print("InjectionLite: Reloaded \(type(of: vc)) from NIB")
    }
    #endif


    /// Generics have per-specialisation vtables and crash Objective runtime apis
    func patchGenerics(oldClass: AnyClass, image: ImageSymbols,
                       injectedGenerics: Set<String>,
                       patched: inout Set<UnsafeRawPointer>) -> Bool {
        let typeName = _typeName(oldClass)
        if let genericClassName = typeName.components(separatedBy: "<").first,
           genericClassName != typeName,
           injectedGenerics.contains(genericClassName) {
            if patched.insert(autoBitCast(oldClass)).inserted {
                let patched = newPatchSwift(oldClass: oldClass, in: image)
                let swizzled = Reloader.swizzleBasics(oldClass: oldClass, in: image)
                log("Injected generic '\(oldClass)' (\(patched),\(swizzled))")
            }
            return oldClass.instancesRespond(to: Self.injectedSEL)
        }
        return false
    }

    /// Patch vtable by looking up functions by symbol name when you don't have access to the original class
    func newPatchSwift(oldClass: AnyClass, in lastLoaded: ImageSymbols) -> Int {
        var patched = 0

        Reloader.iterateSlots(oldClass: oldClass, newClass: oldClass) {
            (slots, oldSlots, _) in
            for slotIndex in 1..<1+slots {
                guard let existing = oldSlots[slotIndex],
                      let info = lastLoaded[existing] ?? DLKit.allImages[existing],
                      let symname = info.name,
                      Reloader.injectableSymbol(symname) else { continue }
                let symbol = String(cString: symname)
                let demangled = symname.demangled ?? symbol

                guard let replacement = lastLoaded[symname] ??
                    Reloader.interposed[symbol] ?? DLKit.allImages[symname] else {
                    log("⚠️ Class patching failed to lookup \(demangled)")
                    continue
                }
                if replacement != existing {
                    oldSlots[slotIndex] = Reloader.traceHook(replacement, symname)
                    detail("Patched[\(slotIndex)] \(replacement)/\(info.owner.imageKey) \(demangled)")
                    patched += 1
                }
            }
        }

        return patched
    }
}

/// Sweeper implementation
class SwiftSweeper {

    /// Seeds for the start of the "sweep" to implement instance level injected() method.
    #if !os(watchOS)
    nonisolated(unsafe)
    static let app = OSApplication.shared
    nonisolated(unsafe)
    static var seeds: [Any] = [app.delegate as Any] + app.windows
    #else
    nonisolated(unsafe)
    static var seeds = [Any]()
    #endif
    nonisolated(unsafe)
    static var current: SwiftSweeper?

    let instanceTask: (AnyObject) -> Void
    var seen = [UnsafeRawPointer: Bool]()
    let debugSweep = getenv(INJECTION_SWEEP_DETAIL) != nil
    let sweepExclusions = { () -> NSRegularExpression? in
        if let exclusions = getenv(INJECTION_SWEEP_EXCLUDE) {
            let pattern = String(cString: exclusions)
            do {
                let filter = try NSRegularExpression(pattern: pattern, options: [])
                log("⚠️ Excluding types matching '\(pattern)' from sweep")
                return filter
            } catch {
                log("⚠️ Invalid sweep filter pattern \(error): \(pattern)")
            }
        }
        return nil
    }()

    init(instanceTask: @escaping (AnyObject) -> Void) {
        self.instanceTask = instanceTask
        SwiftSweeper.current = self
    }

    func sweepValue(_ value: Any, _ containsType: Bool = false) {
        /// Skip values that cannot be cast into `AnyObject` because they end up being `nil`
        /// Fixes a potential crash that the value is not accessible during injection.
//        print(value)
        guard !containsType && value as? AnyObject != nil else { return }

        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set, .collection:
                let containsType = _typeName(type(of: value)).contains(".Type")
                if debugSweep {
                    print("Sweeping collection:", _typeName(type(of: value)))
                }
                for (_, child) in mirror.children {
                    sweepValue(child, containsType)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject)
                return
            case .optional, .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals)
                }
            case .tuple, .struct:
                sweepMembers(value)
            #if compiler(>=6.2) // Xcode 26+
            case .foreignReference:
                // C++ SWIFT_SHARED_REFERENCE types: reference semantics but not
                // Swift/ObjC objects, so we can't treat them as AnyObject.
                // Recurse into any reflected members instead.
                if debugSweep {
                    print("Sweeping foreign reference:", _typeName(type(of: value)))
                }
                sweepMembers(value)
            #endif
            @unknown default:
                break
            }
        }
    }

    func sweepInstance(_ instance: AnyObject) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true
            if let filter = sweepExclusions {
                let typeName = _typeName(type(of: instance))
                if filter.firstMatch(in: typeName,
                    range: NSMakeRange(0, typeName.utf16.count)) != nil {
                    return
                }
            }

            if debugSweep {
                print("Sweeping instance \(reference) of class \(type(of: instance))")
            }

            sweepMembers(instance)
            instance.legacySwiftSweep?()

            instanceTask(instance)
        }
    }

    func sweepMembers(_ instance: Any) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (name, value) in mirror!.children
                where name?.hasSuffix("Type") != true {
                sweepValue(value)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySwiftSweep() {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            let className = NSStringFromClass(cls!)
            if className.hasPrefix("_") || className.hasPrefix("WK") ||
                className.hasPrefix("NS") && className != "NSWindow" {
                return
            }
            if let ivars = class_copyIvarList(cls, &icnt) {
                let object = UInt8(ascii: "@")
                for i in 0 ..< Int(icnt) {
                    if /*let name = ivar_getName(ivars[i])
                        .flatMap({ String(cString: $0)}),
                       sweepExclusions?.firstMatch(in: name,
                           range: NSMakeRange(0, name.utf16.count)) == nil,*/
                       let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
//                                print("\($0.pointee) \(self) \(name):  \(String(cString: type))")
                                if let obj = $0.pointee {
                                    SwiftSweeper.current?.sweepInstance(obj)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSSet {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSArray {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSDictionary {
    @objc override func legacySwiftSweep() {
        self.allValues.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}
#endif
