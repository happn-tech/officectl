/*
 * OfficeKitServiceProvider.swift
 * OfficeKit
 *
 * Created by François Lamboley on 28/06/2019.
 */

import Foundation

import SemiSingleton
import Service



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
	
	public func getDirectoryService(id: String?, container: Container) throws -> AnyDirectoryService {
		let config = try officeKitConfig.getServiceConfig(id: id)
		return try directoryService(with: config, container: container)
	}
	
	public func getDirectoryService<DirectoryServiceType : DirectoryService>(id: String?, container: Container) throws -> DirectoryServiceType {
		if let id = id {
			guard let directoryService: DirectoryServiceType = try getDirectoryService(id: id, container: container).unboxed() else {
				throw InvalidArgumentError(message: "Service with id \(id) does not have the correct type")
			}
			return directoryService
		} else {
			let configs = officeKitConfig.serviceConfigs.values.filter{ $0.providerId == DirectoryServiceType.providerId }
			guard let config = configs.first, configs.count == 1 else {
				throw InvalidArgumentError(message: "No or too many directory services found for type \(DirectoryServiceType.providerId)")
			}
			return try directoryService(with: config, container: container).unboxed()!
		}
	}
	
	public func getDirectoryAuthenticatorService(container: Container) throws -> AnyDirectoryAuthenticatorService {
		return try directoryAuthenticatorService(with: officeKitConfig.authServiceConfig, container: container)
	}
	
	/* ***************
	   MARK: - Private
	   *************** */
	
	private let officeKitConfig: OfficeKitConfig
	
	private var servicesCache = [String: AnyDirectoryService]()
	private var directoryAuthenticatorServiceCache: AnyDirectoryAuthenticatorService?
	
	private func directoryService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryService {
		if let service = servicesCache[config.serviceId] {
			return service
		}
		
		let service = try createDirectoryService(with: config, container: container)
		servicesCache[config.serviceId] = service
		return service
	}
	
	private func createDirectoryService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryService {
		switch config.providerId {
		case LDAPService.providerId:
			return try AnyDirectoryService(
				LDAPService(config: config.unboxed()!, domainAliases: officeKitConfig.domainAliases)
			)
			
		case GoogleService.providerId:
			return try AnyDirectoryService(
				GoogleService(config: config.unboxed()!)
			)
			
		case GitHubService.providerId:
			return try AnyDirectoryService(
				GitHubService(config: config.unboxed()!)
			)
			
		#if canImport(DirectoryService) && canImport(OpenDirectory)
		case OpenDirectoryService.providerId:
			return try AnyDirectoryService(
				OpenDirectoryService(config: config.unboxed()!)
			)
		#endif
			
		default:
			throw InvalidArgumentError(message: "Unknown or unsupported service provider \(config.providerId)")
		}
	}
	
	private func directoryAuthenticatorService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryAuthenticatorService {
		if let authenticator = directoryAuthenticatorServiceCache {
			return authenticator
		}
		
		let authenticator = try createDirectoryAuthenticatorService(with: config, container: container)
		directoryAuthenticatorServiceCache = authenticator
		return authenticator
	}
	
	private func createDirectoryAuthenticatorService(with config: AnyOfficeKitServiceConfig, container: Container) throws -> AnyDirectoryAuthenticatorService {
		switch config.providerId {
		case LDAPService.providerId:
			return try AnyDirectoryAuthenticatorService(
				LDAPService(config: config.unboxed()!, domainAliases: officeKitConfig.domainAliases)
			)
			
		default:
			throw InvalidArgumentError(message: "Unknown or unsupported service authenticator provider \(config.providerId)")
		}
	}
	
}
