// Conta quantos pixels (quase opacos) de um PNG têm uma cor, com tolerância.
// Uso: pixels arquivo.png r g b tolerância
import AppKit

let a = CommandLine.arguments
guard a.count == 6, let dados = FileManager.default.contents(atPath: a[1]),
      let rep = NSBitmapImageRep(data: dados),
      let r = Int(a[2]), let g = Int(a[3]), let b = Int(a[4]), let tol = Int(a[5]) else {
    print("-1")
    exit(1)
}
var n = 0
for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.78 else { continue }
        if abs(Int(c.redComponent * 255) - r) <= tol && abs(Int(c.greenComponent * 255) - g) <= tol
            && abs(Int(c.blueComponent * 255) - b) <= tol { n += 1 }
    }
}
print(n)
