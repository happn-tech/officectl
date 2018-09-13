/*
 * list-users.swift
 * officectl
 *
 * Created by François Lamboley on 6/26/18.
 */

import Foundation

import Guaka
import Vapor

import OfficeKit



func listUsers(flags f: Flags, arguments args: [String], context: CommandContext) throws -> EventLoopFuture<Void> {
	let asyncConfig: AsyncConfig = try context.container.make()
	
	let userBehalf = f.getString(name: "google-admin-email")!
	
	let googleConnector = try GoogleJWTConnector(flags: f, userBehalf: userBehalf)
	let f = googleConnector.connect(scope: SearchGoogleUsersOperation.scopes, asyncConfig: asyncConfig)
	.then{ _ -> EventLoopFuture<[GoogleUser]> in
		let searchOp = SearchGoogleUsersOperation(searchedDomain: "happn.fr", googleConnector: googleConnector)
		return context.container.eventLoop.future(from: searchOp, queue: asyncConfig.operationQueue, resultRetriever: { try $0.result.successValueOrThrow() })
	}
	.then{ users -> EventLoopFuture<Void> in
		var i = 1
		for user in users {
			print(user.primaryEmail.stringValue + ",", terminator: "")
			if i == 69 {print(); print(); i = 0}
			i += 1
		}
		print()
		return context.container.eventLoop.newSucceededFuture(result: ())
	}
	return f
}
