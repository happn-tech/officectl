/*
 * OfficeKitServiceProvider.swift
 * OfficeKit
 *
 * Created by François Lamboley on 28/06/2019.
 */

import Foundation

import SemiSingleton
import Vapor



public class OfficeKitServiceProvider {
	
	public init(config cfg: OfficeKitConfig) {
		officeKitConfig = cfg
	}
	
	public func getAllServices(container: Container) throws -> [AnyDirectoryService] {
		for (k, v) in officeKitConfig.serviceConfigs {
			guard servicesCache[k] == nil else {continue}
			servicesCache[k] = try directoryService(with: v, container: container)
		}
		return Array(servicesCache.values)
	}
	
	public func getDirectoryService(id: String, container: Container) throws -> AnyDirectoryService {
		guard let config = officeKitConfig.serviceConfigs[id] else {
			throw InvalidArgumentError(message: "No service configured with id \(id)")
		}
		return try directoryService(with: config, container: container)
	}
	
	public func getDirectoryAuthenticatorService(container: Container) throws -> AnyDirectoryAuthenticatorService {
		return try directoryAuthenticatorService(with: officeKitConfig.authServiceConfig, container: container)
	}
	
	/* ***************
	   MARK: - Private
	   *************** */
	
	private let officeKitConfig: OfficeKitConfig
	
	private var servicesCache = [String: AnyDirectoryService]()
	
	private func directoryService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryService {
		let ac = try container.make(AsyncConfig.self)
		let sms = try container.make(SemiSingletonStore.self)
		
		switch config.providerId {
		case LDAPService.providerId:
			return try AnyDirectoryService(
				LDAPService(ldapConfig: config.unwrapped()!, domainAliases: officeKitConfig.domainAliases, semiSingletonStore: sms, asyncConfig: ac),
				asyncConfig: ac
			)
			
		case GoogleService.providerId:
			return try AnyDirectoryService(
				GoogleService(config: config.unwrapped()!, semiSingletonStore: sms, asyncConfig: ac),
				asyncConfig: ac
			)
			
		case GitHubService.providerId:
			return try AnyDirectoryService(
				GitHubService(config: config.unwrapped()!, semiSingletonStore: sms, asyncConfig: ac),
				asyncConfig: ac
			)
			
		#if canImport(DirectoryService) && canImport(OpenDirectory)
		case OpenDirectoryService.providerId:
			return try AnyDirectoryService(
				OpenDirectoryService(config: config.unwrapped()!, semiSingletonStore: sms, asyncConfig: ac),
				asyncConfig: ac
			)
		#endif
			
		default:
			throw InvalidArgumentError(message: "Unknown or unsupported service provider \(config.providerId)")
		}
	}
	
	private func directoryAuthenticatorService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryAuthenticatorService {
		let ac = try container.make(AsyncConfig.self)
		let sms = try container.make(SemiSingletonStore.self)
		
		switch config.providerId {
		case LDAPService.providerId:
			return try AnyDirectoryAuthenticatorService(
				LDAPService(ldapConfig: config.unwrapped()!, domainAliases: officeKitConfig.domainAliases, semiSingletonStore: sms, asyncConfig: ac),
				asyncConfig: ac
			)
			
		default:
			throw InvalidArgumentError(message: "Unknown or unsupported service provider \(config.providerId)")
		}
	}
	
}
