import Foundation
import CoreGraphics

enum AndroidWire {
    static let configFlag: UInt64 = 1 << 62
    static let keyFlag: UInt64 = 1 << 61
    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    static func uint(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func position(_ p: CGPoint, _ size: CGSize) -> Data {
        let w = max(1,min(65535,Int(size.width))), h = max(1,min(65535,Int(size.height)))
        return integer(UInt32(max(0,min(w-1,Int(p.x * Double(w)))))) + integer(UInt32(max(0,min(h-1,Int(p.y * Double(h)))))) + integer(UInt16(w)) + integer(UInt16(h))
    }
    static func touch(action: UInt8, point: CGPoint, size: CGSize) -> Data {
        Data([2, action]) + integer(UInt64.max - 1) + position(point,size) + integer(UInt16(action == 1 ? 0 : 65535)) + integer(UInt32(0)) + integer(UInt32(0))
    }
    static func key(code: UInt32, action: UInt8) -> Data {
        Data([0, action]) + integer(code) + integer(UInt32(0)) + integer(UInt32(0))
    }
    static func scroll(point: CGPoint, size: CGSize, dx: Double, dy: Double) -> Data {
        func fixed(_ x: Double) -> Data { integer(Int16(max(-32768,min(32767,Int(x / 16 * 32768))))) }
        return Data([3]) + position(point,size) + fixed(dx) + fixed(dy) + integer(UInt32(0))
    }
    static func text(_ text: String, paste: Bool) -> Data {
        let bytes = Data(text.prefix(paste ? 60000 : 70).utf8)
        if paste { return Data([9]) + integer(UInt64(0)) + Data([1]) + integer(UInt32(bytes.count)) + bytes }
        return Data([1]) + integer(UInt32(bytes.count)) + bytes
    }
    static func nalUnits(_ data: Data) -> [Data] {
        let a = [UInt8](data)
        var starts: [(Int,Int)] = []; var i = 0
        while i + 2 < a.count {
            if a[i] == 0 && a[i+1] == 0 {
                if a[i+2] == 1 { starts.append((i,i+3)); i += 3; continue }
                if i+3 < a.count && a[i+2] == 0 && a[i+3] == 1 { starts.append((i,i+4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { n, start in
            let end = n+1 < starts.count ? starts[n+1].0 : a.count
            return end > start.1 ? Data(a[start.1..<end]) : nil
        }
    }
    static func fittedRect(size: CGSize, bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let k = min(bounds.width/size.width,bounds.height/size.height)
        let s = CGSize(width:size.width*k,height:size.height*k)
        return CGRect(x:bounds.midX-s.width/2,y:bounds.midY-s.height/2,width:s.width,height:s.height)
    }
}
