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
exports.SESS_DIR = exports.MONITOR_DIR = void 0;
exports.run = run;
exports.readSessions = readSessions;
exports.claimSound = claimSound;
exports.formatElapsed = formatElapsed;
/**
 * Leitura das sessões gravadas pelo hook (~/.claude/hooks/claude-monitor-hook.py).
 * Mesma lógica do claude_monitor.py: checa se o processo ainda vive, apaga
 * fantasmas, junta duplicadas e resolve o título direto do transcript.
 */
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const path = __importStar(require("path"));
const child_process_1 = require("child_process");
exports.MONITOR_DIR = path.join(os.homedir(), ".claude-monitor");
exports.SESS_DIR = path.join(exports.MONITOR_DIR, "sessions");
const SOUND_DIR = path.join(exports.MONITOR_DIR, "sounds");
const PROJECTS_DIR = path.join(os.homedir(), ".claude", "projects");
const STALE_AFTER_SEC = 6 * 60 * 60; // fallback pra sessões sem pid/tty (hook antigo)
const TRANSCRIPT_GRACE_SEC = 2; // transcript mexido depois disso = permissão respondida
/** execFile que devolve null em vez de estourar. */
function run(cmd, args) {
    return new Promise((resolve) => {
        (0, child_process_1.execFile)(cmd, args, (err, stdout) => resolve(err ? null : stdout));
    });
}
function pidAlive(pid) {
    try {
        process.kill(pid, 0); // sinal 0 só testa se existe — funciona no Windows também
        return true;
    }
    catch (err) {
        return err?.code === "EPERM"; // existe, só não é nosso
    }
}
/** ttys com `claude` vivo — só pra arquivos antigos, gravados sem pid. */
async function ttysWithClaude() {
    if (process.platform === "win32")
        return null;
    const out = await run("ps", ["-A", "-o", "tty=,comm="]);
    if (out === null)
        return null;
    const ttys = new Set();
    for (const line of out.split("\n")) {
        const parts = line.trim().split(/\s+/);
        if (parts.length >= 2 && parts[0] !== "??" && path.basename(parts.slice(1).join(" ")) === "claude") {
            ttys.add(`/dev/${parts[0]}`);
        }
    }
    return ttys;
}
function isAlive(data, ttys, now) {
    if (data.pid)
        return pidAlive(data.pid);
    if (data.tty)
        return ttys === null || ttys.has(data.tty); // ps falhou — não apaga
    return now - (data.updated || 0) <= STALE_AFTER_SEC;
}
/**
 * Depois de aprovar uma permissão nenhum hook dispara até o Stop, então
 * se o transcript mexeu depois do pedido, a sessão voltou a trabalhar.
 */
function effectiveState(data) {
    const state = data.state === "working" || data.state === "permission" ? data.state : "waiting";
    if (state === "permission" && data.transcript) {
        try {
            if (fs.statSync(data.transcript).mtimeMs / 1000 > data.since + TRANSCRIPT_GRACE_SEC)
                return "working";
        }
        catch {
            // transcript sumiu — fica com o estado gravado
        }
    }
    return state;
}
/**
 * Título de cada sessão lido direto do transcript: o do /rename
 * ("custom-title") ganha do automático ("ai-title"). Lê só os bytes novos
 * a cada ciclo — transcript de sessão longa passa de MB.
 */
class TitleCache {
    state = new Map();
    get(file) {
        if (!file)
            return undefined;
        let entry = this.state.get(file);
        if (!entry) {
            entry = { offset: 0 };
            this.state.set(file, entry);
        }
        try {
            const size = fs.statSync(file).size;
            if (size < entry.offset)
                Object.assign(entry, { offset: 0, custom: undefined, ai: undefined });
            if (size > entry.offset) {
                const buf = Buffer.alloc(size - entry.offset);
                const fd = fs.openSync(file, "r");
                try {
                    fs.readSync(fd, buf, 0, buf.length, entry.offset);
                }
                finally {
                    fs.closeSync(fd);
                }
                const end = buf.lastIndexOf(10) + 1; // não consome linha pela metade
                entry.offset += end;
                for (const line of buf.subarray(0, end).toString("utf8").split("\n")) {
                    if (!line.includes('"custom-title"') && !line.includes('"ai-title"'))
                        continue;
                    try {
                        const obj = JSON.parse(line);
                        if (obj.type === "custom-title")
                            entry.custom = obj.customTitle || entry.custom;
                        else if (obj.type === "ai-title")
                            entry.ai = obj.aiTitle || entry.ai;
                    }
                    catch {
                        // linha quebrada — ignora
                    }
                }
            }
        }
        catch {
            // transcript inacessível — usa o nome gravado pelo hook
        }
        return entry.custom || entry.ai;
    }
    forgetExcept(files) {
        for (const key of this.state.keys())
            if (!files.has(key))
                this.state.delete(key);
    }
}
const titles = new TitleCache();
function findTranscript(id) {
    try {
        for (const dir of fs.readdirSync(PROJECTS_DIR)) {
            const candidate = path.join(PROJECTS_DIR, dir, `${id}.jsonl`);
            if (fs.existsSync(candidate))
                return candidate;
        }
    }
    catch {
        // sem ~/.claude/projects
    }
    return null;
}
function remove(file) {
    try {
        fs.unlinkSync(file);
    }
    catch {
        // outra janela/monitor já apagou
    }
}
async function readSessions() {
    if (!fs.existsSync(exports.SESS_DIR))
        return [];
    const now = Date.now() / 1000;
    const sessions = [];
    const raw = [];
    for (const entry of fs.readdirSync(exports.SESS_DIR)) {
        if (!entry.endsWith(".json"))
            continue;
        try {
            raw.push([entry, JSON.parse(fs.readFileSync(path.join(exports.SESS_DIR, entry), "utf8"))]);
        }
        catch {
            // arquivo sendo escrito nesse instante
        }
    }
    const ttys = raw.some(([, d]) => !d.pid && d.tty) ? await ttysWithClaude() : null;
    for (const [entry, data] of raw) {
        const file = path.join(exports.SESS_DIR, entry);
        if (!isAlive(data, ttys, now)) {
            remove(file);
            continue;
        }
        const id = entry.replace(/\.json$/, "");
        const transcript = data.transcript || findTranscript(id);
        const updated = data.updated || now;
        const since = data.since || updated;
        sessions.push({
            id,
            file,
            name: titles.get(transcript) || data.name || "sessão",
            cwd: data.cwd || "",
            state: effectiveState({ ...data, since, transcript }),
            since,
            updated,
            tty: data.tty || null,
            pid: data.pid || null,
            entrypoint: data.entrypoint || null,
            transcript,
        });
    }
    // /clear e resume criam session_id novo no mesmo processo/terminal:
    // fica só o arquivo mais recente de cada um, o resto é fantasma.
    sessions.sort((a, b) => b.updated - a.updated);
    const unique = [];
    const keys = new Set();
    for (const s of sessions) {
        const key = s.pid ? `pid:${s.pid}` : s.tty ? `tty:${s.tty}` : `id:${s.id}`;
        if (keys.has(key)) {
            remove(s.file);
            continue;
        }
        keys.add(key);
        unique.push(s);
    }
    titles.forgetExcept(new Set(unique.map((s) => s.transcript)));
    return unique;
}
/**
 * Várias janelas do VSCode + o monitor em Python veem a mesma transição.
 * Quem criar o arquivo primeiro toca o som; os outros ficam quietos.
 */
function claimSound(s) {
    try {
        fs.mkdirSync(SOUND_DIR, { recursive: true });
        const now = Date.now();
        for (const f of fs.readdirSync(SOUND_DIR)) {
            const p = path.join(SOUND_DIR, f);
            try {
                if (now - fs.statSync(p).mtimeMs > 60 * 60 * 1000)
                    fs.unlinkSync(p);
            }
            catch {
                // já limpo por outro
            }
        }
        fs.writeFileSync(path.join(SOUND_DIR, `${s.id}-${s.since}`), "", { flag: "wx" });
        return true;
    }
    catch {
        return false;
    }
}
function formatElapsed(seconds) {
    seconds = Math.max(0, Math.floor(seconds));
    if (seconds < 60)
        return `${seconds}s`;
    let minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return `${minutes}min`;
    const hours = Math.floor(minutes / 60);
    minutes %= 60;
    return minutes ? `${hours}h${String(minutes).padStart(2, "0")}` : `${hours}h`;
}
//# sourceMappingURL=sessions.js.map