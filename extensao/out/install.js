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
exports.copyHookFiles = copyHookFiles;
exports.hooksInstalled = hooksInstalled;
exports.installHooks = installHooks;
/**
 * Instala o hook no Claude Code: copia hook.js pra ~/.claude-monitor/ e
 * registra os eventos no ~/.claude/settings.json, preservando os outros hooks.
 */
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const path = __importStar(require("path"));
const HOOK_DIR = path.join(os.homedir(), ".claude-monitor");
const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const HOOK_FILES = ["hook.js", "processes.js"];
const EVENTS = [
    ["UserPromptSubmit", "working"],
    ["Stop", "waiting"],
    ["Notification", "notification"],
    ["SessionEnd", "end"],
];
// hooks antigos deste monitor (inclusive a versão em Python) que a instalação substitui
const OURS = /claude-monitor-hook|\.claude-monitor[\\/]hook\.js/;
function hookCommand(arg) {
    // barra normal funciona no bash, zsh, PowerShell e cmd
    const hookPath = path.join(HOOK_DIR, "hook.js").split(path.sep).join("/");
    return `node "${hookPath}" ${arg}`;
}
/** Mantém o hook instalado sempre na mesma versão da extensão. */
function copyHookFiles(extensionPath) {
    fs.mkdirSync(HOOK_DIR, { recursive: true });
    for (const file of HOOK_FILES) {
        fs.copyFileSync(path.join(extensionPath, "out", file), path.join(HOOK_DIR, file));
    }
}
function readSettings() {
    if (!fs.existsSync(SETTINGS))
        return {};
    try {
        return JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    }
    catch {
        throw new Error(`Não consegui ler ${SETTINGS} (JSON inválido). Corrige o arquivo e tenta de novo.`);
    }
}
function hooksInstalled() {
    try {
        const hooks = readSettings().hooks ?? {};
        return EVENTS.every(([event, arg]) => (hooks[event] ?? []).some((group) => (group.hooks ?? []).some((h) => h.command === hookCommand(arg))));
    }
    catch {
        return false;
    }
}
function installHooks() {
    const settings = readSettings();
    if (fs.existsSync(SETTINGS))
        fs.copyFileSync(SETTINGS, `${SETTINGS}.bak-claude-monitor`);
    settings.hooks ??= {};
    for (const [event, arg] of EVENTS) {
        const groups = (settings.hooks[event] ?? [])
            .map((group) => ({ ...group, hooks: (group.hooks ?? []).filter((h) => !OURS.test(h.command ?? "")) }))
            .filter((group) => group.hooks.length > 0);
        groups.push({ hooks: [{ type: "command", command: hookCommand(arg) }] });
        settings.hooks[event] = groups;
    }
    fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
    fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
}
//# sourceMappingURL=install.js.map