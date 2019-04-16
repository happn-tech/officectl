/*
 * setup_routes.swift
 * officectl
 *
 * Created by François Lamboley on 06/08/2018.
 */

import Foundation

import OfficeKit
import Vapor



func setup_routes(_ router: Router) throws {
	router.post("api", "auth", "login",  use: LoginController().login)
	router.post("api", "auth", "logout", use: LogoutController().logout)
	
	let usersController = UsersController()
	router.get("api", "users", use: usersController.getUsers)
	router.get("api", "users", UserId.parameter, use: usersController.getUser)
	
	/* ******** Temporary password reset page ******** */
	
	let passwordResetController = PasswordResetController()
	router.get("password-reset", use: passwordResetController.showUserSelection)
	router.get("password-reset",  Email.parameter, use: passwordResetController.showResetPage)
	router.post("password-reset", Email.parameter, use: passwordResetController.resetPassword)
}
