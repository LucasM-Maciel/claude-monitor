#!/bin/bash
# Testes do Mac (no CI rodam num Mac de verdade do GitHub):
#   npm run empacotar && bash testes/mac/testes.sh [pasta dos prints]
# Testa o dist/ClaudeMonitor.zip (o que o amigo baixa) numa casa de mentira
# (HOME trocado), com "VS Code" e "Cursor" de mentira que só anotam o que
# receberam. Não mexe na sua ~/.claude-monitor, no seu VS Code nem na internet.
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
SAIDA="${1:-$RAIZ/testes/saida}"
mkdir -p "$SAIDA"
TMP=$(mktemp -d)
FALHAS=0
TOTAL=0

teste() {
  local nome="$1" msg
  shift
  TOTAL=$((TOTAL + 1))
  if msg=$("$@" 2>&1); then
    printf '  \033[32mok\033[0m  %s\n' "$nome"
  else
    FALHAS=$((FALHAS + 1))
    printf '  \033[31mXX\033[0m  %s\n' "$nome"
    printf '%s\n' "$msg" | sed 's/^/      /'
  fi
}
falha() { echo "$*"; return 1; }
# roda com prazo: travou = falha (e mata). Vigia sem processo à parte: um
# "sleep" órfão segurava o $(...) aberto e cada chamada esperava o prazo inteiro
com_prazo() {
  local s=$1 t=0
  shift
  "$@" &
  local p=$!
  while kill -0 "$p" 2>/dev/null; do
    if [ $t -ge $((s * 10)) ]; then kill -9 "$p" 2>/dev/null; break; fi
    sleep 0.1
    t=$((t + 1))
  done
  wait "$p"
}

echo "macOS $(sw_vers -productVersion) — $(xcrun swiftc --version 2>&1 | head -1)"
VERSAO=$(node -p "require('$RAIZ/extensao/package.json').version")
ZIP="$RAIZ/dist/ClaudeMonitor.zip"
[ -f "$ZIP" ] || { echo "Falta o dist/ClaudeMonitor.zip: rode npm run empacotar"; exit 1; }
# extrai como o Finder (ditto mantém as permissões do zip)
ditto -x -k "$ZIP" "$TMP/baixado"
PACOTE="$TMP/baixado/ClaudeMonitor"
mkdir -p "$TMP/vsix"
unzip -q "$PACOTE/arquivos/claude-monitor-$VERSAO.vsix" -d "$TMP/vsix"
xcrun swiftc -O -o "$TMP/pixels" "$RAIZ/testes/mac/pixels.swift" || exit 1
pixels() { "$TMP/pixels" "$@"; }

# casa de mentira com espaço e acento, como "/Users/João Silva"
CASA="$TMP/Users/João Silva"
BIN="$TMP/bin falso"
mkdir -p "$CASA" "$BIN"
for e in code cursor; do
  printf '#!/bin/bash\necho "$@" >> "%s/%s.log"\n' "$BIN" "$e" > "$BIN/$e"
  chmod +x "$BIN/$e"
done
PATH_TESTE="$BIN:$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin"
MONITOR="$CASA/.claude-monitor"
# servidor da Mojang de mentira (testes/mojang-falso.js), no ar até o fim: o instalador baixa dele
node "$RAIZ/testes/mojang-falso.js" > "$TMP/mojang.txt" &
MOJANG_PID=$!
for _ in $(seq 1 100); do [ -s "$TMP/mojang.txt" ] && break; sleep 0.1; done
MOJANG=$(head -1 "$TMP/mojang.txt")
instalar() { env HOME="$CASA" PATH="$PATH_TESTE" CLAUDE_MONITOR_MOJANG="$MOJANG" bash "$PACOTE/instalar-mac.sh" --sem-abrir; }

echo ""
echo "Pacote"
t_sintaxe() {
  local f
  for f in "$RAIZ"/instalar/*.sh "$RAIZ"/testes/mac/*.sh "$PACOTE"/*.sh; do
    bash -n "$f" || falha "erro de sintaxe em $f" || return 1
  done
}
teste "todos os .sh sem erro de sintaxe" t_sintaxe
t_executavel() { [ -x "$PACOTE/instalar-mac.sh" ] || falha "instalar-mac.sh saiu do zip sem permissão de executar"; }
teste "instalar-mac.sh sai do zip executável" t_executavel

echo ""
echo "Instalador"
t_instala() {
  local saida
  saida=$(com_prazo 300 instalar 2>&1) || falha "saiu com erro: $saida" || return 1
  local e
  for e in code cursor; do
    grep -q -- "--install-extension .*claude-monitor-$VERSAO.vsix --force" "$BIN/$e.log" 2>/dev/null \
      || falha "$e recebeu: $(cat "$BIN/$e.log" 2>/dev/null)" || return 1
  done
  local f
  for f in hook.js processes.js overlay.swift minecraft.js vorbis.min.js ClaudeMonitor; do
    [ -f "$MONITOR/$f" ] || falha "falta $f" || return 1
  done
  [ -f "$MONITOR/sons/levelup.wav" ] || falha "não baixou os sons do Minecraft: $saida" || return 1
  [ -x "$MONITOR/ClaudeMonitor" ] || falha "janelinha não é executável" || return 1
  [ ! -f "$MONITOR/install.js" ] || falha "install.js sobrou na pasta" || return 1
  [ "$(cat "$MONITOR/versao-janelinha")" = "$VERSAO" ] || falha "versão marcada: $(cat "$MONITOR/versao-janelinha")" || return 1
  local n
  n=$(node -e "const h=require(process.argv[1]).hooks; console.log(['UserPromptSubmit','Stop','Notification','SessionEnd'].filter(e=>h[e]&&h[e].length===1).length)" "$CASA/.claude/settings.json")
  [ "$n" = 4 ] || falha "hooks: $n de 4" || return 1
  echo "$saida" | grep -q "canto de baixo à direita" || falha "não terminou com a mensagem final: $saida"
}
teste "instala: extensão no VS Code e no Cursor, arquivos, janelinha compilada e hooks" t_instala
if [ -s "$MONITOR/compilar.log" ]; then
  echo "      avisos do compilador:"
  sed 's/^/        /' "$MONITOR/compilar.log" | head -40
fi
t_de_novo() {
  com_prazo 300 instalar >/dev/null 2>&1 || falha "2ª instalação falhou" || return 1
  local n
  n=$(node -p "require(process.argv[1]).hooks.Stop.length" "$CASA/.claude/settings.json")
  [ "$n" = 1 ] || falha "Stop tem $n hooks (duplicou)"
}
teste "rodar o instalador de novo não duplica os hooks" t_de_novo
t_code_do_cursor() {
  local shim="$TMP/Cursor.app/Contents/Resources/app/bin"
  mkdir -p "$shim"
  printf '#!/bin/bash\necho "$@" >> "%s/code.log"\n' "$shim" > "$shim/code"
  chmod +x "$shim/code"
  rm -f "$BIN/code.log"
  env HOME="$CASA" PATH="$shim:$PATH_TESTE" bash "$PACOTE/instalar-mac.sh" --sem-abrir >/dev/null 2>&1 || falha "instalação falhou" || return 1
  [ ! -f "$shim/code.log" ] || falha "usou o code do Cursor como se fosse o VS Code" || return 1
  grep -q -- "--install-extension" "$BIN/code.log" 2>/dev/null || falha "o VS Code não recebeu a extensão"
}
teste "com o code do Cursor na frente do PATH: instala no VS Code de verdade" t_code_do_cursor
t_hook() {
  local cmd sh
  cmd=$(node -p "require(process.argv[1]).hooks.UserPromptSubmit[0].hooks[0].command" "$CASA/.claude/settings.json")
  for sh in /bin/zsh /bin/bash /bin/sh; do
    echo "{\"session_id\":\"via-$(basename $sh)\",\"cwd\":\"/tmp\"}" | env HOME="$CASA" PATH="$PATH_TESTE" "$sh" -c "$cmd"
    [ -f "$MONITOR/sessions/via-$(basename $sh).json" ] || falha "pelo $sh não gravou a sessão (comando: $cmd)" || return 1
  done
}
teste "o hook instalado funciona pelo zsh, bash e sh, com acento no caminho" t_hook
t_sem_editor() {
  local saida r
  saida=$(env HOME="$TMP/outra casa" PATH="$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin" bash "$PACOTE/instalar-mac.sh" --sem-abrir 2>&1)
  r=$?
  if [ -d "/Applications/Visual Studio Code.app" ] || [ -d "/Applications/Cursor.app" ]; then
    echo "(esta máquina tem VS Code/Cursor em /Applications: só confiro que não quebrou)"
    return 0
  fi
  [ $r = 1 ] && echo "$saida" | grep -q "Não achei o VS Code" || falha "$r: $saida"
}
teste "sem VS Code nem Cursor: explica e sai com erro" t_sem_editor

echo ""
echo "Janelinha (cenários de testes/cenarios.js; prints em $SAIDA)"
t_cenario() {
  local c=$1 pasta="$TMP/cenario $1 ção" foto="$SAIDA/mac-$1.png"
  node "$RAIZ/testes/cenarios.js" "$pasta" "$c" $$ >/dev/null || falha "cenarios.js falhou" || return 1
  if [ "$c" = andando ]; then cp "$TMP/magenta.png" "$pasta/picareta.png"; fi
  if [ "$c" = pedra ]; then cp "$TMP/magenta.png" "$pasta/diamante.png"; fi  # o diamante que sobe
  rm -f "$foto" "$foto.txt"
  local extra=()
  [ -f "$pasta/uso.json" ] && extra=(--uso "$pasta/uso.json")
  [ -f "$pasta/clicar.txt" ] && extra+=(--clicar "$(cat "$pasta/clicar.txt")")
  [ -f "$pasta/cena.txt" ] && extra+=(--cena "$(cat "$pasta/cena.txt")")
  com_prazo 60 env HOME="$CASA" "$MONITOR/ClaudeMonitor" --foto "$foto" --pasta "$pasta" "${extra[@]}" \
    || falha "a janelinha não terminou direito" || return 1
  diff <(cat "$pasta/esperado.txt") <(cat "$foto.txt") || falha "o que a janelinha mostrou é diferente do esperado (acima)" || return 1
  [ "$(pixels "$foto" 24 24 24 10)" -gt 5000 ] || falha "cadê o cartão escuro?" || return 1
  [ "$(pixels "$foto" 215 119 87 30)" -gt 30 ] || falha "cadê o Clawd (laranja)?" || return 1
  if [ "$c" = andando ]; then
    [ "$(pixels "$foto" 255 0 255 40)" -gt 5 ] || falha "não usou a picareta.png; perto do magenta: $(pixels "$foto" 255 0 255 120 lista)" || return 1
  elif [ "$c" = pedra ]; then
    [ "$(pixels "$foto" 255 0 255 40)" -gt 5 ] || falha "cadê o diamante (diamante.png) subindo? perto do magenta: $(pixels "$foto" 255 0 255 120 lista)" || return 1
  else
    [ "$(pixels "$foto" 74 237 217 40)" -gt 5 ] || falha "cadê a ferramenta desenhada (ciano)?" || return 1
  fi
  if [ "$c" = bug ]; then
    [ "$(pixels "$foto" 239 68 68 30)" -gt 20 ] || falha "o bug não ficou vermelho com a espadada" || return 1
  fi
  if [ "$c" = atualizar ]; then
    [ "$(pixels "$foto" 167 139 250 30)" -gt 10 ] || falha "cadê o aviso roxo da versão nova?" || return 1
  fi
  if [ "$c" = misto ]; then
    [ "$(pixels "$foto" 167 139 250 30)" -lt 3 ] || falha "aviso roxo sem versão nova"
  fi
}
# picareta magenta de teste: prova que a textura do Minecraft, quando existe, é a usada
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAlSURBVDhPY2AYCPCf4f9/dDGiAUgz2QaMaiYRjGomA1CkeUABAMm+R7mIjocJAAAAAElFTkSuQmCC' | base64 -D > "$TMP/magenta.png"
for c in misto andando parado vazio levelup xp-rodando xp-esperando aldeao clique pedra bug atualizar; do
  teste "cenário '$c': mostra exatamente o esperado" t_cenario "$c"
done
t_cores() {
  local foto="$SAIDA/mac-misto.png" c
  for c in "verde 34 197 94" "vermelha 239 68 68" "azul 96 165 250" "amarela 250 204 21" "laranja-85% 245 158 11"; do
    set -- $c
    [ "$(pixels "$foto" "$2" "$3" "$4" 30)" -gt 10 ] || falha "cadê a cor $1?" || return 1
  done
}
teste "cores das bolinhas e das barras no cenário 'misto'" t_cores
t_barra_vermelha() { [ "$(pixels "$SAIDA/mac-andando.png" 239 68 68 30)" -gt 10 ] || falha "barra do 5h em 97% não ficou vermelha"; }
teste "barra vermelha quando o 5h passa de 95%" t_barra_vermelha

t_uma_so() {
  local pasta="$TMP/uma so"
  mkdir -p "$pasta"
  cp "$MONITOR/ClaudeMonitor" "$pasta/ClaudeMonitor"
  env HOME="$CASA" "$pasta/ClaudeMonitor" --pasta "$pasta" >/dev/null 2>&1 &
  local primeira=$!
  sleep 3
  kill -0 $primeira 2>/dev/null || falha "a janelinha não ficou aberta" || return 1
  com_prazo 10 env HOME="$CASA" "$pasta/ClaudeMonitor" --pasta "$pasta" || falha "a 2ª não desistiu (ficariam duas)" || return 1
  # versão nova = binário trocado: a aberta tem que virar a nova (aqui, um script que deixa um sinal)
  printf '#!/bin/bash\ntouch "%s/reabriu"\n' "$pasta" > "$pasta/novo"
  chmod +x "$pasta/novo"
  mv "$pasta/novo" "$pasta/ClaudeMonitor"
  for _ in $(seq 1 20); do [ -f "$pasta/reabriu" ] && break; sleep 0.5; done
  kill -9 $primeira 2>/dev/null
  [ -f "$pasta/reabriu" ] || falha "não se reabriu com o binário novo"
}
teste "uma janelinha só, e ela vira a versão nova quando o binário muda" t_uma_so

echo ""
echo "Minecraft (servidor da Mojang de mentira: testes/mojang-falso.js)"
t_mc_baixa() {
  local pasta="$TMP/mc1/.claude-monitor" saida f
  mkdir -p "$pasta"
  printf 'janelinha' > "$pasta/ClaudeMonitor"
  touch -t 202001010000 "$pasta/ClaudeMonitor" "$TMP/2020"
  saida=$(env HOME="$TMP/mc1" PATH="$PATH_TESTE" CLAUDE_MONITOR_MOJANG="$MOJANG" node "$MONITOR/minecraft.js" 2>&1) || falha "saiu com erro: $saida" || return 1
  for f in xp1 xp2 xp3 levelup aldeao_hmm1 aldeao_hmm2 gato; do [ -f "$pasta/sons/$f.wav" ] || falha "falta $f.wav: $saida" || return 1; done
  for f in picareta espada diamante pedra; do [ -f "$pasta/$f.png" ] || falha "falta $f.png: $saida" || return 1; done
  # o Mac tem que entender os .wav (o NSSound da janelinha usa o mesmo leitor)
  for f in "$pasta"/sons/*.wav; do afinfo "$f" >/dev/null 2>&1 || falha "o Mac não entende $(basename "$f")" || return 1; done
  [ "$pasta/ClaudeMonitor" -nt "$TMP/2020" ] || falha "não cutucou a janelinha pra recarregar" || return 1
  echo "$saida" | grep -q "Pronto!" || falha "$saida"
}
teste "baixa os sons e as texturas, sem Minecraft nem ffmpeg, e recarrega a janelinha" t_mc_baixa
t_mc_sem_internet() {
  local saida
  mkdir -p "$TMP/mc2"
  if saida=$(env HOME="$TMP/mc2" CLAUDE_MONITOR_MOJANG="http://127.0.0.1:9" node "$MONITOR/minecraft.js" 2>&1); then
    falha "devia sair com erro: $saida"
    return 1
  fi
  echo "$saida" | grep -q 'Cmd+Shift+P > "Claude Monitor: Usar sons do Minecraft"' || falha "$saida" || return 1
  [ ! -d "$TMP/mc2/.claude-monitor/sons" ] || falha "criou a pasta de sons sem ter som"
}
teste "sem internet: explica como tentar de novo, não quebra e não cria nada" t_mc_sem_internet

kill "$MOJANG_PID" 2>/dev/null
rm -rf "$TMP"
echo ""
if [ $FALHAS -gt 0 ]; then printf '\033[31m%d de %d testes FALHARAM\033[0m\n' $FALHAS $TOTAL; exit 1; fi
printf '\033[32m%d testes ok\033[0m\n' $TOTAL
