#if DEBUG
import Foundation
import UIKit
import ZIPFoundation

enum MediaDevelopmentFixtures {
    @MainActor static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let pdf = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:320,height:480)).pdfData { context in
            for index in 1...3 {
                context.beginPage()
                ("Original page \(index)" as NSString).draw(at:CGPoint(x:25,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
            }
        }
        try pdf.write(to:directory.appendingPathComponent("原创页面.pdf"))
        let archiveURL = directory.appendingPathComponent("原创漫画.cbz")
        try? FileManager.default.removeItem(at:archiveURL)
        let archive = try Archive(url:archiveURL,accessMode:.create)
        for index in [2,10] {
            let data = UIGraphicsImageRenderer(size:CGSize(width:320,height:480)).pngData { context in
                (index == 2 ? UIColor.systemBlue : .systemRed).setFill(); context.fill(CGRect(x:0,y:0,width:320,height:480))
                ("Original comic \(index)" as NSString).draw(at:CGPoint(x:20,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24),.foregroundColor:UIColor.white])
            }
            try archive.addEntry(with:"pages/\(index).png",type:.file,uncompressedSize:Int64(data.count),provider:{ offset,size in data.subdata(in:Int(offset)..<Int(offset) + size) })
        }
    }
}
#endif
