import UIKit
import Flutter
import MobileCoreServices
import Photos
import WidgetKit
import WebKit
import Network

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    
    // 🎵 Morning Dew - Single - AryaMusic Records & ciaffa
    // https://music.apple.com/cn/album/morning-dew/1686069386?i=1686069387
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let shareChannel = FlutterMethodChannel(
            name: "pixez/ios_share",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        shareChannel.setMethodCallHandler { [weak self] call, result in
            if call.method == "openCealerLogin",
               let args = call.arguments as? [String: Any],
               let port = args["port"] as? Int,
               let urlStr = args["url"] as? String {
                if #available(iOS 17.0, *) {
                    DispatchQueue.main.async {
                        guard let presenter = self?.visibleViewController() else {
                            result(nil)
                            return
                        }
                        let vc = CealerLoginVC(port: port, urlString: urlStr) { callbackUrl in
                            result(callbackUrl)
                        }
                        vc.modalPresentationStyle = .fullScreen
                        presenter.present(vc, animated: true)
                    }
                } else {
                    result(FlutterError(code: "UNSUPPORTED", message: "Requires iOS 17+", details: nil))
                }
                return
            }

            if call.method == "openEoReader",
               let args = call.arguments as? [String: Any],
               let port = args["port"] as? Int,
               let targetURL = URL(string: "eoreader://pull?port=\(port)") {
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
                DispatchQueue.main.async {
                    UIApplication.shared.open(targetURL, options: [:]) { ok in
                        result(ok)
                    }
                }
                return
            }

            guard call.method == "shareFile",
                  let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID", message: "Missing path", details: nil))
                return
            }
            DispatchQueue.main.async {
                guard let presenter = self?.visibleViewController() else {
                    result(FlutterError(code: "NO_VC", message: "No view controller", details: nil))
                    return
                }
                let fileURL = URL(fileURLWithPath: path)
                let vc = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let popover = vc.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 0,
                        height: 0
                    )
                    popover.permittedArrowDirections = []
                }
                presenter.present(vc, animated: true)
                result(true)
            }
        }

        let batteryChannel = FlutterMethodChannel(name: "samples.flutter.dev/battery",
                                                binaryMessenger: engineBridge.applicationRegistrar.messenger())
        batteryChannel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            guard call.method == "getBatteryLevel" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let args = call.arguments as? [String:Any]
            let path : String = args?["path"] as! String
            let delay:Int = args?["delay"] as! Int
            self.receiveBatteryLevel(result: result,path: path ,delay: delay)
        })
        DocumentPlugin.bind(engineBridge)
        DeepLinkPlugin.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "DeepLinkPlugin")!)
        bindAppWidgetChannel(engineBridge)
    }

    private func bindAppWidgetChannel(_ engineBridge: FlutterImplicitEngineBridge) {
        let appWidgetChannel = FlutterMethodChannel(name: "com.perol.dev/app_widget",
                                                    binaryMessenger: engineBridge.applicationRegistrar.messenger())
        appWidgetChannel.setMethodCallHandler { call, result in
            guard call.method == "setRecommendType" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let type = args["type"] as? String
            else {
                result(FlutterError(code: "bad_args", message: "type is required", details: nil))
                return
            }
            UserDefaults(suiteName: "group.pixez")?.set(type, forKey: "widget_illust_type")
            if #available(iOS 14.0, *) {
                WidgetCenter.shared.reloadAllTimelines()
            }
            result(nil)
        }
    }
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    @objc private func saveImage(image: UIImage, didFinishSavingWithError error: NSError?, contextInfo: AnyObject) {
        var showMessage = ""
        if error != nil {
            showMessage = "保存失败"
        } else {
            showMessage = "保存成功"
        }
        print("encode result: \(showMessage)")
    }
    
    func getAllFilePath(_ dirPath: String) -> [String]? {
        var filePaths = [String]()
        do {
            let array = try FileManager.default.contentsOfDirectory(atPath: dirPath)
            for fileName in array {
                var isDir: ObjCBool = true
                let fullPath = "\(dirPath)/\(fileName)"
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if !isDir.boolValue {
                        filePaths.append(fullPath)
                    }
                }
            }
        } catch let error as NSError {
            print("get file path error: \(error)")
        }
        return filePaths
    }
    
    func saveImageInAlbum(albumName: String = "", gifPath: String) {
        var assetAlbum: PHAssetCollection?
        if albumName.isEmpty {
            let list = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
            assetAlbum = list[0]
        } else {
            let list = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            list.enumerateObjects({ (album, index, stop) in
                let assetCollection = album
                if albumName == assetCollection.localizedTitle {
                    assetAlbum = assetCollection
                    stop.initialize(to: true)
                }
            })
            if assetAlbum == nil {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                }, completionHandler: { (isSuccess, error) in
                    self.saveImageInAlbum(albumName: albumName, gifPath: gifPath)
                })
                return
            }
        }
        PHPhotoLibrary.shared().performChanges({
            let url = URL(fileURLWithPath: gifPath)
            let result = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            if !albumName.isEmpty {
                let assetPlaceholder = result?.placeholderForCreatedAsset
                let albumChangeRequset = PHAssetCollectionChangeRequest(for: assetAlbum!)
                albumChangeRequset!.addAssets([assetPlaceholder!] as NSArray)
            }
        }) { (isSuccess: Bool, error: Error?) in
            if isSuccess {
                DispatchQueue.main.async {
                    let alertController = UIAlertController(title: "encode success", message: nil, preferredStyle: .alert)
                    self.visibleViewController()?.present(alertController, animated: true, completion: nil)
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
                        alertController.dismiss(animated: true, completion: nil)
                    }
                }
            } else {
                print(error!.localizedDescription)
            }
        }
    }
    
    private func receiveBatteryLevel(result: FlutterResult, path: String, delay: Int) {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let gifPath = docs[0] as String + "/" + String(Int(Date.init().timeIntervalSince1970)) + ".gif"
        var paths = getAllFilePath(path)
        paths = paths?.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let imageArray: NSMutableArray = NSMutableArray()
        for i in paths! {
            let image = UIImage.init(named: i)
            if image != nil {
                imageArray.add(image!)
            }
        }
        let ok = saveGifToDocument(imageArray: imageArray, gifPath, delay: delay)
        if ok {
            saveImageInAlbum(albumName: "pxez", gifPath: gifPath)
        }
        result(Int(1))
    }
    
    func saveGifToDocument(imageArray images: NSArray, _ gifPath: String, delay: Int) -> Bool {
        guard images.count > 0 && gifPath.utf8CString.count > 0 else { return false }
        let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, gifPath as CFString, .cfurlposixPathStyle, false)
        let destion = CGImageDestinationCreateWithURL(url!, kUTTypeGIF, images.count, nil)
        let adelay = Float(delay) / Float(1000)
        let delayTime = [kCGImagePropertyGIFUnclampedDelayTime as String: adelay]
        let destDic = [kCGImagePropertyGIFDictionary as String: delayTime]
        let gifPropertiesDic: NSMutableDictionary = NSMutableDictionary()
        gifPropertiesDic.setValue(0, forKey: kCGImagePropertyGIFLoopCount as String)
        let gifDictionaryDestDic = [kCGImagePropertyGIFDictionary as String: gifPropertiesDic]
        CGImageDestinationSetProperties(destion!, gifDictionaryDestDic as CFDictionary?)
        for image in images {
            CGImageDestinationAddImage(destion!, (image as! UIImage).cgImage!, destDic as CFDictionary)
        }
        return CGImageDestinationFinalize(destion!)
    }
    
    private func visibleViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return visibleViewController(from: window?.rootViewController)
    }
    
    private func visibleViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigationController = viewController as? UINavigationController {
            return visibleViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController {
            return visibleViewController(from: tabBarController.selectedViewController)
        }
        if let presentedViewController = viewController?.presentedViewController {
            return visibleViewController(from: presentedViewController)
        }
        return viewController
    }
}

@available(iOS 17.0, *)
class CealerLoginVC: UIViewController, WKNavigationDelegate {
    private let port: Int
    private let urlString: String
    private let completion: (String?) -> Void
    private var completed = false

    init(port: Int, urlString: String, completion: @escaping (String?) -> Void) {
        self.port = port
        self.urlString = urlString
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        if let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) {
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            dataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        }
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("关闭", for: .normal)
        closeBtn.frame = CGRect(x: 16, y: 44, width: 60, height: 36)
        closeBtn.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        view.addSubview(closeBtn)

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func handleClose() {
        finish(with: nil)
    }

    private func finish(with value: String?) {
        guard !completed else { return }
        completed = true
        dismiss(animated: true) { self.completion(value) }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "pixiv" {
            decisionHandler(.cancel)
            finish(with: url.absoluteString)
            return
        }
        decisionHandler(.allow)
    }
}
