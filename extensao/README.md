# Claude Monitor

Uma janelinha sempre por cima, no canto da tela, que mostra as suas sessões do
Claude Code e quanto do seu limite você já usou. Assim você não precisa ficar
olhando aba por aba pra saber quem terminou.

| Bolinha | Quer dizer |
|---|---|
| 🟢 verde | trabalhando |
| 🔴 vermelha | terminou |
| 🔵 azul | te fez uma pergunta |
| 🟡 amarela | pedindo permissão |

- **5h / 7d**: o mesmo que o `/usage` mostra (limite de 5 horas e da semana), com quanto falta pra renovar.
- **Clawd**: anda em volta quando alguma sessão está rodando, pula quando alguém espera você e fica parado quando está tudo quieto.
- **Som** quando uma sessão termina ou precisa de você.
- No VS Code: aba **Claude Monitor** na barra lateral, com clique pra ir direto na sessão, e um contador na barra de status.

Arrastar move a janelinha. Duplo clique traz o VS Code. Botão direito > Fechar.
Pra reabrir: `Ctrl+Shift+P` (Mac: `Cmd+Shift+P`) > **Claude Monitor: Abrir janelinha flutuante**.

Instalação e tutorial: https://github.com/LucasM-Maciel/claude-monitor
