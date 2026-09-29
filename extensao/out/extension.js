"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const vscode = __importStar(require("vscode"));
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const child_process_1 = require("child_process");
const sessions_1 = require("./sessions");
const processes_1 = require("./processes");
const install_1 = require("./install");
const POLL_MS = 1000;
// ordem na lista: o mais urgente em cima
const PRIORITY = { permission: 0, waiting: 1, working: 2, seen: 3 };
const LOOK = {
    permission: { icon: "shield", color: "charts.orange", label: "pedindo permissão" },
    waiting: { icon: "bell-dot", color: "charts.red", label: "esperando você" },
    working: { icon: "sync~spin", color: "charts.green", label: "trabalhando" },
    seen: { icon: "circle-outline", color: "disabledForeground", label: "parado" },
};
let sessions = [];
const lastStates = new Map();
const seen = new Map(); // session id -> `since` do estado já visto
function displayState(s) {
    return s.state === "waiting" && seen.get(s.id) === s.since ? "seen" : s.state;
}
function projectName(s) {
    return path.basename(s.cwd.replace(/[\\/]+$/, "")) || s.cwd;
}
/** Sessão aberta no painel do Claude Code do VSCode (não num terminal). */
function isPanelSession(s) {
    return !!s.entrypoint && (s.entrypoint.includes("vscode") || s.entrypoint === "sdk-ts");
}
class SessionItem extends vscode.TreeItem {
    session;
    constructor(session) {
        super(session.name, vscode.TreeItemCollapsibleState.None);
        this.session = session;
        const state = displayState(session);
        const look = LOOK[state];
        const elapsed = (0, sessions_1.formatElapsed)(Date.now() / 1000 - session.since);
        this.description = `${look.label} há ${elapsed} · ${projectName(session)}`;
        this.tooltip = new vscode.MarkdownString(`**${session.name}**\n\n${look.label} há ${elapsed}\n\n\`${session.cwd}\`` +
            (isPanelSession(session) ? "\n\npainel do Claude no VSCode" : "\n\nterminal"));
        this.iconPath = new vscode.ThemeIcon(look.icon, look.color ? new vscode.ThemeColor(look.color) : undefined);
        this.command = { command: "claudeMonitor.focusSession", title: "Focar sessão", arguments: [session] };
        this.contextValue = state === "waiting" ? "claudeSession.unseen" : "claudeSession";
    }
}
class SessionsProvider {
    _onDidChangeTreeData = new vscode.EventEmitter();
    onDidChangeTreeData = this._onDidChangeTreeData.event;
    refresh() {
        this._onDidChangeTreeData.fire();
    }
    getTreeItem(element) {
        return element;
    }
    getChildren() {
        if (sessions.length === 0) {
            const empty = new vscode.TreeItem("Nenhuma sessão ativa");
            empty.iconPath = new vscode.ThemeIcon("circle-slash");
            return [empty];
        }
        return sessions.map((s) => new SessionItem(s));
    }
}
// --- Janelinha: fora do VS Code, sempre por cima, com sessões + usage + Clawd ---
// Windows: overlay.ps1 (PowerShell/WPF, já vem no Windows). Mac: overlay.swift,
// compilado aqui na 1ª vez (precisa das ferramentas de linha de comando da Apple).
const JANELINHA = {
    win32: ["overlay.ps1", "extrair_minecraft.ps1"],
    darwin: ["overlay.swift", "extrair_minecraft.sh"],
};
const BINARIO_MAC = path.join(sessions_1.MONITOR_DIR, "ClaudeMonitor");
let janelinhaAberta = false; // com ela aberta quem toca o som é ela
/** Diário da janelinha (a do Windows também anota nele): quem copiou, quem abriu. */
function anotar(texto) {
    const diario = path.join(sessions_1.MONITOR_DIR, "janelinha.log");
    try {
        if (fs.existsSync(diario) && fs.statSync(diario).size > 256 * 1024)
            fs.renameSync(diario, `${diario}.1`);
        const d = new Date();
        const hora = `${d.toLocaleString("sv-SE")}.${String(d.getMilliseconds()).padStart(3, "0")}`;
        fs.appendFileSync(diario, `${hora} [${vscode.env.appName ?? "extensão"} ${process.pid}] ${texto}${require("os").EOL}`);
    }
    catch {
        // sem diário, segue
    }
}
function janelinhaLigada() {
    return !!JANELINHA[process.platform] && vscode.workspace.getConfiguration("claudeMonitor").get("overlay", true);
}
/**
 * Copia os arquivos da janelinha pra ~/.claude-monitor quando a extensão muda
 * de versão (entre uma versão e outra dá pra mexer neles lá). A janelinha
 * aberta vê o arquivo novo e se reabre sozinha.
 */
function copiarJanelinha(context) {
    const arquivos = JANELINHA[process.platform];
    if (!arquivos)
        return;
    const marca = path.join(sessions_1.MONITOR_DIR, "versao-janelinha");
    const versao = context.extension.packageJSON.version;
    let copiada = "";
    try {
        copiada = fs.readFileSync(marca, "utf8").trim();
    }
    catch {
        // 1ª vez
    }
    if (copiada === versao && arquivos.every((f) => fs.existsSync(path.join(sessions_1.MONITOR_DIR, f))))
        return;
    const agora = new Date();
    for (const f of arquivos) {
        const destino = path.join(sessions_1.MONITOR_DIR, f);
        fs.copyFileSync(path.join(context.extensionPath, "janelinha", f), destino);
        fs.utimesSync(destino, agora, agora);
    }
    fs.writeFileSync(marca, versao);
    anotar(`copiou a janelinha ${versao} (antes: ${copiada || "nenhuma"})`);
}
/**
 * O instalador troca a extensão, mas a janela aberta segue com a velha até
 * recarregar (29/09: o clique "não funcionava" porque o VS Code rodava a anterior).
 * A marca da janelinha diz a versão instalada: mais nova que esta, oferece
 * recarregar, uma vez. Sozinho não: derrubaria o Claude trabalhando na janela.
 */
let avisouAtualizacao = false;
function conferirAtualizacao(versao) {
    if (avisouAtualizacao)
        return;
    let instalada = "";
    try {
        instalada = fs.readFileSync(path.join(sessions_1.MONITOR_DIR, "versao-janelinha"), "utf8").trim();
    }
    catch {
        return;
    }
    if (instalada.localeCompare(versao, undefined, { numeric: true }) <= 0)
        return;
    avisouAtualizacao = true;
    vscode.window
        .showInformationMessage(`Claude Monitor atualizou pra ${instalada}. Recarregar a janela pra usar? (o Claude que estiver trabalhando nela para)`, "Recarregar")
        .then((escolha) => {
        if (escolha === "Recarregar")
            vscode.commands.executeCommand("workbench.action.reloadWindow");
    });
}
/** Mac: compila overlay.swift quando o binário não existe ou ficou mais velho que ele. */
function compilarMac() {
    const fonte = path.join(sessions_1.MONITOR_DIR, "overlay.swift");
    return new Promise((resolve, reject) => {
        try {
            if (fs.statSync(BINARIO_MAC).mtimeMs >= fs.statSync(fonte).mtimeMs)
                return resolve();
        }
        catch {
            // ainda não compilado
        }
        // outra janela do VS Code pode estar compilando junto: cada uma no seu arquivo
        const temp = `${BINARIO_MAC}.${process.pid}.novo`;
        (0, child_process_1.execFile)("xcrun", ["swiftc", "-swift-version", "5", "-O", "-o", temp, fonte], { timeout: 300000 }, (err, _out, stderr) => {
            if (err)
                return reject(new Error(stderr || err.message));
            fs.renameSync(temp, BINARIO_MAC); // troca de uma vez: a aberta se reabre com a nova
            resolve();
        });
    });
}
async function abrirJanelinha() {
    if (process.platform === "win32") {
        const ps1 = path.join(sessions_1.MONITOR_DIR, "overlay.ps1");
        if (!fs.existsSync(ps1))
            return;
        // via "cmd start": powershell aberto direto com detached morre na hora.
        // overlay.ps1 garante uma só.
        (0, child_process_1.spawn)("cmd.exe", ["/c", "start", '""', "/min", "powershell.exe", "-WindowStyle", "Hidden", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1], { detached: true, stdio: "ignore", windowsHide: true }).unref();
        anotar("mandou abrir a janelinha");
        janelinhaAberta = true;
    }
    else if (process.platform === "darwin") {
        if (!(await (0, sessions_1.run)("xcode-select", ["-p"]))) {
            const escolha = await vscode.window.showWarningMessage("Claude Monitor: a janelinha no Mac precisa das ferramentas de linha de comando da Apple (uns minutos, uma vez só). Depois de instalar, reabra o VS Code.", "Instalar", "Não usar a janelinha");
            if (escolha === "Instalar")
                (0, child_process_1.execFile)("xcode-select", ["--install"], () => { });
            else if (escolha === "Não usar a janelinha")
                vscode.workspace.getConfiguration("claudeMonitor").update("overlay", false, vscode.ConfigurationTarget.Global);
            return;
        }
        try {
            const compilando = compilarMac();
            vscode.window.setStatusBarMessage("$(sync~spin) Claude Monitor: preparando a janelinha…", compilando);
            await compilando;
        }
        catch (err) {
            vscode.window.showErrorMessage(`Claude Monitor: não consegui compilar a janelinha (${err.message.slice(0, 300)})`);
            return;
        }
        // o binário garante um só (trava em ~/.claude-monitor/overlay.lock)
        (0, child_process_1.spawn)(BINARIO_MAC, [], { detached: true, stdio: "ignore" }).unref();
        janelinhaAberta = true;
    }
}
/** Sons e picareta do Minecraft instalado; roda num terminal pra ver o que aconteceu. */
function usarMinecraft() {
    const win = process.platform === "win32";
    const script = path.join(sessions_1.MONITOR_DIR, win ? "extrair_minecraft.ps1" : "extrair_minecraft.sh");
    const terminal = win
        ? vscode.window.createTerminal({ name: "Claude Monitor — Minecraft", shellPath: "powershell.exe", shellArgs: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script] })
        : vscode.window.createTerminal({ name: "Claude Monitor — Minecraft", shellPath: "/bin/bash", shellArgs: [script] });
    terminal.show();
}
/** Os hooks rodam `node`: sem Node.js instalado o Claude Code não avisa ninguém. */
async function conferirNode() {
    const achou = await new Promise((resolve) => (0, child_process_1.execFile)(process.platform === "win32" ? "where" : "which", ["node"], { windowsHide: true }, (err) => resolve(!err)));
    if (achou)
        return;
    const escolha = await vscode.window.showWarningMessage("Claude Monitor: falta o Node.js — sem ele o Claude Code não consegue avisar quais sessões estão rodando. Instale (versão LTS) e reinicie o VS Code.", "Baixar Node.js");
    if (escolha)
        vscode.env.openExternal(vscode.Uri.parse("https://nodejs.org/"));
}
function playSound() {
    const ignore = () => {
        /* som não é crítico */
    };
    if (process.platform === "darwin") {
        (0, child_process_1.execFile)("afplay", ["/System/Library/Sounds/Glass.aiff"], ignore);
    }
    else if (process.platform === "win32") {
        (0, child_process_1.execFile)("powershell", ["-NoProfile", "-Command", "(New-Object Media.SoundPlayer 'C:\\Windows\\Media\\Windows Notify.wav').PlaySync()"], { windowsHide: true }, ignore);
    }
    else {
        (0, child_process_1.execFile)("paplay", ["/usr/share/sounds/freedesktop/stereo/complete.oga"], ignore);
    }
}
/** Sessão rodando no Terminal.app — só ativa o app se achar a aba. */
async function focusTerminalApp(tty) {
    if (process.platform !== "darwin")
        return false;
    const script = `
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is "${tty}" then
            set selected tab of w to t
            set index of w to 1
            activate
            return "found"
          end if
        end repeat
      end repeat
    end tell
    return ""`;
    const out = await (0, sessions_1.run)("osascript", ["-e", script]);
    return out?.trim() === "found";
}
function normalizePath(p) {
    const resolved = path.resolve(p);
    return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}
function isInThisWindow(cwd) {
    if (!cwd)
        return false;
    const target = normalizePath(cwd);
    return (vscode.workspace.workspaceFolders ?? []).some((f) => {
        const root = normalizePath(f.uri.fsPath);
        return target === root || target.startsWith(root + path.sep);
    });
}
async function focusSession(s) {
    seen.set(s.id, s.since);
    provider.refresh();
    if (isPanelSession(s)) {
        if (isInThisWindow(s.cwd)) {
            // a extensão oficial abre/revela a sessão pelo id
            try {
                await vscode.commands.executeCommand("claude-vscode.editor.open", s.id);
                return;
            }
            catch {
                // extensão oficial ausente ou mudou a API — cai pro fallback
            }
        }
    }
    else {
        // o shell de um terminal do VSCode é ancestral do processo do Claude
        const table = s.pid ? await (0, processes_1.processTableAsync)() : null;
        const chain = table && s.pid ? (0, processes_1.ancestors)(table, s.pid) : [];
        for (const terminal of vscode.window.terminals) {
            const pid = await terminal.processId;
            if (pid && chain.includes(pid)) {
                terminal.show();
                return;
            }
        }
        const tty = s.tty || (s.pid ? table?.get(s.pid)?.tty : null);
        if (tty && (await focusTerminalApp(tty)))
            return;
    }
    // sessão de outra janela: abrir a pasta foca a janela que já tem ela aberta
    if (s.cwd && !isInThisWindow(s.cwd)) {
        await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.file(s.cwd), { forceNewWindow: true });
        return;
    }
    const action = await vscode.window.showWarningMessage(`Não achei onde "${s.name}" está rodando.`, "Ver diagnóstico");
    if (action === "Ver diagnóstico")
        vscode.commands.executeCommand("claudeMonitor.debug");
}
let debugChannel;
async function debugTerminals() {
    debugChannel ??= vscode.window.createOutputChannel("Claude Monitor — Debug");
    const channel = debugChannel;
    channel.clear();
    channel.appendLine(`Sessões conhecidas (${sessions_1.SESS_DIR}):`);
    for (const s of sessions) {
        channel.appendLine(`  - ${s.name}  [${s.state}]  id=${s.id}`);
        channel.appendLine(`      cwd=${s.cwd}  pid=${s.pid ?? "(nenhum)"}  entrypoint=${s.entrypoint ?? "(nenhum)"}`);
    }
    channel.appendLine("");
    channel.appendLine(`Hooks instalados no Claude Code: ${(0, install_1.hooksInstalled)() ? "sim" : "NÃO"}`);
    channel.appendLine("");
    const table = await (0, processes_1.processTableAsync)();
    channel.appendLine(`Abas de terminal abertas (${vscode.window.terminals.length}):`);
    for (const t of vscode.window.terminals) {
        const pid = await t.processId;
        const owner = pid ? sessions.find((s) => s.pid && table && (0, processes_1.ancestors)(table, s.pid).includes(pid)) : undefined;
        channel.appendLine(`  - "${t.name}"  shell pid=${pid ?? "?"}  sessão=${owner?.name ?? "(nenhuma)"}`);
    }
    channel.show();
}
const provider = new SessionsProvider();
async function runInstall() {
    try {
        (0, install_1.installHooks)();
        vscode.window.showInformationMessage("Hooks do Claude Monitor instalados. Sessões do Claude que já estavam abertas precisam ser reiniciadas pra aparecer.");
        conferirNode();
    }
    catch (err) {
        vscode.window.showErrorMessage(`Claude Monitor: ${err.message}`);
    }
}
function activate(context) {
    fs.mkdirSync(sessions_1.SESS_DIR, { recursive: true });
    try {
        (0, install_1.copyHookFiles)(context.extensionPath);
    }
    catch (err) {
        vscode.window.showErrorMessage(`Claude Monitor: não consegui copiar o hook (${err.message})`);
    }
    try {
        copiarJanelinha(context);
    }
    catch (err) {
        vscode.window.showErrorMessage(`Claude Monitor: não consegui copiar a janelinha (${err.message})`);
    }
    if (janelinhaLigada())
        abrirJanelinha();
    if ((0, install_1.hooksInstalled)())
        conferirNode();
    else {
        vscode.window
            .showInformationMessage("Claude Monitor: instalar os hooks no Claude Code pra acompanhar as sessões?", "Instalar")
            .then((action) => {
            if (action === "Instalar")
                runInstall();
        });
    }
    const view = vscode.window.createTreeView("claudeMonitor.sessions", { treeDataProvider: provider });
    const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBar.command = "claudeMonitor.sessions.focus";
    statusBar.show();
    context.subscriptions.push(view, statusBar);
    function notify(s) {
        const config = vscode.workspace.getConfiguration("claudeMonitor");
        if (config.get("playSound", true) && !janelinhaAberta && (0, sessions_1.claimSound)(s))
            playSound();
        // toast só na janela focada, senão aparece em todas
        if (config.get("showNotifications", true) && vscode.window.state.focused) {
            const msg = s.state === "permission" ? `Claude pedindo permissão: ${s.name}` : `Claude terminou: ${s.name}`;
            vscode.window.showInformationMessage(msg, "Abrir").then((action) => {
                if (action === "Abrir")
                    focusSession(s);
            });
        }
    }
    function render() {
        const counts = { permission: 0, waiting: 0, working: 0 };
        for (const s of sessions) {
            const state = displayState(s);
            if (state !== "seen")
                counts[state]++;
        }
        const parts = [
            counts.permission && `$(shield) ${counts.permission}`,
            counts.waiting && `$(bell-dot) ${counts.waiting}`,
            counts.working && `$(sync~spin) ${counts.working}`,
        ].filter(Boolean);
        statusBar.text = parts.length ? parts.join("  ") : "$(check) Claude";
        statusBar.backgroundColor = counts.permission
            ? new vscode.ThemeColor("statusBarItem.warningBackground")
            : undefined;
        statusBar.tooltip = "Claude Monitor — clique pra abrir a lista de sessões";
        const pending = counts.permission + counts.waiting;
        view.badge = pending ? { value: pending, tooltip: `${pending} sessão(ões) esperando você` } : undefined;
        provider.refresh();
    }
    let running = false;
    async function tick() {
        if (running)
            return;
        running = true;
        try {
            conferirAtualizacao(context.extension.packageJSON.version);
            const fresh = await (0, sessions_1.readSessions)();
            for (const s of fresh) {
                const prev = lastStates.get(s.id);
                if (prev && prev !== s.state && (s.state === "waiting" || s.state === "permission"))
                    notify(s);
                lastStates.set(s.id, s.state);
            }
            const ids = new Set(fresh.map((s) => s.id));
            for (const id of [...lastStates.keys()])
                if (!ids.has(id))
                    lastStates.delete(id);
            for (const id of [...seen.keys()])
                if (!ids.has(id))
                    seen.delete(id);
            fresh.sort((a, b) => PRIORITY[displayState(a)] - PRIORITY[displayState(b)] || b.since - a.since);
            sessions = fresh;
            render();
        }
        finally {
            running = false;
        }
    }
    // fs.watch reage na hora; o polling atualiza o "há X min" e pega evento perdido
    let debounce;
    try {
        const watcher = fs.watch(sessions_1.SESS_DIR, () => {
            if (debounce)
                clearTimeout(debounce);
            debounce = setTimeout(tick, 150);
        });
        context.subscriptions.push({ dispose: () => watcher.close() });
    }
    catch {
        // watch nativo falhou (raro) — fica só o polling
    }
    const interval = setInterval(tick, POLL_MS);
    context.subscriptions.push({ dispose: () => clearInterval(interval) });
    context.subscriptions.push(vscode.commands.registerCommand("claudeMonitor.focusSession", focusSession), vscode.commands.registerCommand("claudeMonitor.markSeen", (item) => {
        seen.set(item.session.id, item.session.since);
        render();
    }), vscode.commands.registerCommand("claudeMonitor.refresh", tick), vscode.commands.registerCommand("claudeMonitor.debug", debugTerminals), vscode.commands.registerCommand("claudeMonitor.installHooks", runInstall), vscode.commands.registerCommand("claudeMonitor.openOverlay", abrirJanelinha), vscode.commands.registerCommand("claudeMonitor.minecraft", usarMinecraft));
    // clique numa sessão da janelinha: vscode://local.claude-monitor/sessao?id=<id>
    context.subscriptions.push(vscode.window.registerUriHandler({
        async handleUri(uri) {
            const { id } = Object.fromEntries(new URLSearchParams(uri.query));
            const s = (await (0, sessions_1.readSessions)()).find((x) => x.id === id);
            if (s)
                await focusSession(s);
            else
                vscode.window.showWarningMessage("Claude Monitor: essa sessão já fechou.");
        },
    }));
    tick();
}
function deactivate() { }
//# sourceMappingURL=extension.js.map