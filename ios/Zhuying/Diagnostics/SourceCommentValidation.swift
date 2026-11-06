#if DEBUG
import Foundation

@MainActor enum SourceCommentValidation {
    static func run(credential: ShushanCredential?) async throws {
        var samples: [[String:Any]] = [],requests = 0
        let quick = ProcessInfo.processInfo.arguments.contains("--comments-quick")
        if let credential {
            let source = ShushanBookSource(credential:credential),client = ShushanCommentsClient(credential:credential)
            for query in (quick ? ["我在精神病院学斩神"] : ["我在精神病院学斩神","西游记"]) {
                do {
                    requests += 1; let result = try await source.search(query:query,page:1)
                    for candidate in result.books.filter({ (quick ? ["番茄小说"] : ["番茄小说","起点","QQ阅读","企鹅看书","晋江"]).contains($0.source?.provider ?? "") }).prefix(quick ? 1 : 2) {
                        do {
                            requests += 1; let book = try await source.details(for:candidate)
                            requests += 1; let catalog = try await source.chapters(for:book)
                            samples.append(["book":StableContentID.make(book.id),"provider":book.source?.provider ?? "unknown","catalogItems":catalog.count,"remoteIDPresent":!(book.source?.remoteBookID.isEmpty ?? true),"nativeIdentifierSamples":catalog.filter{$0.access != .volume}.prefix(2).map { chapter in
                                ["parameterKeys":chapter.requestParameters.keys.sorted(),"hasItemIDPattern":chapter.nativeChapterID.contains("item_id="),"hasChapterIDPattern":chapter.nativeChapterID.lowercased().contains("chapterid="),"requestIDPresent":chapter.requestParameters["item_id"] != nil || chapter.requestParameters["chapterid"] != nil || chapter.requestParameters["chapterId"] != nil] as [String:Any]
                            }])
                            var tested = 0
                            for chapter in catalog where chapter.access != .volume {
                                guard let context = ShushanCommentContext(book:book,chapter:chapter) else { continue }
                                tested += 1; if tested > (quick ? 1 : 2) { break }
                                var sample: [String:Any] = ["book":StableContentID.make(book.id),"chapter":StableContentID.make(chapter.id),"provider":context.source]
                                var stage = "counts"
                                var readableDocument: ChapterDocument?
                                do {
                                    requests += 1; let counts = try await client.counts(context)
                                    sample["countsStatus"] = "passed"; sample["paragraphs"] = counts.count; sample["comments"] = counts.reduce(0,{$0 + $1.count})
                                    do {
                                        requests += 1; let document = try await source.document(for:chapter,book:book)
                                        readableDocument = document
                                        sample["bodyReadable"] = true; sample["mappedParagraphs"] = ShushanCommentsClient.map(counts,context:context,document:document).count
                                    } catch { sample["bodyReadable"] = false }
                                    if let paragraph = counts.first(where:{$0.count > 0 && (Int($0.nativeID) ?? -1) >= 0}) {
                                        if context.source == "fq" {
                                            stage = "page"; requests += 1
                                            let bytes = try await client.pageData(context,paragraph:paragraph.nativeID)
                                            if let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] { sample["pageRootKeys"] = object.keys.sorted(); sample["pageResponseCode"] = object["code"] as? Int ?? -999; sample["pageDataKeys"] = (object["data"] as? [String:Any])?.keys.sorted() ?? [] }
                                            let page = try ShushanCommentsClient.decodePage(bytes,currentCursor:"0")
                                            sample["pageStatus"] = "passed"; sample["pageItems"] = page.comments.count; sample["hasNextPage"] = page.nextCursor != nil
                                            sample["quotePresent"] = !(page.sourceQuote?.isEmpty ?? true)
                                            if let document = readableDocument,let quote = page.sourceQuote,
                                               let stableID = ShushanCommentsClient.map(counts,context:context,document:document).first(where:{$0.value.nativeID == paragraph.nativeID})?.key,
                                               let original = document.paragraphs.first(where:{$0.id == stableID}) { sample["quoteMatchesMappedParagraph"] = ShushanCommentsClient.sameParagraph(quote,original.text) }
                                            if let next = page.nextCursor { requests += 1; let second = try await client.page(context,paragraph:paragraph.nativeID,cursor:next); sample["secondPageItems"] = second.comments.count; sample["distinctPageIDs"] = Set(page.comments.map(\.id)).isDisjoint(with:second.comments.map(\.id)) }
                                        }
                                        stage = "shell"
                                        requests += 1; let shell = try await client.shell(context,paragraph:paragraph.nativeID)
                                        sample["shellBytes"] = shell.data.count; sample["shellMIME"] = shell.mime ?? "unknown"
                                        if let html = String(data:shell.data,encoding:.utf8) {
                                            let regex = try NSRegularExpression(pattern:"[\\\"'](/(?:api/|paras/)[A-Za-z0-9_/-]+)")
                                            sample["endpointPaths"] = Array(Set(regex.matches(in:html,range:NSRange(html.startIndex...,in:html)).map{(html as NSString).substring(with:$0.range(at:1))})).sorted()
                                            // Raw responses stay in the App cache only, never in reports or Git.
                                            let cache = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("SourceCommentProbe")
                                            try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
                                            try shell.data.write(to:cache.appendingPathComponent(StableContentID.make(chapter.id) + ".html"),options:.atomic)
                                        }
                                    }
                                } catch { sample[stage + "Status"] = "unavailable" }
                                samples.append(sample)
                            }
                        } catch { samples.append(["book":StableContentID.make(candidate.id),"status":"details-or-catalog-unavailable"]) }
                    }
                } catch { samples.append(["query":query,"status":"search-unavailable"]) }
            }
        }
        let result: [String:Any] = ["schemaVersion":1,"sampleKind":"live-app-read-only-comments","credentialAvailable":credential != nil,"requests":requests,"samples":samples,"physicalDeviceAccepted":false]
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("DevelopmentValidation")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("source-comments.json"),options:.atomic)
    }
}
#endif
