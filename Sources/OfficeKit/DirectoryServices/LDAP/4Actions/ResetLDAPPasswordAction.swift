/*
 * ResetLDAPPasswordAction.swift
 * OfficeKit
 *
 * Created by François Lamboley on 13/11/2018.
 */

import Foundation

import SemiSingleton
import Vapor



public class ResetLDAPPasswordAction : Action<LDAPDistinguishedName, String, Void>, SemiSingleton {
	
	public static func additionalInfo(from container: Container) throws -> (AsyncConfig, LDAPConnector) {
		return try (container.make(), container.make())
	}
	
	public typealias SemiSingletonKey = LDAPDistinguishedName
	public typealias SemiSingletonAdditionalInitInfo = (AsyncConfig, LDAPConnector)
	
	public required init(key u: LDAPDistinguishedName, additionalInfo: (AsyncConfig, LDAPConnector), store: SemiSingletonStore) {
		deps = Dependencies(asyncConfig: additionalInfo.0, ldapConnector: additionalInfo.1)
		
		super.init(subject: u)
	}
	
	public override func unsafeStart(parameters newPassword: String, handler: @escaping (Result<Void, Error>) -> Void) throws {
		/* Note: To be symmetrical with the reset google user action, we could use
		 *       the existingLDAPUser method. */
		deps.ldapConnector.connect(scope: (), handlerQueue: deps.asyncConfig.dispatchQueue, handler: { _, error in
			if let e = error {return handler(.failure(e))}
			
			let person = LDAPInetOrgPerson(dn: self.subject.stringValue, sn: [], cn: [])
			person.userPassword = newPassword
			
			let operation = ModifyLDAPPasswordsOperation(users: [person], connector: self.deps.ldapConnector)
			operation.completionBlock = {
				if let e = operation.errors[0] {handler(.failure(e))}
				else                           {handler(.success(()))}
			}
			self.deps.asyncConfig.operationQueue.addOperations([operation], waitUntilFinished: false)
		})
	}
	
	private struct Dependencies {
		
		var asyncConfig: AsyncConfig
		var ldapConnector: LDAPConnector
		
	}
	
	private let deps: Dependencies
	
}