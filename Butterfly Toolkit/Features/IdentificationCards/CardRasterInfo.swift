// PNG 输入校验：记录实际尺寸，检查有效 Alpha，防止不透明矩形被当成蝴蝶。
import Foundation
import ImageIO
import CoreGraphics

nonisolated struct CardRasterInfo: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var issue: String?
    static func read(_ url:URL) throws -> Self {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CardError.message("PNG 无法解码：\(url.lastPathComponent)") }
        var result=Self(width:image.width,height:image.height)
        guard image.width > 0,image.height > 0,image.width <= 16000,image.height <= 16000 else { throw CardError.message("PNG 尺寸无效或过大") }
        if [.none,.noneSkipFirst,.noneSkipLast].contains(image.alphaInfo) { result.issue="PNG 不含透明通道，请检查素材"; return result }
        let count=image.width*image.height
        var pixels=[UInt8](repeating:0,count:count*4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context=CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CardError.message("无法读取 PNG 透明度") }
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        var visible=false,transparent=false
        for offset in stride(from:3,to:pixels.count,by:4) {
            visible = visible || pixels[offset] > 0; transparent = transparent || pixels[offset] < 255
            if visible && transparent { break }
        }
        if !visible { result.issue="PNG 没有可见主体" }
        else if !transparent { result.issue="PNG 完全不透明，请检查是否选错素材" }
        return result
    }
}
