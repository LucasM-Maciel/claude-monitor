// Monta uma ~/.claude-monitor de mentira pra testar a janelinha (Windows e Mac
// usam os mesmos cenários) e grava o que ela TEM que mostrar em esperado.txt,
// no mesmo formato do .txt que ela escreve no modo --foto/-Foto.
//
// Uso: node testes/cenarios.js <pasta> <misto|andando|parado|vazio|levelup|xp-rodando|xp-esperando|aldeao|clique|pedra|bug> <pid vivo>
//   <pid vivo>: um processo que fica aberto durante o teste (o shell do teste).
//
// O "misto" junta os casos que já deram ou podem dar errado:
//  - 1ª mensagem sem título: o hook grava o nome da pasta ("meu-projeto"); vale o do transcript
//  - /rename ganha do título automático, mesmo vindo antes
//  - permissão aprovada (transcript mexeu depois do pedido) = trabalhando
//  - pergunta no fim do texto (em negrito, ou seguida de uma frase), "?" em citação
//    (aspas/crases) não conta, caixinha aberta, caixinha já respondida
//  - texto de subagente (isSidechain) não conta
//  - transcript > 64 KB (a leitura do fim corta a 1ª linha no meio)
//  - acento e emoji; transcript que sumiu
//  - fora da lista: pid morto, sessão velha sem pid, duplicada do mesmo pid,
//    arquivo quebrado e arquivo que não é .json
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const [pasta, cenario, pidVivoTexto] = process.argv.slice(2);
const pidVivo = Number(pidVivoTexto);
if (!pasta || !cenario || !pidVivo) {
    console.error("uso: node testes/cenarios.js <pasta> <cenario> <pid vivo>");
    process.exit(2);
}
const agora = Date.now() / 1000;
const dirSessoes = path.join(pasta, "sessions");
const dirTranscripts = path.join(pasta, "transcripts");
fs.rmSync(pasta, { recursive: true, force: true });
fs.mkdirSync(dirTranscripts, { recursive: true });

// --- linhas de transcript, no formato do Claude Code (JSON compacto, uma por linha)
const titulo = (t) => ({ type: "ai-title", aiTitle: t, sessionId: "x" });
const renomeado = (t) => ({ type: "custom-title", customTitle: t, sessionId: "x" });
const pergunta = (texto) => ({ type: "user", isSidechain: false, message: { role: "user", content: texto } });
const texto = (t, extra = {}) => ({
    type: "assistant", isSidechain: false, ...extra,
    message: { role: "assistant", content: [{ type: "text", text: t }] },
});
const ferramenta = (nome, id = "t1") => ({
    type: "assistant", isSidechain: false,
    message: { role: "assistant", content: [{ type: "tool_use", id, name: nome, input: {} }] },
});
const resultado = (id = "t1") => ({
    type: "user", isSidechain: false,
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: "ok" }] },
});
const enchimento = () => texto("x".repeat(100 * 1024));  // uma linha de 100 KB

const esperado = [];
const antes = {};  // id -> situação na leitura anterior (vira antes.json: decide o som)
let ordem = 0;
/**
 * Cria a sessão. `mostra` = [nome, situação] que a janelinha tem que mostrar
 * (null = não pode aparecer). Quanto antes criada, mais em cima (updated maior).
 * `antes` = situação que a janelinha tinha visto antes (pra testar o som da mudança).
 */
function sessao(id, { estado, linhas, nomeNoArquivo, pid, updated, since, mexeuEm, semTranscript, mostra, antes: situacaoAntes }) {
    fs.mkdirSync(dirSessoes, { recursive: true });
    ordem += 1;
    if (situacaoAntes) antes[id] = situacaoAntes;
    const transcript = path.join(dirTranscripts, `${id}.jsonl`);
    if (linhas && !semTranscript) {
        fs.writeFileSync(transcript, linhas.map((l) => JSON.stringify(l)).join("\n") + "\n");
        if (mexeuEm) fs.utimesSync(transcript, mexeuEm, mexeuEm);
    }
    const u = updated ?? agora - ordem;
    fs.writeFileSync(path.join(dirSessoes, `${id}.json`), JSON.stringify({
        name: nomeNoArquivo ?? "meu-projeto",
        cwd: "C:\\Users\\amigo\\projetos\\meu-projeto",
        state: estado,
        since: since ?? u,
        updated: u,
        ...(pid ? { pid } : {}),
        entrypoint: "claude-vscode",
        transcript,
    }));
    if (mostra) esperado.push({ updated: u, linha: `sessao: ${mostra[0]} | hook=${estado} | janelinha=${mostra[1]}` });
}

function pidMorto() {
    return spawnSync(process.execPath, ["-e", ""]).pid;  // já terminou quando volta
}

function uso(cinco, sete) {
    const daqui = (min) => new Date(Date.now() + min * 60000).toISOString().replace("Z", "+00:00");
    fs.writeFileSync(path.join(pasta, "uso.json"), JSON.stringify({
        five_hour: { utilization: cinco, resets_at: daqui(90) },
        seven_day: { utilization: sete, resets_at: daqui(3 * 1440 + 60) },
    }));
}

let clawd;
let temUso = false;
let som = "nenhum";  // o que a janelinha tocaria: nenhum, xp, aldeao ou levelup
let clique = "nenhum";  // o link que o clique abriria (a sessão a clicar vai em clicar.txt)
if (cenario === "misto") {
    sessao("renomeada", {
        estado: "working", mostra: ["Minha sessão renomeada", "working"],
        linhas: [titulo("Título automático"), renomeado("Minha sessão renomeada"), titulo("Outro automático"),
            pergunta("roda os testes"), ferramenta("Bash")],
    });
    sessao("permissao-aprovada", {
        estado: "permission", since: agora - 600, mexeuEm: agora, mostra: ["Permissão já aprovada", "working"],
        linhas: [titulo("Permissão já aprovada"), ferramenta("Bash")],
    });
    sessao("permissao-aberta", {
        estado: "permission", since: agora - 5, mexeuEm: agora - 60, mostra: ["Pedindo permissão agora", "permission"],
        linhas: [titulo("Pedindo permissão agora"), ferramenta("Bash")],
    });
    sessao("pergunta-texto", {
        estado: "waiting", mostra: ["Pergunta no fim do texto", "question"],
        linhas: [titulo("Pergunta no fim do texto"), enchimento(), enchimento(),
            texto("Fiz as mudanças.\n\nPosso seguir com o deploy?\n")],
    });
    sessao("pergunta-e-frase", {  // pergunta seguida de contexto continua sendo pergunta
        estado: "waiting", mostra: ["Pergunta seguida de frase", "question"],
        linhas: [titulo("Pergunta seguida de frase"),
            texto("Renomeei o repositório.\n\nQuer o nome novo também no produto? Por enquanto só o repositório mudou.")],
    });
    sessao("pergunta-negrito", {
        estado: "waiting", mostra: ["Pergunta em negrito", "question"],
        linhas: [titulo("Pergunta em negrito"), texto("Pronto.\n\n**Posso seguir com o deploy?**  \n")],
    });
    sessao("citacao", {  // "?" entre aspas/crases é fala citada, não pergunta pra você
        estado: "waiting", mostra: ["Citação com interrogação", "finished"],
        linhas: [titulo("Citação com interrogação"),
            texto("Feito.\n\nTestei o \"consegue vir?\", o “Tem Voyage?” e o `troca?`, 3 rodadas cada.")],
    });
    sessao("terminou", {
        estado: "waiting", mostra: ["Terminou", "finished"],
        linhas: [titulo("Terminou"), texto("Quer que eu rode os testes?"), pergunta("sim"), texto("Pronto, tudo verde.")],
    });
    sessao("caixa", {
        estado: "working", mostra: ["Caixinha aberta", "question"],
        linhas: [titulo("Caixinha aberta"), ferramenta("AskUserQuestion")],
    });
    sessao("caixa-respondida", {
        estado: "waiting", mostra: ["Caixinha respondida", "finished"],
        linhas: [titulo("Caixinha respondida"), ferramenta("AskUserQuestion"), resultado()],
    });
    sessao("subagente", {
        estado: "waiting", mostra: ["Com subagente", "finished"],
        linhas: [titulo("Com subagente"), texto("Feito."), texto("Quer mais alguma coisa?", { isSidechain: true })],
    });
    sessao("sem-transcript", {
        estado: "waiting", nomeNoArquivo: "sem-transcript", semTranscript: true, linhas: [],
        mostra: ["sem-transcript", "finished"],
    });
    sessao("acentos", {
        estado: "working", mostra: ["Ação com acentuação ✓ e emoji 🚀", "working"],
        linhas: [titulo("Ação com acentuação ✓ e emoji 🚀"), ferramenta("Edit")],
    });
    sessao("duplicada-nova", {
        estado: "waiting", pid: pidVivo, mostra: ["Duplicada nova", "finished"],
        linhas: [titulo("Duplicada nova"), texto("ok")],
    });
    sessao("duplicada-velha", { estado: "working", pid: pidVivo, linhas: [titulo("Duplicada velha")] });
    sessao("pid-morto", { estado: "working", pid: pidMorto(), linhas: [titulo("Pid morto")] });
    sessao("velha", { estado: "waiting", updated: agora - 7 * 3600, linhas: [titulo("Velha sem pid")] });
    fs.writeFileSync(path.join(dirSessoes, "quebrada.json"), '{"name": "quebr');
    fs.writeFileSync(path.join(dirSessoes, "lixo.txt"), "não sou sessão");
    clawd = "pulando";  // pergunta/permissão ganha de trabalhando
    uso(42.4, 85);
    temUso = true;
} else if (cenario === "andando") {
    sessao("a", { estado: "working", mostra: ["Rodando testes", "working"], linhas: [titulo("Rodando testes"), ferramenta("Bash")] });
    sessao("b", { estado: "working", mostra: ["Escrevendo código", "working"], linhas: [titulo("Escrevendo código"), ferramenta("Edit")] });
    clawd = "andando";
    uso(97, 30);
    temUso = true;
} else if (cenario === "parado") {
    sessao("a", { estado: "waiting", mostra: ["Tudo pronto", "finished"], linhas: [titulo("Tudo pronto"), texto("Feito.")] });
    clawd = "parado";
} else if (cenario === "demo") {  // o print do README
    sessao("a", { estado: "working", mostra: ["Corrigir o login do app", "working"], linhas: [titulo("Corrigir o login do app"), ferramenta("Edit")] });
    sessao("b", { estado: "waiting", mostra: ["Página de preços", "question"], linhas: [titulo("Página de preços"), texto("Deixei 3 opções de layout. Qual você prefere?")] });
    sessao("c", { estado: "permission", since: agora - 5, mexeuEm: agora - 60, mostra: ["Migrar o banco pro Postgres", "permission"], linhas: [titulo("Migrar o banco pro Postgres"), ferramenta("Bash")] });
    sessao("d", { estado: "waiting", since: agora - 1500, mostra: ["Testes do checkout", "finished"], linhas: [titulo("Testes do checkout"), texto("Pronto: 48 testes passando.")] });
    clawd = "pulando";
    uso(38, 64);
    temUso = true;
} else if (cenario === "vazio") {
    clawd = "parado";  // sem pasta sessions nenhuma
} else if (cenario === "levelup") {  // a última terminou e não sobrou nada: sobe de nível
    sessao("a", { estado: "waiting", antes: "working", mostra: ["Deploy pronto", "finished"], linhas: [titulo("Deploy pronto"), texto("Feito.")] });
    sessao("b", { estado: "waiting", antes: "finished", mostra: ["Testes verdes", "finished"], linhas: [titulo("Testes verdes"), texto("Pronto.")] });
    clawd = "parado";
    som = "levelup";
} else if (cenario === "xp-rodando") {  // terminou uma, outra ainda roda: só XP
    sessao("a", { estado: "waiting", antes: "working", mostra: ["Deploy pronto", "finished"], linhas: [titulo("Deploy pronto"), texto("Feito.")] });
    sessao("b", { estado: "working", antes: "working", mostra: ["Ainda rodando", "working"], linhas: [titulo("Ainda rodando"), ferramenta("Bash")] });
    clawd = "andando";
    som = "xp";
} else if (cenario === "xp-esperando") {  // terminou uma, outra espera você: só XP
    sessao("a", { estado: "waiting", antes: "working", mostra: ["Deploy pronto", "finished"], linhas: [titulo("Deploy pronto"), texto("Feito.")] });
    sessao("b", { estado: "waiting", antes: "question", mostra: ["Esperando você", "question"], linhas: [titulo("Esperando você"), texto("Posso seguir?")] });
    clawd = "pulando";
    som = "xp";
} else if (cenario === "aldeao") {  // terminou e perguntou juntas: o aldeão ganha
    sessao("a", { estado: "waiting", antes: "working", mostra: ["Deploy pronto", "finished"], linhas: [titulo("Deploy pronto"), texto("Feito.")] });
    sessao("b", { estado: "waiting", antes: "working", mostra: ["Esperando você", "question"], linhas: [titulo("Esperando você"), texto("Posso seguir?")] });
    clawd = "pulando";
    som = "aldeao";
} else if (cenario === "clique") {  // clique na do meio: acha a linha certa e manda o id dela
    sessao("0a1b-primeira", { estado: "waiting", mostra: ["Primeira", "finished"], linhas: [titulo("Primeira"), texto("Feito.")] });
    sessao("2c3d-meio", { estado: "working", mostra: ["A do meio", "working"], linhas: [titulo("A do meio"), ferramenta("Bash")] });
    sessao("4e5f-ultima", { estado: "waiting", mostra: ["Última", "finished"], linhas: [titulo("Última"), texto("Pronto.")] });
    fs.writeFileSync(path.join(pasta, "clicar.txt"), "2c3d-meio");
    clique = "vscode://local.claude-monitor/sessao?id=2c3d-meio";
    clawd = "andando";
} else if (cenario === "pedra" || cenario === "bug") {  // no meio da luta: o diamante subindo / o bug apanhando
    sessao("a", { estado: "working", mostra: ["Rodando testes", "working"], linhas: [titulo("Rodando testes"), ferramenta("Bash")] });
    fs.writeFileSync(path.join(pasta, "cena.txt"), cenario === "pedra" ? "pedra 2.1" : "bug 1.5");
    clawd = `andando (${cenario})`;
} else {
    console.error(`cenário desconhecido: ${cenario}`);
    process.exit(2);
}

if (Object.keys(antes).length) fs.writeFileSync(path.join(pasta, "antes.json"), JSON.stringify(antes));
const linhas = esperado.sort((a, b) => b.updated - a.updated).map((e) => e.linha);
linhas.push(`clawd: ${clawd}`, `usage: ${temUso ? "ok" : "indisponivel"}`, `som: ${som}`, `clique: ${clique}`);
fs.writeFileSync(path.join(pasta, "esperado.txt"), linhas.join("\n") + "\n");
console.log(linhas.join("\n"));
