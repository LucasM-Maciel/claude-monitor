// install.js: mexe no ~/.claude/settings.json do amigo. Não pode perder nada
// dele, nem duplicar, nem estragar o arquivo.
const { test, beforeEach } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

// casa com espaço e acento: o comando do hook tem que sair entre aspas
const casa = fs.mkdtempSync(path.join(os.tmpdir(), "cm install ção-"));
process.env.HOME = casa;
process.env.USERPROFILE = casa;
const install = require("../../extensao/out/install.js");

const SETTINGS = path.join(casa, ".claude", "settings.json");
const EVENTOS = ["UserPromptSubmit", "Stop", "Notification", "SessionEnd"];
const ler = () => JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
const escrever = (o) => {
    fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
    fs.writeFileSync(SETTINGS, typeof o === "string" ? o : JSON.stringify(o, null, 2));
};
const comandosDoMonitor = (s) =>
    EVENTOS.flatMap((e) => (s.hooks[e] ?? []).flatMap((g) => g.hooks.map((h) => h.command))).filter((c) => c.includes(".claude-monitor"));

beforeEach(() => fs.rmSync(path.join(casa, ".claude"), { recursive: true, force: true }));

test("sem settings.json: cria com os 4 hooks", () => {
    assert.strictEqual(install.hooksInstalled(), false);
    install.installHooks();
    const s = ler();
    for (const e of EVENTOS) assert.strictEqual(s.hooks[e].length, 1, e);
    assert.strictEqual(install.hooksInstalled(), true);
});

test("comando com aspas e barra normal (funciona no bash, zsh, cmd e PowerShell)", () => {
    install.installHooks();
    const c = ler().hooks.Stop[0].hooks[0].command;
    assert.match(c, /^node ".+\/\.claude-monitor\/hook\.js" waiting$/);
    assert.ok(!c.includes("\\"), c);
});

test("preserva os hooks e as configurações que o amigo já tinha", () => {
    escrever({
        model: "opus",
        permissions: { allow: ["Bash(git status)"] },
        hooks: {
            Stop: [{ hooks: [{ type: "command", command: "python meu_hook.py" }] }],
            PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "echo oi" }] }],
        },
    });
    install.installHooks();
    const s = ler();
    assert.strictEqual(s.model, "opus");
    assert.deepStrictEqual(s.permissions, { allow: ["Bash(git status)"] });
    assert.strictEqual(s.hooks.PreToolUse[0].hooks[0].command, "echo oi");
    assert.ok(s.hooks.Stop.some((g) => g.hooks.some((h) => h.command === "python meu_hook.py")));
    assert.strictEqual(comandosDoMonitor(s).length, 4);
});

test("rodar 2x não duplica", () => {
    install.installHooks();
    install.installHooks();
    assert.strictEqual(comandosDoMonitor(ler()).length, 4);
});

test("troca o hook antigo do monitor (versão Python) em vez de somar", () => {
    escrever({ hooks: { Stop: [{ hooks: [{ type: "command", command: "python3 ~/.claude/hooks/claude-monitor-hook.py waiting" }] }] } });
    install.installHooks();
    const stop = ler().hooks.Stop.flatMap((g) => g.hooks.map((h) => h.command));
    assert.strictEqual(stop.length, 1);
    assert.match(stop[0], /hook\.js" waiting$/);
});

test("guarda cópia do settings.json de antes", () => {
    escrever({ model: "antes" });
    install.installHooks();
    assert.strictEqual(JSON.parse(fs.readFileSync(`${SETTINGS}.bak-claude-monitor`, "utf8")).model, "antes");
});

test("settings.json quebrado: avisa e NÃO sobrescreve", () => {
    escrever('{"model": "opus",,,');
    assert.throws(() => install.installHooks(), /JSON inválido/);
    assert.strictEqual(fs.readFileSync(SETTINGS, "utf8"), '{"model": "opus",,,');
    assert.strictEqual(install.hooksInstalled(), false);
});

test("copyHookFiles leva hook.js e processes.js pra ~/.claude-monitor", () => {
    install.copyHookFiles(path.join(__dirname, "..", "..", "extensao"));
    for (const f of ["hook.js", "processes.js"]) assert.ok(fs.existsSync(path.join(casa, ".claude-monitor", f)), f);
});
