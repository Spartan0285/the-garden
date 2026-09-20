// Build a .icns that Tiger and Leopard can actually read.
//
//   swift scripts/make-icns.swift artwork.png Resources/Garden.icns
//
// Modern `iconutil` writes only the types Mac OS X 10.7 and later use
// (ic04, ic05, ic07 ...), which 10.4 and 10.5 ignore: an app built with one
// shows the blank application icon.  This writes the 32-bit RGB types those
// systems read - is32/il32/ih32/it32 with their 8-bit masks, run-length
// encoded the way icns wants - and adds 256 and 512 for later systems.
//
// Those two are JPEG 2000, not PNG.  Leopard prefers ic08 over the 128-pixel
// it32, but PNG in an icns only arrived in 10.6: given a PNG there, Leopard
// picks it, fails to decode it, and draws nothing at all.  Measured on a
// PowerBook G4 running 10.5.9 - the icon was blank until these became JPEG
// 2000, which is what that system was written for.  10.6 and later read both.
//
// Runs on the modern Mac the sources are edited on; the result is committed.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: make-icns.swift <artwork.png> <out.icns>") }

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(arguments[1])")
}

/// The artwork drawn at `size`, as premultiplied-free RGBA, one byte a channel.
func rgba(_ size: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("cannot make a \(size)x\(size) context") }
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    // Undo the premultiplication: icns keeps colour and mask apart, and a
    // premultiplied edge would darken against the mask.
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let alpha = Int(pixels[i + 3])
        guard alpha > 0 && alpha < 255 else { continue }
        for c in 0..<3 {
            pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha))
        }
    }
    return pixels
}

/// icns run-length encoding: 0x80|n means the next byte repeated n+3 times
/// (3...130); n below 0x80 means n+1 literal bytes follow (1...128).
func packbits(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    var literal: [UInt8] = []

    func flushLiteral() {
        var start = 0
        while start < literal.count {
            let n = min(128, literal.count - start)
            out.append(UInt8(n - 1))
            out.append(contentsOf: literal[start..<(start + n)])
            start += n
        }
        literal.removeAll(keepingCapacity: true)
    }

    while i < bytes.count {
        var run = 1
        while i + run < bytes.count && bytes[i + run] == bytes[i] && run < 130 { run += 1 }
        if run >= 3 {
            flushLiteral()
            out.append(UInt8(0x80 + (run - 3)))
            out.append(bytes[i])
            i += run
        } else {
            literal.append(bytes[i])
            i += 1
        }
    }
    flushLiteral()
    return out
}

func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
    var out = Array(type.utf8)
    let length = UInt32(data.count + 8)
    out.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                            UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
    out.append(contentsOf: data)
    return out
}

/// is32/il32/ih32/it32: the three colour channels one after the other, each
/// run-length encoded.  The 128x128 one begins with four zero bytes.
func colourChunk(_ type: String, _ size: Int) -> [UInt8] {
    let pixels = rgba(size)
    var body: [UInt8] = size == 128 ? [0, 0, 0, 0] : []
    for channel in 0..<3 {
        var plane = [UInt8](repeating: 0, count: size * size)
        for p in 0..<(size * size) { plane[p] = pixels[p * 4 + channel] }
        body.append(contentsOf: packbits(plane))
    }
    return chunk(type, body)
}

func maskChunk(_ type: String, _ size: Int) -> [UInt8] {
    let pixels = rgba(size)
    var mask = [UInt8](repeating: 0, count: size * size)
    for p in 0..<(size * size) { mask[p] = pixels[p * 4 + 3] }
    return chunk(type, mask)
}

func imageChunk(_ type: String, _ size: Int) -> [UInt8] {
    // Drawn again rather than reusing rgba(): the encoder wants the
    // premultiplied pixels CoreGraphics produces, not the separated ones
    // icns wants for its own types.
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot make a \(size)x\(size) context") }
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else { fail("cannot make a \(size)x\(size) image") }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg-2000" as CFString, 1, nil)
    else { fail("cannot encode JPEG 2000") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return chunk(type, [UInt8](out as Data))
}

var body: [UInt8] = []
// What 10.4 and 10.5 read.
body += colourChunk("is32", 16);  body += maskChunk("s8mk", 16)
body += colourChunk("il32", 32);  body += maskChunk("l8mk", 32)
body += colourChunk("ih32", 48);  body += maskChunk("h8mk", 48)
body += colourChunk("it32", 128); body += maskChunk("t8mk", 128)
// What 10.5 and later prefer, as JPEG 2000 (see the note at the top).
body += imageChunk("ic08", 256)
body += imageChunk("ic09", 512)

var file = Array("icns".utf8)
let total = UInt32(body.count + 8)
file += [UInt8(total >> 24 & 0xFF), UInt8(total >> 16 & 0xFF),
         UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF)]
file += body

try Data(file).write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2]), \(file.count) bytes")
