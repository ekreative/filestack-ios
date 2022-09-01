//
//  PhotoLibraryPermission.swift
//  
//
//  Created by Sergii Polishchuk on 31.08.2022.
//

import UIKit
import FilestackSDK
import Foundation

class PhotoLibraryPermission: NSObject, Cancellable, Monitorizable, Startable {
    let presentedViewController: UIViewController

    private let trackingProgress = TrackingProgress()
    var progress: Progress { trackingProgress }
    
    init(presentedViewController: UIViewController) {
        self.presentedViewController = presentedViewController
    }

    /// Add `Startable` conformance.
    @discardableResult
    func start() -> Bool {
        let alert = UIAlertController(title: "Permission Needed",
                                      message: "The application does not have the permission to access your photos or files. Please change it in Settings",
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Settings", style: .default, handler: { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        presentedViewController.present(alert, animated: true)
        return true
    }

    /// Add `Cancellable` conformance.
    @discardableResult
    func cancel() -> Bool {
        return true
    }
}
