// The MIT License (MIT)
//
// Copyright (c) 2016 Alexander Grebenyuk (github.com/kean).

import Foundation

/// A promise is an object that represents an asynchronous task. Use `then()`
/// to get the result of the promise. Use `catch()` to catch errors.
///
/// Promises start in a *pending* state and *resolve* with a value to become
/// *fulfilled* or an `Error` to become *rejected*.
public final class Promise<T> {
    private var state: State<T> = .pending(Handlers<T>())
    private let lock = NSLock()

    // MARK: Creation

    /// Creates a new, pending promise.
    ///
    /// - parameter value: The provided closure is called immediately on the
    /// current thread. In the closure you should start an asynchronous task and
    /// call either `fulfill` or `reject` when it completes.
    public init(_ closure: (_ fulfill: @escaping (T) -> Void, _ reject: @escaping (Error) -> Void) -> Void) {
        closure({ self.resolve(.fulfilled($0)) }, { self.resolve(.rejected($0)) })
    }

    private func resolve(_ resolution: Resolution<T>) {
        lock.lock(); defer { lock.unlock() }
        if case let .pending(handlers) = state {
            state = .resolved(resolution)
            // Handlers only contain `queue.async` calls which are fast
            // enough for a critical section (no real need to optimize this).
            handlers.objects.forEach { $0(resolution) }
        }
    }

    /// Creates a promise fulfilled with a given value.
    public init(value: T) { state = .resolved(.fulfilled(value)) }

    /// Creates a promise rejected with a given error.
    public init(error: Error) { state = .resolved(.rejected(error)) }

    // MARK: Finally

    /// The provided closure executes asynchronously when the promise resolves.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    /// - returns: self
    @discardableResult public func finally(on queue: DispatchQueue = .main, _ closure: @escaping (Resolution<T>) -> Void) -> Promise<T> {
        let _closure: (Resolution<T>) -> Void = { resolution in
            queue.async { closure(resolution) }
        }
        lock.lock(); defer { lock.unlock() }
        switch state {
        case let .pending(handlers): handlers.objects.append(_closure)
        case let .resolved(resolution): _closure(resolution)
        }
        return self
    }

    // MARK: Synchronous Inspection

    /// Returns resolution if the promise has already resolved.
    public var resolution: Resolution<T>? {
        lock.lock(); defer { lock.unlock() }
        return state.resolution
    }
}

/// Extensions on top of `finally`.
public extension Promise {

    // MARK: Then

    /// The provided closure executes asynchronously when the promise fulfills
    /// with a value.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    /// - returns: self
    @discardableResult public func then(on queue: DispatchQueue = .main, _ closure: @escaping (T) -> Void) -> Promise<T> {
        return finally(on: queue, then: closure, catch: nil)
    }

    /// Transforms `Promise<T>` to `Promise<U>`.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    /// queue by default.
    /// - returns: A promise fulfilled with a value returns by the closure.
    public func then<U>(on queue: DispatchQueue = .main, _ closure: @escaping (T) -> U) -> Promise<U> {
        return then(on: queue) { Promise<U>(value: closure($0)) }
    }

    /// The provided closure executes asynchronously when the promise fulfills
    /// with a value. Allows you to chain promises.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    /// - returns: A promise that resolves with the resolution of the promise
    /// returned by the given closure.
    public func then<U>(on queue: DispatchQueue = .main, _ closure: @escaping (T) -> Promise<U>) -> Promise<U> {
        return Promise<U>() { fulfill, reject in
            finally(
                on: queue,
                then: { // resolve new promise with the promise returned by the closure
                    closure($0).finally(on: queue, then: fulfill, catch: reject)
                },
                catch: reject) // bubble up error
        }
    }

    // MARK: Catch

    /// The provided closure executes asynchronously when the promise is
    /// rejected with an error.
    ///
    /// A promise bubbles up errors. It allows you to catch all errors returned
    /// by a chain of promises with a single `catch()`.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    @discardableResult public func `catch`(on queue: DispatchQueue = .main, _ closure: @escaping (Error) -> Void) -> Promise<T> {
        return finally(on: queue, then: nil, catch: closure)
    }

    /// Unlike `catch` `recover` allows you to continue the chain of promises
    /// by recovering from the error by creating a new promise.
    ///
    /// - parameter on: A queue on which the closure is run. `.main` by default.
    public func recover(on queue: DispatchQueue = .main, _ closure: @escaping (Error) -> Promise<T>) -> Promise<T> {
        return Promise<T>() { fulfill, reject in
            finally(
                on: queue,
                then: fulfill, // bubble up value
                catch: { // resolve new promise with the promise returned by the closure
                    closure($0).finally(on: queue, then: fulfill, catch: reject)
            })
        }
    }

    /// Private convenience method on top of `completion(on:closure:)`.
    /// Allows you to add `then` and `catch` closures with a single call.
    @discardableResult private func finally(on queue: DispatchQueue = .main, then: ((T) -> Void)?, `catch`: ((Error) -> Void)?) -> Promise<T> {
        return finally(on: queue) {
            switch $0 {
            case let .fulfilled(val): then?(val)
            case let .rejected(err): `catch`?(err)
            }
        }
    }
}

private final class Handlers<T> {
    var objects = [(Resolution<T>) -> Void]() // boxed handlers
}

private enum State<T> {
    case pending(Handlers<T>), resolved(Resolution<T>)

    var resolution: Resolution<T>? {
        if case let .resolved(resolution) = self { return resolution }
        return nil
    }
}

/// Represents a *resolution* (result) of a promise.
public enum Resolution<T> {
    case fulfilled(T), rejected(Error)

    public var value: T? {
        if case let .fulfilled(val) = self { return val }
        return nil
    }

    public var error: Error? {
        if case let .rejected(err) = self { return err }
        return nil
    }
}
