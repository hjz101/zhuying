import Foundation
@testable import Yueshan

enum AudioTestFixtures {
    static func wave(samples: Int = 800) -> Data {
        var result = Data()
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of:&value) { result.append(contentsOf:$0) } }
        func number(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of:&value) { result.append(contentsOf:$0) } }
        result.append(Data("RIFF".utf8)); number(UInt32(36 + samples * 2)); result.append(Data("WAVEfmt ".utf8)); number(16)
        word(1); word(1); number(16000); number(32000); word(2); word(16); result.append(Data("data".utf8)); number(UInt32(samples * 2))
        for index in 0..<samples { word(UInt16(bitPattern:Int16(sin(Double(index) * 0.1) * 1200))) }; return result
    }
    static func profile() -> AudioServiceProfile { .init(name:"原创测试服务",baseURL:"https://speech.test/v1",ttsModel:"test-speech",analysisModel:"test-analysis",voice:"narrator") }
    static func book(chapters: Int = 2) -> Book {
        .init(id:"local-narration",title:"原创朗读作品",author:"阅山测试",genre:"本地",category:"其他",status:"测试",words:"测试",color:"sage",subtitle:"TXT",intro:"原创",tags:[],chapters:(0..<chapters).map { "第\($0 + 1)章 原创" },content:(0..<chapters).map { ["第\($0 + 1)章的读者👩🏽‍🚀看见星光。"] })
    }
}
