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
/**
 * Hook do Claude Code (UserPromptSubmit, Stop, Notification, SessionEnd).
 * Script Node standalone — não importa nada do VSCode. A extensão copia ele
 * pra ~/.claude-monitor/hook.js e registra no ~/.claude/settings.json.
 *
 * Lê o JSON do stdin e grava ~/.claude-monitor/sessions/<session_id>.json
 *
 * Uso: node hook.js <working|waiting|notification|end>
 *   notification -> vira "permission" se for pedido de permissão, senão "waiting"
 *   end          -> apaga o arquivo da sessão
 */
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const path = __importStar(require("path"));
const processes_1 = require("./processes");
const SESS_DIR = path.join(os.homedir(), ".claude-monitor", "sessions");
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "fish", "cmd", "powershell", "pwsh", "conhost"]);
function readStdin() {
    try {
        return JSON.parse(fs.readFileSync(0, "utf8"));
    }
    catch {
        return {};
    }
}
/**
 * PID do processo do Claude. O Claude exporta CLAUDE_PID; se não vier, sobe
 * a árvore: o primeiro ancestral chamado "claude" ou, na falta dele (instalação
 * via npm roda como node), o primeiro que não é shell.
 */
function findClaudePid() {
    const fromEnv = Number(process.env.CLAUDE_PID);
    if (fromEnv)
        return fromEnv;
    const table = (0, processes_1.processTable)();
    if (!table)
        return null;
    let firstNonShell = null;
    let pid = table.get(process.pid)?.ppid;
    for (let i = 0; pid && i < 15; i++) {
        const proc = table.get(pid);
        if (!proc)
            break;
        if (proc.name === "claude")
            return pid;
        if (firstNonShell === null && !SHELLS.has(proc.name))
            firstNonShell = pid;
        pid = proc.ppid;
    }
    return firstNonShell;
}
/**
 * O /rename grava "custom-title" no transcript; o título automático é o
 * "ai-title". O do /rename ganha. Pega sempre o mais recente.
 */
function getTitle(transcript, sessionId) {
    let custom;
    let ai;
    try {
        for (const line of fs.readFileSync(transcript, "utf8").split("\n")) {
            if (!line.includes('"custom-title"') && !line.includes('"ai-title"'))
                continue;
            try {
                const obj = JSON.parse(line);
                if ((obj.sessionId ?? sessionId) !== sessionId)
                    continue;
                if (obj.type === "custom-title")
                    custom = obj.customTitle || custom;
                else if (obj.type === "ai-title")
                    ai = obj.aiTitle || ai;
            }
            catch {
                // linha quebrada
            }
        }
    }
    catch {
        // sem transcript
    }
    return custom || ai;
}
/**
 * Notification dispara tanto pra pedido de permissão quanto pro aviso de
 * "tá ocioso há 60s". Só o primeiro é urgente.
 */
function notificationState(data) {
    const kind = String(data.notification_type || "").toLowerCase();
    const message = String(data.message || "").toLowerCase();
    if (kind.includes("permission") || message.includes("permission") || kind.includes("elicitation")) {
        return "permission";
    }
    return "waiting";
}
function main() {
    const event = process.argv[2] || "waiting";
    const data = readStdin();
    const sessionId = data.session_id || "unknown";
    fs.mkdirSync(SESS_DIR, { recursive: true });
    const file = path.join(SESS_DIR, `${sessionId}.json`);
    if (event === "end") {
        fs.rmSync(file, { force: true });
        return;
    }
    let previous = {};
    try {
        previous = JSON.parse(fs.readFileSync(file, "utf8"));
    }
    catch {
        // primeira vez dessa sessão
    }
    const state = event === "notification" ? notificationState(data) : event;
    const now = Date.now() / 1000;
    // mesmo estado de antes (ex.: aviso de ociosidade depois do Stop) não
    // reinicia o relógio do "esperando há X"
    const since = previous.state === state && previous.since ? previous.since : now;
    const cwd = data.cwd || "";
    const transcript = data.transcript_path || "";
    const name = getTitle(transcript, sessionId) || path.basename(cwd.replace(/[\\/]+$/, "")) || sessionId.slice(0, 8);
    // o pid não muda durante a sessão — no Windows achar ele custa ~1s de PowerShell
    const pid = previous.pid || findClaudePid();
    fs.writeFileSync(file, JSON.stringify({
        name,
        cwd,
        state,
        since,
        updated: now,
        pid,
        entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || previous.entrypoint || null,
        transcript,
    }));
}
try {
    main();
}
catch {
    // hook nunca pode travar o Claude
}
//# sourceMappingURL=hook.js.map