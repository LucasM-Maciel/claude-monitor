// Monta o que os amigos baixam, em dist/:
//   claude-monitor-<versão>.vsix  a extensão (com a janelinha dentro)
//   ClaudeMonitor.zip             instaladores + .vsix + COMO INSTALAR/ATUALIZAR.txt
// Uso: npm run empacotar
const fs = require("fs");
const path = require("path");
const { createVSIX } = require("@vscode/vsce");
const yazl = require("yazl");

const raiz = __dirname;
const dist = path.join(raiz, "dist");
const versao = require("./extensao/package.json").version;

async function main() {
    fs.rmSync(dist, { recursive: true, force: true });
    fs.mkdirSync(dist);
    const vsix = path.join(dist, `claude-monitor-${versao}.vsix`);
    await createVSIX({
        cwd: path.join(raiz, "extensao"),
        packagePath: vsix,
        dependencies: false,
        allowMissingRepository: true,
        skipLicense: true,
    });

    const zip = new yazl.ZipFile();
    const instalar = (nome) => path.join(raiz, "instalar", nome);
    zip.addFile(instalar("COMO INSTALAR.txt"), "ClaudeMonitor/COMO INSTALAR.txt");
    zip.addFile(instalar("COMO ATUALIZAR.txt"), "ClaudeMonitor/COMO ATUALIZAR.txt");
    zip.addFile(instalar("instalar-windows.cmd"), "ClaudeMonitor/instalar-windows.cmd");
    zip.addFile(instalar("instalar-mac.sh"), "ClaudeMonitor/instalar-mac.sh", { mode: 0o100755 });
    zip.addFile(instalar("instalar-windows.ps1"), "ClaudeMonitor/arquivos/instalar-windows.ps1");
    zip.addFile(vsix, `ClaudeMonitor/arquivos/${path.basename(vsix)}`);
    zip.end();
    await new Promise((ok, erro) =>
        zip.outputStream.pipe(fs.createWriteStream(path.join(dist, "ClaudeMonitor.zip"))).on("close", ok).on("error", erro));
    console.log(`dist/${path.basename(vsix)}\ndist/ClaudeMonitor.zip`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
