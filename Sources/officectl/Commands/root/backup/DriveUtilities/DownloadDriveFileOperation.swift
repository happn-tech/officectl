/*
 * DownloadDriveFileOperation.swift
 * officectl
 *
 * Created by François Lamboley on 11/02/2020.
 */

import Foundation

import GenericJSON
import NIO
import OfficeKit
import RetryingOperation
import URLRequestOperation



class DownloadDriveFileOperation : RetryingOperation, HasResult {
	
	static let downloadBinaryQueue = OperationQueue(name_OperationQueue: "Download Binary Queue")
	
	typealias ResultType = GoogleDriveDoc
	
	let state: DownloadDriveState
	
	let doc: GoogleDriveDoc
	
	private(set) var result = Result<GoogleDriveDoc, Error>.failure(OperationIsNotFinishedError())
	
	init(state s: DownloadDriveState, doc d: GoogleDriveDoc) {
		doc = d
		state = s
	}
	
	override func startBaseOperation(isRetry: Bool) {
		if let n = doc.name     { _ = try? state.logFile.logCSVLine([doc.id, "name", n]) }
		if let t = doc.mimeType { _ = try? state.logFile.logCSVLine([doc.id, "mime-type", t]) }
		if let o = doc.owners   { _ = try? state.logFile.logCSVLine([doc.id, "owners", o.map{ $0.emailAddress?.stringValue ?? "<unknown address>" }.joined(separator: ", ")]) }
		if let p = doc.parents  { _ = try? state.logFile.logCSVLine([doc.id, "parent_ids", p.joined(separator: ", ")]) }
		if let perms = doc.permissions {
			let encoder = JSONEncoder()
			for pjson in perms {
				guard let pstr = (try? encoder.encode(pjson)).flatMap({ String(data: $0, encoding: .utf8) }) else {
					_ = try? state.logFile.logCSVLine([doc.id, "permission_string_interpolated_because_json_encoding_failed", "\(pjson)"])
					continue
				}
				_ = try? state.logFile.logCSVLine([doc.id, "permission", pstr])
			}
		}
		
		let fileDownloadDestinationURL = self.state.allFilesDestinationBaseURL.appendingPathComponent(self.doc.id, isDirectory: false)
		
		let fileObjectURL = driveApiBaseURL.appendingPathComponent("files", isDirectory: true).appendingPathComponent(doc.id)
		var urlComponents = URLComponents(url: fileObjectURL, resolvingAgainstBaseURL: true)!
		urlComponents.queryItems = [URLQueryItem(name: "alt", value: "media")]
		
		var urlRequest = URLRequest(url: urlComponents.url!)
		urlRequest.timeoutInterval = 24*3600
		
		_ = state.connector.connect(scope: driveROScope, eventLoop: state.eventLoop)
		.flatMap{ _ in self.state.connector.authenticate(request: urlRequest, eventLoop: self.state.eventLoop) }
		.flatMap{ urlRequestAuthResult -> EventLoopFuture<Void> in
			var isDir = ObjCBool(true)
			guard !FileManager.default.fileExists(atPath: fileDownloadDestinationURL.path, isDirectory: &isDir) else {
				/* If the file exists and is not a directory we assume it has
				 * already been downloaded from the drive. We do not check
				 * whether it is out of date or not; we’re not a sync service,
				 * all we want mostly is being able to continue downloading if
				 * the process stopped for whatever reason.
				 * We still re-link the file even if it was already downloaded
				 * because we cannot be certain it has been linked without a db
				 * or an xattr on the files, which are neither solutions I want
				 * to implement. */
				guard !isDir.boolValue else {
					return self.state.eventLoop.makeFailedFuture(InvalidArgumentError(message: "A folder exists where a file would be downloaded."))
				}
				return self.state.eventLoop.future()
			}
			
			var downloadConfig = URLRequestOperation.Config(request: urlRequestAuthResult.result, session: nil)
			downloadConfig.destinationURL = fileDownloadDestinationURL
			downloadConfig.downloadBehavior = .failIfDestinationExists
			downloadConfig.acceptableStatusCodes = IndexSet(integersIn: 200..<300).union(IndexSet(integer: 403))
			
			let op = DriveUtils.rateLimitGoogleDriveAPIOperation(DownloadBinaryForDoc(config: downloadConfig), queue: DownloadDriveFileOperation.downloadBinaryQueue)
			return EventLoopFuture<Void>.future(from: op, on: self.state.eventLoop, queue: DownloadDriveFileOperation.downloadBinaryQueue, resultRetriever: { o in
				if let e = o.finalError {throw e}
				else                    {return ()}
			})
		}
		.flatMap{ _ in
			self.state.getPaths(objectId: self.doc.id, objectName: self.doc.name ?? self.doc.id, parentIds: self.doc.parents)
		}
		.flatMapThrowing{ paths in
			let fm = FileManager.default
			for p in paths {
				_ = try? self.state.logFile.logCSVLine([self.doc.id, "path", p])
				
				let destinationURL = URL(fileURLWithPath: p, isDirectory: true, relativeTo: self.state.driveDestinationBaseURL)
				let destinationURLFolder = destinationURL.deletingLastPathComponent()
				
				/* Remove previous file if applicable. */
				_ = try? fm.removeItem(at: destinationURL)
				
				try fm.createDirectory(at: destinationURLFolder, withIntermediateDirectories: true, attributes: nil)
				try fm.linkItem(at: fileDownloadDestinationURL, to: destinationURL)
			}
		}
		.flatMap{ _ -> EventLoopFuture<Void> in
			/* Try and delete the downloaded file if needed */
			guard self.state.eraseDownloadedFiles else {
				return self.state.eventLoop.future()
			}
			
			var request = URLRequest(url: fileObjectURL)
			request.httpMethod = "DELETE"
			
			return self.state.connector.connect(scope: driveFileScope, eventLoop: self.state.eventLoop)
			.flatMap{ _ in self.state.connector.authenticate(request: request, eventLoop: self.state.eventLoop) }
			.flatMap{ authenticatedRequest in
				let requestOperationConfig = URLRequestOperation.Config(request: authenticatedRequest.result, session: nil, acceptableStatusCodes: IndexSet(integersIn: 200..<300).union(IndexSet(integer: 403)))
				let op = DriveUtils.rateLimitGoogleDriveAPIOperation(DeleteFileURLRequestOperation(config: requestOperationConfig))
				
				return EventLoopFuture<Void>.future(from: op, on: self.state.eventLoop, queue: DownloadDriveFileOperation.downloadBinaryQueue, resultRetriever: { o in
					if let e = o.finalError {throw InvalidArgumentError(message: "Cannot delete file; error: \(e)")}
					else                    {return ()}
				})
			}
		}
		.always{ result in
			switch result {
			case .success:        self.succeedDownload()
			case .failure(let e): self.failDownload(error: e)
			}
		}
	}
	
	override var isAsynchronous: Bool {
		return true
	}
	
	private class DownloadBinaryForDoc : URLRequestOperation {
		
		override func computeRetryInfo(sourceError error: Error?, completionHandler: @escaping (URLRequestOperation.RetryMode, URLRequest, Error?) -> Void) {
			if statusCode == 403 {
				/* If we have a 403, we check the content of the file for the error
				 * reported by google. Whatever the error, we will delete the file
				 * after checking and reporting the error. */
				defer {downloadedFileURL.flatMap{ _ = try? FileManager.default.removeItem(at: $0) }}
				
				if let data = downloadedFileURL.flatMap({ try? Data(contentsOf: $0) }) {
					let jsonDecoder = JSONDecoder()
					guard
						let json = try? jsonDecoder.decode(JSON.self, from: data),
						let _ = json["error"]?["errors"]?.arrayValue?.first(where: { $0["domain"]?.stringValue == "usageLimits" && $0["reason"]?.stringValue == "userRateLimitExceeded" })
					else {
						return completionHandler(.doNotRetry, currentURLRequest, InvalidArgumentError(message: "Got 403 w/ message from server: \(data.reduce("", { $0 + String(format: "%02x", $1) }))"))
					}
					return completionHandler(.retry(withDelay: 100, enableReachability: false, enableOtherRequestsObserver: false), currentURLRequest, nil)
				}
				return completionHandler(.doNotRetry, currentURLRequest, InvalidArgumentError(message: "403 from server"))
			}
			super.computeRetryInfo(sourceError: error, completionHandler: completionHandler)
		}
		
	}
	
	private class DeleteFileURLRequestOperation : URLRequestOperationWithRetryRecoveryHandler {
		
		override func computeRetryInfo(sourceError error: Error?, completionHandler: @escaping (URLRequestOperation.RetryMode, URLRequest, Error?) -> Void) {
			if statusCode == 403 {
				return DriveUtils.retryRecoveryHandler(self, sourceError: InvalidArgumentError(message: "Got 403 when deleting file"), completionHandler: completionHandler)
			}
			super.computeRetryInfo(sourceError: error, completionHandler: completionHandler)
		}
		
	}
	
	private func succeedDownload() {
		state.status.syncQueue.sync{
			state.status[state.userAndDest.user].nFilesProcessed += 1
			state.status[state.userAndDest.user].nBytesProcessed += doc.size.flatMap{ Int($0) } ?? 0
		}
		baseOperationEnded()
	}
	
	private func failDownload(error: Error) {
		_ = try? state.logFile.logCSVLine([doc.id, "download_error", error.legibleLocalizedDescription])
		state.status.syncQueue.sync{ state.status[state.userAndDest.user].nFailures += 1 }
		result = .failure(error)
		baseOperationEnded()
	}
	
}
