import Foundation

enum LibraryRecordSync {
    private struct BookEntry: Codable { let book: LibraryBookRecord; let group: String? }
    private struct Favorite: Codable { let position: Int }
    static func desired(_ archive: LibraryDatabaseArchive) throws -> [SyncEntry.Kind:[String:Data]] {
        var values = Dictionary(uniqueKeysWithValues:SyncEntry.Kind.allCases.map{($0,[String:Data]())})
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for book in archive.books { values[.book]![book.id] = try encoder.encode(BookEntry(book:book,group:archive.groups[book.id])) }
        for chapter in archive.chapters { values[.chapter]![chapter.id] = try encoder.encode(chapter) }
        for (position,id) in archive.favorites.enumerated() { values[.favorite]![id] = try encoder.encode(Favorite(position:position)) }
        let orders = Dictionary(uniqueKeysWithValues:archive.chapters.map{($0.id,$0.order)})
        for anchor in archive.progress {
            let payload = try encoder.encode(SyncedPosition(anchor:anchor,chapterOrder:orders[anchor.chapterID] ?? 0))
            values[.current]![anchor.bookID] = payload; values[.farthest]![anchor.bookID] = payload
        }
        for mark in archive.bookmarks { values[.bookmark]![mark.id] = try encoder.encode(mark) }
        if let bytes = archive.preferences[ProductionLibraryPersistence.viewKey],var view = try? JSONDecoder().decode(LibraryViewPreferences.self,from:bytes) {
            // Bitmap resources and credentials never travel as settings.
            view.settings.preferences.bubbleImageData = nil; view.settings.preferences.customBubbleImageData = nil
            values[.settings]!["reader"] = try encoder.encode(view.settings)
            if archive.books.isEmpty,view.settings == ReadingSettings(),view.userSettingsEdited != true { values.removeValue(forKey:.settings) }
            for (id,location) in view.mediaLocations ?? [:] { values[.mediaCurrent]![id] = try encoder.encode(location) }
            for mark in view.mediaBookmarks ?? [] { values[.mediaBookmark]![mark.id] = try encoder.encode(mark) }
            for (id,anchor) in view.farthestPositions ?? [:] { values[.farthest]![id] = try encoder.encode(SyncedPosition(anchor:anchor,chapterOrder:orders[anchor.chapterID] ?? 0)) }
        }
        return values
    }
    static func applying(_ state: RecordSyncState,to original: LibraryDatabaseArchive) throws -> LibraryDatabaseArchive {
        let decoder = JSONDecoder()
        func entries(_ kind: SyncEntry.Kind) -> [SyncEntry] { state.entries.values.filter{$0.kind == kind && !$0.deleted}.sorted{$0.id < $1.id} }
        func decode<T: Decodable>(_ entry: SyncEntry,as: T.Type) throws -> T { try entry.validate(); guard let data = entry.payload else { throw CloudAccessError.invalidData }; return try decoder.decode(T.self,from:data) }
        var result = original
        let books = try entries(.book).map { entry -> BookEntry in
            let item = try decode(entry,as:BookEntry.self)
            guard item.book.id == entry.id,!item.book.title.isEmpty,item.book.title.utf8.count <= 8192,item.book.display != nil else { throw CloudAccessError.invalidData }
            try item.book.media?.validate(); if let cover = item.book.cover { guard cover.kind == .image,cover.isValid else { throw CloudAccessError.invalidData } }
            return item
        }
        result.books = books.map(\.book); let ids = Set(result.books.map(\.id))
        result.groups = Dictionary(uniqueKeysWithValues:books.compactMap{ item in item.group.map{(item.book.id,$0)} })
        result.chapters = try entries(.chapter).compactMap { entry in
            let item = try decode(entry,as:ChapterRecord.self)
            guard item.id == entry.id,item.order >= 0,item.title.utf8.count <= 8192 else { throw CloudAccessError.invalidData }
            return ids.contains(item.bookID) ? item : nil
        }
        let chapterIDs = Set(result.chapters.map(\.id))
        for id in ids { let catalog = result.chapters.filter{$0.bookID == id}; guard !catalog.isEmpty,Set(catalog.map(\.order)).count == catalog.count else { throw CloudAccessError.invalidData } }
        result.favorites = try entries(.favorite).compactMap { entry -> (String,Int)? in
            let value = try decode(entry,as:Favorite.self); guard value.position >= 0,value.position <= 50000 else { throw CloudAccessError.invalidData }; return ids.contains(entry.id) ? (entry.id,value.position) : nil
        }.sorted{$0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1}.map(\.0)
        result.progress = try entries(.current).compactMap { entry in
            let value = try decode(entry,as:SyncedPosition.self)
            guard entry.id == value.anchor.bookID,value.anchor.paragraphIndex >= 0,value.anchor.utf16Offset >= 0 else { throw CloudAccessError.invalidData }
            // Keep a removed chapter's anchor for explicit recovery, as the
            // regular catalog refresh path does; never substitute another ID.
            return ids.contains(value.anchor.bookID) ? value.anchor : nil
        }
        result.bookmarks = try entries(.bookmark).compactMap { entry in
            let mark = try decode(entry,as:LibraryBookmarkRecord.self); guard mark.id == entry.id else { throw CloudAccessError.invalidData }; return ids.contains(mark.anchor.bookID) ? mark : nil
        }
        var view = try original.preferences[ProductionLibraryPersistence.viewKey].map{try decoder.decode(LibraryViewPreferences.self,from:$0)} ?? LibraryViewPreferences(LibrarySnapshot(favorites:[],progress:[:]))
        if let entry = entries(.settings).first(where:{$0.id == "reader"}) {
            var settings = try decode(entry,as:ReadingSettings.self); settings.preferences.normalize()
            settings.fontSize = ReaderPreferenceBounds.clamp(settings.fontSize,14...30,fallback:20); settings.lineSpacing = ReaderPreferenceBounds.clamp(settings.lineSpacing,0...24,fallback:12)
            // Locally installed bitmap resources remain available on devices
            // that already have them; new devices use the existing fallback.
            settings.preferences.bubbleImageData = view.settings.preferences.bubbleImageData
            settings.preferences.customBubbleImageData = view.settings.preferences.customBubbleImageData
            view.settings = settings
        }
        view.mediaLocations = Dictionary(uniqueKeysWithValues:try entries(.mediaCurrent).compactMap { entry -> (String,MediaReadingLocation)? in
            let location = try decode(entry,as:MediaReadingLocation.self); guard let media = result.books.first(where:{$0.id == entry.id})?.media else { return nil }; return (entry.id,location.validated(pages:media.pageCount))
        })
        view.mediaBookmarks = try entries(.mediaBookmark).compactMap { entry in
            let mark = try decode(entry,as:MediaBookmark.self); guard mark.id == entry.id else { throw CloudAccessError.invalidData }; return ids.contains(mark.bookID) ? mark : nil
        }
        view.farthestPositions = Dictionary(uniqueKeysWithValues:try entries(.farthest).compactMap { entry -> (String,ReadingAnchor)? in
            let value = try decode(entry,as:SyncedPosition.self); guard value.anchor.bookID == entry.id else { throw CloudAccessError.invalidData }; return ids.contains(entry.id) ? (entry.id,value.anchor) : nil
        })
        result.preferences[ProductionLibraryPersistence.viewKey] = try JSONEncoder().encode(view)
        guard Set(result.books.map(\.id)).count == result.books.count,chapterIDs.count == result.chapters.count else { throw CloudAccessError.invalidData }
        return result
    }
}
