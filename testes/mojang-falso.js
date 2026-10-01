// Mojang de mentira pros testes: manifesto -> versão -> índice -> objetos, e o
// jar do jogo atendendo Range (como o servidor de verdade). Todo som é o
// testes/bip.ogg (feito pra teste, não é da Mojang: estéreo, 48 kHz, 0,25 s) e o
// jar leva as texturas magenta dos testes no meio de outros arquivos.
//   Teste Node:  const m = await iniciar({ semRange, faltando, lixo }); m.url; m.pedidos; m.fechar()
//   PowerShell/bash:  node testes/mojang-falso.js -> imprime a URL e fica no ar até matar
const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const yazl = require("yazl");
const { SONS } = require("../extensao/janelinha/minecraft.js");

// a mesma picareta magenta 16x16 dos testes da janelinha
const MAGENTA = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAlSURBVDhPY2AYCPCf4f9/dDGiAUgz2QaMaiYRjGomA1CkeUABAMm+R7mIjocJAAAAAElFTkSuQmCC", "base64");
const BIP = fs.readFileSync(path.join(__dirname, "bip.ogg"));
const HASH = crypto.createHash("sha1").update(BIP).digest("hex");

function jar() {
    const zip = new yazl.ZipFile();
    // mais de 64 KB antes do índice: o "fim do zip" não é o arquivo inteiro
    zip.addBuffer(crypto.randomBytes(100000), "net/minecraft/Main.class");
    for (const t of ["item/diamond_pickaxe", "item/diamond_sword", "item/diamond", "block/diamond_ore"]) {
        zip.addBuffer(MAGENTA, `assets/minecraft/textures/${t}.png`);
    }
    zip.addBuffer(MAGENTA, "assets/minecraft/textures/item/iron_pickaxe.png", { compress: false });
    zip.end();
    return new Promise((ok) => {
        const pedacos = [];
        zip.outputStream.on("data", (p) => pedacos.push(p)).on("end", () => ok(Buffer.concat(pedacos)));
    });
}

async function iniciar({ semRange = false, faltando = [], lixo = false } = {}) {
    const cliente = await jar();
    const pedidos = [];
    const servidor = http.createServer((req, res) => {
        pedidos.push(req.headers.range ? `${req.url} ${req.headers.range}` : req.url);
        const base = `http://127.0.0.1:${servidor.address().port}`;
        const json = (o) => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(o)); };
        if (req.url === "/version_manifest_v2.json") {
            return json({ latest: { release: "1.99", snapshot: "99w99a" }, versions: [
                { id: "99w99a", url: `${base}/errada.json` },
                { id: "1.99", url: `${base}/1.99.json` },
            ] });
        }
        if (req.url === "/1.99.json") {
            return json({ assetIndex: { url: `${base}/indice.json` }, downloads: { client: { url: `${base}/client.jar`, size: cliente.length } } });
        }
        if (req.url === "/indice.json") {
            const objetos = { "icons/icon_16x16.png": { hash: "5ff04807c356f1beed0b86ccf659b44b9983e3fa", size: 781 } };
            for (const som of Object.values(SONS)) if (!faltando.includes(som)) objetos[`minecraft/sounds/${som}.ogg`] = { hash: HASH, size: BIP.length };
            return json({ objects: objetos });
        }
        if (req.url === `/objetos/${HASH.slice(0, 2)}/${HASH}`) return res.end(lixo ? crypto.randomBytes(BIP.length) : BIP);
        if (req.url === "/client.jar") {
            const faixa = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || "");
            if (!faixa || semRange) return res.end(cliente);
            res.statusCode = 206;
            return res.end(cliente.subarray(Number(faixa[1]), Number(faixa[2]) + 1));
        }
        res.statusCode = 404;
        res.end();
    });
    await new Promise((ok) => servidor.listen(0, "127.0.0.1", ok));
    return {
        url: `http://127.0.0.1:${servidor.address().port}`,
        pedidos,
        cliente,
        fechar: () => new Promise((ok) => { servidor.close(ok); servidor.closeAllConnections(); }),
    };
}

if (require.main === module) iniciar().then((m) => console.log(m.url));

module.exports = { iniciar, MAGENTA, BIP };
