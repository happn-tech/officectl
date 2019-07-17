/*
 * app.swift
 * officectl
 *
 * Created by François Lamboley on 10/07/2019.
 */

import Foundation

import OfficeKit
import Vapor



func app(_ env: Environment) throws -> Application {
	var env = env
	let forcedConfigPath: String?
	if let idx = env.arguments.lastIndex(where: { $0 == "--config-file" }), idx + 1 < env.arguments.count {
		forcedConfigPath = env.arguments[idx+1]
		env.arguments.remove(at: idx)
		env.arguments.remove(at: idx)
	} else {
		forcedConfigPath = nil
	}
	let verbose: Bool
	if let idx = env.arguments.lastIndex(where: { $0 == "--verbose" }) {
		verbose = true
		env.arguments.remove(at: idx)
	} else {
		verbose = false
	}
	
	guard !env.arguments.contains(where: { Set(arrayLiteral: "--config-file", "--verbose").contains($0) }) else {
		throw InvalidArgumentError(message: "The --config-file or --verbose options can only be specified once.")
	}
	
	var config = Config.default()
	var services = Services.default()
	try configure(&config, &env, &services, forcedConfigPath: forcedConfigPath, verbose: verbose)
	
	let app = try Application(config: config, environment: env, services: services)
	try boot(app)
	
	return app
}