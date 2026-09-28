#!/bin/bash
# Tira do Minecraft Java instalado o que a janelinha usa e grava em ~/.claude-monitor:
#  - picareta.png (textura da picareta de diamante, da versão mais nova instalada)
#  - sons/*.wav   (dos assets; precisa do ffmpeg: brew install ffmpeg)
# Sem Minecraft, a janelinha usa os sons do Mac e uma picareta desenhada.
# Os arquivos não vão junto no pacote porque são da Mojang: cada um tira do seu jogo.
# Pra trocar/adicionar som, mexa na lista e rode de novo: bash extrair_minecraft.sh
# (os nomes dos sons estão em .../minecraft/assets/indexes/*.json)
# Bash 3.2 (o do Mac): nada de array associativo.
SONS="xp:random/orb levelup:random/levelup pop:random/pop aldeao_hmm1:mob/villager/idle1
aldeao_hmm2:mob/villager/idle2 aldeao_sim:mob/villager/yes1 pling:note/pling sino:note/bell
bigorna:random/anvil_land gato:mob/cat/meow1"
TONS_XP="0.8 1.0 1.25"  # como o jogo, o XP muda de tom a cada vez: xp1, xp2, xp3

MC="$HOME/Library/Application Support/minecraft"
DESTINO="$HOME/.claude-monitor"
if [ ! -d "$MC/assets/indexes" ]; then
  echo "Minecraft Java não encontrado — a janelinha fica com os sons do Mac."
  exit 0
fi
mkdir -p "$DESTINO"

# picareta: textures/item (1.13+) ou textures/items (antigas), do jar mais novo
# cujo nome bate com a pasta da versão (as outras são de mods/instaladores)
JAR=$(ls -t "$MC"/versions/*/*.jar 2>/dev/null | while IFS= read -r j; do
  if [ "$(basename "$j" .jar)" = "$(basename "$(dirname "$j")")" ]; then echo "$j"; break; fi
done)
if [ -n "$JAR" ]; then
  for dentro in assets/minecraft/textures/item/diamond_pickaxe.png assets/minecraft/textures/items/diamond_pickaxe.png; do
    if unzip -p "$JAR" "$dentro" > "$DESTINO/picareta.png.novo" 2>/dev/null && [ -s "$DESTINO/picareta.png.novo" ]; then
      mv "$DESTINO/picareta.png.novo" "$DESTINO/picareta.png"
      echo "picareta.png (de $(basename "$JAR"))"
      break
    fi
  done
  rm -f "$DESTINO/picareta.png.novo"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Pra usar os sons do Minecraft falta o ffmpeg. Instale com:  brew install ffmpeg"
  echo "e rode de novo (no VS Code: Cmd+Shift+P > \"Claude Monitor: Usar sons do Minecraft\")."
  exit 0
fi
INDICE=$(ls -t "$MC"/assets/indexes/*.json | head -1)
mkdir -p "$DESTINO/sons"

for par in $SONS; do
  nome=${par%%:*}
  som=${par#*:}
  # "minecraft/sounds/random/orb.ogg": {"hash": "abc...", "size": 123}
  hash=$(grep -o "\"minecraft/sounds/$som.ogg\": *{\"hash\": *\"[0-9a-f]*\"" "$INDICE" | grep -o '[0-9a-f]\{40\}' | head -1)
  if [ -z "$hash" ]; then echo "aviso: $nome ($som) não está no Minecraft"; continue; fi
  ogg="$MC/assets/objects/${hash:0:2}/$hash"
  if [ ! -f "$ogg" ]; then echo "aviso: $nome ainda não foi baixado pelo Minecraft"; continue; fi
  taxa=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$ogg")
  if [ "$nome" = "xp" ]; then tons=$TONS_XP; else tons="1.0"; fi
  i=0
  for tom in $tons; do
    i=$((i + 1))
    if [ "$tons" = "1.0" ]; then wav="$DESTINO/sons/$nome.wav"; else wav="$DESTINO/sons/$nome$i.wav"; fi
    # muda o tom mudando a taxa (como o jogo faz) e volta pra 44100 pro .wav
    nova=$(awk -v t="$taxa" -v f="$tom" 'BEGIN { printf "%d", t * f }')
    ffmpeg -y -loglevel error -i "$ogg" -ac 1 -af "asetrate=$nova,aresample=44100,volume=0.8" -sample_fmt s16 "$wav" \
      && echo "$(basename "$wav")"
  done
done
# a janelinha aberta vê o binário "mudar" e se reabre já com os sons
[ -f "$DESTINO/ClaudeMonitor" ] && touch "$DESTINO/ClaudeMonitor"
echo "Pronto! A janelinha já está com os sons do Minecraft."
