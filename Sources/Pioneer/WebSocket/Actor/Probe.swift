//
//  Probe.swift
//  Pioneer
//
//  Created by d-exclaimation on 11:32 PM.
//  Copyright © 2021 d-exclaimation. All rights reserved.
//

import Foundation
import Desolate
import Vapor
import GraphQL
import Graphiti

extension Pioneer {
    /// Actor for handling Websocket distribution and dispatching of client specific actor
    actor Probe: AbstractDesolate, NonStop {
        private let schema: Schema<Resolver, Context>
        private let resolver: Resolver
        private let proto: SubProtocol.Type

        init(schema: Schema<Resolver, Context>, resolver: Resolver, proto: SubProtocol.Type) {
            self.schema = schema
            self.resolver = resolver
            self.proto = proto
        }

        // Mark: -- States --
        private var clients: [UUID: Process] = [:]

        func onMessage(msg: Act) async -> Signal {
            switch msg {
            // Allocate space and save any verified process
            case .connect(process: let process):
                clients.update(process.id, with: process)

            // Deallocate the space from a closing process
            case .disconnect(pid: let pid):
                clients.delete(pid)

            // Long running operation require its own actor, thus initialing one if there were none prior
            case .start(pid: let pid, oid: let oid, gql: let gql, ctx: let ctx):
                // TODO: Start long running process
                break

            // Short lived operation is processed immediately and pipe back later
            case .once(pid: let pid, oid: let oid, gql: let gql, ctx: let ctx):
                guard let process = clients[pid] else { break }

                let future = execute(gql, ctx: ctx, req: process.req)

                pipeToSelf(future: future) { res in
                    switch res {
                    case .success(let result):
                        return .outgoing(oid: oid, process: process,
                            res: .from(type: self.proto.next, id: oid, result)
                        )
                    case .failure(let error):
                        let result: GraphQLResult = .init(data: nil, errors: [.init(message: error.localizedDescription)])
                        return .outgoing(oid: oid, process: process,
                            res: .from(type: self.proto.next, id: oid, result)
                        )
                    }
                }

            // Stopping any operation to client specific actor
            case .stop(pid: let pid, oid: let oid):
                // TODO: Stop running process for pid and oid
                break

            // Message from pipe to self result after processing short lived operation
            case .outgoing(oid: let oid, process: let process, res: let res):
                process.send(res.jsonString)
                process.send(GraphQLMessage(id: oid, type: proto.complete).jsonString)
            }

            return same
        }

        /// Execute short-lived GraphQL Operation
        private func execute(_ gql: GraphQLRequest, ctx: Context, req: Request) -> Future<GraphQLResult> {
            schema.execute(
                request: gql.query,
                resolver: resolver,
                context: ctx,
                eventLoopGroup: req.eventLoop,
                variables: gql.variables ?? [:],
                operationName: gql.operationName
            )
        }

        enum Act {
            case connect(process: Process)
            case disconnect(pid: UUID)
            case start(pid: UUID, oid: String, gql: GraphQLRequest, ctx: Context)
            case once(pid: UUID, oid: String, gql: GraphQLRequest, ctx: Context)
            case stop(pid: UUID, oid: String)
            case outgoing(oid: String, process: Process, res: GraphQLMessage)
        }
    }
}