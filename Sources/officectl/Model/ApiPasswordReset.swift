/*
 * ApiPasswordReset.swift
 * officectl
 *
 * Created by François Lamboley on 15/04/2019.
 */

import Foundation

import OfficeKit



struct ApiPasswordReset : Codable {
	
	var userId: UserId
	
	var isExecuting: Bool
	var services: [ApiServicePasswordReset]
	
	init(passwordReset: ResetPasswordAction) {
		userId = passwordReset.subject.id
		isExecuting = passwordReset.isExecuting
		services = [
			ApiServicePasswordReset(ldapPasswordReset: passwordReset.resetLDAPPasswordAction),
			ApiServicePasswordReset(googlePasswordReset: passwordReset.resetGooglePasswordAction)
		]
	}
	
}