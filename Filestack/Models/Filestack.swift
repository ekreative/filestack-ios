//
//  Filestack.swift
//  Filestack
//
//  Created by Ruben Nine on 10/19/17.
//  Copyright © 2017 Filestack. All rights reserved.
//

import Foundation
import FilestackSDK
import SafariServices


public typealias FolderListCompletionHandler = (_ response: FolderListResponse) -> Swift.Void
public typealias StoreCompletionHandler = (_ response: StoreResponse) -> Swift.Void

internal typealias CompletionHandler = (_ response: CloudResponse, _ safariError: Error?) -> Swift.Void


/**
    The `Filestack` class provides an unified API to upload files and manage cloud contents using Filestack REST APIs.
 */
@objc(FSFilestack) public class Filestack: NSObject {


    // MARK: - Notifications

    /// This notification should be posted after an app receives an URL after authentication against a cloud provider.
    public static let resumeCloudRequestNotification = Notification.Name("resume-filestack-cloud-request")


    // MARK: - Properties

    /// An API key obtained from the [Developer Portal](http://dev.filestack.com).
    public let apiKey: String

    /// A `Security` object. `nil` by default.
    public let security: Security?

    /// A `Config` object.
    public let config: Config


    // MARK: - Private Properties

    private let client: Client
    private let cloudService = CloudService()

    private var pendingRequests: [URL: (CloudRequest, DispatchQueue, CompletionHandler)]
    private var lastToken: String?
    private var resumeCloudRequestNotificationObserver: NSObjectProtocol!
    private var safariAuthSession: AnyObject? = nil


    // MARK: - Lifecyle Functions

    /**
        Default initializer.

        - Parameter apiKey: An API key obtained from the Developer Portal.
        - Parameter security: A `Security` object. `nil` by default.
        - Parameter config: A `Config` object. `nil` by default.
        - Parameter token: A token obtained from `lastToken` to use initially. This could be useful to avoid
             authenticating against a cloud provider assuming that the passed token has not yet expired.
     */
    @objc public init(apiKey: String, security: Security? = nil, config: Config? = nil, token: String? = nil) {

        self.apiKey = apiKey
        self.security = security
        self.lastToken = token
        self.client = Client(apiKey: apiKey, security: security)
        self.pendingRequests = [:]
        self.config = config ?? Config()

        super.init()
    }


    // MARK: - Public Functions


    /**
        Uploads a file directly to a given storage location (currently only S3 is supported.)

        - Parameter localURL: The URL of the local file to be uploaded.
        - Parameter storeOptions: An object containing the store options (e.g. location, region, container, access, etc.
            If none given, S3 location with default options is assumed.
        - Parameter useIntelligentIngestionIfAvailable: Attempts to use Intelligent Ingestion for file uploading.
            Defaults to `true`.
        - Parameter queue: The queue on which the upload progress and completion handlers are dispatched.
        - Parameter uploadProgress: Sets a closure to be called periodically during the lifecycle of the upload process
            as data is uploaded to the server. `nil` by default.
        - Parameter completionHandler: Adds a handler to be called once the upload has finished.
     */
    @discardableResult public func upload(from localURL: URL,
                                          storeOptions: StorageOptions = StorageOptions(location: .s3),
                                          useIntelligentIngestionIfAvailable: Bool = true,
                                          queue: DispatchQueue = .main,
                                          uploadProgress: ((Progress) -> Void)? = nil,
                                          completionHandler: @escaping (NetworkJSONResponse?) -> Void) -> CancellableRequest {

        let mpu = client.multiPartUpload(from: localURL,
                                         storeOptions: storeOptions,
                                         useIntelligentIngestionIfAvailable: useIntelligentIngestionIfAvailable,
                                         queue: queue,
                                         startUploadImmediately: false,
                                         uploadProgress: uploadProgress,
                                         completionHandler: completionHandler)

        mpu.uploadFile()

        return mpu
    }

    /**
        Uploads a file to a given storage location picked interactively from the camera or the photo library.

        - Parameter viewController: The view controller that will present the picker.
        - Parameter sourceType: The desired source type (e.g. camera, photo library.)
        - Parameter storeOptions: An object containing the store options (e.g. location, region, container, access, etc.)
            If none given, S3 location with default options is assumed.
        - Parameter useIntelligentIngestionIfAvailable: Attempts to use Intelligent Ingestion for file uploading.
            Defaults to `true`.
        - Parameter queue: The queue on which the upload progress and completion handlers are dispatched.
        - Parameter uploadProgress: Sets a closure to be called periodically during the lifecycle of the upload process
            as data is uploaded to the server. `nil` by default.
        - Parameter completionHandler: Adds a handler to be called once the upload has finished.
     */
    @discardableResult public func uploadFromImagePicker(viewController: UIViewController,
                                                         sourceType: UIImagePickerControllerSourceType,
                                                         storeOptions: StorageOptions = StorageOptions(location: .s3),
                                                         useIntelligentIngestionIfAvailable: Bool = true,
                                                         queue: DispatchQueue = .main,
                                                         uploadProgress: ((Progress) -> Void)? = nil,
                                                         completionHandler: @escaping (NetworkJSONResponse?) -> Void) -> CancellableRequest {

        let mpu = client.multiPartUpload(storeOptions: storeOptions,
                                         useIntelligentIngestionIfAvailable: useIntelligentIngestionIfAvailable,
                                         queue: queue,
                                         startUploadImmediately: false,
                                         uploadProgress: uploadProgress,
                                         completionHandler: completionHandler)

        let uploadController = PickerUploadController(multipartUpload: mpu,
                                                      viewController: viewController,
                                                      sourceType: sourceType)

        uploadController.filePickedCompletionHandler = { (success) in
            // Remove completion handler, so this `PickerUploadController` object can be properly deallocated.
            uploadController.filePickedCompletionHandler = nil

            if success {
                // As soon as a file is picked, let's send a progress update with 0% progress for faster feedback.
                let progress = Progress(totalUnitCount: 1)
                progress.completedUnitCount = 0

                uploadProgress?(progress)
            }
        }

        uploadController.start()

        return mpu
    }

    /**
         Lists the content of a cloud provider at a given path. Results are paginated (see `pageToken` below.)

         - Parameter provider: The cloud provider to use (e.g. Dropbox, GoogleDrive, S3)
         - Parameter path: The path to list (be sure to include a trailing slash "/".)
         - Parameter pageToken: A token obtained from a previous call to this function. This token is included in every
             `FolderListResponse` returned by this function in a property called `nextToken`.
         - Parameter completionHandler: Adds a handler to be called once the request has completed either with a success,
             or error response.
     */
    @discardableResult public func folderList(provider: CloudProvider,
                                              path: String,
                                              pageToken: String? = nil,
                                              queue: DispatchQueue = .main,
                                              completionHandler: @escaping FolderListCompletionHandler) -> CancellableRequest {

        guard let appURLScheme = config.appURLScheme else {
            fatalError("Please make sure your Filestack config object has an appURLScheme set.")
        }

        let request = FolderListRequest(appURLScheme: appURLScheme,
                                        apiKey: apiKey,
                                        security: security,
                                        token:  lastToken,
                                        pageToken: pageToken,
                                        provider: provider,
                                        path: path)

        let genericCompletionHandler: CompletionHandler = { response, safariError in
            switch (response, safariError) {
            case (let response as FolderListResponse, nil):

                completionHandler(response)

            case (_, let error):

                let response = FolderListResponse(contents: nil,
                                                  nextToken: nil,
                                                  authURL: nil,
                                                  error: error)

                completionHandler(response)
            }
        }

        perform(request: request, queue: queue, completionBlock: genericCompletionHandler)

        return request
    }

    /**
        Stores a file from a given cloud provider and path at the desired store location.

        - Parameter provider: The cloud provider to use (e.g. Dropbox, GoogleDrive, S3)
        - Parameter path: The path to a file in the cloud provider.
        - Parameter storeOptions: An object containing the store options (e.g. location, region, container, access, etc.)
             If none given, S3 location is assumed.
        - Parameter completionHandler: Adds a handler to be called once the request has completed either with a success,
             or error response.
     */
    @discardableResult public func store(provider: CloudProvider,
                                         path: String,
                                         storeOptions: StorageOptions = StorageOptions(location: .s3),
                                         queue: DispatchQueue = .main,
                                         completionHandler: @escaping StoreCompletionHandler) -> CancellableRequest {

        let request = StoreRequest(apiKey: apiKey,
                                   security: security,
                                   token:  lastToken,
                                   provider: provider,
                                   path: path,
                                   storeOptions: storeOptions)

        let genericCompletionHandler: CompletionHandler = { response, _ in
            guard let response = response as? StoreResponse else { return }
            completionHandler(response)
        }

        perform(request: request, queue: queue, completionBlock: genericCompletionHandler)

        return request
    }

    /**
        Presents an interactive UI that will allow the user to pick files from a local or cloud source and upload them
        to a given location.

        - Parameter viewController: The view controller that will present the interactive UI.
        - Parameter storeOptions: An object containing the store options (e.g. location, region, container, access, etc.)
            If none given, S3 location is assumed.
     */
    public func presentInteractiveUploader(viewController: UIViewController,
                                           storeOptions: StorageOptions = StorageOptions(location: .s3)) {

        let storyboard = UIStoryboard(name: "InteractiveUploader", bundle: Bundle(for: classForCoder))

        let scene = NavigationScene(filestack: self,
                                    storeOptions: storeOptions)

        let fsnc = storyboard.instantiateViewController(for: scene)

        viewController.present(fsnc, animated: true)
    }


    // MARK: - Internal Functions

    internal func prefetch(completionBlock: @escaping PrefetchCompletionHandler) {

        let prefetchRequest = PrefetchRequest(apiKey: apiKey)

        prefetchRequest.perform(cloudService: cloudService, completionBlock: completionBlock)
    }


    // MARK: - Private Functions

    private func perform(request: CloudRequest, queue: DispatchQueue = .main, completionBlock: @escaping CompletionHandler) {

        // Perform request.
        // On success, store last token and call completion block.
        // Else, if auth is required, add request to pending requests, open Safari and request authentication.
        request.perform(cloudService: cloudService, queue: queue) { (authRedirectURL, response) in
            if let token = request.token {
                self.lastToken = token
            }

            if let authURL = response.authURL, let authRedirectURL = authRedirectURL {
                DispatchQueue.main.async {
                    if #available(iOS 11, *) {
                        let safariAuthSession = SFAuthenticationSession(url: authURL,
                                                                        callbackURLScheme: self.config.appURLScheme,
                                                                        completionHandler: { (url, error) in
                                                                            // Remove strong reference,
                                                                            // so object can be deallocated.
                                                                            self.safariAuthSession = nil

                                                                            if let safariError = error {
                                                                                completionBlock(response, safariError)
                                                                            } else if let url = url, url.absoluteString.starts(with: authRedirectURL.absoluteString) {
                                                                                self.perform(request: request,
                                                                                             queue: queue,
                                                                                             completionBlock: completionBlock)
                                                                            }
                        })

                        // Keep a strong reference to the auth session.
                        self.safariAuthSession = safariAuthSession

                        safariAuthSession.start()
                    } else if #available(iOS 10, *) {
                        UIApplication.shared.open(authURL) { success in
                            if success {
                                self.addPendingRequest(appRedirectURL: authRedirectURL,
                                                       request: request,
                                                       queue: queue,
                                                       completionBlock: completionBlock)
                            }
                        }
                    } else {
                        if UIApplication.shared.openURL(authURL) {
                            self.addPendingRequest(appRedirectURL: authRedirectURL,
                                                   request: request,
                                                   queue: queue,
                                                   completionBlock: completionBlock)
                        }
                    }
                }
            } else {
                completionBlock(response, nil)
            }
        }
    }

    private func addPendingRequest(appRedirectURL: URL, request: CloudRequest, queue: DispatchQueue, completionBlock: @escaping CompletionHandler) {

        pendingRequests[appRedirectURL] = (request, queue, completionBlock)

        if resumeCloudRequestNotificationObserver == nil {
            self.addResumeCloudRequestNotificationObserver()
        }
    }

    private func removePendingRequest(appRedirectURL: URL) {

        pendingRequests.removeValue(forKey: appRedirectURL)

        if pendingRequests.isEmpty {
            removeResumeCloudRequestNotificationObserver()
        }
    }

    @discardableResult private func resumeCloudRequest(using url: URL) -> Bool {

        // Find pending request identified by `requestUUID` or return early.
        let matchingRequests = pendingRequests.filter { url.absoluteString.starts(with: $0.key.absoluteString) }

        guard let (request, queue, completionBlock) = matchingRequests.first?.value else {
            return false
        }

        // Perform pending request.
        // On success, store last token, remove pending request, and call completion block.
        // Else, if auth is still required, open Safari and request authentication.
        request.perform(cloudService: cloudService, queue: queue) { (_, response) in
            if let token = request.token {
                self.lastToken = token
            }

            if let authURL = response.authURL {
                if #available(iOS 10, *) {
                    UIApplication.shared.open(authURL)
                } else {
                    UIApplication.shared.openURL(authURL)
                }
            } else {
                self.removePendingRequest(appRedirectURL: url)
                completionBlock(response, nil)
            }
        }

        return true
    }

    private func addResumeCloudRequestNotificationObserver() {

        resumeCloudRequestNotificationObserver =
            NotificationCenter.default.addObserver(forName: Filestack.resumeCloudRequestNotification,
                                                   object: nil,
                                                   queue: .main) { (notification) in
                                                    if let url = notification.object as? URL {
                                                        self.resumeCloudRequest(using: url)
                                                    }
        }
    }

    private func removeResumeCloudRequestNotificationObserver() {

        if let resumeCloudRequestNotificationObserver = resumeCloudRequestNotificationObserver {
            NotificationCenter.default.removeObserver(resumeCloudRequestNotificationObserver)
        }

        resumeCloudRequestNotificationObserver = nil
    }
}

