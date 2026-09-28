// Conta quantos pixels (quase opacos) de um PNG têm uma cor, com tolerância.
// Uso: pixels arquivo.png r g b tolerância [lista]
// Compara o valor CRU gravado no arquivo, sem converter cor: o NSBitmapImageRep
// ignora o perfil do PNG e lê como "Generic RGB", e aí o magenta (255,0,255)
// virava (255,64,255) na conversão pra sRGB. Com "lista": em vez do total,
// mostra cada cor que casou, pra entender uma falha no CI.
import AppKit

let a = CommandLine.arguments
guard a.count == 6 || a.count == 7, let dados = FileManager.default.contents(atPath: a[1]),
      let rep = NSBitmapImageRep(data: dados),
      let r = Int(a[2]), let g = Int(a[3]), let b = Int(a[4]), let tol = Int(a[5]) else {
    print("-1")
    exit(1)
}
let lista = a.count == 7
var n = 0
var vistas: [String: Int] = [:]
for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        let (cr, cg, cb) = (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        guard abs(cr - r) <= tol && abs(cg - g) <= tol && abs(cb - b) <= tol else { continue }
        if c.alphaComponent > 0.78 { n += 1 }
        if lista { vistas["\(cr),\(cg),\(cb) alfa=\(String(format: "%.2f", c.alphaComponent))", default: 0] += 1 }
    }
}
if lista {
    print("\(n) contados")
    for (k, v) in vistas.sorted(by: { $0.value > $1.value }).prefix(10) { print("  \(v)x \(k)") }
} else {
    print(n)
}
