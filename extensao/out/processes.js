"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.processTable = processTable;
exports.processTableAsync = processTableAsync;
exports.ancestors = ancestors;
/**
 * Tabela de processos (pid -> pai, nome, tty) usada pelo hook pra achar o
 * Claude e pela extensão pra achar o terminal dono de uma sessão.
 * macOS/Linux via `ps`; Windows via PowerShell (mais lento, ~1s).
 */
const child_process_1 = require("child_process");
const WIN_QUERY = 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId),$($_.ParentProcessId),$($_.Name)" }';
function command() {
    return process.platform === "win32"
        ? ["powershell", ["-NoProfile", "-Command", WIN_QUERY]]
        : ["ps", ["-A", "-o", "pid=,ppid=,tty=,comm="]];
}
function normalizeName(raw) {
    return raw.split(/[\\/]/).pop().toLowerCase().replace(/\.exe$/, "").replace(/^-/, ""); // "-zsh" = shell de login
}
function parse(out) {
    const table = new Map();
    for (const line of out.split(/\r?\n/)) {
        if (process.platform === "win32") {
            const [pid, ppid, ...name] = line.split(",");
            if (pid && ppid)
                table.set(Number(pid), { ppid: Number(ppid), name: normalizeName(name.join(",")), tty: null });
            continue;
        }
        const parts = line.trim().split(/\s+/);
        if (parts.length < 4)
            continue;
        table.set(Number(parts[0]), {
            ppid: Number(parts[1]),
            tty: parts[2] === "??" || parts[2] === "?" ? null : `/dev/${parts[2]}`,
            name: normalizeName(parts.slice(3).join(" ")),
        });
    }
    return table;
}
/** Versão síncrona — pro hook, que é um script curto. */
function processTable() {
    const [cmd, args] = command();
    try {
        return parse((0, child_process_1.execFileSync)(cmd, args, { encoding: "utf8", timeout: 10000, windowsHide: true }));
    }
    catch {
        return null;
    }
}
/** Versão assíncrona — pra extensão não travar o VSCode esperando o PowerShell. */
function processTableAsync() {
    const [cmd, args] = command();
    return new Promise((resolve) => {
        (0, child_process_1.execFile)(cmd, args, { encoding: "utf8", timeout: 10000, windowsHide: true }, (err, stdout) => resolve(err ? null : parse(stdout)));
    });
}
/** pid + todos os ancestrais (até 20 níveis). */
function ancestors(table, pid) {
    const chain = [];
    for (let current = pid; current && chain.length < 20; current = table.get(current)?.ppid) {
        if (chain.includes(current))
            break;
        chain.push(current);
    }
    return chain;
}
//# sourceMappingURL=processes.js.map