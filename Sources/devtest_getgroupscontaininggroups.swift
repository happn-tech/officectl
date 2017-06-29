import Guaka
import Foundation


let devtestGetgroupscontaininggroupsCommand = Command(
	usage: "getgroupscontaininggroups", configuration: configuration, run: execute
)

private func configuration(command: Command) {
	command.add(
		flags: [
		]
	)
}

private func execute(flags: Flags, args: [String]) {
	guard let (accessTokenString, _) = try? rootConfig.superuser.getAccessToken(forScopes: ["https://www.googleapis.com/auth/admin.directory.group", "https://www.googleapis.com/auth/admin.directory.user.readonly"], onBehalfOfUserWithEmail: "francois.lamboley@happn.fr") else {
		devtestGetgroupscontaininggroupsCommand.fail(statusCode: 1, errorMessage: "Cannot get access token for admin user")
	}
	
	var getGroupsComponents = URLComponents(string: "https://www.googleapis.com/admin/directory/v1/groups?domain=happn.fr")!
	getGroupsComponents.queryItems = [
		URLQueryItem(name: "domain", value: "happn.fr")
	]
	
	var getGroupsRequest = URLRequest(url: getGroupsComponents.url!)
	getGroupsRequest.addValue("Bearer \(accessTokenString)", forHTTPHeaderField: "Authorization")
	
	guard let (dataO, _) = try? URLSession.shared.synchronousDataTask(with: getGroupsRequest), let data = dataO, let parsedData = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any], let groups = parsedData["groups"] as? [[String: Any]] else {
		devtestGetgroupscontaininggroupsCommand.fail(statusCode: 1, errorMessage: "Cannot get groups")
	}
	
	for group in groups {
		guard let id = group["id"] as? String, let name = group["email"] as? String else {continue}
		
		let getGroupContentComponents = URLComponents(string: "https://www.googleapis.com/admin/directory/v1/groups/\(id)/members")!
		
		var getGroupsContentRequest = URLRequest(url: getGroupContentComponents.url!)
		getGroupsContentRequest.addValue("Bearer \(accessTokenString)", forHTTPHeaderField: "Authorization")
		
		guard let (dataO, _) = try? URLSession.shared.synchronousDataTask(with: getGroupsContentRequest), let data = dataO, let parsedData = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any], let members = (parsedData["members"] as? [[String: Any]])?.flatMap({ $0["email"] as? String }) else {
			continue
		}
		
		if members.contains(where: { $0.hasPrefix("staff.") }) {
			print(name)
		}
	}
}
