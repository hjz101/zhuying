#if DEBUG
import Foundation
import Darwin
import WebKit

@MainActor enum NetworkBrowserValidation {
    static func run() async throws {
        var samples: [[String:Any]] = []
        for host in ["example.com","self-signed.badssl.com"] {
            do {
                let ip = try await Task.detached { try address(host) }.value
                let origin = URL(string:"https://" + host)!,transport = try SourceNetworkTransport(origin:origin,profile:.init(mode:.fixedIP,server:ip),maximumBytes:512 * 1024)
                do {
                    let (data,response) = try await transport.send(URLRequest(url:origin))
                    samples.append(["case":host == "example.com" ? "fixed-ip-https" : "invalid-certificate","status":response.statusCode,"bytes":data.count,"tunnels":await transport.tunnelCount(),"accepted":host == "example.com" && response.statusCode == 200])
                } catch { samples.append(["case":host == "example.com" ? "fixed-ip-https" : "invalid-certificate","accepted":host != "example.com" && [-1200,-1202,-1203].contains((error as NSError).code),"errorDomain":(error as NSError).domain,"errorCode":(error as NSError).code,"tunnels":await transport.tunnelCount()]) }
            } catch { samples.append(["case":host,"accepted":false,"phase":"resolve"]) }
        }
        let domain = "network-browser-probe-" + UUID().uuidString,defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let browser = NativeSourceBrowser(),sessions = SourceBrowserSessions(defaults:defaults)
        browser.configure(sourceID:"probe",origin:nil,sessions:sessions,javascript:true)
        defer { browser.discardImport(); browser.close() }
        browser.open("https://www.gutenberg.org/cache/epub/1342/pg1342.txt")
        do {
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline,browser.webView?.url == nil || browser.webView?.isLoading == true { try await Task.sleep(for:.milliseconds(200)) }
            let text = try await browser.webView!.evaluateJavaScript("document.body.innerText.length") as? Int ?? 0
            guard text > 1000 else { throw ContentFailure.invalidResponse }
            browser.downloadCurrent()
            let downloadDeadline = Date().addingTimeInterval(48)
            while browser.imported == nil,Date() < downloadDeadline { try await Task.sleep(for:.milliseconds(250)); if !browser.downloading,browser.message != nil { break } }
            guard let file = browser.imported else { throw ContentFailure.invalidResponse }
            let data = try Data(contentsOf:file.url),prepared = try BookImporter.prepare(data:data,name:file.url.lastPathComponent)
            samples.append(["case":"native-browser-download-preview","accepted":true,"pageCharacters":text,"bytes":data.count,"chapters":prepared.book.chapters.count,"libraryMutated":false])
        } catch { samples.append(["case":"native-browser-download-preview","accepted":false,"errorDomain":(error as NSError).domain,"errorCode":(error as NSError).code]) }
        let result: [String:Any] = ["schemaVersion":1,"samples":samples,"credentialsUsed":false,"physicalDeviceAccepted":false]
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("DevelopmentValidation")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("network-browser.json"),options:.atomic)
    }
    private nonisolated static func address(_ host: String) throws -> String {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var values: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,nil,&hints,&values) == 0,let values else { throw SourceNetworkError.unavailable }; defer { freeaddrinfo(values) }
        var output = [CChar](repeating:0,count:Int(NI_MAXHOST))
        guard getnameinfo(values.pointee.ai_addr,values.pointee.ai_addrlen,&output,socklen_t(output.count),nil,0,NI_NUMERICHOST) == 0 else { throw SourceNetworkError.unavailable }
        return String(cString:output)
    }
}
#endif
