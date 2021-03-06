//
//  CwlKeyValueObserver.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A wrapper around key-value observing so that you:
///	1. don't need to implement `observeValue` yourself, you can instead handle changes in a closure
///	2. you get a `CallbackReason` for each change which includes `valueChanged`, `pathChanged`, `targetDeleted`.
///	3. observation is automatically cancelled if you release the KeyValueObserver or the target is released
///
/// THREAD SAFETY:
/// This class is memory safe even when observations are triggered concurrently from different threads.
/// Do note though that while all changes are registered under the mutex, callbacks are invoked *outside* the mutex, so it is possible for callbacks to be invoked in a different order than the internal synchronized order.
/// In general, this shouldn't be a problem (since key-value observing is not itself synchronized so there *isn't* an authoritative ordering). However, this may cause unexpected behavior if you invoke `cancel` on this class. If you `cancel` the `KeyValueObserver` while it is concurrently processing changes on another thread, this might result in callback invocations occurring *after* the call to `cancel`. This will only happen if the changes associated with those callbacks were received *before* the `cancel` - it's just the callback that's getting invoked later.
public class KeyValueObserver: NSObject {
	public typealias Callback = (_ change: [NSKeyValueChangeKey: Any], _ reason: CallbackReason) -> Void

	// This is the user-supplied callback function
	private var callback: Callback?
	
	// When observing a keyPath, we use a separate KeyValueObserver for each component of the path. The `tailObserver` is the `KeyValueObserver` for the *next* element in the path.
	private var tailObserver: KeyValueObserver?
	
	// This is the key that we're observing on `target`
	private let key: String
	
	// This is any path beyond the key.
	private let tailPath: String?
	
	// This is the set of options passed on construction
	private let options: NSKeyValueObservingOptions
	
	// Used to ensure memory safety for the callback and tailObserver.
	private let mutex = DispatchQueue(label: "")
	
	// Our "deletionBlock" is called to notify us that the target is being deallocated (so we can remove the key value observation before a warning is logged) and this happens during the target's "objc_destructinstance" function. At this point, a `weak` var will be `nil` and an `unowned` will trigger a `_swift_abortRetainUnowned` failure.
	// So we're left with `Unmanaged`. Careful cancellation before the target is deallocated is necessary to ensure we don't access an invalid memory location.
	private let target: Unmanaged<NSObject>
	
	/// The `CallbackReason` explains the location in the path where the change occurred.
	///
	/// - valueChanged: the observed value changed
	/// - pathChanged: one of the connected elements in the path changed
	/// - targetDeleted: the observed target was deallocated
	/// - cancelled: will never be sent
	public enum CallbackReason {
		case valueChanged
		case pathChanged
		case targetDeleted
		case cancelled
	}
	
	/// Establish the key value observing.
	///
	/// - Parameters:
	///   - target: object on which there's a property we wish to observe
	///   - keyPath: a key or keyPath identifying the property we wish to observe
	///   - options: same as for the normal `addObserver` method
	///   - callback: will be invoked on each change with the change dictionary and the change reason
	public init(target: NSObject, keyPath: String, options: NSKeyValueObservingOptions = NSKeyValueObservingOptions.new.union(NSKeyValueObservingOptions.initial), callback: @escaping Callback) {
		self.callback = callback
		self.target = Unmanaged.passUnretained(target)
		self.options = options
		
		// Look for "." indicating a key path
		var range = keyPath.range(of: ".")
		
		// If we have a collection operator, consider the next path component as part of this key
		if let r = range, keyPath.hasPrefix("@") {
			range = keyPath.range(of: ".", range: keyPath.index(after: r.lowerBound)..<keyPath.endIndex, locale: nil)
		}
		
		// Set the key and tailPath based on whether we detected multiple path components
		if let r = range {
			self.key = keyPath.substring(to: r.lowerBound)
			self.tailPath = keyPath.substring(from: keyPath.index(after: r.lowerBound))
		} else {
			self.key = keyPath
			
			// If we're observing a weak property, add an observer on self to the target to detect when it may be set to nil without going through the property setter
			var p: String? = nil
			if let propertyName = keyPath.cString(using: String.Encoding.utf8) {
				let property = class_getProperty(type(of: target), propertyName)
				// Look for both the "id" and "weak" attributes.
				if property != nil, let attributes = String(validatingUTF8: property_getAttributes(property))?.components(separatedBy: ","), attributes.filter({ $0.hasPrefix("T@") || $0 == "W" }).count == 2 {
					p = "self"
				}
			}
			self.tailPath = p
		}
		
		super.init()
		
		// Detect if the target is deleted
		let deletionBlock = OnDelete { [weak self] in self?.cancel(.targetDeleted) }
		objc_setAssociatedObject(target, Unmanaged.passUnretained(self).toOpaque(), deletionBlock, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN)
		
		// Start observing the target
		if key != "self" {
			var currentOptions = options
			if !isObservingTail {
				currentOptions = NSKeyValueObservingOptions.new.union(options.intersection(NSKeyValueObservingOptions.prior))
			}
			
			target.addObserver(self, forKeyPath: key, options: currentOptions, context: Unmanaged.passUnretained(self).toOpaque())
		}
		
		// Start observing the value of the target
		if tailPath != nil {
			updateTailObserver(onValue: target.value(forKeyPath: self.key) as? NSObject, isInitial: true)
		}
	}
	
	deinit {
		cancel()
	}
	
	// Method must be called from *INSIDE* mutex (although, it must be *OUTSIDE* the tailObserver's mutex).
	private func updateTailObserver(onValue: NSObject?, isInitial: Bool) {
		tailObserver?.cancel()
		tailObserver = nil
		
		if let _ = self.callback, let tp = tailPath, let currentValue = onValue {
			let currentOptions = isInitial ? self.options : self.options.subtracting(NSKeyValueObservingOptions.initial)
			self.tailObserver = KeyValueObserver(target: currentValue, keyPath: tp, options: currentOptions, callback: self.tailCallback)
		}
	}
	
	// Safe for invocation in or out of mutex
	private var isObservingTail: Bool {
		return tailPath == nil || tailPath == "self"
	}
	
	// Safe for invocation in or out of mutex
	private var needsWeakTailObserver: Bool {
		return tailPath == "self"
	}
	
	// Method is called *OUTSIDE* mutex since it is used as a callback function for the `tailObserver`
	private func tailCallback(_ change: [NSKeyValueChangeKey: Any], reason: CallbackReason) {
		switch reason {
		case .cancelled:
			return
		case .targetDeleted:
			let c = mutex.sync(execute: { () -> Callback? in
				updateTailObserver(onValue: nil, isInitial: false)
				return self.callback
			})
			c?(change, self.isObservingTail ? .valueChanged : .pathChanged)
		default:
			let c = mutex.sync { self.callback }
			c?(change, reason)
		}
	}
	
	// Method must be called from *INSIDE* mutex.
	private func targetValue() -> Any? {
		if let t = tailObserver, !isObservingTail {
			return t.targetValue()
		} else {
			return target.takeUnretainedValue().value(forKeyPath: key)
		}
	}
	
	// Method must be called from *INSIDE* mutex.
	private func updateTailObserverGivenChangeDictionary(change: [NSKeyValueChangeKey: Any]) {
		if let newValue = change[NSKeyValueChangeKey.newKey] as? NSObject {
			let value: NSObject? = newValue == NSNull() ? nil : newValue
			updateTailObserver(onValue: value, isInitial: false)
		} else {
			updateTailObserver(onValue: targetValue() as? NSObject, isInitial: false)
		}
	}
	
	// Implementation of standard key-value observing method.
	public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
		if context != Unmanaged.passUnretained(self).toOpaque() {
			super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
		}
		
		guard let c = change else {
			assertionFailure("Expected change dictionary")
			return
		}
		
		if self.isObservingTail {
			let cb = mutex.sync { () -> Callback? in
				if needsWeakTailObserver {
					updateTailObserverGivenChangeDictionary(change: c)
				}
				return self.callback
			}
			cb?(c, .valueChanged)
			
		} else {
			let tuple = mutex.sync { () -> (Callback, [NSKeyValueChangeKey: Any])? in
				var transmittedChange: [NSKeyValueChangeKey: Any] = [:]
				if !options.intersection(NSKeyValueObservingOptions.old).isEmpty {
					transmittedChange[NSKeyValueChangeKey.oldKey] = tailObserver?.targetValue()
				}
				if let _ = c[NSKeyValueChangeKey.notificationIsPriorKey] as? Bool {
					transmittedChange[NSKeyValueChangeKey.notificationIsPriorKey] = true
				}
				updateTailObserverGivenChangeDictionary(change: c)
				if !options.intersection(NSKeyValueObservingOptions.new).isEmpty {
					transmittedChange[NSKeyValueChangeKey.newKey] = tailObserver?.targetValue()
				}
				if let c = callback {
					return (c, transmittedChange)
				}
				return nil
			}
			if let (cb, tc) = tuple {
				cb(tc, .pathChanged)
			}
		}
	}
	
	/// Stop observing.
	public func cancel() {
		cancel(.cancelled)
	}
	
	// Method is called *OUTSIDE* mutex
	private func cancel(_ reason: CallbackReason) {
		let cb = mutex.sync { () -> Callback? in
			guard let c = callback else { return nil }
			
			// Flag as inactive
			callback = nil
			
			// Remove the observations from this object
			if key != "self" {
				target.takeUnretainedValue().removeObserver(self, forKeyPath: key, context: Unmanaged.passUnretained(self).toOpaque())
			}
			objc_setAssociatedObject(target, Unmanaged.passUnretained(self).toOpaque(), nil, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN);
			
			// Remove tail observers
			updateTailObserver(onValue: nil, isInitial: false)
			
			// Send notifications
			return reason != .cancelled ? c : nil
		}
		
		cb?([:], reason)
	}
}
