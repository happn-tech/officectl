/*
 * LDAPService.swift
 * OfficeKit
 *
 * Created by François Lamboley on 29/05/2019.
 */

import Foundation

import Async
import SemiSingleton



public class LDAPService : DirectoryService, DirectoryServiceAuthenticator {
	
	public enum Error : Swift.Error {
		
		case userNotFound
		case tooManyUsersFound
		
		case passwordIsEmpty
		
	}
	
	static public let id = "ldap"
	
	public typealias UserIdType = LDAPDistinguishedName
	public typealias AuthenticationChallenge = String
	
	public let supportsPasswordChange = true
	
	public let serviceName: String
	public let asyncConfig: AsyncConfig
	public let ldapConfig: OfficeKitConfig.LDAPConfig
	public let semiSingletonStore: SemiSingletonStore
	
	public let ldapConnector: LDAPConnector
	
	public init(name: String, ldapConfig config: OfficeKitConfig.LDAPConfig, semiSingletonStore sms: SemiSingletonStore, asyncConfig ac: AsyncConfig) throws {
		asyncConfig = ac
		serviceName = name
		ldapConfig = config
		semiSingletonStore = sms
		
		ldapConnector = try sms.semiSingleton(forKey: config.connectorSettings)
	}
	
	public func changePasswordAction(for user: LDAPDistinguishedName) throws -> Action<LDAPDistinguishedName, String, Void> {
		return semiSingletonStore.semiSingleton(forKey: user, additionalInitInfo: (asyncConfig, ldapConnector)) as ResetLDAPPasswordAction
	}
	
	public func authenticate(user dn: LDAPDistinguishedName, challenge checkedPassword: String) -> Future<Bool> {
		asyncConfig.eventLoop.future()
		.thenThrowing{ _ in
			guard !checkedPassword.isEmpty else {throw Error.passwordIsEmpty}
			
			var ldapConnectorConfig = self.ldapConfig.connectorSettings
			ldapConnectorConfig.authMode = .userPass(username: dn.stringValue, password: checkedPassword)
			return try LDAPConnector(key: ldapConnectorConfig)
		}
		.then{ (connector: LDAPConnector) in
			return connector.connect(scope: (), forceReconnect: true, asyncConfig: self.asyncConfig).map{ true }
		}
		.catchMap{ error in
			if LDAPConnector.isInvalidPassError(error) {
				return false
			}
			throw error
		}
	}
	
	public func isAdmin(_ user: LDAPDistinguishedName) -> Future<Bool> {
		let adminGroupsDN = ldapConfig.adminGroupsDN
		guard adminGroupsDN.count > 0 else {return asyncConfig.eventLoop.future(false)}
		
		let searchQuery = LDAPSearchQuery.or(adminGroupsDN.map{
			LDAPSearchQuery.simple(attribute: .memberof, filtertype: .equal, value: Data($0.stringValue.utf8))
		})
		
		return ldapConnector.connect(scope: (), asyncConfig: asyncConfig)
		.then{ _ -> EventLoopFuture<[LDAPInetOrgPersonWithObject]> in
			let op = SearchLDAPOperation(ldapConnector: self.ldapConnector, request: LDAPSearchRequest(scope: .subtree, base: user, searchQuery: searchQuery, attributesToFetch: nil))
			return self.asyncConfig.eventLoop.future(from: op, queue: self.asyncConfig.operationQueue).map{ $0.results.compactMap{ LDAPInetOrgPersonWithObject(object: $0) } }
		}
		.thenThrowing{ objects -> Bool in
			guard objects.count <= 1 else {
				throw Error.tooManyUsersFound
			}
			guard let inetOrgPerson = objects.first else {
				return false
			}
			return inetOrgPerson.object.parsedDistinguishedName == user
		}
	}
	
}