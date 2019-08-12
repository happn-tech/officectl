/*
 * UsersController.swift
 * officectl
 *
 * Created by François Lamboley on 01/03/2019.
 */

import Foundation

import GenericJSON
import JWT
import OfficeKit
import SemiSingleton
import Vapor



class UsersController {
	
	func getAllUsers(_ req: Request) throws -> Future<ApiResponse<ApiUsersSearchResult>> {
		/* General auth check */
		let officectlConfig = try req.make(OfficectlConfig.self)
		guard let bearer = req.http.headers.bearerAuthorization else {throw Abort(.unauthorized)}
		let token = try JWT<ApiAuth.Token>(from: bearer.token, verifiedUsing: .hs256(key: officectlConfig.jwtSecret))
		
		/* Only admins are allowed to list the users. */
		guard token.payload.adm else {
			throw Abort(.forbidden)
		}
		
		let logger = try req.make(Logger.self)
		let sProvider = try req.make(OfficeKitServiceProvider.self)
		
		let serviceIdsStr: String? = req.query["service_ids"]
		let serviceIds = serviceIdsStr?.split(separator: ",").map(String.init)
		let services = try serviceIds.flatMap{ try $0.map{ try sProvider.getDirectoryService(id: $0, container: req) } } ?? sProvider.getAllServices(container: req)
		
		let serviceAndFutureUsers = services.map{ service in (service, req.future().flatMap{ try service.listAllUsers(on: req) }) }
		
		return Future.waitAll(serviceAndFutureUsers, eventLoop: req.eventLoop).flatMap{ servicesAndUserResults in
			let promise = req.eventLoop.newPromise(ApiUsersSearchResult.self)
			
			/* Let’s merge the users */
			let queue = DispatchQueue(label: "Compute merge of users")
			queue.async{
				do {
					struct ServiceAndUserId : Hashable, Equatable {
						var serviceId: String
						var userId: AnyHashable
					}
					class TaggedUser : CustomStringConvertible {
						let user: AnyDirectoryUser
						let service: AnyDirectoryService
						var linkedUserByServiceId: [String: TaggedUser] = [:]
						init(service s: AnyDirectoryService, user u: AnyDirectoryUser) {service = s; user = u}
						
						var serviceAndUserId: ServiceAndUserId {return ServiceAndUserId(serviceId: service.config.serviceId, userId: user.userId)}
						var description: String {return "TaggedUser<\(service.config.serviceId) - \(user)>; linkedUsers: \(linkedUserByServiceId.keys)\n\n\n"}
						
						func link(to linkedUser: TaggedUser) throws {
							var visited = Set<[ServiceAndUserId]>()
							return try link(to: linkedUser, visited: &visited)
						}
						
						private func link(to linkedUser: TaggedUser, visited: inout Set<[ServiceAndUserId]>) throws {
							guard !visited.contains([serviceAndUserId, linkedUser.serviceAndUserId]) else {return}
							visited.insert([serviceAndUserId, linkedUser.serviceAndUserId])
							
							guard user.userId != linkedUser.user.userId || service.config.serviceId != linkedUser.service.config.serviceId else {
								/* Not linking myself to myself… */
								return
							}
							
							/* Make the actual link. */
							if let currentlyLinkedUser = linkedUserByServiceId[linkedUser.service.config.serviceId] {
								guard currentlyLinkedUser.user.userId == linkedUser.user.userId else {
									throw InternalError(message: "User \(self.user) is asked to be linked to \(linkedUser.user), but is also already linked to \(currentlyLinkedUser.user)")
								}
							} else {
								linkedUserByServiceId[linkedUser.service.config.serviceId] = linkedUser
							}
							/* Make the reverse link. */
							try linkedUser.link(to: self, visited: &visited)
							/* Link related users. */
							for toLink in linkedUserByServiceId.values {
								assert(toLink.linkedUserByServiceId.values.contains(where: { $0.user.userId == user.userId && $0.service.config.serviceId == service.config.serviceId }))
								try toLink.link(to: linkedUser, visited: &visited)
							}
						}
					}
					
					let startComputationTime = Date()
					
					/* First let’s drop the unsuccessful users fetches */
					var fetchErrorsByService = [String: ApiError]()
					let servicesAndUsers = servicesAndUserResults.compactMap{ serviceAndUserResults -> [TaggedUser]? in
						let service = serviceAndUserResults.0
						switch serviceAndUserResults.1 {
						case .failure(let error):
							fetchErrorsByService[service.config.serviceId] = ApiError(error: error, environment: req.environment)
							return nil
							
						case .success(let users):
							return users.map{ TaggedUser(service: service, user: $0) }
						}
					}.flatMap{ $0 }
					
					let usersByServiceAndUserId = try groupCollection(servicesAndUsers, by: { taggedUser in ServiceAndUserId(serviceId: taggedUser.service.config.serviceId, userId: taggedUser.user.userId) })
					
					/* Now we merge the users that we do have. */
					for (_, taggedUser) in usersByServiceAndUserId {
						let currentUserServiceId = taggedUser.service.config.serviceId
						for service in services {
							let serviceId = service.config.serviceId
							guard serviceId != currentUserServiceId else {continue}
							guard !fetchErrorsByService.keys.contains(serviceId) else {
								/* No need to check for a matching user for this service
								 * as we know there was an error fetching the list of
								 * the users in this service. */
								continue
							}
							guard let logicallyLinkedUser = try? service.logicalUser(fromUser: taggedUser.user, in: taggedUser.service, hints: [:]) else {
//								logger.debug("Error finding logically linked user with: {\n  source service id: \(currentUserServiceId)\n  dest service id:\(serviceId)\n  source user: \(taggedUser.user)\n}")
								continue
							}
							guard let logicallyLinkedTaggedUser = usersByServiceAndUserId[ServiceAndUserId(serviceId: serviceId, userId: logicallyLinkedUser.userId)] else {
//								logger.debug("Found logically linked user, but user does not exist: {\n  source service id: \(currentUserServiceId)\n  dest service id:\(serviceId)\n  source user: \(taggedUser.user)\n  dest user: \(logicallyLinkedUser)\n}")
								continue
							}
							try taggedUser.link(to: logicallyLinkedTaggedUser)
						}
					}
					
					let validServiceIds = Set(services.map{ $0.config.serviceId }).subtracting(fetchErrorsByService.keys)
					
					var treatedServiceAndUserIds = Set<ServiceAndUserId>()
					let results = try usersByServiceAndUserId.compactMap{ kv -> [String: JSON]? in
						let (serviceAndUserId, taggedUser) = kv
						
						guard !treatedServiceAndUserIds.contains(serviceAndUserId) else {return nil}
						treatedServiceAndUserIds.insert(serviceAndUserId)
						
						var res = try [taggedUser.service.config.serviceId: taggedUser.service.exportableJSON(from: taggedUser.user)]
						for (linkedServiceId, linkedUser) in taggedUser.linkedUserByServiceId {
							let linkedServiceAndUserId = ServiceAndUserId(serviceId: linkedServiceId, userId: linkedUser.user.userId)
							guard !treatedServiceAndUserIds.contains(linkedServiceAndUserId) else {
								throw InternalError(message: "Got already treated linked user! \(linkedServiceAndUserId) for \(serviceAndUserId)")
							}
							res[linkedServiceId] = try linkedUser.service.exportableJSON(from: linkedUser.user)
							treatedServiceAndUserIds.insert(linkedServiceAndUserId)
						}
						for sId in validServiceIds {
							if !res.keys.contains(sId) {
								res[sId] = .some(nil)
							}
						}
						return res
					}
					
					logger.info("Computed merged users list in \(-startComputationTime.timeIntervalSinceNow) seconds")
					promise.succeed(result: ApiUsersSearchResult(request: "TODO", results: results, errorsByServiceId: fetchErrorsByService))
				} catch {
					promise.fail(error: error)
				}
			}
			
			return promise.futureResult.map{ ApiResponse.data($0) }
		}
	}
	
	func getMe(_ req: Request) throws -> Future<ApiResponse<ApiUserSearchResult>> {
		/* General auth check */
		let officectlConfig = try req.make(OfficectlConfig.self)
		guard let bearer = req.http.headers.bearerAuthorization else {throw Abort(.unauthorized)}
		let token = try JWT<ApiAuth.Token>(from: bearer.token, verifiedUsing: .hs256(key: officectlConfig.jwtSecret))
		
		let myUserId = try FullUserId(taggedId: token.payload.sub, container: req)
		return try getUserNoAuthCheck(userId: myUserId, container: req)
	}
	
	func getUser(_ req: Request) throws -> Future<ApiResponse<ApiUserSearchResult>> {
		/* General auth check */
		let officectlConfig = try req.make(OfficectlConfig.self)
		guard let bearer = req.http.headers.bearerAuthorization else {throw Abort(.unauthorized)}
		let token = try JWT<ApiAuth.Token>(from: bearer.token, verifiedUsing: .hs256(key: officectlConfig.jwtSecret))
		
		/* Parameter retrieval */
		let userId = try req.parameters.next(FullUserId.self)
		
		/* Only admins are allowed to see any user. Other users can only see
		 * themselves. */
		guard try token.payload.adm || token.payload.representsSameUserAs(userId: userId, container: req) else {
			throw Abort(.forbidden)
		}
		
		return try getUserNoAuthCheck(userId: userId, container: req)
	}
	
	private func getUserNoAuthCheck(userId: FullUserId, container: Container) throws -> Future<ApiResponse<ApiUserSearchResult>> {
		let sProvider = try container.make(OfficeKitServiceProvider.self)
		let (service, user) = try (userId.service, userId.service.logicalUser(fromUserId: userId.id, hints: [:]))
		
		let allServices = try sProvider.getAllServices(container: container)
		let userFutures = allServices.map{ curService in
			container.future().flatMap{
				try curService.existingUser(from: user, in: service, propertiesToFetch: [], on: container)
			}
		}
		return Future.waitAll(userFutures, eventLoop: container.eventLoop).map{ userResults in
			var serviceIdToUser = [String: ApiResponse<JSON?>]()
			for (idx, userResult) in userResults.enumerated() {
				let service = allServices[idx]
				serviceIdToUser[service.config.serviceId] = ApiResponse(result: userResult.flatMap{ curUser in Result{ try curUser.flatMap{ try service.exportableJSON(from: $0) } } }, environment: container.environment)
			}
			return ApiResponse.data(ApiUserSearchResult(request: userId.taggedId, results: serviceIdToUser))
		}
	}
	
}
