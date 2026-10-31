import Foundation

public enum CodexAppServerError: Error, Equatable, Sendable {
    case invalidState, closed, malformedMessage, overloaded, timedOut, cancelled
    case unsupportedVersion(String)
    case processExited(Int32)
    case server(code: Int, message: String)
}

public enum CodexRequestID: Hashable, Sendable {
    case integer(Int), string(String)

    fileprivate init?(_ value: Any?) {
        if let text = value as? String { self = .string(text) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue == Double(number.intValue) { self = .integer(number.intValue) }
        else { return nil }
    }
    fileprivate var json: Any {
        switch self { case .integer(let id): id; case .string(let id): id }
    }
}

public struct CodexApprovalRequest: Equatable, Sendable {
    public enum Kind: String, Sendable { case commandExecution, fileChange, permissions }
    public let id: CodexRequestID
    public let kind: Kind
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let command: String?
    public let directory: String?
    public let reason: String?
    /// Exact requested profile for display/review. Accept grants this profile for this turn only.
    public let permissions: [String: HostJSON]?
}

public enum CodexApprovalDecision: String, Sendable { case accept, decline }

public enum CodexChatEvent: Equatable, Sendable {
    /// Upsert by id in TranscriptLog; deltas contain the full text accumulated so far.
    case message(TranscriptMessage)
    case approval(CodexApprovalRequest)
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String, status: String)
}

/// Single app-server connection. Consume `events` concurrently with commands; call `close()` on exit.
/// No credentials are read; the CLI owns authentication. Only `startTurn` spends model tokens.
public actor CodexAppServerClient {
    public nonisolated let events: AsyncThrowingStream<CodexChatEvent, Error>
    private let continuation: AsyncThrowingStream<CodexChatEvent, Error>.Continuation
    private let process: any CodexAppServerProcess
    private let requestTimeout: Duration
    private let approvalTimeout: Duration
    private var reader: Task<Void, Never>?
    private var pending: [CodexRequestID: CheckedContinuation<Data, Error>] = [:]
    private var timers: [CodexRequestID: Task<Void, Never>] = [:]
    private var approvals: [CodexRequestID: (request: CodexApprovalRequest, timer: Task<Void, Never>)] = [:]
    private var nextID = 0
    private var started = false
    private var ready = false
    private var terminalError: CodexAppServerError?
    private var buffer = Data()
    private var adapter = CodexTranscriptAdapter()
    private static let maxLineBytes = 8 * 1024 * 1024

    public init(process: any CodexAppServerProcess, requestTimeout: Duration = .seconds(30),
                approvalTimeout: Duration = .seconds(60)) {
        self.process = process
        self.requestTimeout = requestTimeout
        self.approvalTimeout = approvalTimeout
        let pair = AsyncThrowingStream<CodexChatEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        events = pair.stream
        continuation = pair.continuation
    }

    public func initialize() async throws {
        guard !started, terminalError == nil else { throw terminalError ?? .invalidState }
        started = true
        do {
            let output = try process.launch()
            reader = Task { [weak self] in
                do {
                    for try await chunk in output {
                        guard let self else { return }
                        try await self.consume(chunk)
                    }
                    await self?.fail(.closed)
                } catch {
                    await self?.fail(error as? CodexAppServerError ?? .malformedMessage)
                }
            }
            let params = CodexInitializeParams(clientInfo: CodexClientInfo(name: "smthz", version: "0.1.0"))
            let data = try await request("initialize", params: params)
            let response = try JSONDecoder().decode(CodexInitializeResponse.self, from: data)
            // App-server has no negotiated protocolVersion. Pin its experimental schema to 0.164.x.
            let pattern = #"(?:^|\s)codex(?:-app-server)?/0\.164\.\d+(?:\s|$)"#
            guard response.userAgent.range(of: pattern, options: .regularExpression) != nil else {
                throw CodexAppServerError.unsupportedVersion(response.userAgent)
            }
            try await send(["method": "initialized"])
            ready = true
        } catch {
            fail(error as? CodexAppServerError ?? .malformedMessage)
            throw error
        }
    }

    public func startThread(directory: String, model: String? = nil) async throws -> String {
        try requireReady()
        let params = CodexThreadStartParams(cwd: directory, model: model,
                                           approvalPolicy: "on-request", sandbox: "workspace-write")
        return try threadID(await request("thread/start", params: params))
    }

    /// Emits restored rows through `events` before returning the resumed thread id.
    public func resume(threadID: String) async throws -> String {
        try requireReady()
        let params = CodexThreadResumeParams(threadId: threadID, approvalPolicy: "on-request", sandbox: "workspace-write")
        let data = try await request("thread/resume", params: params)
        let id = try self.threadID(data)
        let result = try object(data)
        let thread = result["thread"] as? [String: Any] ?? [:]
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            guard let turnID = turn["id"] as? String else { continue }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if let message = adapter.item(item, threadID: id, turnID: turnID) { try emit(.message(message)) }
            }
        }
        return id
    }

    public func startTurn(threadID: String, text: String) async throws -> String {
        try requireReady()
        let params = CodexTurnStartParams(threadId: threadID, input: [CodexTextInput(type: "text", text: text)])
        let data = try await request("turn/start", params: params)
        guard let result = try? JSONDecoder().decode(CodexTurnStartResponse.self, from: data),
              !result.turn.id.isEmpty else { throw CodexAppServerError.malformedMessage }
        return result.turn.id
    }

    public func interrupt(threadID: String, turnID: String) async throws {
        try requireReady()
        let params = CodexTurnInterruptParams(threadId: threadID, turnId: turnID)
        _ = try await request("turn/interrupt", params: params)
    }

    public func respond(to id: CodexRequestID, decision: CodexApprovalDecision) async throws {
        try requireReady()
        guard let approval = approvals.removeValue(forKey: id) else { throw CodexAppServerError.invalidState }
        approval.timer.cancel()
        let data: Data
        if approval.request.kind == .permissions {
            let profile = decision == .accept ? approval.request.permissions ?? [:] : [:]
            data = try JSONEncoder().encode(CodexPermissionsRequestApprovalResponse(permissions: profile, scope: "turn"))
        } else {
            data = try JSONEncoder().encode(CodexCommandExecutionRequestApprovalResponse(decision: decision.rawValue))
        }
        try await send(["id": id.json, "result": object(data)])
    }

    public func close() { fail(.closed) }

    private func requireReady() throws {
        if let terminalError { throw terminalError }
        guard ready else { throw CodexAppServerError.invalidState }
    }

    private func threadID(_ data: Data) throws -> String {
        guard let result = try? JSONDecoder().decode(CodexThreadStartResponse.self, from: data),
              !result.thread.id.isEmpty else { throw CodexAppServerError.malformedMessage }
        return result.thread.id
    }

    private func request<P: Encodable & Sendable>(_ method: String, params: P) async throws -> Data {
        try await request(method, params: object(JSONEncoder().encode(params)))
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        if let terminalError { throw terminalError }
        nextID += 1
        let id = CodexRequestID.integer(nextID)
        let bytes = try encoded(["id": id.json, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { reply in
                pending[id] = reply
                timers[id] = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.fail(.timedOut)
                }
                Task { [weak self, process] in
                    do { try await process.write(bytes) }
                    catch { await self?.fail(.closed) }
                }
            }
        } onCancel: {
            Task { await self.fail(.cancelled) }
        }
    }

    private func send(_ value: [String: Any]) async throws {
        do { try await process.write(encoded(value)) }
        catch { fail(.closed); throw error }
    }

    private func encoded(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= Self.maxLineBytes else { throw CodexAppServerError.overloaded }
        data.append(0x0A)
        return data
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.malformedMessage
        }
        return value
    }

    private func consume(_ chunk: Data) async throws {
        guard terminalError == nil else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maxLineBytes else {
                throw CodexAppServerError.overloaded
            }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty || line == Data([0x0D]) { continue }
            try await receive(object(line))
        }
        guard buffer.count <= Self.maxLineBytes else { throw CodexAppServerError.overloaded }
    }

    private func receive(_ envelope: [String: Any]) async throws {
        let id = CodexRequestID(envelope["id"])
        guard envelope["id"] == nil || id != nil,
              envelope["jsonrpc"] == nil || envelope["jsonrpc"] as? String == "2.0" else {
            throw CodexAppServerError.malformedMessage
        }
        if let method = envelope["method"] as? String {
            guard let params = envelope["params"] as? [String: Any] else { throw CodexAppServerError.malformedMessage }
            if let id {
                try await approval(method, id: id, params: params)
            } else {
                try notification(method, params: params)
            }
        } else if let id {
            guard let reply = pending.removeValue(forKey: id) else { return } // A late reply after cancellation.
            timers.removeValue(forKey: id)?.cancel()
            if let error = envelope["error"] as? [String: Any],
               let code = error["code"] as? Int, let message = error["message"] as? String {
                reply.resume(throwing: CodexAppServerError.server(code: code, message: message))
            } else if let result = envelope["result"] {
                let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                if let data { reply.resume(returning: data) }
                else { reply.resume(throwing: CodexAppServerError.malformedMessage) }
            } else { reply.resume(throwing: CodexAppServerError.malformedMessage) }
        } else { throw CodexAppServerError.malformedMessage }
    }

    private func approval(_ method: String, id: CodexRequestID, params: [String: Any]) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: params)
        let request: CodexApprovalRequest
        switch method {
        case "item/commandExecution/requestApproval":
            let p = try JSONDecoder().decode(CodexCommandExecutionRequestApprovalParams.self, from: bytes)
            request = CodexApprovalRequest(id: id, kind: .commandExecution, threadID: p.threadId,
                turnID: p.turnId, itemID: p.itemId, command: p.command, directory: p.cwd, reason: p.reason, permissions: nil)
        case "item/fileChange/requestApproval":
            let p = try JSONDecoder().decode(CodexFileChangeRequestApprovalParams.self, from: bytes)
            request = CodexApprovalRequest(id: id, kind: .fileChange, threadID: p.threadId,
                turnID: p.turnId, itemID: p.itemId, command: nil, directory: p.grantRoot, reason: p.reason, permissions: nil)
        case "item/permissions/requestApproval":
            let p = try JSONDecoder().decode(CodexPermissionsRequestApprovalParams.self, from: bytes)
            request = CodexApprovalRequest(id: id, kind: .permissions, threadID: p.threadId,
                turnID: p.turnId, itemID: p.itemId, command: nil, directory: p.cwd, reason: p.reason, permissions: p.permissions)
        default:
            // Unknown server requests fail closed; never silently grant permissions or run tools.
            try await send(["id": id.json, "error": ["code": -32601, "message": "Unsupported server request: " + method]])
            return
        }
        guard approvals[id] == nil else { throw CodexAppServerError.malformedMessage }
        let timer = Task { [weak self, approvalTimeout] in
            do { try await Task.sleep(for: approvalTimeout) } catch { return }
            try? await self?.respond(to: id, decision: .decline)
        }
        approvals[id] = (request, timer)
        try emit(.approval(request))
    }

    private func notification(_ method: String, params: [String: Any]) throws {
        switch method {
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let data = try JSONSerialization.data(withJSONObject: params)
            let delta = try JSONDecoder().decode(CodexAgentMessageDeltaNotification.self, from: data)
            try emit(.message(adapter.delta(delta, reasoning: method != "item/agentMessage/delta")))
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String else { throw CodexAppServerError.malformedMessage }
            if let message = adapter.item(item, threadID: threadID, turnID: turnID) { try emit(.message(message)) }
        case "turn/started", "turn/completed":
            guard let threadID = params["threadId"] as? String, let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { throw CodexAppServerError.malformedMessage }
            if method == "turn/started" { try emit(.turnStarted(threadID: threadID, turnID: turnID)) }
            else {
                guard let status = turn["status"] as? String else { throw CodexAppServerError.malformedMessage }
                try emit(.turnCompleted(threadID: threadID, turnID: turnID, status: status))
            }
        default: break // New optional notifications do not change the known wire contract.
        }
    }

    private func emit(_ event: CodexChatEvent) throws {
        if case .dropped = continuation.yield(event) { throw CodexAppServerError.overloaded }
    }

    private func fail(_ error: CodexAppServerError) {
        guard terminalError == nil else { return }
        terminalError = error
        ready = false
        reader?.cancel()
        for timer in timers.values { timer.cancel() }
        for approval in approvals.values { approval.timer.cancel() }
        timers.removeAll()
        approvals.removeAll()
        let replies = pending.values
        pending.removeAll()
        for reply in replies { reply.resume(throwing: error) }
        process.stop()
        continuation.finish(throwing: error)
    }

    deinit {
        reader?.cancel()
        for timer in timers.values { timer.cancel() }
        for approval in approvals.values { approval.timer.cancel() }
        process.stop()
        continuation.finish()
    }
}
