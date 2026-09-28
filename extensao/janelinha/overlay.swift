// Claude Monitor no Mac: a mesma janelinha do Windows (overlay.ps1) em Swift/AppKit.
// Sempre por cima, com as sessões do Claude Code (arquivos do hook em
// ~/.claude-monitor/sessions) e o usage (mesmo endpoint do /usage, com o login
// do Claude Code guardado no Keychain; só lê, nunca renova o token). O Clawd,
// com a picareta, anda pela borda enquanto algo roda, pula parado em cima quando
// há pergunta/permissão e fica parado em cima quando nada roda.
// Sons e picareta vêm do Minecraft, se tiver (extrair_minecraft.sh); senão, sons
// do Mac e uma picareta desenhada aqui.
// Arrastar: botão esquerdo. Duplo clique: traz o VS Code. Botão direito: "Fechar".
// A extensão compila isto (xcrun swiftc -swift-version 5 -O -o ClaudeMonitor
// overlay.swift) e abre; a trava em overlay.lock deixa uma só. Quando o binário
// muda (versão nova), ela se reabre sozinha.
// Teste: ClaudeMonitor --foto arquivo.png desenha, salva o PNG (e, ao lado, um
// .txt com o que viu) e sai. Sem internet: o usage vem de --uso arquivo.json, se
// passar. --pasta troca a ~/.claude-monitor por outra.
import Cocoa

let ambiente = ProcessInfo.processInfo.environment
let home = ambiente["HOME"] ?? NSHomeDirectory()
let argumentos = CommandLine.arguments
func argumento(_ nome: String) -> String? {
    if let i = argumentos.firstIndex(of: nome), i + 1 < argumentos.count { return argumentos[i + 1] }
    return nil
}
let arquivoFoto = argumento("--foto")
let pasta = argumento("--pasta") ?? home + "/.claude-monitor"
let dirSessoes = pasta + "/sessions"

try? FileManager.default.createDirectory(atPath: pasta, withIntermediateDirectories: true)
if arquivoFoto == nil {
    // O_CLOEXEC: no execv da versão nova a trava solta junto
    let trava = open(pasta + "/overlay.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    if trava < 0 || flock(trava, LOCK_EX | LOCK_NB) != 0 { exit(0) }
}

func dataDoArquivo(_ caminho: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: caminho))?[.modificationDate] as? Date
}
let binario = Bundle.main.executablePath ?? argumentos[0]
let versao = dataDoArquivo(binario)

func hex(_ codigo: String) -> NSColor {
    var s = codigo.hasPrefix("#") ? String(codigo.dropFirst()) : codigo
    var alfa: CGFloat = 1
    if s.count == 8 {
        alfa = CGFloat(Int(s.prefix(2), radix: 16) ?? 255) / 255
        s = String(s.dropFirst(2))
    }
    let v = Int(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alfa)
}

// situação da sessão (ver situacao) -> cor da bolinha e texto do tooltip
let estados: [String: (cor: String, rotulo: String)] = [
    "working": ("#22C55E", "trabalhando"),
    "finished": ("#EF4444", "terminou"),
    "question": ("#60A5FA", "pergunta pra você"),
    "permission": ("#FACC15", "pedindo permissão"),
]

// --- sons: "hmm" do aldeão = pergunta/permissão, XP = terminou (com mais de um, sorteia)
func sonsDoMinecraft(_ nomes: [String]) -> [String] {
    nomes.map { pasta + "/sons/" + $0 + ".wav" }.filter { FileManager.default.fileExists(atPath: $0) }
}
let aldeao = sonsDoMinecraft(["aldeao_hmm1", "aldeao_hmm2"])
let xp = sonsDoMinecraft(["xp1", "xp2", "xp3"])
var tocando: NSSound?  // segura o som até acabar de tocar
func tocar(_ situacao: String) {
    let pedido = situacao != "finished"
    var som: NSSound?
    if let arquivo = (pedido ? aldeao : xp).randomElement() { som = NSSound(contentsOfFile: arquivo, byReference: true) }
    if som == nil { som = NSSound(named: NSSound.Name(pedido ? "Ping" : "Glass")) }
    tocando?.stop()
    tocando = som
    som?.play()
}

// --- sessões (mesma regra da extensão e do overlay.ps1) ---
struct Sessao {
    var id: String
    var nome: String
    var estado: String
    var since: Double
    var updated: Double
    var pid: Int32?
    var transcript: String
    var situacao = ""
}

func numero(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func lerSessoes(agora: Double) -> [Sessao] {
    let fm = FileManager.default
    guard let arquivos = try? fm.contentsOfDirectory(atPath: dirSessoes) else { return [] }
    var vistas: [String: Sessao] = [:]
    for arquivo in arquivos where arquivo.hasSuffix(".json") {
        guard let dados = fm.contents(atPath: dirSessoes + "/" + arquivo),
              let d = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else { continue }
        let pid = numero(d["pid"]).flatMap { Int32(exactly: $0) }
        let updated = numero(d["updated"]) ?? 0
        // pid vivo; sem pid, atualizada nas últimas 6h
        if let p = pid, p > 0 {
            if kill(p, 0) != 0 && errno != EPERM { continue }
        } else if agora - updated > 6 * 3600 { continue }
        let id = String(arquivo.dropLast(5))
        let transcript = d["transcript"] as? String ?? ""
        let s = Sessao(id: id, nome: titulo(transcript) ?? (d["name"] as? String ?? "sessão"),
                       estado: d["state"] as? String ?? "waiting", since: numero(d["since"]) ?? updated,
                       updated: updated, pid: pid, transcript: transcript)
        let chave = pid.map { "pid:\($0)" } ?? "id:\(id)"
        if let v = vistas[chave], v.updated >= s.updated { continue }
        vistas[chave] = s
    }
    return vistas.values.map { s -> Sessao in
        var s = s
        s.situacao = situacao(s)
        return s
    }.sorted { $0.updated > $1.updated }
}

// Título da aba: o do /rename ("custom-title") ganha do automático ("ai-title").
// O hook só grava o nome quando você manda mensagem, e na 1ª ainda não existe
// título. Lê só o pedaço novo do transcript.
final class LeituraTitulo { var lido: UInt64 = 0; var custom: String?; var ai: String? }
var titulos: [String: LeituraTitulo] = [:]
let marcaAI = Data("\"type\":\"ai-title\"".utf8)
let marcaCustom = Data("\"type\":\"custom-title\"".utf8)
func titulo(_ transcript: String) -> String? {
    guard !transcript.isEmpty else { return nil }
    let t = titulos[transcript] ?? LeituraTitulo()
    titulos[transcript] = t
    guard let h = FileHandle(forReadingAtPath: transcript) else { return t.custom ?? t.ai }
    defer { h.closeFile() }
    let tamanho = h.seekToEndOfFile()
    if tamanho < t.lido { t.lido = 0; t.custom = nil; t.ai = nil }
    if tamanho > t.lido {
        h.seek(toFileOffset: t.lido)
        let dados = h.readData(ofLength: Int(tamanho - t.lido))
        if let fim = dados.lastIndex(of: 10) {  // não consome linha pela metade
            let completo = dados[dados.startIndex...fim]
            t.lido += UInt64(completo.count)
            for linha in completo.split(separator: 10) {
                guard linha.range(of: marcaAI) != nil || linha.range(of: marcaCustom) != nil,
                      let o = (try? JSONSerialization.jsonObject(with: Data(linha))) as? [String: Any] else { continue }
                if o["type"] as? String == "custom-title", let v = o["customTitle"] as? String, !v.isEmpty { t.custom = v }
                if o["type"] as? String == "ai-title", let v = o["aiTitle"] as? String, !v.isEmpty { t.ai = v }
            }
        }
    }
    return t.custom ?? t.ai
}

// O que a última mensagem da conversa pede: "caixa" (AskUserQuestion aberto),
// "texto" (resposta terminando em pergunta) ou nada. Lê só o fim do transcript,
// e só quando ele muda de tamanho.
final class LeituraPedido { var tamanho: UInt64 = 0; var resultado: String? }
var pedidos: [String: LeituraPedido] = [:]
func ultimoPedido(_ transcript: String) -> String? {
    guard !transcript.isEmpty, let h = FileHandle(forReadingAtPath: transcript) else { return nil }
    defer { h.closeFile() }
    let tamanho = h.seekToEndOfFile()
    if let c = pedidos[transcript], c.tamanho == tamanho { return c.resultado }
    let n = min(tamanho, 65536)
    h.seek(toFileOffset: tamanho - n)
    var linhas = h.readData(ofLength: Int(n)).split(separator: 10)
    if n < tamanho, !linhas.isEmpty { linhas.removeFirst() }  // leu do meio: a 1ª pode ter vindo pela metade
    var resultado: String?
    for linha in linhas.reversed() {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(linha))) as? [String: Any] else { continue }
        let tipo = o["type"] as? String
        if tipo != "assistant" && tipo != "user" { continue }
        if o["isSidechain"] as? Bool == true { continue }
        if tipo == "assistant", let bloco = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]])?.last {
            if bloco["type"] as? String == "tool_use" {
                if bloco["name"] as? String == "AskUserQuestion" { resultado = "caixa" }
            } else if bloco["type"] as? String == "text", let texto = bloco["text"] as? String {
                // "?" entre aspas ou crases é citação (fala de cliente, exemplo), não pergunta pra você
                let ultima = (texto.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
                    .replacingOccurrences(of: "\"[^\"]*\"|“[^”]*”|`[^`]*`", with: "", options: .regularExpression)
                if ultima.contains("?") { resultado = "texto" }
            }
        }
        break
    }
    let c = LeituraPedido()
    c.tamanho = tamanho
    c.resultado = resultado
    pedidos[transcript] = c
    return resultado
}

// Situação a partir do estado do hook + última mensagem. Trabalhando/permissão só
// viram pergunta com a caixinha (texto com "?" no meio do trabalho não conta).
func situacao(_ s: Sessao) -> String {
    var estado = s.estado
    // depois de aprovar uma permissão nenhum hook dispara até a sessão parar; se o
    // transcript mexeu depois do pedido, ela voltou a trabalhar (regra da extensão)
    if estado == "permission", let m = dataDoArquivo(s.transcript), m.timeIntervalSince1970 > s.since + 2 {
        estado = "working"
    }
    let pedido = ultimoPedido(s.transcript)
    if estado == "working" || estado == "permission" { return pedido == "caixa" ? "question" : estado }
    return pedido != nil ? "question" : "finished"
}

// som quando alguma sessão MUDA de situação pra terminou/pergunta/permissão (uma
// vez por mudança; na abertura não toca). Se vierem juntas, o aldeão ganha do XP.
var ultimaSituacao: [String: String] = [:]
func avisar(_ sessoes: [Sessao]) {
    var tocar_: String?
    for s in sessoes {
        if let antes = ultimaSituacao[s.id], antes != s.situacao, estados[s.situacao] != nil, s.situacao != "working",
           tocar_ != "permission", tocar_ != "question" {
            tocar_ = s.situacao
        }
        ultimaSituacao[s.id] = s.situacao
    }
    if let t = tocar_ { tocar(t) }
}

func tempo(_ minutos: Double) -> String {
    guard minutos.isFinite else { return "" }
    let m = max(0, Int(minutos.rounded(.down)))
    if m < 1 { return "agora" }
    if m < 60 { return "\(m)m" }
    if m < 1440 { return "\(m / 60)h" + (m % 60 < 10 ? "0" : "") + "\(m % 60)" }
    return "\(m / 1440)d\((m % 1440) / 60)h"
}

// --- usage: o mesmo endpoint do /usage, a cada 2 min ---
struct Medida { let pct: Double; let renova: Date? }
var uso: [(rotulo: String, medida: Medida)]? = nil
var proximaBusca = Date.distantPast
var buscando = false

func dataISO(_ texto: String?) -> Date? {
    guard var s = texto else { return nil }
    if let r = s.range(of: "\\.\\d+", options: .regularExpression) { s.removeSubrange(r) }  // fração de segundo
    return ISO8601DateFormatter().date(from: s)
}
func medida(_ v: Any?) -> Medida? {
    guard let o = v as? [String: Any], let pct = numero(o["utilization"]) else { return nil }
    return Medida(pct: pct, renova: dataISO(o["resets_at"] as? String))
}
// Login do Claude Code: no Mac fica no Keychain (item "Claude Code-credentials");
// em alguns casos, no arquivo ~/.claude/.credentials.json.
func token() -> String? {
    var dados = FileManager.default.contents(atPath: home + "/.claude/.credentials.json")
    if dados == nil {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        dados = saida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { return nil }
    }
    guard let d = dados, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    return (o["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
}
func usoDe(_ o: [String: Any]) -> [(rotulo: String, medida: Medida)]? {
    let pares: [(String, Medida?)] = [("5h", medida(o["five_hour"])), ("7d", medida(o["seven_day"]))]
    let medidas = pares.compactMap { par -> (rotulo: String, medida: Medida)? in
        guard let m = par.1 else { return nil }
        return (rotulo: par.0, medida: m)
    }
    return medidas.isEmpty ? nil : medidas
}
func buscarUso() {
    if arquivoFoto != nil {  // teste: nada de internet
        if uso == nil, let f = argumento("--uso"), let d = FileManager.default.contents(atPath: f),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { uso = usoDe(o) }
        return
    }
    if buscando || Date() < proximaBusca { return }
    buscando = true
    proximaBusca = Date().addingTimeInterval(20)  // se falhar, tenta de novo logo
    DispatchQueue.global().async {
        guard let tk = token(), let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            DispatchQueue.main.async { buscando = false }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer " + tk, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { dados, resposta, _ in
            let status = (resposta as? HTTPURLResponse)?.statusCode ?? 0
            let novo: [(rotulo: String, medida: Medida)]? = {
                guard status == 200, let d = dados,
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
                return usoDe(o)
            }()
            DispatchQueue.main.async {
                buscando = false
                if let n = novo {
                    uso = n
                    proximaBusca = Date().addingTimeInterval(120)
                } else if status == 429 {
                    proximaBusca = Date().addingTimeInterval(300)  // limite de requisições: espera mais
                }
            }
        }.resume()
    }
}

func trazerEditor() {
    for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
    where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", id]
        try? p.run()
        return
    }
}

// --- desenho ---
let L: CGFloat = 320, A: CGFloat = 440  // janela fixa; o resto é transparente e o clique passa
let M: CGFloat = 34                      // espaço em volta do cartão, por onde o Clawd anda
let fonte = NSFont.systemFont(ofSize: 12)

func escrever(_ s: String, _ c: NSColor, _ r: NSRect, _ alinhamento: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    p.alignment = alinhamento
    let h = ceil(fonte.ascender - fonte.descender)
    (s as NSString).draw(in: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h + 1),
                         withAttributes: [.font: fonte, .foregroundColor: c, .paragraphStyle: p])
}

final class Raiz: NSView {
    override var isFlipped: Bool { true }
}

final class Cartao: NSView {
    var linhas: [(cor: NSColor, nome: String, tempo: String, rotulo: String)] = []
    var dicas: [NSString] = []  // o tooltip não segura o dono
    override var isFlipped: Bool { true }

    // preso no canto de baixo à direita, cresce pra cima
    func arrumar() {
        let n = CGFloat(max(linhas.count, 1))
        let u = CGFloat(max(uso?.count ?? 1, 1))
        let h = 6 + n * 20 + 10 + u * 20 + 6
        frame = NSRect(x: L - M - 242, y: A - M - h, width: 242, height: h)
        removeAllToolTips()
        dicas = linhas.map { $0.rotulo as NSString }
        for (i, d) in dicas.enumerated() {
            addToolTip(NSRect(x: 0, y: 6 + CGFloat(i) * 20, width: 242, height: 20), owner: d, userData: nil)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        hex("#E6181818").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let x: CGFloat = 10
        var y: CGFloat = 6
        if linhas.isEmpty {
            escrever("nenhuma sessão aberta", hex("#9CA3AF"), NSRect(x: x, y: y, width: 222, height: 20))
            y += 20
        }
        for l in linhas {
            l.cor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 6, width: 8, height: 8)).fill()
            escrever(l.nome, hex("#E5E7EB"), NSRect(x: x + 16, y: y, width: 170, height: 20))
            escrever(l.tempo, l.cor, NSRect(x: x + 186, y: y, width: 36, height: 20), .right)
            y += 20
        }
        y += 5
        hex("#33FFFFFF").setFill()
        NSRect(x: x, y: y, width: 222, height: 1).fill()
        y += 5
        guard let medidas = uso else {
            escrever("usage indisponível", hex("#6B7280"), NSRect(x: x, y: y, width: 222, height: 20))
            return
        }
        for (rotulo, m) in medidas {
            let c = m.pct >= 95 ? hex("#EF4444") : m.pct >= 80 ? hex("#F59E0B") : hex("#D1D5DB")
            escrever(rotulo, hex("#9CA3AF"), NSRect(x: x, y: y, width: 18, height: 20))
            let trilho = NSRect(x: x + 18, y: y + 8, width: 118, height: 4)
            hex("#3F3F46").setFill()
            NSBezierPath(roundedRect: trilho, xRadius: 2, yRadius: 2).fill()
            c.setFill()
            let cheio = 118 * CGFloat(min(max(m.pct, 0), 100)) / 100
            NSBezierPath(roundedRect: NSRect(x: trilho.minX, y: trilho.minY, width: cheio, height: 4), xRadius: 2, yRadius: 2).fill()
            escrever(String(format: "%.0f%%", m.pct), c, NSRect(x: x + 136, y: y, width: 38, height: 20), .right)
            // quanto falta pra renovar
            let falta = m.renova.map { tempo($0.timeIntervalSinceNow / 60) } ?? ""
            escrever(falta, hex("#6B7280"), NSRect(x: x + 174, y: y, width: 48, height: 20), .right)
            y += 20
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { trazerEditor(); return }
        window?.performDrag(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let fechar = NSMenuItem(title: "Fechar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        fechar.target = NSApp
        menu.addItem(fechar)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// --- Clawd: pixel art do mascote do Claude Code (o do banner do terminal) ---
// '#' corpo, 'o' olho, 'A'/'B' os dois pares de pernas, que se alternam.
// Origem (0,0) = entre os pés, então ele "pisa" na trilha e o corpo fica pra fora.
// Pixel 2x mais alto que largo, como os meio-blocos do terminal (senão fica achatado).
let sprite = [
    "...############...",
    "...##o######o##...",
    ".################.",
    "...############...",
    "....A.B....A.B....",
]
let pw: CGFloat = 1.5, ph: CGFloat = 3

// Picareta sem Minecraft: 16x16 desenhada aqui, com o cabo no mesmo pixel da
// textura do jogo. d/c/b = cabeça (contorno, diamante, brilho); k/h = cabo.
let picaretaPropria = [
    "................",
    "....ddddd.......",
    "...dbbcccdd.....",
    "....dddcccbd....",
    ".......ddcccd...",
    ".........dccd...",
    "........kdcbcd..",
    ".......khkdccd..",
    "......khk..dcd..",
    ".....khk...dcd..",
    "....khk.....dd..",
    "...khk..........",
    "..khk...........",
    "..kk............",
    "................",
    "................",
]
let coresPicareta: [(Character, String)] = [("d", "#1B6E73"), ("c", "#4AEDD9"), ("b", "#C9FFF6"), ("k", "#3B2A14"), ("h", "#8A5A2B")]

// retângulos de mesma cor num caminho só: pixels vizinhos sem risco entre eles
func forma(_ linhas: [String], _ largura: CGFloat, _ altura: CGFloat, _ dx: CGFloat, _ dy: CGFloat,
           _ pega: (Character) -> Bool) -> CGPath {
    let caminho = CGMutablePath()
    for (lin, linha) in linhas.enumerated() {
        let cs = Array(linha)
        var col = 0
        while col < cs.count {
            if !pega(cs[col]) { col += 1; continue }
            var fim = col
            while fim + 1 < cs.count && pega(cs[fim + 1]) { fim += 1 }
            caminho.addRect(CGRect(x: (CGFloat(col) + dx) * largura, y: (CGFloat(lin) + dy) * altura,
                                   width: CGFloat(fim - col + 1) * largura, height: altura))
            col = fim + 1
        }
    }
    return caminho
}
let corpo = forma(sprite, pw, ph, -9, -5) { $0 == "#" || $0 == "o" }
let olhos = forma(sprite, pw, ph, -9, -5) { $0 == "o" }
let pernaA = forma(sprite, pw, ph, -9, -5) { $0 == "A" }
let pernaB = forma(sprite, pw, ph, -9, -5) { $0 == "B" }
let desenhoPicareta: [(CGPath, NSColor)] = coresPicareta.map { par -> (CGPath, NSColor) in
    (forma(picaretaPropria, 1.1, 1.1, 0, 0, { $0 == par.0 }), hex(par.1))
}
let texturaPicareta = NSImage(contentsOfFile: pasta + "/picareta.png")
let cabo = CGPoint(x: 2.75, y: 14.85)  // pixel (2,5; 13,5) da textura, em 1,1 por pixel
let mao = CGPoint(x: 12, y: -7.5)       // ponta do braço direito do Clawd

// Trilha = borda arredondada do cartão, no sentido horário; o Clawd gira junto
// nas curvas. Fora do modo "andando" ele fica parado no meio da borda de cima.
final class Palco: NSView {
    weak var cartao: Cartao?
    var modo = ""
    var fracao: CGFloat = 0  // onde ele está na volta (0-1); sobrevive ao cartão mudar de tamanho
    var antes = ProcessInfo.processInfo.systemUptime
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // "andando" (algo rodando): anda, pula, troca de perna e minera.
    // "pulando" (pergunta/permissão): parado em cima do cartão, pulando.
    // "parado" (nada rodando): parado em cima do cartão, com as 4 pernas no chão.
    func mudar(_ novo: String) {
        if novo == modo { return }
        if novo == "andando", let c = cartao?.frame { fracao = (c.width / 2 - 8) / perimetro(c) }  // sai do meio de cima
        modo = novo
        needsDisplay = true
    }

    func perimetro(_ c: NSRect) -> CGFloat { 2 * (c.width + c.height) - (8 - 2 * .pi) * 8 }

    // ponto e direção a uma distância d do começo da borda de cima (y pra baixo)
    func naBorda(_ c: NSRect, _ distancia: CGFloat) -> (CGPoint, CGFloat) {
        let r: CGFloat = 8
        let reta = c.width - 2 * r, lado = c.height - 2 * r, curva = CGFloat.pi * r / 2
        let trechos: [CGFloat] = [reta, curva, lado, curva, reta, curva, lado, curva]
        var d = distancia
        var i = 0
        while i < 7 && d > trechos[i] {
            d -= trechos[i]
            i += 1
        }
        switch i {
        case 0: return (CGPoint(x: c.minX + r + d, y: c.minY), 0)
        case 1: return arco(CGPoint(x: c.maxX - r, y: c.minY + r), -.pi / 2, d / r)
        case 2: return (CGPoint(x: c.maxX, y: c.minY + r + d), .pi / 2)
        case 3: return arco(CGPoint(x: c.maxX - r, y: c.maxY - r), 0, d / r)
        case 4: return (CGPoint(x: c.maxX - r - d, y: c.maxY), .pi)
        case 5: return arco(CGPoint(x: c.minX + r, y: c.maxY - r), .pi / 2, d / r)
        case 6: return (CGPoint(x: c.minX, y: c.maxY - r - d), -.pi / 2)
        default: return arco(CGPoint(x: c.minX + r, y: c.minY + r), .pi, d / r)
        }
    }
    func arco(_ centro: CGPoint, _ inicio: CGFloat, _ andou: CGFloat) -> (CGPoint, CGFloat) {
        let a = inicio + andou
        return (CGPoint(x: centro.x + 8 * cos(a), y: centro.y + 8 * sin(a)), a + .pi / 2)
    }

    func tique() {
        let agora = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(agora - antes, 0.1))
        antes = agora
        guard modo != "parado", let c = cartao?.frame, c.width > 0 else { return }
        if modo == "andando" {
            fracao += 50 * dt / perimetro(c)  // ~50 px/s
            fracao -= fracao.rounded(.down)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = cartao?.frame, c.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = ProcessInfo.processInfo.systemUptime
        var (ponto, angulo) = (CGPoint(x: c.midX, y: c.minY), CGFloat(0))
        if modo == "andando" { (ponto, angulo) = naBorda(c, fracao * perimetro(c)) }
        ctx.saveGState()
        ctx.translateBy(x: ponto.x, y: ponto.y)
        ctx.rotate(by: angulo)
        if modo != "parado" {
            // pulinhos: sobe rápido e desacelera no alto; a volta acelera
            let u = t.truncatingRemainder(dividingBy: 0.32) / 0.16
            let p = CGFloat(u <= 1 ? u : 2 - u)
            ctx.translateBy(x: 0, y: -5 * (1 - (1 - p) * (1 - p)))
        }
        for (caminho, cor) in [(corpo, hex("#D77757")), (olhos, hex("#1A1A1A"))] {
            ctx.addPath(caminho)
            ctx.setFillColor(cor.cgColor)
            ctx.fillPath()
        }
        // andando troca de perna a cada meio pulo; parado, as 4 no chão
        let passo = Int(t / 0.16) % 2 == 0
        ctx.setFillColor(hex("#D77757").cgColor)
        if modo != "andando" || passo { ctx.addPath(pernaA) }
        if modo != "andando" || !passo { ctx.addPath(pernaB) }
        ctx.fillPath()

        // picareta na mão direita; andando, balança como quem minera
        ctx.translateBy(x: mao.x, y: mao.y)
        if modo == "andando" {
            let u = t.truncatingRemainder(dividingBy: 0.64) / 0.32
            let p = u <= 1 ? u : 2 - u
            ctx.rotate(by: CGFloat(-25 + 40 * sin(p * .pi / 2)) * .pi / 180)
        }
        ctx.translateBy(x: -cabo.x, y: -cabo.y)
        if let img = texturaPicareta {
            NSGraphicsContext.current?.imageInterpolation = .none
            img.draw(in: NSRect(x: 0, y: 0, width: 17.6, height: 17.6), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        } else {
            ctx.setShouldAntialias(false)
            for (caminho, cor) in desenhoPicareta {
                ctx.addPath(caminho)
                ctx.setFillColor(cor.cgColor)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }
}

// --- janela ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // sem ícone no Dock
let janela = NSPanel(contentRect: NSRect(x: 0, y: 0, width: L, height: A),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
janela.isOpaque = false
janela.backgroundColor = .clear
janela.hasShadow = false
janela.level = .floating
janela.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
janela.hidesOnDeactivate = false
janela.isReleasedWhenClosed = false
janela.allowsToolTipsWhenApplicationIsInactive = true
let raiz = Raiz(frame: NSRect(x: 0, y: 0, width: L, height: A))
let cartao = Cartao(frame: .zero)
let palco = Palco(frame: raiz.bounds)
palco.cartao = cartao
raiz.addSubview(cartao)
raiz.addSubview(palco)
janela.contentView = raiz
// nasce no canto de baixo à direita (a margem M já afasta o cartão da borda)
if let tela = NSScreen.main?.visibleFrame { janela.setFrameOrigin(NSPoint(x: tela.maxX - L, y: tela.minY)) }

// a extensão trocou o binário por uma versão nova: vira ela (mesmo processo)
func seAtualizou() {
    guard arquivoFoto == nil, let v = versao, let agora = dataDoArquivo(binario), agora != v else { return }
    var args: [UnsafeMutablePointer<CChar>?] = argumentos.map { strdup($0) }
    args.append(nil)
    execv(binario, &args)
}

func atualizar() {
    let agora = Date().timeIntervalSince1970
    let sessoes = lerSessoes(agora: agora)
    avisar(sessoes)
    cartao.linhas = sessoes.map { s -> (cor: NSColor, nome: String, tempo: String, rotulo: String) in
        let e = estados[s.situacao] ?? (cor: "#9CA3AF", rotulo: s.situacao)
        return (cor: hex(e.cor), nome: s.nome, tempo: tempo((agora - s.since) / 60), rotulo: e.rotulo)
    }
    buscarUso()
    cartao.arrumar()  // redesenha a cada 2 s pra contagem de "falta" andar entre as buscas
    // pedindo algo (pergunta/permissão) ganha de trabalhando, que ganha de parado.
    // Depois do arrumar: na 1ª vez o cartão ainda tem largura 0 e o Clawd sairia por baixo
    let situacoes = Set(sessoes.map { $0.situacao })
    palco.mudar(situacoes.contains("question") || situacoes.contains("permission") ? "pulando"
                : situacoes.contains("working") ? "andando" : "parado")
    palco.needsDisplay = true
    if let foto = arquivoFoto {
        let visto = sessoes.map { "sessao: \($0.nome) | hook=\($0.estado) | janelinha=\($0.situacao)" }
            + ["clawd: \(palco.modo)", "usage: \(uso == nil ? "indisponivel" : "ok")"]
        try? (visto.joined(separator: "\n") + "\n").write(toFile: foto + ".txt", atomically: true, encoding: .utf8)
    }
    seAtualizou()
}

func repetir(_ intervalo: TimeInterval, _ bloco: @escaping () -> Void) {
    let t = Timer(timeInterval: intervalo, repeats: true) { _ in bloco() }
    RunLoop.main.add(t, forMode: .common)  // continua durante arrasto e menu
}

atualizar()
janela.orderFrontRegardless()
repetir(2) { atualizar() }
repetir(1.0 / 30) { palco.tique() }

if let foto = arquivoFoto {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        atualizar()
        if let rep = raiz.bitmapImageRepForCachingDisplay(in: raiz.bounds) {
            raiz.cacheDisplay(in: raiz.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: foto))
            print("foto: \(foto)")
        }
        exit(0)
    }
}
app.run()
