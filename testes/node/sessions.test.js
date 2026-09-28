// sessions.js: a lista de sessões da barra lateral do VS Code.
const { test, beforeEach } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const casa = fs.mkdtempSync(path.join(os.tmpdir(), "cm-sessions-"));
process.env.HOME = casa;
process.env.USERPROFILE = casa;
const sessions = require("../../extensao/out/sessions.js");

const agora = () => Date.now() / 1000;
const pidMorto = () => spawnSync(process.execPath, ["-e", ""]).pid;
function gravar(id, dados) {
    fs.mkdirSync(sessions.SESS_DIR, { recursive: true });
    fs.writeFileSync(path.join(sessions.SESS_DIR, `${id}.json`), JSON.stringify({ cwd: casa, updated: agora(), ...dados }));
}
beforeEach(() => fs.rmSync(sessions.SESS_DIR, { recursive: true, force: true }));

test("sem pasta de sessões: lista vazia", async () => {
    assert.deepStrictEqual(await sessions.readSessions(), []);
});

test("pid morto sai da lista e o arquivo é apagado", async () => {
    gravar("viva", { name: "viva", state: "working", pid: process.pid });
    gravar("morta", { name: "morta", state: "working", pid: pidMorto() });
    const lista = await sessions.readSessions();
    assert.deepStrictEqual(lista.map((s) => s.name), ["viva"]);
    assert.ok(!fs.existsSync(path.join(sessions.SESS_DIR, "morta.json")));
});

test("mesmo processo com 2 arquivos (/clear): fica o mais novo", async () => {
    gravar("velho", { name: "velho", state: "working", pid: process.pid, updated: agora() - 100 });
    gravar("novo", { name: "novo", state: "waiting", pid: process.pid });
    assert.deepStrictEqual((await sessions.readSessions()).map((s) => s.name), ["novo"]);
});

test("permissão aprovada (transcript mexeu depois) vira 'working'", async () => {
    const t = path.join(casa, "t.jsonl");
    fs.writeFileSync(t, "{}\n");
    gravar("p", { name: "p", state: "permission", pid: process.pid, since: agora() - 600, transcript: t });
    assert.strictEqual((await sessions.readSessions())[0].state, "working");
});

test("permissão ainda aberta continua 'permission'", async () => {
    const t = path.join(casa, "t2.jsonl");
    fs.writeFileSync(t, "{}\n");
    const antes = agora() - 60;
    fs.utimesSync(t, antes, antes);
    gravar("p", { name: "p", state: "permission", pid: process.pid, since: agora(), transcript: t });
    assert.strictEqual((await sessions.readSessions())[0].state, "permission");
});

test("título do transcript ganha do nome gravado; /rename ganha do automático", async () => {
    const t = path.join(casa, "t3.jsonl");
    fs.writeFileSync(t, [
        JSON.stringify({ type: "ai-title", aiTitle: "Automático" }),
        JSON.stringify({ type: "custom-title", customTitle: "Renomeada" }),
    ].join("\n") + "\n");
    gravar("r", { name: "meu-projeto", state: "working", pid: process.pid, transcript: t });
    assert.strictEqual((await sessions.readSessions())[0].name, "Renomeada");
});

test("arquivo quebrado é ignorado sem derrubar a lista", async () => {
    gravar("boa", { name: "boa", state: "working", pid: process.pid });
    fs.writeFileSync(path.join(sessions.SESS_DIR, "ruim.json"), "{quebr");
    assert.deepStrictEqual((await sessions.readSessions()).map((s) => s.name), ["boa"]);
});

test("formatElapsed", () => {
    assert.strictEqual(sessions.formatElapsed(5), "5s");
    assert.strictEqual(sessions.formatElapsed(125), "2min");
    assert.strictEqual(sessions.formatElapsed(3600), "1h");
    assert.strictEqual(sessions.formatElapsed(3 * 3600 + 7 * 60), "3h07");
    assert.strictEqual(sessions.formatElapsed(-10), "0s");
});

test("som: só o 1º que pede toca (várias janelas do VS Code)", () => {
    const s = { id: "som", since: agora() };
    assert.strictEqual(sessions.claimSound(s), true);
    assert.strictEqual(sessions.claimSound(s), false);
});
