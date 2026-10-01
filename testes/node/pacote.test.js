// O que vai pros amigos: arquivos certos, no formato certo, sem nada pessoal.
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");

const RAIZ = path.join(__dirname, "..", "..");
const EXT = path.join(RAIZ, "extensao");
const DIST = path.join(RAIZ, "dist");
const manifesto = JSON.parse(fs.readFileSync(path.join(EXT, "package.json"), "utf8"));

function arquivos(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
        const p = path.join(dir, e.name);
        if (["node_modules", ".git", "dist"].includes(e.name)) return [];
        return e.isDirectory() ? arquivos(p) : [p];
    });
}
const doProjeto = arquivos(RAIZ).filter((f) => !f.endsWith("package-lock.json"));
const comExtensao = (ext) => doProjeto.filter((f) => f.endsWith(ext));

test("PowerShell 5 (o do Windows) só lê acento certo com BOM: todo .ps1 tem BOM", () => {
    for (const f of comExtensao(".ps1")) {
        const b = fs.readFileSync(f);
        assert.ok(b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf, `${path.relative(RAIZ, f)} sem BOM`);
    }
});

test("bash do Mac quebra com CRLF: .sh sem \\r e com #!/bin/bash", () => {
    for (const f of comExtensao(".sh")) {
        const t = fs.readFileSync(f, "utf8");
        assert.ok(!t.includes("\r"), `${path.relative(RAIZ, f)} tem CRLF`);
        assert.ok(t.startsWith("#!/bin/bash\n"), path.relative(RAIZ, f));
    }
});

test(".cmd só com ASCII (o cmd do Windows embaralha acento)", () => {
    for (const f of comExtensao(".cmd")) {
        assert.ok(/^[\x00-\x7f]*$/.test(fs.readFileSync(f, "latin1")), path.relative(RAIZ, f));
    }
});

test("nada pessoal no repositório público (caminho da máquina, token, e-mail)", () => {
    // o que é pessoal é descoberto aqui na hora, pra não ficar escrito no próprio teste
    const escapar = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const casa = require("os").homedir();
    const pessoal = [casa, casa.split(path.sep).join("/"), casa.split(path.sep).join("\\\\")];
    try {
        pessoal.push(require("child_process").execFileSync("git", ["config", "user.email"], { encoding: "utf8" }).trim());
    } catch {
        // sem git configurado
    }
    const proibido = [
        ...pessoal.filter((s) => s.length > 6).map((s) => new RegExp(escapar(s), "i")),
        /sk-ant-[a-z0-9]/i,
        /"accessToken"\s*:\s*"[^"]{8,}/,
    ];
    for (const f of doProjeto.filter((f) => !/\.(png|vsix|zip)$/.test(f))) {
        const t = fs.readFileSync(f, "utf8");
        for (const p of proibido) assert.ok(!p.test(t), `${path.relative(RAIZ, f)} tem ${p}`);
    }
});

test("configurações lidas no código existem no package.json", () => {
    const codigo = fs.readFileSync(path.join(EXT, "out", "extension.js"), "utf8");
    const usadas = [...codigo.matchAll(/\.get\("(\w+)"/g)].map((m) => `claudeMonitor.${m[1]}`);
    const declaradas = Object.keys(manifesto.contributes.configuration.properties);
    for (const u of new Set(usadas)) assert.ok(declaradas.includes(u), `${u} não está no package.json`);
});

test("arquivos da janelinha que a extensão copia existem", () => {
    const codigo = fs.readFileSync(path.join(EXT, "out", "extension.js"), "utf8");
    const bloco = codigo.match(/const JANELINHA = \{([\s\S]*?)\};/)[1];
    const nomes = [...bloco.matchAll(/"([\w.]+\.(?:ps1|swift|sh|js))"/g)].map((m) => m[1]);
    assert.ok(nomes.length >= 4, nomes.join());
    for (const n of nomes) assert.ok(fs.existsSync(path.join(EXT, "janelinha", n)), n);
});

test("instaladores extraem do .vsix os mesmos arquivos que existem na extensão", () => {
    for (const f of ["instalar-windows.ps1", "instalar-mac.sh"]) {
        const t = fs.readFileSync(path.join(RAIZ, "instalar", f), "utf8");
        const citados = [...t.matchAll(/(?:extension\/|')((?:out|janelinha)\/[\w.]+)/g)].map((m) => m[1]);
        assert.ok(citados.length >= 4, `${f}: ${citados}`);
        for (const c of citados) assert.ok(fs.existsSync(path.join(EXT, c)), `${f} cita ${c}, que não existe`);
    }
});

// --- o pacote montado (npm run empacotar); no CI ele sempre existe ---
const temDist = fs.existsSync(path.join(DIST, "ClaudeMonitor.zip"));
function entradas(zip) {
    const yauzl = require("yauzl");
    return new Promise((ok, erro) => yauzl.open(zip, { lazyEntries: true }, (e, z) => {
        if (e) return erro(e);
        const lista = [];
        z.on("entry", (en) => { lista.push({ nome: en.fileName, modo: (en.externalFileAttributes >>> 16) & 0o777 }); z.readEntry(); });
        z.on("end", () => ok(lista));
        z.readEntry();
    }));
}

test("ClaudeMonitor.zip tem tudo, com o instalador do Mac executável", { skip: !temDist && "rode npm run empacotar" }, async () => {
    const lista = await entradas(path.join(DIST, "ClaudeMonitor.zip"));
    const nomes = lista.map((e) => e.nome).sort();
    assert.deepStrictEqual(nomes, [
        "ClaudeMonitor/COMO ATUALIZAR.txt",
        "ClaudeMonitor/COMO INSTALAR.txt",
        `ClaudeMonitor/arquivos/claude-monitor-${manifesto.version}.vsix`,
        "ClaudeMonitor/arquivos/instalar-windows.ps1",
        "ClaudeMonitor/instalar-mac.sh",
        "ClaudeMonitor/instalar-windows.cmd",
    ]);
    assert.ok(lista.every((e) => !e.nome.includes("\\")), "barra invertida no zip vira nome de arquivo no Mac");
    assert.strictEqual(lista.find((e) => e.nome.endsWith("instalar-mac.sh")).modo, 0o755);
});

test(".vsix leva a janelinha, os scripts e nada de sobra", { skip: !temDist && "rode npm run empacotar" }, async () => {
    const nomes = (await entradas(path.join(DIST, `claude-monitor-${manifesto.version}.vsix`))).map((e) => e.nome);
    for (const n of ["extension/package.json", "extension/readme.md", "extension/out/extension.js", "extension/out/hook.js",
        "extension/out/processes.js", "extension/out/install.js", "extension/out/sessions.js",
        "extension/janelinha/overlay.ps1", "extension/janelinha/overlay.swift",
        "extension/janelinha/minecraft.js", "extension/janelinha/vorbis.min.js", "extension/janelinha/vorbis-licencas.txt"]) {
        assert.ok(nomes.some((x) => x.toLowerCase() === n), `falta ${n} (tem: ${nomes.join(", ")})`);
    }
    // nada da Mojang no pacote: sons e texturas vêm do servidor dela na instalação
    assert.ok(!nomes.some((n) => /node_modules|\.map$|\.wav$|\.ogg$|\.png$/.test(n)), nomes.join(", "));
});
