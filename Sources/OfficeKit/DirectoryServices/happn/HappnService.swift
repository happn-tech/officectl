/*
 * HappnService.swift
 * OfficeKit
 *
 * Created by François Lamboley on 28/08/2019.
 */

import Foundation

import GenericJSON
import NIO
import SemiSingleton
import Vapor



public final class HappnService : DirectoryService {
	
	public static var providerId = "internal_happn"
	
	public typealias ConfigType = HappnServiceConfig
	public typealias UserType = HappnUser
	
	public let config: HappnServiceConfig
	public let globalConfig: GlobalConfig
	
	public init(config c: HappnServiceConfig, globalConfig gc: GlobalConfig) {
		config = c
		globalConfig = gc
	}
	
	public func shortDescription(from user: HappnUser) -> String {
		return user.login ?? "<null user id>"
	}
	
	public func string(fromUserId userId: String?) -> String {
		return userId ?? "__officectl_internal__null_happn_id__"
	}
	
	public func userId(fromString string: String) throws -> String? {
		guard string != "__officectl_internal__null_happn_id__" else {
			return nil
		}
		return string
	}
	
	public func string(fromPersistentId pId: String) -> String {
		return pId
	}
	
	public func persistentId(fromString string: String) throws -> String {
		return string
	}
	
	public func json(fromUser user: HappnUser) throws -> JSON {
		/* Probably not optimal in terms of speed, but works well and avoids
		 * having a shit-ton of glue to create in the GoogleUser (or in this
		 * method). */
		return try JSON(encodable: user)
	}
	
	public func logicalUser(fromJSON json: JSON) throws -> HappnUser {
		/* Probably not optimal in terms of speed, but works well and avoids
		 * having a shit-ton of glue to create in the GoogleUser (or in this
		 * method). */
		let encoded = try JSONEncoder().encode(json)
		return try JSONDecoder().decode(HappnUser.self, from: encoded)
	}
	
	public func logicalUser(fromWrappedUser userWrapper: DirectoryUserWrapper) throws -> HappnUser {
		if userWrapper.sourceServiceId == config.serviceId {
			if let underlyingUser = userWrapper.underlyingUser {return try logicalUser(fromJSON: underlyingUser)}
			else {
				/* The generic user id from our service, but there is no underlying
				 * user… Let’s create a HappnUser from the user id. */
				return HappnUser(login: userWrapper.userId.id)
			}
		}
		
		/* *** No underlying user from our service. We infer the user from the generic properties of the wrapped user. *** */
		
		guard let email = userWrapper.mainEmail(domainMap: globalConfig.domainAliases) else {
			throw InvalidArgumentError(message: "Cannot get an email from the user to create a HappnUser")
		}
		var res = HappnUser(login: email.stringValue)
		if userWrapper.firstName != .unsupported {res.firstName = userWrapper.firstName}
		if userWrapper.lastName  != .unsupported {res.lastName  = userWrapper.lastName}
		if userWrapper.nickname  != .unsupported {res.nickname  = userWrapper.nickname}
		return res
	}
	
	public func applyHints(_ hints: [DirectoryUserProperty : String?], toUser user: inout HappnUser, allowUserIdChange: Bool) -> Set<DirectoryUserProperty> {
		var res = Set<DirectoryUserProperty>()
		/* For all changes below we nullify the record because changing the record
		 * is not something that is possible and we want the record wrapper and
		 * its underlying record to be in sync. So all changes to the wrapper must
		 * be done with a nullification of the underlying record. */
		for (property, value) in hints {
			switch property {
			case .userId:
				guard allowUserIdChange else {continue}
				user.login = value
				res.insert(.identifyingEmail)
				res.insert(.userId)
				
			case .identifyingEmail:
				guard allowUserIdChange else {continue}
				guard hints[.userId] == nil else {
					if hints[.userId] != value {
						OfficeKitConfig.logger?.warning("Invalid hints given for a HappnUser: both userId and identifyingEmail are defined with different values. Only userId will be used.")
					}
					continue
				}
				guard let email = value.flatMap({ Email(string: $0) }) else {
					OfficeKitConfig.logger?.warning("Invalid value for an identifying email of a happn user.")
					continue
				}
				user.login = email.stringValue
				res.insert(.identifyingEmail)
				res.insert(.userId)
				
			case .persistentId:
				guard let id = value else {
					OfficeKitConfig.logger?.warning("Invalid value for a persistent id of a happn user.")
					continue
				}
				user.id = .set(id)
				res.insert(.persistentId)
				
			case .firstName:
				user.firstName = .set(value)
				res.insert(.firstName)
				
			case .lastName:
				user.lastName = .set(value)
				res.insert(.lastName)
				
			case .nickname:
				user.nickname = .set(value)
				res.insert(.nickname)
				
			case .password:
				guard let pass = value else {
					OfficeKitConfig.logger?.warning("The password of a happn user cannot be removed.")
					continue
				}
				OfficeKitConfig.logger?.warning("Setting the password of a happn user via hints can lead to unexpected results (including security flaws for this user). Please use the dedicated method to set the password in the service.")
				user.password = .set(pass)
				res.insert(.password)
				
			case .custom("gender"):
				guard let gender = value.flatMap({ HappnUser.Gender(rawValue: $0) }) else {
					OfficeKitConfig.logger?.warning("Invalid gender for a happn user.")
					continue
				}
				user.gender = .set(gender)
				
			case .custom("birthdate"):
				guard let birthdate = value.flatMap({ HappnUser.birthDateFormatter.date(from: $0) }) else {
					OfficeKitConfig.logger?.warning("Invalid gender for a happn user.")
					continue
				}
				user.birthDate = .set(birthdate)
				
			case .otherEmails, .custom:
				(/*nop (not supported)*/)
			}
		}
		return res
	}
	
	public func existingUser(fromPersistentId pId: String, propertiesToFetch: Set<DirectoryUserProperty>, on container: Container) throws -> EventLoopFuture<HappnUser?> {
		#warning("TODO: properties to fetch")
		let happnConnector: HappnConnector = try container.makeSemiSingleton(forKey: config.connectorSettings)
		
		return happnConnector.connect(scope: GetHappnUserOperation.scopes, eventLoop: container.eventLoop)
		.then{ _ in
			let op = GetHappnUserOperation(userKey: pId, connector: happnConnector)
			return Future<HappnUser>.future(from: op, eventLoop: container.eventLoop).map{ $0 as HappnUser? }
		}
		.catchMap{ e in
			switch e {
			case let error as NSError where error.domain == "com.happn.officectl.happn" && error.code == 25002:
				/* User not found error*/
				return nil
				
			default: throw e
			}
		}
	}
	
	public func existingUser(fromUserId uId: String?, propertiesToFetch: Set<DirectoryUserProperty>, on container: Container) throws -> EventLoopFuture<HappnUser?> {
		guard let uId = uId else {
			/* Yes. It’s ugly. But the only admin user with a nil login is 244. */
			return try existingUser(fromPersistentId: HappnConnector.nullLoginUserId, propertiesToFetch: propertiesToFetch, on: container)
		}
		
		#warning("TODO: properties to fetch")
		let happnConnector: HappnConnector = try container.makeSemiSingleton(forKey: config.connectorSettings)
		
		return happnConnector.connect(scope: SearchHappnUsersOperation.scopes, eventLoop: container.eventLoop)
		.then{ _ in
			let ids = Set(Email(string: uId)?.allDomainVariants(aliasMap: self.globalConfig.domainAliases).map{ $0.stringValue } ?? [uId])
			let futures = ids.map{ id -> Future<[HappnUser]> in
				let op = SearchHappnUsersOperation(query: id, happnConnector: happnConnector)
				return Future<[HappnUser]>.future(from: op, eventLoop: container.eventLoop)
			}
			return Future.reduce([HappnUser](), futures, eventLoop: container.eventLoop, +)
		}
		.map{ (users: [HappnUser]) -> HappnUser? in
			guard users.count <= 1 else {
				throw InvalidArgumentError(message: "Given user id has more than one user found")
			}
			return users.first
		}
	}
	
	public func listAllUsers(on container: Container) throws -> EventLoopFuture<[HappnUser]> {
		let happnConnector: HappnConnector = try container.makeSemiSingleton(forKey: config.connectorSettings)
		
		return happnConnector.connect(scope: SearchHappnUsersOperation.scopes, eventLoop: container.eventLoop)
		.then{ _ in
			let searchOp = SearchHappnUsersOperation(query: nil, happnConnector: happnConnector)
			return Future<[HappnUser]>.future(from: searchOp, eventLoop: container.eventLoop)
		}
	}
	
	public let supportsUserCreation = true
	public func createUser(_ user: HappnUser, on container: Container) throws -> EventLoopFuture<HappnUser> {
		let happnConnector: HappnConnector = try container.makeSemiSingleton(forKey: config.connectorSettings)
		
		return happnConnector.connect(scope: CreateHappnUserOperation.scopes, eventLoop: container.eventLoop)
		.then{ _ in
			let op = CreateHappnUserOperation(user: user, connector: happnConnector)
			return Future<HappnUser>.future(from: op, eventLoop: container.eventLoop)
		}
	}
	
	public let supportsUserUpdate = true
	public func updateUser(_ user: HappnUser, propertiesToUpdate: Set<DirectoryUserProperty>, on container: Container) throws -> EventLoopFuture<HappnUser> {
		throw NotImplementedError()
	}
	
	public let supportsUserDeletion = true
	public func deleteUser(_ user: HappnUser, on container: Container) throws -> EventLoopFuture<Void> {
		let happnConnector: HappnConnector = try container.makeSemiSingleton(forKey: config.connectorSettings)
		
		return happnConnector.connect(scope: DeleteHappnUserOperation.scopes, eventLoop: container.eventLoop)
		.then{ _ in
			let op = DeleteHappnUserOperation(user: user, connector: happnConnector)
			return Future<Void>.future(from: op, eventLoop: container.eventLoop)
		}
	}
	
	public let supportsPasswordChange = true
	public func changePasswordAction(for user: HappnUser, on container: Container) throws -> ResetPasswordAction {
		let semiSingletonStore: SemiSingletonStore = try container.make()
		let happnConnector: HappnConnector = semiSingletonStore.semiSingleton(forKey: config.connectorSettings)
		return semiSingletonStore.semiSingleton(forKey: user, additionalInitInfo: happnConnector) as ResetHappnPasswordAction
	}
	
}
