//
//  Pioneer+WebSocket.swift
//  Pioneer
//
//  Created by d-exclaimation on 11:36 AM.
//

import Foundation
import Vapor
import NIO
import NIOHTTP1
import GraphQL

extension Pioneer {
    /// KeepAlive Task
    typealias KeepAlive = Task<Void, Error>?
    
    /// Apply middleware through websocket
    func applyWebSocket(on router: RoutesBuilder, at path: [PathComponent] = ["graphql", "websocket"]) {
        router.get(path) { req throws -> Response in
            /// Explicitly handle Websocket upgrade with sub-protocol
            let protocolHeader: [String] = req.headers[.secWebSocketProtocol]
            guard let _ = protocolHeader.first(where: websocketProtocol.isValid) else {
                throw GraphQLError(ResolveError.unsupportedProtocol)
            }

            let header: HTTPHeaders = ["Sec-WebSocket-Protocol": websocketProtocol.name]
            func shouldUpgrade(req: Request) -> EventLoopFuture<HTTPHeaders?> {
                req.eventLoop.next().makeSucceededFuture(.some(header))
            }

            return req.webSocket(shouldUpgrade: shouldUpgrade) { req, ws in
                let res = Response()
                let ctx = contextBuilder(req, res)
                let process = Process(ws: ws, ctx: ctx, req: req)

                ws.sendPing()

                /// Scheduled keep alive message interval
                let keepAlive: KeepAlive = setInterval(delay: 12_500_000_000) {
                    if ws.isClosed {
                        throw GraphQLError(message: "WebSocket closed before any termination")
                    }
                    process.send(websocketProtocol.keepAliveMessage)
                }

                ws.onText { _, txt in
                    Task.init {
                        await onMessage(process: process, keepAlive: keepAlive, txt: txt)
                    }
                }

                ws.onClose.whenComplete { _ in
                    onEnd(pid: process.id, keepAlive: keepAlive)
                }
            }
        }
    }

    /// On Websocket message callback
    func onMessage(process: Process, keepAlive: KeepAlive, txt: String) async  -> Void {
        guard let data = txt.data(using: .utf8) else {
            // Shouldn't accept any message that aren't utf8 string
            // -> Close with 1003 code
            await process.close(code: .unacceptableData)
            return
        }

        switch websocketProtocol.parse(data) {

        // Initial sub-protocol handshake established
        // Dispatch process to probe so it can start accepting operations
        // Timer fired here to keep connection alive by sub-protocol standard
        case .initial:
            await probe.connect(with: process)
            websocketProtocol.initialize(ws: process.ws)

        // Ping is for requesting server to send a keep alive message
        case .ping:
            process.send(websocketProtocol.keepAliveMessage)

        // Explicit message to terminate connection to deallocate resources, stop timer, and close connection
        case .terminate:
            await probe.disconnect(for: process.id)
            keepAlive?.cancel()
            await process.close(code: .goingAway)

        // Start -> Long running operation
        case .start(oid: let oid, gql: let gql):
            // Introspection guard
            guard case .some(true) = try? allowed(from: gql) else {
                let err = GraphQLMessage.errors(id: oid, type: websocketProtocol.error, [
                    .init(message: "GraphQL introspection is not allowed by Pioneer, but the query contained __schema or __type.")
                ])
                return process.send(err.jsonString)
            }
            await probe.start(
                for: process.id,
                with: oid,
                given: gql
            )

        // Once -> Short lived operation
        case .once(oid: let oid, gql: let gql):
            // Introspection guard
            guard case .some(true) = try? allowed(from: gql) else {
                let err = GraphQLMessage.errors(id: oid, type: websocketProtocol.error, [
                    .init(message: "GraphQL introspection is not allowed by Pioneer, but the query contained __schema or __type.")
                ])
                return process.send(err.jsonString)
            }
            await probe.once(
                for: process.id,
                with: oid,
                given: gql
            )

        // Stop -> End any running operation
        case .stop(oid: let oid):
            await probe.stop(
                for: process.id,
                with: oid
            )

        // Error in validation should notify that no operation will be run, does not close connection
        case .error(oid: let oid, message: let message):
            let err = GraphQLMessage.errors(id: oid, type: websocketProtocol.error, [.init(message: message)])
            process.send(err.jsonString)

        // Fatal error is an event trigger when message given in unacceptable by protocol standard
        // This message if processed any further will cause securities vulnerabilities, thus connection should be closed
        case .fatal(message: let message):
            let err = GraphQLMessage.errors(type: websocketProtocol.error, [.init(message: message)])
            process.send(err.jsonString)

            // Deallocation of resources
            await probe.disconnect(for: process.id)
            keepAlive?.cancel()
            await process.close(code: .policyViolation)

        case .ignore:
            break
        }
    }

    /// On closing connection callback
    func onEnd(pid: UUID, keepAlive: KeepAlive) -> Void {
        Task {
            await probe.disconnect(for: pid)
        }
        keepAlive?.cancel()
    }
}


@discardableResult func setInterval(delay: UInt64?, _ block: @escaping @Sendable () throws -> Void) -> Task<Void, Error>? {
    guard let delay = delay else {
        return nil
    }
    return Task {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: delay)
            try block()
        }
    }
}
