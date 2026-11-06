import Foundation
import ImageIO
import UIKit

struct CoverSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let author: String
    let imageID: Int
    var imageURL: URL { URL(string:"https://covers.openlibrary.org/b/id/\(imageID)-M.jpg?default=false")! }
}
struct CoverSearchClient: Sendable {
    var transport: any HTTPTransport = BoundedAudioHTTPTransport(maximumBytes:2 * 1024 * 1024)
    func search(_ title: String) async throws -> [CoverSearchResult] {
        let value = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count <= 200 else { throw ContentFailure.invalidResponse }
        var url = URLComponents(string:"https://openlibrary.org/search.json")!
        url.queryItems = [.init(name:"title",value:value),.init(name:"limit",value:"20"),.init(name:"fields",value:"key,title,author_name,cover_i")]
        let data = try await fetch(url.url!)
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],let rows = root["docs"] as? [[String:Any]],rows.count <= 100 else { throw ContentFailure.invalidResponse }
        var seen = Set<Int>()
        return rows.compactMap { row in
            guard let image = row["cover_i"] as? Int,image > 0,seen.insert(image).inserted,let key = row["key"] as? String,key.hasPrefix("/works/"),key.count <= 200,let title = row["title"] as? String,title.count <= 1000 else { return nil }
            return .init(id:key,title:title,author:((row["author_name"] as? [String]) ?? []).prefix(3).joined(separator:"、"),imageID:image)
        }
    }
    func download(_ result: CoverSearchResult) async throws -> Data { try Self.normalized(await fetch(result.imageURL)) }
    private func fetch(_ url: URL) async throws -> Data {
        guard ["openlibrary.org","covers.openlibrary.org"].contains(url.host ?? ""),url.scheme == "https" else { throw ContentFailure.invalidResponse }
        var request = URLRequest(url:url); request.timeoutInterval = 20; request.setValue("YueshanReader/0.8 (user-selected cover search)",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await transport.send(request); try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode),response.url?.host == url.host,data.count <= 2 * 1024 * 1024 else { throw ContentFailure.unavailable }; return data
    }
    static func normalized(_ data: Data) throws -> Data {
        try MediaBookImporter.validateImage(data)
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:800,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),let png = UIImage(cgImage:image).pngData(),png.count <= 4 * 1024 * 1024 else { throw ContentFailure.invalidResponse }; return png
    }
}
