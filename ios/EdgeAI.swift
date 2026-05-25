import Foundation
import React

@objc(EdgeAI)
class EdgeAI: RCTEventEmitter {

    static var shared: EdgeAI?
    static let sharedRequests = EdgeAIRequests()
    private var hasJSListeners = false

    override init() {
        super.init()
        EdgeAI.shared = self
    }

    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String]! {
        return ["EdgeAIRequest", "EdgeAICancel", "ModelConsentGranted"]
    }

    override func startObserving() {
        hasJSListeners = true
        #if DEBUG
        print("[EdgeAI] JS listener attached")
        #endif
    }

    override func stopObserving() {
        hasJSListeners = false
        #if DEBUG
        print("[EdgeAI] JS listener detached")
        #endif
    }

    // SwiftUI calls this:
    @objc func generate(_ prompt: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        #if DEBUG
        print("[EdgeAI] Generate called with prompt length: \(prompt.count)")
        #endif

        if prompt.isEmpty {
            #if DEBUG
            print("[EdgeAI] Error: Empty prompt")
            #endif
            reject("EMPTY_PROMPT", "Prompt cannot be empty", nil)
            return
        }

        let modelReady = UserDefaults.standard.bool(forKey: "modelReady")
        if !modelReady {
            #if DEBUG
            print("[EdgeAI] Error: Model is not ready")
            #endif
            reject("MODEL_NOT_READY", "AI model is not ready yet.", nil)
            return
        }

        if !hasJSListeners {
            #if DEBUG
            print("[EdgeAI] Error: No JS listeners for EdgeAIRequest")
            #endif
            reject("NO_JS_LISTENER", "AI request handler is not attached.", nil)
            return
        }

        let requestId = UUID().uuidString
        #if DEBUG
        print("[EdgeAI] Generated requestId: \(requestId)")
        #endif

        // No timeout; allow long-running generations (summaries can be slow on-device).
        let timeoutSeconds: TimeInterval = 0

        EdgeAI.sharedRequests.store(requestId: requestId, resolve: resolve, reject: reject, timeoutSeconds: timeoutSeconds)

        // Emit event to JS on main queue to ensure delivery order
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            print("[EdgeAI] Emitting EdgeAIRequest event")
            #endif
            self?.sendEvent(withName: "EdgeAIRequest", body: [
                "requestId": requestId,
                "prompt": prompt
            ])
        }
    }

    // JS calls this to respond:
    @objc func resolveRequest(_ requestId: String, text: String) {
        #if DEBUG
        print("[EdgeAI] Resolving request \(requestId) with text length: \(text.count)")
        #endif
        EdgeAI.sharedRequests.resolve(requestId: requestId, text: text)
    }

    @objc func rejectRequest(_ requestId: String, code: String, message: String) {
        #if DEBUG
        print("[EdgeAI] Rejecting request \(requestId) with code: \(code), message: \(message)")
        #endif
        EdgeAI.sharedRequests.reject(requestId: requestId, code: code, message: message)
    }

    @objc func cancelCurrentGeneration() {
        #if DEBUG
        print("[EdgeAI] Cancel current generation requested")
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.sendEvent(withName: "EdgeAICancel", body: [:])
        }
    }

    @objc func getModelConsentState(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        let consented = UserDefaults.standard.bool(forKey: "modelDownloadConsented")
        let declined = UserDefaults.standard.bool(forKey: "modelDownloadDeclined")
        resolve(["consented": consented, "declined": declined])
    }

    @objc(setModelReady:)
    func setModelReady(_ ready: Bool) {
        let applyReadyState = {
            UserDefaults.standard.set(ready, forKey: "modelReady")
            NotificationCenter.default.post(
                name: NSNotification.Name("ModelReadyStatus"),
                object: nil,
                userInfo: ["ready": ready]
            )
        }

        if Thread.isMainThread {
            applyReadyState()
        } else {
            DispatchQueue.main.async {
                applyReadyState()
            }
        }
    }
}

final class EdgeAIRequests {
    private var resolvers: [String: RCTPromiseResolveBlock] = [:]
    private var rejecters: [String: RCTPromiseRejectBlock] = [:]
    private var timers: [String: Timer] = [:]
    private let lock = NSLock()

    func store(requestId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock, timeoutSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        print("[EdgeAIRequests] Storing request \(requestId) with timeout \(timeoutSeconds)s")
        #endif
        resolvers[requestId] = resolve
        rejecters[requestId] = reject

        if timeoutSeconds > 0 {
            let timer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                #if DEBUG
                print("[EdgeAIRequests] Request \(requestId) timed out")
                #endif
                self.lock.lock(); defer { self.lock.unlock() }
                if let _ = self.rejecters.removeValue(forKey: requestId) {
                    _ = self.resolvers.removeValue(forKey: requestId)
                    self.timers.removeValue(forKey: requestId)
                    reject("TIMEOUT", "The AI request timed out after \(timeoutSeconds) seconds.", nil)
                }
            }
            timers[requestId] = timer
        }
        #if DEBUG
        print("[EdgeAIRequests] Active requests: \(resolvers.count)")
        #endif
    }

    func resolve(requestId: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        timers.removeValue(forKey: requestId)?.invalidate()
        guard let r = resolvers.removeValue(forKey: requestId) else {
            #if DEBUG
            print("[EdgeAIRequests] Warning: No resolver found for request \(requestId)")
            #endif
            return
        }
        _ = rejecters.removeValue(forKey: requestId)
        #if DEBUG
        print("[EdgeAIRequests] Resolved request \(requestId). Remaining requests: \(resolvers.count)")
        #endif
        r(text)
    }

    func reject(requestId: String, code: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        timers.removeValue(forKey: requestId)?.invalidate()
        guard let rej = rejecters.removeValue(forKey: requestId) else {
            #if DEBUG
            print("[EdgeAIRequests] Warning: No rejecter found for request \(requestId)")
            #endif
            return
        }
        _ = resolvers.removeValue(forKey: requestId)
        #if DEBUG
        print("[EdgeAIRequests] Rejected request \(requestId) with \(code): \(message). Remaining requests: \(rejecters.count)")
        #endif
        rej(code, message, nil)
    }
}
