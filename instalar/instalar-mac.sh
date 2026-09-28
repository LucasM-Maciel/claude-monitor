#!/bin/bash
# Instala o Claude Monitor no Mac: a extensão no VS Code/Cursor, os hooks no
# Claude Code, a janelinha (compilada aqui, uma vez) e, se tiver Minecraft, os
# sons e a picareta do jogo. Rodar de novo não estraga: reinstala por cima.
# Uso: abra o Terminal, digite "bash " (com espaço), arraste este arquivo pra
# janela e aperte Enter.
# Testes: --sem-abrir (não abre a janelinha no final).
SEM_ABRIR=""
[ "${1:-}" = "--sem-abrir" ] && SEM_ABRIR=1

passo() { printf '\n\033[36m== %s\033[0m\n' "$1"; }
ok() { printf '   \033[32mOK\033[0m  %s\n' "$1"; }
aviso() { printf '   \033[33m!!\033[0m  %s\n' "$1"; }
falhou() { printf '\n   \033[31mXX\033[0m  %s\n\n' "$1"; exit 1; }

AQUI="$(cd "$(dirname "$0")" && pwd)"
PASTA="$HOME/.claude-monitor"
VSIX=$(ls "$AQUI"/arquivos/claude-monitor-*.vsix 2>/dev/null | tail -1)
[ -n "$VSIX" ] || falhou "Não achei o arquivos/claude-monitor-*.vsix do lado deste instalador. Extraia o .zip inteiro antes."
VERSAO=$(basename "$VSIX" .vsix | sed 's/^claude-monitor-//')
printf '\033[36mClaude Monitor %s\033[0m\n' "$VERSAO"

passo "Procurando o VS Code / Cursor"
EDITORES=()
for par in "code|/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
           "cursor|/Applications/Cursor.app/Contents/Resources/app/bin/cursor"; do
  nome="${par%%|*}"
  fixo="${par#*|}"
  exe=""
  while IFS= read -r c; do
    # o Cursor pode pôr um "code" dele no PATH: esse não é o VS Code
    if [ "$nome" = code ]; then case "$c $(readlink "$c" 2>/dev/null)" in *[Cc]ursor*) continue ;; esac; fi
    exe="$c"
    break
  done < <(type -ap "$nome" 2>/dev/null)
  [ -z "$exe" ] && [ -x "$fixo" ] && exe="$fixo"
  if [ -n "$exe" ]; then EDITORES+=("$exe"); ok "$exe"; fi
done
[ ${#EDITORES[@]} -gt 0 ] || falhou "Não achei o VS Code nem o Cursor. Instale o VS Code (https://code.visualstudio.com) e rode de novo."

passo "Instalando a extensão"
for exe in "${EDITORES[@]}"; do
  if saida=$("$exe" --install-extension "$VSIX" --force 2>&1); then ok "$(basename "$exe")"
  else aviso "$(basename "$exe") não aceitou a extensão:"; echo "$saida" | sed 's/^/       /'; fi
done

passo "Copiando os arquivos pra ~/.claude-monitor"
# os mesmos que a extensão copia quando o VS Code abre; aqui já saem de dentro do .vsix (é um zip)
TEMP=$(mktemp -d)
mkdir -p "$PASTA"
unzip -o -j -q "$VSIX" extension/out/hook.js extension/out/processes.js \
  extension/janelinha/overlay.swift extension/janelinha/extrair_minecraft.sh -d "$PASTA" \
  || falhou "O .vsix está incompleto. Baixe de novo."
unzip -o -j -q "$VSIX" extension/out/install.js -d "$TEMP" || falhou "O .vsix está incompleto. Baixe de novo."
printf '%s' "$VERSAO" > "$PASTA/versao-janelinha"  # a extensão só recopia quando a versão muda
ok "$PASTA"

passo "Ligando o Claude Code na extensão (hooks)"
if command -v node >/dev/null 2>&1; then
  if saida=$(node -e 'require(process.argv[1]).installHooks()' "$TEMP/install.js" 2>&1); then
    ok "hooks no ~/.claude/settings.json (cópia do anterior em settings.json.bak-claude-monitor)"
  else
    aviso "Não consegui mexer no ~/.claude/settings.json: $saida"
    aviso "Depois, no VS Code: Cmd+Shift+P > \"Claude Monitor: Instalar hooks no Claude Code\"."
  fi
else
  aviso "Falta o Node.js: o Claude Code usa ele pra avisar quais sessões estão rodando."
  if command -v brew >/dev/null 2>&1; then aviso "Instale com:  brew install node   e rode este instalador de novo."
  else aviso "Instale a versão LTS em https://nodejs.org e rode este instalador de novo."; fi
fi
rm -rf "$TEMP"

passo "Montando a janelinha"
if ! xcode-select -p >/dev/null 2>&1; then
  aviso "Faltam as ferramentas de linha de comando da Apple (uma vez só)."
  aviso "Vai abrir uma janela: clique em Instalar, espere terminar e rode este instalador de novo."
  xcode-select --install >/dev/null 2>&1
  exit 1
fi
if xcrun swiftc -swift-version 5 -O -o "$PASTA/ClaudeMonitor.novo" "$PASTA/overlay.swift" 2> "$PASTA/compilar.log"; then
  mv "$PASTA/ClaudeMonitor.novo" "$PASTA/ClaudeMonitor"  # troca de uma vez: a aberta se reabre com a nova
  ok "janelinha pronta"
else
  cat "$PASTA/compilar.log"
  falhou "Não consegui montar a janelinha. Mande o texto acima pra quem te passou o Claude Monitor."
fi

passo "Minecraft (opcional)"
bash "$PASTA/extrair_minecraft.sh"

if [ -z "$SEM_ABRIR" ]; then
  nohup "$PASTA/ClaudeMonitor" >/dev/null 2>&1 &
fi

printf '\n\033[32mPronto! A janelinha aparece no canto de baixo à direita.\033[0m\n'
echo "Feche e abra o VS Code de novo. Sessões do Claude que já estavam abertas"
echo "precisam ser reabertas pra aparecer (as novas aparecem sozinhas)."
echo "Se o Mac perguntar se \"security\" pode acessar \"Claude Code-credentials\","
echo "clique em \"Permitir Sempre\": é só pra janelinha ler o seu usage (5h/7d)."
