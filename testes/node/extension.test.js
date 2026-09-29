// extension.js rodando de verdade, com um VS Code de mentira e sem abrir nada:
// spawn/execFile são gravados em vez de executados. A plataforma é trocada pra
// testar os caminhos do Windows e do Mac em qualquer máquina.
const { test, afterEach } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const Module = require("module");
const cp = require("child_process");

const RAIZ = path.join(__dirname, "..", "..", "extensao");
const manifesto = JSON.parse(fs.readFileSync(path.join(RAIZ, "package.json"), "utf8"));

// --- VS Code de mentira ---
function criarVscode(config) {
    const r = { comandos: new Map(), mensagens: [], terminais: [], executados: [], config: { ...config } };
    const msg = (tipo, respostas) => (texto, ...botoes) => {
        r.mensagens.push({ tipo, texto, botoes });
        return Promise.resolve(respostas?.[texto.slice(0, 40)]);
    };
    const vscode = {
        EventEmitter: class { constructor() { this.event = () => ({ dispose() {} }); } fire() {} },
        TreeItem: class { constructor(label) { this.label = label; } },
        ThemeIcon: class { constructor(id) { this.id = id; } },
        ThemeColor: class { constructor(id) { this.id = id; } },
        MarkdownString: class { constructor(v) { this.value = v; } },
        TreeItemCollapsibleState: { None: 0 },
        StatusBarAlignment: { Left: 1 },
        ConfigurationTarget: { Global: 1 },
        Uri: { file: (p) => ({ fsPath: p }), parse: (u) => ({ toString: () => u }) },
        window: {
            state: { focused: true },
            terminals: [],
            createTreeView: () => ({ dispose() {} }),
            createStatusBarItem: () => ({ show() {}, dispose() {} }),
            showInformationMessage: msg("info"),
            showWarningMessage: msg("aviso"),
            showErrorMessage: msg("erro"),
            setStatusBarMessage: () => ({ dispose() {} }),
            createTerminal: (o) => { r.terminais.push(o); return { show() {} }; },
            createOutputChannel: () => ({ clear() {}, appendLine() {}, show() {} }),
            registerUriHandler: (h) => { r.uri = h; return { dispose() {} }; },
        },
        workspace: {
            workspaceFolders: [],
            getConfiguration: () => ({
                get: (k, padrao) => (k in r.config ? r.config[k] : padrao),
                update: async (k, v) => { r.config[k] = v; },
            }),
        },
        commands: {
            registerCommand: (id, fn) => { r.comandos.set(id, fn); return { dispose() {} }; },
            executeCommand: async (...a) => { r.executados.push(a); },
        },
        env: { openExternal: async () => true },
    };
    r.vscode = vscode;
    return { vscode, r };
}

// --- processos de mentira ---
let processos;  // [{ tipo, cmd, args }]
let semFerramentasApple = false;
let semNode = false;
const spawnReal = cp.spawn, execFileReal = cp.execFile;
cp.spawn = (cmd, args) => {
    processos.push({ tipo: "spawn", cmd, args });
    return { unref() {} };
};
cp.execFile = (cmd, args, opcoes, cb) => {
    if (typeof opcoes === "function") cb = opcoes;
    processos.push({ tipo: "execFile", cmd, args });
    let erro = null;
    if (cmd === "xcode-select" && args[0] === "-p" && semFerramentasApple) erro = new Error("sem CLT");
    if ((cmd === "where" || cmd === "which") && semNode) erro = new Error("não achou");
    if (cmd === "xcrun") fs.writeFileSync(args[args.indexOf("-o") + 1], "binário");  // "compila"
    setImmediate(() => cb?.(erro, erro ? "" : "/Library/Developer/CommandLineTools\n", ""));
    return {};
};

const plataformaReal = process.platform;
let ativa;  // { ext, contexto }
let modLoad = Module._load;

/** Ativa a extensão numa casa nova (ou na mesma, pra simular reabrir o VS Code). */
async function ativar({ plataforma = "win32", config = {}, casa, versao = manifesto.version, hooks = true } = {}) {
    casa ??= fs.mkdtempSync(path.join(os.tmpdir(), "cm-ext-"));
    process.env.HOME = casa;
    process.env.USERPROFILE = casa;
    Object.defineProperty(process, "platform", { value: plataforma });
    if (hooks) {
        // hooks já instalados: sem a pergunta "Instalar?"
        fs.mkdirSync(path.join(casa, ".claude"), { recursive: true });
        const cmd = (a) => `node "${path.join(casa, ".claude-monitor", "hook.js").split(path.sep).join("/")}" ${a}`;
        fs.writeFileSync(path.join(casa, ".claude", "settings.json"), JSON.stringify({
            hooks: Object.fromEntries([["UserPromptSubmit", "working"], ["Stop", "waiting"], ["Notification", "notification"], ["SessionEnd", "end"]]
                .map(([e, a]) => [e, [{ hooks: [{ type: "command", command: cmd(a) }] }]])),
        }));
    }
    processos = [];
    const { vscode, r } = criarVscode(config);
    Module._load = function (pedido, ...resto) {
        return pedido === "vscode" ? vscode : modLoad.call(this, pedido, ...resto);
    };
    for (const k of Object.keys(require.cache)) if (k.startsWith(path.join(RAIZ, "out"))) delete require.cache[k];
    const ext = require(path.join(RAIZ, "out", "extension.js"));
    const contexto = {
        subscriptions: [],
        extensionPath: RAIZ,
        extension: { packageJSON: { ...manifesto, version: versao } },
    };
    ext.activate(contexto);
    ativa = { ext, contexto };
    await new Promise((ok) => setTimeout(ok, 50));  // deixa as promessas do activate andarem
    return { casa, r, pasta: path.join(casa, ".claude-monitor") };
}
function desativar() {
    if (!ativa) return;
    for (const d of ativa.contexto.subscriptions) d.dispose?.();
    ativa = null;
    Module._load = modLoad;
    Object.defineProperty(process, "platform", { value: plataformaReal });
}
afterEach(desativar);
const spawns = () => processos.filter((p) => p.tipo === "spawn");

test("Windows: copia hook + janelinha, marca a versão e abre a janelinha", async () => {
    const { pasta } = await ativar({ plataforma: "win32" });
    for (const f of ["hook.js", "processes.js", "overlay.ps1", "extrair_minecraft.ps1"]) assert.ok(fs.existsSync(path.join(pasta, f)), f);
    assert.strictEqual(fs.readFileSync(path.join(pasta, "versao-janelinha"), "utf8"), manifesto.version);
    const [s] = spawns();
    assert.strictEqual(s.cmd, "cmd.exe");
    assert.ok(s.args.includes(path.join(pasta, "overlay.ps1")));
    assert.ok(s.args.includes("Bypass"), "sem ExecutionPolicy Bypass o PowerShell recusa o script");
    const diario = fs.readFileSync(path.join(pasta, "janelinha.log"), "utf8");
    assert.match(diario, new RegExp(`copiou a janelinha ${manifesto.version} \\(antes: nenhuma\\)`));
    assert.match(diario, /mandou abrir a janelinha/);
});

test("Mac: copia o .swift, compila com swift 5 e abre o binário", async () => {
    const { pasta } = await ativar({ plataforma: "darwin" });
    for (const f of ["overlay.swift", "extrair_minecraft.sh"]) assert.ok(fs.existsSync(path.join(pasta, f)), f);
    const compilou = processos.find((p) => p.cmd === "xcrun");
    assert.ok(compilou, "não chamou o xcrun swiftc");
    assert.deepStrictEqual(compilou.args.slice(0, 4), ["swiftc", "-swift-version", "5", "-O"]);
    assert.ok(fs.existsSync(path.join(pasta, "ClaudeMonitor")), "o binário compilado não foi pro lugar");
    assert.strictEqual(spawns()[0].cmd, path.join(pasta, "ClaudeMonitor"));
});

test("Mac: não recompila quando o binário já está em dia", async () => {
    const { casa } = await ativar({ plataforma: "darwin" });
    desativar();
    await ativar({ plataforma: "darwin", casa });
    assert.ok(!processos.some((p) => p.cmd === "xcrun"), "recompilou à toa");
    assert.strictEqual(spawns().length, 1);
});

test("Mac sem as ferramentas da Apple: explica e oferece instalar, sem abrir nada", async () => {
    semFerramentasApple = true;
    try {
        const { r } = await ativar({ plataforma: "darwin" });
        const aviso = r.mensagens.find((m) => m.tipo === "aviso" && m.texto.includes("ferramentas"));
        assert.ok(aviso, JSON.stringify(r.mensagens));
        assert.deepStrictEqual(aviso.botoes, ["Instalar", "Não usar a janelinha"]);
        assert.strictEqual(spawns().length, 0);
        assert.ok(!processos.some((p) => p.cmd === "xcrun"));
    } finally {
        semFerramentasApple = false;
    }
});

test("Linux: nada de janelinha (só a barra lateral)", async () => {
    const { pasta } = await ativar({ plataforma: "linux" });
    assert.ok(!fs.existsSync(path.join(pasta, "overlay.ps1")));
    assert.strictEqual(spawns().length, 0);
});

test("reabrir o VS Code na mesma versão NÃO apaga o que o amigo mexeu no overlay", async () => {
    const { casa, pasta } = await ativar();
    fs.appendFileSync(path.join(pasta, "overlay.ps1"), "\n# mexi aqui\n");
    desativar();
    await ativar({ casa });
    assert.match(fs.readFileSync(path.join(pasta, "overlay.ps1"), "utf8"), /# mexi aqui/);
});

test("versão nova da extensão troca o overlay (e a janelinha aberta se reabre)", async () => {
    const { casa, pasta } = await ativar();
    fs.appendFileSync(path.join(pasta, "overlay.ps1"), "\n# versão velha\n");
    desativar();
    await ativar({ casa, versao: "99.0.0" });
    assert.doesNotMatch(fs.readFileSync(path.join(pasta, "overlay.ps1"), "utf8"), /versão velha/);
    assert.strictEqual(fs.readFileSync(path.join(pasta, "versao-janelinha"), "utf8"), "99.0.0");
    assert.match(fs.readFileSync(path.join(pasta, "janelinha.log"), "utf8"), new RegExp(`copiou a janelinha 99\\.0\\.0 \\(antes: ${manifesto.version.replace(/\./g, "\\.")}\\)`));
});

test("diário da janelinha passou de 256 KB: vira .1 e começa de novo", async () => {
    const { casa, pasta } = await ativar();
    fs.writeFileSync(path.join(pasta, "janelinha.log"), "x".repeat(300 * 1024));
    desativar();
    await ativar({ casa });
    assert.strictEqual(fs.statSync(path.join(pasta, "janelinha.log.1")).size, 300 * 1024);
    assert.match(fs.readFileSync(path.join(pasta, "janelinha.log"), "utf8"), /^\S+ \S+ \[\S+ \d+\] mandou abrir a janelinha\r?\n$/);
});

test("arquivo da janelinha apagado volta na próxima abertura", async () => {
    const { casa, pasta } = await ativar();
    fs.rmSync(path.join(pasta, "overlay.ps1"));
    desativar();
    await ativar({ casa });
    assert.ok(fs.existsSync(path.join(pasta, "overlay.ps1")));
});

test("janelinha desligada nas configurações: não abre", async () => {
    await ativar({ config: { overlay: false } });
    assert.strictEqual(spawns().length, 0);
});

test("sem hooks: pergunta se instala; com hooks: não pergunta", async () => {
    const sem = await ativar({ hooks: false });
    assert.ok(sem.r.mensagens.some((m) => m.texto.includes("instalar os hooks")));
    desativar();
    const com = await ativar();
    assert.ok(!com.r.mensagens.some((m) => m.texto.includes("instalar os hooks")));
});

test("sem Node.js: avisa (os hooks rodam node)", async () => {
    semNode = true;
    try {
        const { r } = await ativar();
        assert.ok(r.mensagens.some((m) => m.texto.includes("Node.js")), JSON.stringify(r.mensagens));
    } finally {
        semNode = false;
    }
});

test("todo comando do package.json existe de verdade (e vice-versa)", async () => {
    const { r } = await ativar();
    const declarados = manifesto.contributes.commands.map((c) => c.command).sort();
    assert.deepStrictEqual([...r.comandos.keys()].sort(), declarados);
});

test("'Abrir janelinha' abre de novo", async () => {
    const { r } = await ativar();
    await r.comandos.get("claudeMonitor.openOverlay")();
    assert.strictEqual(spawns().length, 2);
});

test("clique na janelinha (vscode://local.claude-monitor/sessao?id=…) abre a aba da sessão", async () => {
    const { r, pasta } = await ativar();
    const projeto = path.join(os.tmpdir(), "projeto-do-clique");
    r.vscode.workspace.workspaceFolders = [{ uri: { fsPath: projeto } }];
    fs.writeFileSync(path.join(pasta, "sessions", "abc-123.json"), JSON.stringify({
        name: "Minha sessão", cwd: path.join(projeto, "sub"), state: "working", pid: process.pid,
        since: Date.now() / 1000, updated: Date.now() / 1000, entrypoint: "claude-vscode",
    }));
    await r.uri.handleUri({ query: "id=abc-123" });
    assert.deepStrictEqual(r.executados.at(-1), ["claude-vscode.editor.open", "abc-123"]);
    await r.uri.handleUri({ query: "id=nao-existe" });
    assert.ok(r.mensagens.some((m) => m.texto.includes("já fechou")), JSON.stringify(r.mensagens));
});

test("'Usar sons do Minecraft' roda o script certo num terminal", async () => {
    for (const [plataforma, shell, script] of [["win32", "powershell.exe", "extrair_minecraft.ps1"], ["darwin", "/bin/bash", "extrair_minecraft.sh"]]) {
        const { r, pasta } = await ativar({ plataforma });
        r.comandos.get("claudeMonitor.minecraft")();
        const t = r.terminais.at(-1);
        assert.strictEqual(t.shellPath, shell);
        assert.ok(t.shellArgs.includes(path.join(pasta, script)), JSON.stringify(t.shellArgs));
        desativar();
    }
});

test("som: com a janelinha aberta quem toca é ela; sem janelinha, a extensão toca", async () => {
    for (const [overlay, tocaNaExtensao] of [[true, false], [false, true]]) {
        const { r, pasta } = await ativar({ config: { overlay } });
        const arquivo = path.join(pasta, "sessions", "s.json");
        const gravar = (state) => fs.writeFileSync(arquivo, JSON.stringify({ name: "s", cwd: "", state, pid: process.pid, since: Date.now() / 1000, updated: Date.now() / 1000 }));
        gravar("working");
        await r.comandos.get("claudeMonitor.refresh")();
        gravar("waiting");
        await r.comandos.get("claudeMonitor.refresh")();
        const tocou = processos.some((p) => p.tipo === "execFile" && p.cmd === "powershell" && p.args.join(" ").includes("SoundPlayer"));
        assert.strictEqual(tocou, tocaNaExtensao, `overlay=${overlay}`);
        desativar();
    }
});

process.on("exit", () => { cp.spawn = spawnReal; cp.execFile = execFileReal; });
