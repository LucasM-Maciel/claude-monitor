// hook.js: o que o Claude Code roda a cada evento. Não pode travar o Claude
// nunca, e tem que gravar o estado certo.
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const HOOK = path.join(__dirname, "..", "..", "extensao", "out", "hook.js");

function casaNova() {
    return fs.mkdtempSync(path.join(os.tmpdir(), "cm hook ção-"));  // espaço e acento de propósito
}
function rodar(casa, evento, dados, env = {}) {
    const r = spawnSync(process.execPath, [HOOK, evento], {
        input: typeof dados === "string" ? dados : JSON.stringify(dados),
        env: { ...process.env, HOME: casa, USERPROFILE: casa, CLAUDE_PID: String(process.pid), ...env },
        encoding: "utf8",
        timeout: 15000,
    });
    assert.strictEqual(r.status, 0, `hook saiu com ${r.status}: ${r.stderr}`);
    return r;
}
function sessao(casa, id) {
    return JSON.parse(fs.readFileSync(path.join(casa, ".claude-monitor", "sessions", `${id}.json`), "utf8"));
}
function transcript(casa, linhas) {
    const f = path.join(casa, "t.jsonl");
    fs.writeFileSync(f, linhas.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return f;
}

test("UserPromptSubmit grava 'working' com pid, pasta e nome da pasta", () => {
    const casa = casaNova();
    rodar(casa, "working", { session_id: "s1", cwd: path.join(casa, "meu-projeto") });
    const s = sessao(casa, "s1");
    assert.strictEqual(s.state, "working");
    assert.strictEqual(s.name, "meu-projeto");
    assert.strictEqual(s.pid, process.pid);
    assert.ok(Math.abs(s.since - Date.now() / 1000) < 30);
});

test("nome vem do transcript: /rename ganha do título automático", () => {
    const casa = casaNova();
    const t = transcript(casa, [
        { type: "custom-title", customTitle: "Renomeada", sessionId: "s1" },
        { type: "ai-title", aiTitle: "Automático", sessionId: "s1" },
    ]);
    rodar(casa, "working", { session_id: "s1", cwd: casa, transcript_path: t });
    assert.strictEqual(sessao(casa, "s1").name, "Renomeada");
});

test("título de outra sessão no mesmo transcript não vale", () => {
    const casa = casaNova();
    const t = transcript(casa, [
        { type: "ai-title", aiTitle: "Minha", sessionId: "s1" },
        { type: "ai-title", aiTitle: "De outra", sessionId: "s2" },
    ]);
    rodar(casa, "working", { session_id: "s1", cwd: casa, transcript_path: t });
    assert.strictEqual(sessao(casa, "s1").name, "Minha");
});

test("Stop vira 'waiting'; aviso de ociosidade depois não reinicia o relógio", () => {
    const casa = casaNova();
    rodar(casa, "waiting", { session_id: "s1", cwd: casa });
    const antes = sessao(casa, "s1").since;
    rodar(casa, "notification", { session_id: "s1", cwd: casa, message: "Claude is waiting for your input" });
    const s = sessao(casa, "s1");
    assert.strictEqual(s.state, "waiting");
    assert.strictEqual(s.since, antes);
});

test("pedido de permissão vira 'permission' (pela mensagem, pelo tipo e por elicitation)", () => {
    for (const dados of [
        { message: "Claude needs your permission to use Bash" },
        { notification_type: "permission_prompt", message: "x" },
        { notification_type: "elicitation_dialog", message: "x" },
    ]) {
        const casa = casaNova();
        rodar(casa, "notification", { session_id: "s1", cwd: casa, ...dados });
        assert.strictEqual(sessao(casa, "s1").state, "permission", JSON.stringify(dados));
    }
});

test("2º pedido de permissão seguido reinicia o relógio (senão o transcript do trabalho entre os dois vira 'working')", () => {
    const casa = casaNova();
    const pedido = { session_id: "s1", cwd: casa, notification_type: "permission_prompt", message: "x" };
    rodar(casa, "notification", pedido);
    const antes = sessao(casa, "s1").since;
    rodar(casa, "notification", pedido);  // aprovou o 1º, ela trabalhou e pediu de novo: nenhum hook no meio
    const s = sessao(casa, "s1");
    assert.strictEqual(s.state, "permission");
    assert.ok(s.since > antes, `since ${s.since} devia passar de ${antes}`);
});

test("SessionEnd apaga a sessão", () => {
    const casa = casaNova();
    rodar(casa, "working", { session_id: "s1", cwd: casa });
    rodar(casa, "end", { session_id: "s1" });
    assert.ok(!fs.existsSync(path.join(casa, ".claude-monitor", "sessions", "s1.json")));
});

test("pid fica o mesmo a sessão inteira (não recalcula a cada evento)", () => {
    const casa = casaNova();
    rodar(casa, "working", { session_id: "s1", cwd: casa });
    rodar(casa, "waiting", { session_id: "s1", cwd: casa }, { CLAUDE_PID: "12345" });
    assert.strictEqual(sessao(casa, "s1").pid, process.pid);
});

test("entrada quebrada ou vazia não derruba o hook", () => {
    const casa = casaNova();
    rodar(casa, "working", "isso não é json");
    rodar(casa, "working", "");
    assert.strictEqual(sessao(casa, "unknown").state, "working");
});

test("hook nunca falha, nem com a pasta de casa impossível de usar", () => {
    const casa = casaNova();
    const arquivo = path.join(casa, "sou-um-arquivo");
    fs.writeFileSync(arquivo, "x");
    rodar(arquivo, "working", { session_id: "s1", cwd: casa });  // .claude-monitor dentro de um ARQUIVO
});

test("hook é rápido (o UserPromptSubmit segura o Claude enquanto roda)", () => {
    const casa = casaNova();
    const inicio = Date.now();
    rodar(casa, "working", { session_id: "s1", cwd: casa });
    assert.ok(Date.now() - inicio < 3000, `demorou ${Date.now() - inicio} ms`);
});
