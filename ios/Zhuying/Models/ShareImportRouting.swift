import Foundation

struct ShareImportRequest: Identifiable, Equatable {
    enum Kind: String { case file, source, theme }
    let kind: Kind
    let url: URL
    var id: String { StableContentID.make(kind.rawValue,url.absoluteString) }
    static func parse(_ incoming: URL) throws -> Self {
        guard incoming.absoluteString.utf8.count <= 8192 else { throw ContentFailure.invalidResponse }
        if incoming.isFileURL { return .init(kind:.file,url:incoming) }
        guard let parts = URLComponents(url:incoming,resolvingAgainstBaseURL:false),BrandCompatibility.accepts(parts.scheme?.lowercased(), current:"zhuying"),parts.host == "import",parts.path.isEmpty || parts.path == "/",parts.fragment == nil,
              let query = parts.queryItems,query.count == 2,Set(query.map(\.name)) == ["kind","url"],
              let kind = query.first(where:{$0.name == "kind"})?.value.flatMap(Kind.init(rawValue:)),
              let text = query.first(where:{$0.name == "url"})?.value else { throw BookImportError.message("不支持此分享链接。当前支持 zhuying://import 的 file、source、theme 类型；未知阅读器方言不会自动执行。") }
        let url = try BookImporter.remoteURL(text)
        let sensitive = Set(["token","access_token","api_key","apikey","key","password","authorization","cookie"])
        guard URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.contains(where:{sensitive.contains($0.name.lowercased())}) != true,url.fragment == nil else { throw BookImportError.message("分享链接包含凭据字段，请改用不带凭据的文件链接；密钥只在应用内配置。") }
        return .init(kind:kind,url:url)
    }
}
