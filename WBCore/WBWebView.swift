//
//  WBWebView.swift
//  BleBrowser
//
//  Created by David Park on 22/12/2016.
//  Copyright 2016-2017 David Park. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import UIKit
import WebKit
import SafariServices

class WBWebView: WKWebView, WKNavigationDelegate {
    let webBluetoothHandlerName = "bluetooth"
    private var _wbManager: WBManager?
    private var geolocationHelper = GeolocationHelper()
    var autoselectDevice: Bool = false
    
    var wbManager: WBManager? {
        get {
            return self._wbManager
        }
        set(newWBManager) {
            if self._wbManager != nil {
                self.configuration.userContentController.removeScriptMessageHandler(forName: self.webBluetoothHandlerName)
            }
            self._wbManager = newWBManager
            if let newMan = newWBManager {
                self.configuration.userContentController.add(newMan, name: self.webBluetoothHandlerName)
            }
        }
    }
    
    public func loadURLFromPLIST() {
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist") {
           let nsDictionary = NSDictionary(contentsOfFile: path)
            
           // Added cache policy prevents content to be cached.
            self.load(URLRequest(url: URL(string: nsDictionary?.value(forKey: "url") as! String)!, cachePolicy: URLRequest.CachePolicy.reloadIgnoringCacheData))
        }
    }
    
    public func setAutoselectDevice(autoselectDevice: Bool) {
        self.autoselectDevice = autoselectDevice
        self._wbManager?.autoselectDevice = self.autoselectDevice
    }

    private var _navDelegates: [WKNavigationDelegate] = []

    // MARK: - Initializers
    required public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        
        // Set webview configuration
        geolocationHelper.setUserContentController(webViewConfiguration: configuration)
        geolocationHelper.setWebView(webView: self)
    }

    convenience public required init?(coder: NSCoder) {
        // load polyfill script
        let webCfg = WKWebViewConfiguration()
        let userController = WKUserContentController()
        webCfg.userContentController = userController
        webCfg.allowsInlineMediaPlayback = true
        self.init(
            frame: CGRect(),
            configuration: webCfg
        )
        self.navigationDelegate = self

        // TODO: this probably should be more controllable.
        // Before configuring the WKWebView, delete caches since
        // it seems a bit arbitrary when this happens otherwise.
        // This from http://stackoverflow.com/a/34376943/5920499
        let websiteDataTypes = NSSet(array: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) as! Set<String>
        let ds = WKWebsiteDataStore.default()
        ds.removeData(
            ofTypes: websiteDataTypes,
            modifiedSince: NSDate(timeIntervalSince1970: 0) as Date,
            completionHandler:{})

        // Load js
        for jsfilename in [
            "stringview",
            "WBUtils",
            "WBEventTarget",
            "WBBluetoothUUID",
            "WBDevice",
            "WBRemoteGATTServer",
            "WBBluetoothRemoteGATTService",
            "WBBluetoothRemoteGATTCharacteristic",
            "WBPolyfill"
        ] {
            guard let filePath = Bundle(for: WBWebView.self).path(forResource: jsfilename, ofType:"js") else {
                NSLog("Failed to find polyfill \(jsfilename)")
                return
            }
            var polyfillScriptContent: String
            do {
                polyfillScriptContent = try NSString(contentsOfFile: filePath, encoding: String.Encoding.utf8.rawValue) as String
            } catch _ {
                NSLog("Error loading polyfil")
                return
            }
            let userScript = WKUserScript(
                source: polyfillScriptContent, injectionTime: .atDocumentStart,
                forMainFrameOnly: false)
            userController.addUserScript(userScript)
        }
        
        // Let the app know, that we are a native wrapper.
        let nativeScriptSource = "window.native = 'iOS';";
        let script = WKUserScript(source: nativeScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userController.addUserScript(script)
        
        // WKWebView static config
        self.translatesAutoresizingMaskIntoConstraints = false
        self.allowsBackForwardNavigationGestures = true
    }

    // MARK: - API
    open func addNavigationDelegate(_ del: WKNavigationDelegate) {
        self._navDelegates.append(del)
    }
    open func removeNavigationDelegate(_ del: WKNavigationDelegate) {
        self._navDelegates.removeAll(where: {$0.isEqual(del)})
    }

    // MARK: - WKNavigationDelegate
    // Propagates the notification to all the registered delegates
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self._navDelegates.forEach{$0.webView?(webView, didStartProvisionalNavigation: navigation)}
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self._enableBluetoothInView()
        self._enableLocationTracking()
        self._navDelegates.forEach{$0.webView?(webView, didFinish: navigation)}
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self._navDelegates.forEach{$0.webView?(webView, didFail: navigation, withError: error)}
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self._navDelegates.forEach{$0.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)}
    }
    
    // Decides the policy for a new navigation action
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if (navigationAction.request.url?.scheme == "tel" || navigationAction.request.url?.scheme == "mailto") {
            UIApplication.shared.open(navigationAction.request.url!)
            decisionHandler(.cancel)
        } else if navigationAction.targetFrame == nil {
            if let url = navigationAction.request.url {
                let safariVC = SFSafariViewController(url: url)
                guard let viewController = WBWebView.getCurrentViewController() else {
                    return;
                }
                safariVC.modalPresentationStyle = .formSheet
                viewController.present(safariVC, animated: true)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    
    // Returns the main UIViewController
    static func getCurrentViewController() -> UIViewController? {
        if let rootController = UIApplication.shared.keyWindow?.rootViewController {
            var currentController: UIViewController! = rootController
            while( currentController.presentedViewController != nil ) {
                currentController = currentController.presentedViewController
            }
            return currentController
        }
        return nil
    }

    // MARK: - Internal
    open func _enableBluetoothInView() {
        self.evaluateJavaScript(
            "window.iOSNativeAPI.enableBluetooth()",
            completionHandler: { _, error in
                if let error_ = error {
                    NSLog("Error enabling bluetooth in view: \(error_)")
                }
            }
        )
    }
    
    open func _enableLocationTracking() {
        self.evaluateJavaScript(self.geolocationHelper.getJavaScripToEvaluate());
    }
}

class SpecialTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by: UIGestureRecognizer) -> Bool {
        return false
    }
}
