// minecraft.js de verdade contra a Mojang de mentira (testes/mojang-falso.js):
// baixa, decodifica e grava sem Minecraft e sem ffmpeg.
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const mojang = require("../mojang-falso");

const MINECRAFT = path.join(__dirname, "..", "..", "extensao", "janelinha", "minecraft.js");
const { baixarTudo, wav, SONS } = require(MINECRAFT);

const pastaNova = () => fs.mkdtempSync(path.join(os.tmpdir(), "cm-mc-"));
function lerWav(dados) {
    const b = Buffer.isBuffer(dados) ? dados : fs.readFileSync(dados);
    return {
        cabecalho: [b.toString("ascii", 0, 4), b.toString("ascii", 8, 16), b.toString("ascii", 36, 40)],
        formato: [b.readUInt16LE(20), b.readUInt16LE(22), b.readUInt32LE(24), b.readUInt16LE(34)],  // PCM, canais, taxa, bits
        amostras: Array.from({ length: b.readUInt32LE(40) / 2 }, (_, i) => b.readInt16LE(44 + 2 * i)),
    };
}
async function comMojang(opcoes, fn) {
    const m = await mojang.iniciar(opcoes);
    process.env.CLAUDE_MONITOR_MOJANG = m.url;
    try {
        return await fn(m);
    } finally {
        delete process.env.CLAUDE_MONITOR_MOJANG;
        await m.fechar();
    }
}
const WAVS = ["xp1", "xp2", "xp3", ...Object.keys(SONS).filter((n) => n !== "xp")].map((n) => `${n}.wav`).sort();
const TEXTURAS = ["picareta", "espada", "diamante", "pedra"];

test("baixa os sons (XP em 3 tons) e as texturas da versão mais nova, e cutuca a janelinha", async () => {
    await comMojang({}, async (m) => {
        const destino = pastaNova();
        const overlay = path.join(destino, "overlay.ps1");
        fs.writeFileSync(overlay, "");
        fs.utimesSync(overlay, new Date(2020, 0, 1), new Date(2020, 0, 1));
        const r = await baixarTudo({ destino });
        assert.deepStrictEqual(r, { versao: "1.99", sons: 12, texturas: 4 });
        assert.deepStrictEqual(fs.readdirSync(path.join(destino, "sons")).sort(), WAVS, "sobrou .novo ou faltou som");
        for (const f of WAVS) {
            const w = lerWav(path.join(destino, "sons", f));
            assert.deepStrictEqual(w.cabecalho, ["RIFF", "WAVEfmt ", "data"], f);
            assert.deepStrictEqual(w.formato, [1, 1, 44100, 16], f);
        }
        // o bip tem 0,25 s a 48 kHz: tom 1 dá 0,25 s a 44100; o XP grave (0,8) dura mais, o agudo (1,25) menos
        const duracao = (f) => lerWav(path.join(destino, "sons", f)).amostras.length / 44100;
        assert.ok(Math.abs(duracao("pop.wav") - 0.25) < 0.001, duracao("pop.wav"));
        assert.ok(Math.abs(duracao("xp1.wav") - 0.25 / 0.8) < 0.001, duracao("xp1.wav"));
        assert.ok(Math.abs(duracao("xp3.wav") - 0.25 / 1.25) < 0.001, duracao("xp3.wav"));
        for (const t of TEXTURAS) assert.ok(fs.readFileSync(path.join(destino, `${t}.png`)).equals(mojang.MAGENTA), t);
        assert.ok(fs.statSync(overlay).mtime.getFullYear() > 2020, "não cutucou a janelinha pra recarregar");
        const doJar = m.pedidos.filter((p) => p.startsWith("/client.jar"));
        assert.ok(doJar.length && doJar.every((p) => / bytes=\d+-\d+$/.test(p)), `baixou o jar inteiro: ${doJar}`);
        assert.ok(!m.pedidos.includes("/errada.json"), "pegou o snapshot em vez da versão mais nova");
    });
});

test("wav(): junta os canais, 80% do volume, e o tom muda a duração como no jogo", () => {
    const seno = Float32Array.from({ length: 4410 }, (_, i) => Math.sin((2 * Math.PI * 441 * i) / 44100));
    const igual = lerWav(wav([seno, seno], 44100));
    assert.strictEqual(igual.amostras.length, 4410);
    assert.ok(Math.abs(Math.max(...igual.amostras) - 0.8 * 32767) < 40, Math.max(...igual.amostras));
    // um canal o contrário do outro: a mistura é silêncio
    assert.ok(lerWav(wav([seno, seno.map((x) => -x)], 44100)).amostras.every((a) => a === 0));
    // tom 2: metade do tempo, o dobro de passagens por zero
    const zeros = (a) => a.slice(1).filter((x, i) => (x >= 0) !== (a[i] >= 0)).length;
    const agudo = lerWav(wav([seno], 44100, 2));
    assert.strictEqual(agudo.amostras.length, 2205);
    assert.ok(Math.abs(zeros(agudo.amostras) - zeros(igual.amostras)) <= 2, `${zeros(agudo.amostras)} x ${zeros(igual.amostras)}`);
    // de 22050 pra 44100: o dobro de amostras
    assert.strictEqual(lerWav(wav([seno], 22050)).amostras.length, 8820);
});

test("som que não está no índice só avisa; os outros baixam", async () => {
    await comMojang({ faltando: ["random/levelup"] }, async () => {
        const destino = pastaNova();
        const log = [];
        const r = await baixarTudo({ destino, log: (t) => log.push(t) });
        assert.strictEqual(r.sons, 11);
        assert.ok(!fs.existsSync(path.join(destino, "sons", "levelup.wav")));
        assert.ok(log.some((l) => /aviso: levelup \(random\/levelup\) não está no Minecraft 1\.99/.test(l)), log.join("\n"));
    });
});

test("servidor que ignora Range: sons sim, texturas não (nem lê o jar inteiro)", async () => {
    await comMojang({ semRange: true }, async () => {
        const destino = pastaNova();
        const log = [];
        const r = await baixarTudo({ destino, log: (t) => log.push(t) });
        assert.strictEqual(r.sons, 12);
        assert.strictEqual(r.texturas, 0);
        assert.ok(log.some((l) => /aviso: texturas: .*HTTP 200/.test(l)), log.join("\n"));
        for (const t of TEXTURAS) assert.ok(!fs.existsSync(path.join(destino, `${t}.png`)), t);
    });
});

test("arquivo de som estragado: avisa, não grava nada e não cutuca a janelinha", async () => {
    await comMojang({ lixo: true, semRange: true }, async () => {
        const destino = pastaNova();
        const overlay = path.join(destino, "overlay.ps1");
        fs.writeFileSync(overlay, "");
        fs.utimesSync(overlay, new Date(2020, 0, 1), new Date(2020, 0, 1));
        const log = [];
        const r = await baixarTudo({ destino, log: (t) => log.push(t) });
        assert.strictEqual(r.sons, 0);
        assert.deepStrictEqual(fs.readdirSync(path.join(destino, "sons")), []);
        assert.ok(log.filter((l) => l.startsWith("aviso: ")).length >= 10, log.join("\n"));
        assert.strictEqual(fs.statSync(overlay).mtime.getFullYear(), 2020);
    });
});

test("sem internet: rejeita com o motivo e não cria nada", async () => {
    const m = await mojang.iniciar();
    await m.fechar();  // porta que acabou de fechar: ninguém atende
    process.env.CLAUDE_MONITOR_MOJANG = m.url;
    try {
        const destino = pastaNova();
        await assert.rejects(baixarTudo({ destino }), /ECONNREFUSED|connect/);
        assert.deepStrictEqual(fs.readdirSync(destino), []);
    } finally {
        delete process.env.CLAUDE_MONITOR_MOJANG;
    }
});

/** node minecraft.js numa casa de mentira (assíncrono: o servidor de mentira roda neste processo) */
function rodarCli(url) {
    const casa = pastaNova();
    return new Promise((ok) => cp.execFile(process.execPath, [MINECRAFT], {
        env: { ...process.env, HOME: casa, USERPROFILE: casa, CLAUDE_MONITOR_MOJANG: url },
    }, (erro, saida) => ok({ codigo: erro ? erro.code : 0, saida, casa })));
}

test("pelo terminal (o instalador): diz o que baixou e termina com \"Pronto!\"", async () => {
    await comMojang({}, async (m) => {
        const r = await rodarCli(m.url);
        assert.strictEqual(r.codigo, 0, r.saida);
        assert.match(r.saida, /xp1\.wav[\s\S]*picareta\.png[\s\S]*Pronto! A janelinha já está com os sons do Minecraft 1\.99/);
        assert.ok(fs.existsSync(path.join(r.casa, ".claude-monitor", "sons", "levelup.wav")));
    });
});

test("pelo terminal, sem internet: explica como tentar de novo e sai com erro", async () => {
    const m = await mojang.iniciar();
    await m.fechar();
    const r = await rodarCli(m.url);
    assert.strictEqual(r.codigo, 1, r.saida);
    assert.match(r.saida, /Não consegui falar com o servidor da Mojang/);
    assert.match(r.saida, /Claude Monitor: Usar sons do Minecraft/);
    assert.doesNotMatch(r.saida, /Pronto!/);
});
