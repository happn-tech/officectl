/*
 * ErasureUtils.swift
 * OfficeKit
 *
 * Created by François Lamboley on 11/07/2019.
 */

import Foundation

import Service



public typealias AnyDSUPair = DSUPair<AnyDirectoryService>
public struct DSUPair<DirectoryServiceType : DirectoryService> : Hashable {
	
	public let service: DirectoryServiceType
	public let user: DirectoryServiceType.UserType
	
	public let serviceId: String
	public let taggedId: TaggedId
	
	public var dsuIdPair: DSUIdPair<DirectoryServiceType> {
		return DSUIdPair(service: service, user: user.userId)
	}
	
	public init(service s: DirectoryServiceType, user u: DirectoryServiceType.UserType) {
		service = s
		user = u
		serviceId = service.config.serviceId
		taggedId = TaggedId(tag: serviceId, id: service.string(fromUserId: user.userId))
	}
	
	public init?<SourceServiceType : DirectoryService>(service s: SourceServiceType, user u: SourceServiceType.UserType) {
		guard let s: DirectoryServiceType = s.unboxed() else {
			return nil
		}
		
		guard let u: DirectoryServiceType.UserType = u.unboxed() else {
			/* In theory we can fatalError here. However, because we’re a server
			 * and must not crash, let’s play it safe. */
			OfficeKitConfig.logger?.error("Got impossible situation where service is unboxed to \(DirectoryServiceType.self), but the user is not unboxed to this directory user type!")
			return nil
		}
		
		self.init(service: s, user: u)
	}
	
	public func hop<NewDirectoryServiceType : DirectoryService>(to newService: NewDirectoryServiceType) throws -> DSUPair<NewDirectoryServiceType> {
		return try DSUPair<NewDirectoryServiceType>(service: newService, user: newService.logicalUser(fromUser: user, in: service))
	}
	
	public func passwordResetPair(on container: Container) throws -> DSPasswordResetPair<DirectoryServiceType>? {
		return try DSPasswordResetPair<DirectoryServiceType>(dsuPair: self, on: container)
	}
	
	public func userWrapper() throws -> DirectoryUserWrapper {
		return try service.wrappedUser(fromUser: user)
	}
	
	public func hash(into hasher: inout Hasher) {
		hasher.combine(taggedId)
	}
	
	public static func ==(_ lhs: DSUPair<DirectoryServiceType>, _ rhs: DSUPair<DirectoryServiceType>) -> Bool {
		return lhs.taggedId == rhs.taggedId
	}
	
}


public typealias AnyDSUIdPair = DSUIdPair<AnyDirectoryService>
public struct DSUIdPair<DirectoryServiceType : DirectoryService> : Hashable {
	
	public let service: DirectoryServiceType
	public let userId: DirectoryServiceType.UserType.UserIdType
	
	public let serviceId: String
	public let taggedId: TaggedId
	
	public init(service s: DirectoryServiceType, user u: DirectoryServiceType.UserType.UserIdType) {
		service = s
		userId = u
		
		serviceId = service.config.serviceId
		taggedId = TaggedId(tag: serviceId, id: service.string(fromUserId: userId))
	}
	
	public init?<SourceServiceType : DirectoryService>(service s: SourceServiceType, user u: SourceServiceType.UserType) {
		guard let dsu = DSUPair<DirectoryServiceType>(service: s, user: u) else {
			return nil
		}
		
		service = dsu.service
		userId = dsu.user.userId
		
		serviceId = dsu.serviceId
		taggedId = dsu.taggedId
	}
	
	public init(taggedId tid: TaggedId, servicesProvider: OfficeKitServiceProvider) throws {
		service = try servicesProvider.getDirectoryService(id: tid.tag)
		userId = try service.userId(fromString: tid.id)
		
		serviceId = service.config.serviceId
		taggedId = tid
		
		if let logger = OfficeKitConfig.logger {
			let newTid = TaggedId(tag: service.config.serviceId, id: service.string(fromUserId: userId))
			if tid != newTid {
				logger.error("Got a tagged it whose service/userId conversion does not convert back to itself. Source = \(tid), New = \(newTid)")
			}
		}
	}
	
	public init(string: String, servicesProvider: OfficeKitServiceProvider) throws {
		let tid = TaggedId(string: string)
		try self.init(taggedId: tid, servicesProvider: servicesProvider)
	}
	
	public func dsuPair() throws -> DSUPair<DirectoryServiceType> {
		return try DSUPair(service: service, user: service.logicalUser(fromUserId: userId))
	}
	
	public func hash(into hasher: inout Hasher) {
		hasher.combine(taggedId)
	}
	
	public static func ==(_ lhs: DSUIdPair<DirectoryServiceType>, _ rhs: DSUIdPair<DirectoryServiceType>) -> Bool {
		return lhs.taggedId == rhs.taggedId
	}
	
}


/** A PasswordReset, and its DSUPair. */
public typealias AnyDSPasswordResetPair = DSPasswordResetPair<AnyDirectoryService>
public struct DSPasswordResetPair<DirectoryServiceType : DirectoryService> {
	
	public let dsuPair: DSUPair<DirectoryServiceType>
	public let passwordReset: ResetPasswordAction
	
	public init?(dsuPair p: DSUPair<DirectoryServiceType>, on container: Container) throws {
		guard p.service.supportsPasswordChange else {
			return nil
		}
		
		dsuPair = p
		passwordReset = try p.service.changePasswordAction(for: p.user, on: container)
	}
	
}