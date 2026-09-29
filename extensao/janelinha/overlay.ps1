# Claude Monitor fora do VS Code: janelinha sempre por cima com as sessões do
# Claude Code (arquivos do hook em ~/.claude-monitor/sessions) e o usage
# (mesmo endpoint do /usage, com o login do Claude Code; não renova o token).
# Toca som quando uma sessão passa a esperar você. O Clawd, com a picareta de
# diamante, anda pela borda enquanto algo roda, pula parado em cima quando há
# pergunta/permissão e fica parado em cima quando nada roda.
# Sons e picareta vêm do Minecraft, se ele estiver instalado (extrair_minecraft.ps1);
# senão, sons do Windows e uma picareta desenhada aqui.
# Clique numa sessão: abre ela no VS Code. Arrastar: botão esquerdo. Duplo clique:
# traz o VS Code. Botão direito: "Fechar".
# Passar o mouse numa sessão: o estado dela.
# A extensão abre isto a cada janela do VS Code; o mutex deixa uma só. Quando a
# extensão atualiza este arquivo, a janelinha se reabre sozinha com a versão nova.
# Teste: -Foto arquivo.png desenha, salva e sai (sem internet: o usage vem de -ArquivoUso
# arquivo.json, se passar); -Pasta troca a ~/.claude-monitor por outra; -Clicar id
# clica na linha dessa sessão (o .txt diz o link que abriria); -Cena "pedra 2.1"
# fotografa esse instante da cena (pedra ou bug), em segundos.
param([string]$Foto, [string]$Pasta, [string]$ArquivoUso, [string]$Clicar, [string]$Cena)
Add-Type -AssemblyName PresentationFramework
if (-not $Pasta) { $Pasta = Join-Path $HOME '.claude-monitor' }
# quem me abre de dentro do VS Code me passa ELECTRON_RUN_AS_NODE=1; com ele, o Code.exe
# que o vscode:// do clique chama roda como Node e morre calado (visto 29/09)
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction Ignore

# diário em janelinha.log: quem abriu, quem desistiu, quando se reabriu, erros.
# Às vezes ela some ao atualizar e não se sabe por quê. O -Foto não anota.
$diario = Join-Path $Pasta 'janelinha.log'
function Anotar($t) {
    if ($Foto) { return }
    try {
        if ((Test-Path -LiteralPath $diario) -and (Get-Item -LiteralPath $diario).Length -gt 256KB) { Move-Item -LiteralPath $diario "$diario.1" -Force }
        [IO.File]::AppendAllText($diario, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$PID] $($t -replace '\s*[\r\n]+\s*', ' ')`r`n", [Text.UTF8Encoding]::new($false))
    } catch {}
}
function Hora($utc) { if ($utc) { $utc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff') } else { 'sumiu' } }
# quem me abriu: extensão (cmd, que já saiu), instalador, atalho (explorer) ou a janelinha velha
function Pai {
    try {
        $id = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        $p = Get-Process -Id $id -ErrorAction Ignore  # Ignore: o pai que já saiu não conta nos erros do "fechou"
        "pai $id $(if ($p) { $p.ProcessName } else { '(já saiu)' })"
    } catch { 'pai ?' }
}

if (-not $Foto) {
    $primeira = $false
    $mutex = [Threading.Mutex]::new($true, 'ClaudeMonitorOverlay', [ref]$primeira)
    # solta o handle antes de anotar: enquanto ele existir, a que está se reabrindo acha que já tem uma
    if (-not $primeira) { $mutex.Dispose(); Anotar "saiu: já tem uma aberta ($(Pai))"; exit }
}
$versao = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc
Anotar "abriu: arquivo de $(Hora $versao) ($(Pai))"
$dir = Join-Path $Pasta 'sessions'
$cred = Join-Path $HOME '.claude\.credentials.json'
# situação da sessão (ver Situacao) -> cor da bolinha e texto do tooltip
$estados = @{
    working    = @('#22C55E', 'trabalhando')
    finished   = @('#EF4444', 'terminou')
    question   = @('#60A5FA', 'pergunta pra você')
    permission = @('#FACC15', 'pedindo permissão')
}
# com mais de um, sorteia. Outros na pasta sons\: pop, aldeao_sim, pling, sino,
# bigorna, gato. Com a janelinha aberta a extensão não toca som.
$aldeao = @(1..2 | ForEach-Object { "$Pasta\sons\aldeao_hmm$_.wav" } | Where-Object { Test-Path $_ })
$xp = @(1..3 | ForEach-Object { "$Pasta\sons\xp$_.wav" } | Where-Object { Test-Path $_ })
$levelup = @("$Pasta\sons\levelup.wav") | Where-Object { Test-Path $_ }
if (-not $aldeao) { $aldeao = @("$env:WINDIR\Media\Windows Notify Messaging.wav") }
if (-not $xp) { $xp = @("$env:WINDIR\Media\Windows Notify System Generic.wav") }
if (-not $levelup) { $levelup = @("$env:WINDIR\Media\tada.wav") }
$sons = @{
    permission = $aldeao   # "hmm" do aldeão
    question   = $aldeao
    finished   = $xp       # pegar XP
    tudo       = $levelup  # subir de nível: a última terminou e não sobrou nada rodando nem esperando
}
$nomeDoSom = @{ permission = 'aldeao'; question = 'aldeao'; finished = 'xp'; tudo = 'levelup' }  # pro .txt do -Foto
$tocador = New-Object Media.SoundPlayer
$ultimo = @{}  # id da sessão -> última situação vista
# teste: o -Foto parte da situação anterior em antes.json, pra ver qual som tocaria
if ($Foto -and (Test-Path -LiteralPath "$Pasta\antes.json")) {
    (Get-Content -LiteralPath "$Pasta\antes.json" -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ultimo[$_.Name] = $_.Value }
}
$somDaVez = $null  # o último som decidido (o -Foto grava no .txt em vez de tocar)
$cliqueDaVez = $null  # o link do último clique numa sessão (o -Foto grava no .txt em vez de abrir)
$uso = @{ proxima = [DateTime]::MinValue; dados = $null }  # usage é buscado a cada 2 min
if ($Foto) { $uso = @{ proxima = [DateTime]::MaxValue; dados = $(if ($ArquivoUso) { Get-Content $ArquivoUso -Raw | ConvertFrom-Json }) } }
$margem = 34  # espaço em volta do cartão, por onde o Clawd anda e pula com a picareta

# Janela de tamanho fixo que nunca se move sozinha: o cartão fica preso no canto
# de baixo à direita e cresce pra cima por dentro dela. (Mover janela transparente
# depois de aberta faz o WPF às vezes desenhá-la na posição antiga.) O resto é
# transparente e o clique passa pro que está atrás.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="320" Height="440" FontFamily="Segoe UI" FontSize="12">
  <Grid>
    <Border Name="Cartao" Background="#E6181818" CornerRadius="8" Padding="10,6"
            HorizontalAlignment="Right" VerticalAlignment="Bottom">
      <StackPanel>
        <StackPanel Name="Sessoes"/>
        <Border Height="1" Background="#33FFFFFF" Margin="0,5,0,4"/>
        <StackPanel Name="Uso"/>
      </StackPanel>
    </Border>
    <Canvas Name="Mascote" IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Top">
      <Canvas.RenderTransform><MatrixTransform/></Canvas.RenderTransform>
    </Canvas>
  </Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$cartao = $win.FindName('Cartao')
$painelSessoes = $win.FindName('Sessoes')
$painelUso = $win.FindName('Uso')
$mascote = $win.FindName('Mascote')
$cartao.Margin = [Windows.Thickness]::new($margem)

function Cor($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

function Texto($texto, $cor, $largura) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $texto
    $t.Foreground = Cor $cor
    $t.VerticalAlignment = 'Center'
    if ($largura) { $t.Width = $largura }
    $t
}

function Linha {
    $l = New-Object Windows.Controls.StackPanel
    $l.Orientation = 'Horizontal'
    $l.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    foreach ($e in $args) { [void]$l.Children.Add($e) }
    $l
}

function Tempo($min) {
    $m = [math]::Max(0, [int][math]::Floor($min))
    if ($m -lt 1) { return 'agora' }
    if ($m -lt 60) { return "${m}m" }
    if ($m -lt 1440) { return '{0}h{1:00}' -f [math]::Floor($m / 60), ($m % 60) }
    return '{0}d{1}h' -f [math]::Floor($m / 1440), [math]::Floor(($m % 1440) / 60)
}

function Sessoes($agora) {
    $vistas = @{}
    Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
        try { $s = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        # mesma regra da extensão: pid vivo; sem pid, atualizada nas últimas 6h
        if ($s.pid) { if (-not (Get-Process -Id $s.pid -ErrorAction Ignore)) { return } }  # Ignore: sessão morta não conta nos erros do "fechou"
        elseif ($agora - $s.updated -gt 6 * 3600) { return }
        $s | Add-Member -NotePropertyName id -NotePropertyValue $_.BaseName
        $titulo = Titulo $s.transcript
        if ($titulo) { $s.name = $titulo }
        $chave = if ($s.pid) { $s.pid } else { $s.id }
        if (-not $vistas[$chave] -or $vistas[$chave].updated -lt $s.updated) { $vistas[$chave] = $s }
    }
    $vistas.Values | ForEach-Object { $_ | Add-Member -NotePropertyName situacao -NotePropertyValue (Situacao $_) -PassThru } |
        Sort-Object updated -Descending
}

# Título da aba: o do /rename ("custom-title") ganha do automático ("ai-title").
# O hook só grava o nome quando você manda mensagem, e na 1ª ainda não existe
# título (ficava o nome da pasta). Lê só o pedaço novo do transcript.
$titulos = @{}  # transcript -> @{ lido; custom; ai }
function Titulo($transcript) {
    if (-not $transcript) { return $null }
    $t = $titulos[$transcript]
    if (-not $t) { $t = @{ lido = 0L; custom = $null; ai = $null }; $titulos[$transcript] = $t }
    try {
        $fs = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $t.lido) { $t.lido = 0L; $t.custom = $null; $t.ai = $null }
            $n = [int]($fs.Length - $t.lido)
            if ($n -gt 0) {
                [void]$fs.Seek($t.lido, 'Begin')
                $buf = New-Object byte[] $n
                $lidos = 0
                while ($lidos -lt $n) { $k = $fs.Read($buf, $lidos, $n - $lidos); if ($k -le 0) { break }; $lidos += $k }
                $fim = [Array]::LastIndexOf($buf, [byte]10, $lidos - 1) + 1  # não consome linha pela metade
                $t.lido += $fim
                $texto = [Text.Encoding]::UTF8.GetString($buf, 0, $fim)
                foreach ($m in [regex]::Matches($texto, '(?m)^.*"type":"(?:custom|ai)-title".*$')) {
                    try { $o = $m.Value | ConvertFrom-Json } catch { continue }
                    if ($o.type -eq 'custom-title' -and $o.customTitle) { $t.custom = $o.customTitle }
                    elseif ($o.type -eq 'ai-title' -and $o.aiTitle) { $t.ai = $o.aiTitle }
                }
            }
        } finally { $fs.Dispose() }
    } catch { }
    if ($t.custom) { $t.custom } else { $t.ai }
}

# O que a última mensagem da conversa pede: 'caixa' (AskUserQuestion aberto),
# 'texto' (resposta terminando em pergunta) ou nada. Lê só o fim do transcript,
# e só quando ele muda de tamanho.
$leituras = @{}  # transcript -> @{ tamanho; resultado }
function UltimoPedido($transcript) {
    if (-not $transcript) { return $null }
    $info = Get-Item -LiteralPath $transcript -ErrorAction SilentlyContinue
    if (-not $info) { return $null }
    $cache = $leituras[$transcript]
    if ($cache -and $cache.tamanho -eq $info.Length) { return $cache.resultado }
    $resultado = $null
    try {
        $fs = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [int][math]::Min($fs.Length, 65536)
            $cortou = $n -lt $fs.Length  # leu do meio: a 1ª linha pode ter vindo pela metade
            [void]$fs.Seek(-$n, 'End')
            $buf = New-Object byte[] $n
            [void]$fs.Read($buf, 0, $n)
        } finally { $fs.Dispose() }
        $linhas = [Text.Encoding]::UTF8.GetString($buf).Split("`n")
        for ($i = $linhas.Count - 1; $i -ge [int]$cortou; $i--) {
            $l = $linhas[$i]
            if ($l -notmatch '"type":"(assistant|user)"' -or $l -match '"isSidechain":true') { continue }
            # cada bloco da resposta vem numa linha; só converte o JSON (lento no
            # PowerShell 5) quando é texto — ferramenta se resolve pelo nome
            if ($l -match '"type":"assistant"') {
                if ($l -match '"type":"tool_use"') { if ($l -match '"name":"AskUserQuestion"') { $resultado = 'caixa' } }
                elseif ($l -match '"type":"text"') {
                    $bloco = @(($l | ConvertFrom-Json).message.content)[-1]
                    # "?" entre aspas ou crases é citação (fala de cliente, exemplo), não pergunta pra você
                    $ultima = ($bloco.text.Trim() -split "`n")[-1] -replace '"[^"]*"|“[^”]*”|`[^`]*`', ''
                    if ($ultima -match '\?') { $resultado = 'texto' }
                }
            }
            break
        }
    } catch { }
    $leituras[$transcript] = @{ tamanho = $info.Length; resultado = $resultado }
    $resultado
}

# Situação a partir do estado do hook + última mensagem. Trabalhando/permissão só
# viram pergunta com a caixinha (texto com "?" no meio do trabalho não conta).
function Situacao($s) {
    $estado = $s.state
    # depois de aprovar uma permissão nenhum hook dispara até a sessão parar; se o
    # transcript mexeu depois do pedido, ela voltou a trabalhar (regra da extensão)
    if ($estado -eq 'permission' -and $s.transcript) {
        $mexeu = (Get-Item -LiteralPath $s.transcript -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($mexeu -and ([DateTimeOffset]$mexeu).ToUnixTimeMilliseconds() / 1000 -gt $s.since + 2) { $estado = 'working' }
    }
    $pedido = UltimoPedido $s.transcript
    switch ($estado) {
        'waiting' { if ($pedido) { 'question' } else { 'finished' } }
        default   { if ($pedido -eq 'caixa') { 'question' } else { $estado } }
    }
}

# som quando alguma sessão MUDA de situação pra terminou/pergunta/permissão (uma
# vez por mudança; na abertura não toca). Se vierem juntas, o aldeão ganha do XP.
# Terminou a última (todas terminadas, nada rodando nem esperando): sobe de nível.
function Avisar($sessoes) {
    $tocar = $null
    foreach ($s in $sessoes) {
        $antes = $ultimo[$s.id]
        if ($antes -and $antes -ne $s.situacao -and $sons[$s.situacao] -and $tocar -notin 'permission', 'question') { $tocar = $s.situacao }
        $ultimo[$s.id] = $s.situacao
    }
    if ($tocar -eq 'finished' -and -not @($sessoes | Where-Object { $_.situacao -ne 'finished' })) { $tocar = 'tudo' }
    if ($tocar) {
        $script:somDaVez = $tocar
        if ($Foto) { return }
        $tocador.SoundLocation = $sons[$tocar] | Get-Random
        # no diário: amigo sem som manda o janelinha.log e dá pra ver se ela tentou tocar
        try { $tocador.Play(); Anotar "tocou $($nomeDoSom[$tocar]) ($(Split-Path $tocador.SoundLocation -Leaf))" }
        catch { Anotar "não toquei $($tocador.SoundLocation): $($_.Exception.Message)" }
    }
}

function Medidor($rotulo, $dado) {
    $pct = [double]$dado.utilization
    $cor = if ($pct -ge 95) { '#EF4444' } elseif ($pct -ge 80) { '#F59E0B' } else { '#D1D5DB' }
    $trilho = New-Object Windows.Controls.Border
    $trilho.Width = 118; $trilho.Height = 4
    $trilho.CornerRadius = [Windows.CornerRadius]::new(2)
    $trilho.Background = Cor '#3F3F46'
    $trilho.VerticalAlignment = 'Center'
    $barra = New-Object Windows.Controls.Border
    $barra.Width = 118 * [math]::Min($pct, 100) / 100
    $barra.CornerRadius = [Windows.CornerRadius]::new(2)
    $barra.Background = Cor $cor
    $barra.HorizontalAlignment = 'Left'
    $trilho.Child = $barra
    $p = Texto ('{0:0}%' -f $pct) $cor 38
    $p.TextAlignment = 'Right'
    # quanto falta pra renovar
    $falta = if ($dado.resets_at) { Tempo ([DateTimeOffset]$dado.resets_at - [DateTimeOffset]::Now).TotalMinutes } else { '' }
    $f = Texto $falta '#6B7280' 48
    $f.TextAlignment = 'Right'
    Linha (Texto $rotulo '#9CA3AF' 18) $trilho $p $f
}

function Atualizar {
    $agora = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000
    $sessoes = @(Sessoes $agora)
    Avisar $sessoes
    $painelSessoes.Children.Clear()
    if (-not $sessoes) { [void]$painelSessoes.Children.Add((Texto 'nenhuma sessão aberta' '#9CA3AF')) }
    foreach ($s in $sessoes) {
        $cor, $rotulo = $estados[$s.situacao]
        if (-not $cor) { $cor, $rotulo = '#9CA3AF', $s.situacao }
        $bola = New-Object Windows.Shapes.Ellipse
        $bola.Width = 8; $bola.Height = 8
        $bola.Fill = Cor $cor
        $bola.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        $bola.VerticalAlignment = 'Center'
        $nomeSessao = Texto $s.name '#E5E7EB' 170
        $nomeSessao.TextTrimming = 'CharacterEllipsis'
        $tempo = Texto (Tempo (($agora - $s.since) / 60)) $cor 36
        $tempo.TextAlignment = 'Right'
        $linha = Linha $bola $nomeSessao $tempo
        $linha.Background = [Windows.Media.Brushes]::Transparent
        $linha.ToolTip = $rotulo
        $linha.Tag = "sessao:$($s.id)"  # o clique acha a sessão por aqui
        $linha.Cursor = [Windows.Input.Cursors]::Hand
        [void]$painelSessoes.Children.Add($linha)
    }
    # pedindo algo (pergunta/permissão) ganha de trabalhando, que ganha de parado
    $situacoes = @($sessoes | ForEach-Object { $_.situacao })
    Clawd $(if ($situacoes -contains 'question' -or $situacoes -contains 'permission') { 'pulando' }
            elseif ($situacoes -contains 'working') { 'andando' } else { 'parado' })
    if ($passeio.modo -eq 'andando' -and -not $luta.tipo -and -not $Foto -and [DateTime]::Now -ge $luta.proxima) {
        ComecarCena $(if ($luta.ferramenta -eq 'espada') { 'bug' } else { 'pedra' })
    }

    if ([DateTime]::Now -ge $uso.proxima) {
        $uso.proxima = [DateTime]::Now.AddSeconds(20)  # se falhar, tenta de novo logo
        try {
            $token = (Get-Content $cred -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
            $uso.dados = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 5 -Headers @{
                Authorization    = "Bearer $token"
                'anthropic-beta' = 'oauth-2025-04-20'
            }
            $uso.proxima = [DateTime]::Now.AddMinutes(2)
        } catch {
            # falha passageira: fica o último valor; se for limite de requisições, espera mais
            if ($_.Exception.Response.StatusCode.value__ -eq 429) { $uso.proxima = [DateTime]::Now.AddMinutes(5) }
        }
    }
    # redesenha a cada 2 s pra contagem de "falta" andar entre as buscas
    $painelUso.Children.Clear()
    if ($uso.dados) {
        [void]$painelUso.Children.Add((Medidor '5h' $uso.dados.five_hour))
        [void]$painelUso.Children.Add((Medidor '7d' $uso.dados.seven_day))
    } else {
        [void]$painelUso.Children.Add((Texto 'usage indisponível' '#6B7280'))
    }
}

# --- Clawd: pixel art do mascote do Claude Code (o do banner do terminal) ---
# '#' corpo, 'o' olho, 'A'/'B' os dois pares de pernas, que se alternam.
# Origem (0,0) = entre os pés, então ele "pisa" na trilha e o corpo fica pra fora.
# Pixel 2x mais alto que largo, como os meio-blocos do terminal (senão fica achatado).
$sprite = @(
    '...############...',
    '...##o######o##...',
    '.################.',
    '...############...',
    '....A.B....A.B....'
)
$pw = 1.5; $ph = 3

# pulinhos: sobe rápido e desacelera no alto; o AutoReverse faz a volta acelerar
$pulo = New-Object Windows.Controls.Canvas
$pulo.RenderTransform = New-Object Windows.Media.TranslateTransform
[void]$mascote.Children.Add($pulo)
$salto = [Windows.Media.Animation.DoubleAnimation]::new(0, -5, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(160)))
$salto.AutoReverse = $true
$salto.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$salto.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = 'EaseOut' }
[Windows.Media.Animation.Timeline]::SetDesiredFrameRate($salto, 40)
$pulo.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $salto)

function Forma($padrao, $cor) {
    $g = New-Object Windows.Media.GeometryGroup
    for ($lin = 0; $lin -lt $sprite.Count; $lin++) {
        foreach ($m in [regex]::Matches($sprite[$lin], $padrao)) {
            $r = [Windows.Rect]::new(($m.Index - 9) * $pw, ($lin - 5) * $ph, $m.Length * $pw, $ph)
            [void]$g.Children.Add([Windows.Media.RectangleGeometry]::new($r))
        }
    }
    $p = New-Object Windows.Shapes.Path
    $p.Data = $g
    $p.Fill = Cor $cor
    [void]$pulo.Children.Add($p)
    $p
}
[void](Forma '[#o]+' '#D77757')
[void](Forma 'o+' '#1A1A1A')
$pernaA = Forma 'A+' '#D77757'
$pernaB = Forma 'B+' '#D77757'
$pernaB.Visibility = 'Hidden'

# Sem Minecraft: 16x16 desenhados aqui, com o cabo no mesmo pixel das texturas
# do jogo. d/c/b = diamante (contorno, cor, brilho); k/h = cabo; s/e/l = pedra
# (cor, escuro, claro). O bug é sempre daqui (o Minecraft não tem um que sirva).
$cores16 = [ordered]@{ d = '#1B6E73'; c = '#4AEDD9'; b = '#C9FFF6'; k = '#3B2A14'; h = '#8A5A2B'; s = '#7D7D7D'; e = '#5E5E5E'; l = '#A0A0A0' }
$desenhos = @{
    picareta = @(
        '................',
        '....ddddd.......',
        '...dbbcccdd.....',
        '....dddcccbd....',
        '.......ddcccd...',
        '.........dccd...',
        '........kdcbcd..',
        '.......khkdccd..',
        '......khk..dcd..',
        '.....khk...dcd..',
        '....khk.....dd..',
        '...khk..........',
        '..khk...........',
        '..kk............',
        '................',
        '................')
    espada = @(
        '................',
        '............ddd.',
        '...........dbcd.',
        '..........dbcd..',
        '.........dbcd...',
        '........dbcd....',
        '.......dbcd.....',
        '......dbcd......',
        '..dd.dbcd.......',
        '..dcdbcd........',
        '...dccd.........',
        '...kdcdd........',
        '..khkddcd.......',
        '.khk...dd.......',
        '.kk.............',
        '................')
    diamante = @(
        '................',
        '................',
        '....dddddddd....',
        '...dbbcccccbd...',
        '..dbbccccccccd..',
        '..dccccccccccd..',
        '...dcccccccbd...',
        '....dccccccd....',
        '.....dccccd.....',
        '......dccd......',
        '.......dd.......',
        '................',
        '................',
        '................',
        '................',
        '................')
    pedra = @(
        'ssslssssesssslss',
        'sesssssssslsssse',
        'sssbcssesssssbcs',
        'lsdccdsssssesdcd',
        'ssssdsslssssssds',
        'sesssssssbcsssss',
        'ssslsssesdccdsls',
        'ssssssssssdsssss',
        'sbcsslssssssesss',
        'dccdsssssslssbcs',
        'sdsssesssssssdcc',
        'ssssssssbcssssds',
        'slssssesdccdslss',
        'sssesssssdssssss',
        'ssssslsssssssess',
        'esssssssslssssss')
    # de lado, olhando pra esquerda (pro Clawd); p/q = as pernas, que se alternam
    bug = @(
        'a............',
        '.a...vvvvv...',
        '..a.vwwvvvvv.',
        '.aaavwvvxvvvv',
        'aoaavvvvvxvvv',
        '.aaaavvvvvxv.',
        '..pq..pq..pq.',
        '.p..qp..qp..q')
}
$coresBug = [ordered]@{ v = '#65A30D'; w = '#A3E635'; x = '#365314'; a = '#111827'; o = '#F8FAFC'; p = '#111827'; q = '#111827' }
$coresBugVermelho = [ordered]@{ v = '#EF4444'; w = '#FCA5A5'; x = '#991B1B'; a = '#450A0A'; o = '#FEE2E2'; p = '#450A0A'; q = '#450A0A' }  # levou o golpe
function Desenho($linhas, $cores) {
    $grupo = New-Object Windows.Media.DrawingGroup
    # retângulo invisível do tamanho todo: sem ele a imagem encolhe pro tamanho do desenho
    [void]$grupo.Children.Add([Windows.Media.GeometryDrawing]::new([Windows.Media.Brushes]::Transparent, $null,
        [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, $linhas[0].Length, $linhas.Count))))
    foreach ($c in $cores.Keys) {
        $g = New-Object Windows.Media.GeometryGroup
        for ($y = 0; $y -lt $linhas.Count; $y++) {
            for ($x = 0; $x -lt $linhas[$y].Length; $x++) {
                if ($linhas[$y][$x] -ceq $c) { [void]$g.Children.Add([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($x, $y, 1, 1))) }
            }
        }
        [void]$grupo.Children.Add([Windows.Media.GeometryDrawing]::new((Cor $cores[$c]), $null, $g))
    }
    [Windows.Media.DrawingImage]::new($grupo)
}
# textura do Minecraft (extrair_minecraft.ps1), se tiver; senão, o desenho daqui
function Textura($nome) {
    $arquivo = "$Pasta\$nome.png"
    if (-not (Test-Path $arquivo)) { return Desenho $desenhos[$nome] $cores16 }
    $textura = New-Object Windows.Media.Imaging.BitmapImage
    $textura.BeginInit()
    $textura.UriSource = [Uri]$arquivo
    $textura.CacheOption = 'OnLoad'
    $textura.EndInit()
    $textura
}
function Imagem($fonte, $lado, $altura) {
    $i = New-Object Windows.Controls.Image
    $i.Source = $fonte
    $i.Width = $lado; $i.Height = $(if ($altura) { $altura } else { $lado })
    [Windows.Media.RenderOptions]::SetEdgeMode($i, 'Aliased')
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($i, 'NearestNeighbor')
    $i
}
$texturas = @{}
foreach ($n in 'picareta', 'espada', 'diamante', 'pedra') { $texturas[$n] = Textura $n }

# a ferramenta (picareta ou espada) na mão direita, balançando como quem minera;
# o cabo (canto de baixo à esquerda da textura) fica na mão
$ferramenta = Imagem $texturas.picareta 17.6  # 1,1 por pixel da textura 16x16
$cabo = [Windows.Point]::new(2.75, 14.85)  # pixel (2,5; 13,5) da textura
$mao = [Windows.Point]::new(12, -7.5)      # ponta do braço direito do Clawd
[Windows.Controls.Canvas]::SetLeft($ferramenta, $mao.X - $cabo.X)
[Windows.Controls.Canvas]::SetTop($ferramenta, $mao.Y - $cabo.Y)
$giro = [Windows.Media.RotateTransform]::new(0, $cabo.X, $cabo.Y)
$ferramenta.RenderTransform = $giro
$balanco = [Windows.Media.Animation.DoubleAnimation]::new(-25, 15, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(320)))
$balanco.AutoReverse = $true
$balanco.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$balanco.EasingFunction = New-Object Windows.Media.Animation.SineEase
[Windows.Media.Animation.Timeline]::SetDesiredFrameRate($balanco, 40)
$giro.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $balanco)
[void]$pulo.Children.Add($ferramenta)

# Trilha = borda arredondada do cartão, no sentido horário; o Clawd gira junto
# nas curvas. Refeita quando o cartão muda de tamanho, sem perder o lugar dele.
# Fora do modo 'andando' ele fica parado no meio da borda de cima.
$passeio = @{ relogio = [Diagnostics.Stopwatch]::StartNew(); duracao = 0; inicio = 0; modo = $null }
function Trilha {
    if ($luta.tipo) { return }  # parado lutando; o fim da cena refaz a trilha
    $w = $cartao.ActualWidth; $h = $cartao.ActualHeight
    if (-not $w) { return }
    $o = $cartao.TranslatePoint([Windows.Point]::new(0, 0), $mascote.Parent)
    if ($passeio.modo -ne 'andando') {
        $mascote.RenderTransform.BeginAnimation([Windows.Media.MatrixTransform]::MatrixProperty, $null)
        $mascote.RenderTransform.Matrix = [Windows.Media.Matrix]::new(1, 0, 0, 1, $o.X + $w / 2, $o.Y)
        $passeio.duracao = 0  # quando voltar a andar, sai daqui
        return
    }
    $r = 8; $esq = $o.X; $dir_ = $o.X + $w; $topo = $o.Y; $base = $o.Y + $h
    $d = [string]::Format([Globalization.CultureInfo]::InvariantCulture,
        'M {0},{2} L {1},{2} A {8},{8} 0 0 1 {3},{4} L {3},{5} A {8},{8} 0 0 1 {1},{6} L {0},{6} A {8},{8} 0 0 1 {7},{5} L {7},{4} A {8},{8} 0 0 1 {0},{2} Z',
        [object[]]@(($esq + $r), ($dir_ - $r), $topo, $dir_, ($topo + $r), ($base - $r), $base, $esq, $r))
    $perimetro = 2 * ($w + $h) - (8 - 2 * [math]::PI) * $r
    # fração da volta onde ele está; parado, estava no meio de cima
    $fracao = if ($passeio.duracao) { ($passeio.relogio.Elapsed.TotalSeconds + $passeio.inicio) % $passeio.duracao / $passeio.duracao }
              else { ($w / 2 - $r) / $perimetro }
    $passeio.duracao = $perimetro / 50  # ~50 px/s
    $passeio.inicio = $fracao * $passeio.duracao
    $passeio.relogio.Restart()

    $a = New-Object Windows.Media.Animation.MatrixAnimationUsingPath
    $a.PathGeometry = [Windows.Media.PathGeometry]::CreateFromGeometry([Windows.Media.Geometry]::Parse($d))
    $a.DoesRotateWithTangent = $true
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds($passeio.duracao))
    $a.BeginTime = [TimeSpan]::FromSeconds(-$passeio.inicio)
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 40)
    $mascote.RenderTransform.BeginAnimation([Windows.Media.MatrixTransform]::MatrixProperty, $a)
}
$cartao.Add_SizeChanged({ Trilha })

$passo = New-Object Windows.Threading.DispatcherTimer
$passo.Interval = [TimeSpan]::FromMilliseconds(160)  # troca de perna a cada meio pulo
$passo.Add_Tick({
    $v = $pernaA.Visibility
    $pernaA.Visibility = $pernaB.Visibility
    $pernaB.Visibility = $v
})

# --- Cenas: de vez em quando, andando, ele para e luta ---
# picareta: aparece uma pedra de diamante na frente, ele bate 3x, ela vira farelo
# e sobe um diamante. espada: chega um bug, 3 espadadas, o bug vira fumaça. A
# ferramenta é sorteada cada vez que ele começa a andar. Tudo mora no Canvas que
# anda pela trilha (x+ = pra frente, y- = pra fora do cartão) e cada quadro é
# função do tempo (Quadro), então o -Foto fotografa qualquer instante (-Cena).
$bugs = @{}
foreach ($perna in 'p', 'q') {
    $linhas = $desenhos.bug | ForEach-Object { $_.Replace($(if ($perna -eq 'p') { 'q' } else { 'p' }), '.') }
    $bugs[$perna] = Desenho $linhas $coresBug
    $bugs["$perna!"] = Desenho $linhas $coresBugVermelho
}
$alvo = Imagem $texturas.pedra 12
$alvo.Visibility = 'Hidden'
$mascote.Children.Insert(0, $alvo)  # atrás da ferramenta, que bate por cima
$diamante = Imagem $texturas.diamante 11
$diamante.Visibility = 'Hidden'
[void]$mascote.Children.Add($diamante)
$farelos = foreach ($i in 1..8) {
    $f = New-Object Windows.Shapes.Rectangle
    $f.Visibility = 'Hidden'
    [void]$mascote.Children.Add($f)
    $f
}
$voos = @(@(-30, -60), @(-12, -80), @(10, -75), @(28, -55), @(-22, -30), @(20, -35), @(0, -90), @(34, -20))  # px/s
$coresFarelo = @{ pedra = '#7D7D7D', '#4AEDD9', '#A0A0A0', '#5E5E5E'; bug = '#E5E7EB', '#9CA3AF' }
# em segundos: o alvo chega, leva 3 golpes (o 3º mata) e a cena acaba em "fim"
$roteiros = @{ pedra = @{ chega = 0.3; golpe = 0.5; fim = 3.2 }; bug = @{ chega = 1.0; golpe = 0.45; fim = 2.9 } }
$luta = @{ tipo = $null; relogio = New-Object Diagnostics.Stopwatch; proxima = [DateTime]::MaxValue; ferramenta = 'picareta' }
function Pos($e, $x, $y) { [Windows.Controls.Canvas]::SetLeft($e, $x); [Windows.Controls.Canvas]::SetTop($e, $y) }
# ângulo da ferramenta num golpe (u de 0 a 1): levanta devagar, desce rápido
function Golpe($u) { if ($u -lt 0.7) { -40 * $u / 0.7 } else { -40 + 110 * ($u - 0.7) / 0.3 } }
function Quadro($t) {
    $c = $roteiros[$luta.tipo]
    $morre = $c.chega + 3 * $c.golpe
    $g = ($t - $c.chega) / $c.golpe  # golpes dados, com fração
    $giro.Angle = $(if ($g -ge 0 -and $g -lt 3) { Golpe ($g % 1) } else { 0 })
    $acerto = $(if ($g -ge 1 -and $t -lt $morre) { ($g % 1) * $c.golpe } else { 99 })  # s desde o último golpe
    $d = $t - $morre  # s desde que morreu
    $alvo.Visibility = $(if ($d -lt 0) { 'Visible' } else { 'Hidden' })
    if ($luta.tipo -eq 'pedra') {
        $alvo.RenderTransform = [Windows.Media.ScaleTransform]::new(1, [math]::Min(1.0, $t / $c.chega), 6, 12)  # brota do chão
        Pos $alvo (16 + $(if ($acerto -lt 0.1) { 1 } else { 0 })) -12  # treme com o golpe
        $centro = 22, -6
    } else {
        $x = $(if ($t -lt $c.chega) { 42 - 25 * $t / $c.chega } else { 17 + $(if ($acerto -lt 0.15) { 2 } else { 0 }) })  # chega; recua no golpe
        Pos $alvo $x -12.8
        $alvo.Source = $bugs["$(if ([math]::Floor($t / 0.1) % 2) { 'q' } else { 'p' })$(if ($acerto -lt 0.15) { '!' })"]
        $centro = 27.4, -6.4
    }
    # farelos da pedra (caem) ou fumaça do bug (sobe devagar e cresce), por 0,6 s
    for ($i = 0; $i -lt 8; $i++) {
        $f = $farelos[$i]
        $f.Visibility = $(if ($d -ge 0 -and $d -lt 0.6) { 'Visible' } else { 'Hidden' })
        if ($f.Visibility -ne 'Visible') { continue }
        $f.Opacity = 1 - $d / 0.6
        if ($luta.tipo -eq 'pedra') {
            $f.Width = 2; $f.Height = 2
            Pos $f ($centro[0] + $voos[$i][0] * $d) ($centro[1] + $voos[$i][1] * $d + 150 * $d * $d)
        } else {
            # nasce numa roda em volta do bug e se abre
            $f.Width = 3 + 5 * $d; $f.Height = $f.Width
            $x = $centro[0] + $voos[$i][0] * (0.06 + $d * 0.3) - $f.Width / 2
            Pos $f $x ($centro[1] + $voos[$i][1] * (0.06 + $d * 0.2) - 10 * $d - $f.Width / 2)
        }
    }
    # o diamante sobe da pedra, fica balançando e some
    $diamante.Visibility = $(if ($luta.tipo -eq 'pedra' -and $d -ge 0) { 'Visible' } else { 'Hidden' })
    if ($diamante.Visibility -eq 'Visible') {
        $s = [math]::Min(1.0, $d / 0.6)
        Pos $diamante 16.5 (-11.5 - 16 * (1 - (1 - $s) * (1 - $s)) + [math]::Sin($d * 7) * 0.8)
        $diamante.Opacity = $(if ($d -lt 1) { 1 } else { [math]::Max(0.0, 1 - ($d - 1) / 0.4) })
    }
}
$quadros = New-Object Windows.Threading.DispatcherTimer
$quadros.Interval = [TimeSpan]::FromMilliseconds(40)
$quadros.Add_Tick({
    $t = $luta.relogio.Elapsed.TotalSeconds
    if ($t -lt $roteiros[$luta.tipo].fim) { Quadro $t } else { FimDaCena; Movimento }
})
function ComecarCena($tipo) {
    $luta.tipo = $tipo
    $ferramenta.Source = $texturas[$(if ($tipo -eq 'bug') { 'espada' } else { 'picareta' })]
    if ($tipo -eq 'pedra') { $alvo.Source = $texturas.pedra; $alvo.Width = 12; $alvo.Height = 12 }
    else { $alvo.RenderTransform = $null; $alvo.Width = 13 * 1.6; $alvo.Height = 8 * 1.6 }
    for ($i = 0; $i -lt 8; $i++) { $farelos[$i].Fill = Cor $coresFarelo[$tipo][$i % $coresFarelo[$tipo].Count] }
    # congela onde está: sem trilha, pulo, troca de perna nem balanço
    $passeio.relogio.Stop()
    $m = $mascote.RenderTransform.Value
    $mascote.RenderTransform.BeginAnimation([Windows.Media.MatrixTransform]::MatrixProperty, $null)
    $mascote.RenderTransform.Matrix = $m
    $pulo.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $passo.Stop()
    $pernaA.Visibility = 'Visible'; $pernaB.Visibility = 'Visible'
    $giro.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
    $luta.relogio.Restart()
    Quadro 0
    $quadros.Start()
}
function FimDaCena {
    $quadros.Stop()
    $luta.tipo = $null
    $alvo.Visibility = 'Hidden'; $diamante.Visibility = 'Hidden'
    foreach ($f in $farelos) { $f.Visibility = 'Hidden' }
    $giro.Angle = 0
    $luta.proxima = [DateTime]::Now.AddSeconds((Get-Random -Minimum 20 -Maximum 45))
    $passeio.relogio.Start()  # a trilha continua de onde parou
}

# 'andando' (algo rodando): anda, pula, troca de perna e minera (e às vezes luta).
# 'pulando' (pergunta/permissão): parado em cima do cartão, pulando.
# 'parado' (nada rodando): parado em cima do cartão, com as 4 pernas no chão.
function Clawd($modo) {
    if ($passeio.modo -eq $modo) { return }
    if ($luta.tipo) { FimDaCena }  # mudou no meio da luta
    if ($modo -eq 'andando' -and -not $Foto) {  # o -Foto fica sempre na picareta
        $luta.ferramenta = Get-Random -InputObject 'picareta', 'espada'
        $ferramenta.Source = $texturas[$luta.ferramenta]
        $luta.proxima = [DateTime]::Now.AddSeconds((Get-Random -Minimum 20 -Maximum 45))
    }
    $passeio.modo = $modo
    Movimento
}
function Movimento {
    $modo = $passeio.modo
    $anda = $modo -eq 'andando'
    $pulo.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $(if ($modo -eq 'parado') { $null } else { $salto }))
    $passo.Stop()
    $pernaA.Visibility = 'Visible'
    $pernaB.Visibility = $(if ($anda) { 'Hidden' } else { 'Visible' })
    if ($anda) { $passo.Start() }
    if ($giro) { $giro.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $(if ($anda) { $balanco } else { $null })) }
    Trilha
}

# nasce no canto de baixo à direita (a $margem já afasta o cartão da borda)
# Só o arrasto muda o lugar dela. Às vezes, logo depois de abrir, o Windows/WPF
# joga a janela pra outro canto sozinho; aí ela volta (na hora e a cada 2 s).
$area = [Windows.SystemParameters]::WorkArea
$lugar = @{ x = $area.Right - $win.Width; y = $area.Bottom - $win.Height; arrastando = $false }
if ($Foto) { $lugar.x = -10000; $win.ShowActivated = $false }  # teste: desenha fora da tela
function Recolocar {
    if ($lugar.arrastando) { return }
    if ([math]::Abs($win.Left - $lugar.x) -gt 1 -or [math]::Abs($win.Top - $lugar.y) -gt 1) {
        $win.Left = $lugar.x
        $win.Top = $lugar.y
    }
}
$win.Left = $lugar.x
$win.Top = $lugar.y
$win.Add_LocationChanged({ Recolocar })

function TrazerVSCode {
    $shell = New-Object -ComObject WScript.Shell
    if (-not $shell.AppActivate('Visual Studio Code')) { [void]$shell.AppActivate('Cursor') }
}
# a sessão da linha nesse ponto da janela (a linha guarda "sessao:<id>" no Tag), ou nada
function SessaoNoPonto($ponto) {
    for ($e = [Windows.Media.VisualTreeHelper]::HitTest($win, $ponto).VisualHit; $e; $e = [Windows.Media.VisualTreeHelper]::GetParent($e)) {
        if ("$($e.Tag)" -like 'sessao:*') { return "$($e.Tag)".Substring(7) }
    }
}
# a extensão recebe o link e abre a aba (ou o terminal) da sessão, como o clique na lista dela
function AbrirSessao($id) {
    $url = "vscode://local.claude-monitor/sessao?id=$([uri]::EscapeDataString($id))"
    if ($Foto) { $script:cliqueDaVez = $url; return }
    try { Start-Process $url -ErrorAction Stop } catch { Anotar "não abri $url ($_)"; TrazerVSCode }
}
$win.Add_MouseLeftButtonDown({
    if ($_.ClickCount -eq 2) { TrazerVSCode; return }
    # já na descida: durante o arrasto a lista pode se redesenhar
    $sessao = SessaoNoPonto ($_.GetPosition($win))
    $lugar.arrastando = $true
    try { $win.DragMove() } finally { $lugar.arrastando = $false }
    $clicou = [math]::Abs($win.Left - $lugar.x) -le 2 -and [math]::Abs($win.Top - $lugar.y) -le 2  # não arrastou
    $lugar.x = $win.Left
    $lugar.y = $win.Top
    if ($clicou -and $sessao) { AbrirSessao $sessao }
})
$fechar = New-Object Windows.Controls.MenuItem
$fechar.Header = 'Fechar'
$fechar.Add_Click({ Anotar 'fechada pelo menu'; $win.Close() })
# só anota: o erro segue o caminho de sempre
$win.Dispatcher.Add_UnhandledException({ Anotar "erro: $($_.Exception.Message)" })
$win.ContextMenu = New-Object Windows.Controls.ContextMenu
[void]$win.ContextMenu.Items.Add($fechar)

# "sempre por cima" às vezes quebra: o Windows deixa janela normal passar na frente
# (visto 29/09: VS Code, Fotos e Opera na frente dela). Se tiver alguma, volta pro
# topo sem roubar o foco. Só quando quebrou: senão brigaria com o menu Iniciar,
# o recorte de tela e as outras "sempre por cima".
if (-not $Foto) {
    try {
        Add-Type -Namespace ClaudeMonitor -Name Topo -MemberDefinition @'
[DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr depois, int x, int y, int cx, int cy, uint f);
// devolve o pid da 1ª janela normal (de outro processo) acima desta, depois de voltar pro topo; 0 = nada na frente
public static uint Voltar(IntPtr h, uint eu) {
    for (IntPtr w = GetWindow(h, 3); w != IntPtr.Zero; w = GetWindow(w, 3)) {  // 3 = a de cima
        uint pid;
        GetWindowThreadProcessId(w, out pid);
        if (pid == eu || !IsWindowVisible(w) || (GetWindowLong(w, -20) & 0x8) != 0) continue;  // 0x8 = sempre por cima
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x13);  // -1 = topo; 0x13 = sem mover, redimensionar nem ativar
        return pid;
    }
    return 0;
}
'@
    } catch { Anotar "sem o conserto do sempre por cima: $_" }
}
function NoTopo {
    if (-not ('ClaudeMonitor.Topo' -as [type])) { return }
    $na = [ClaudeMonitor.Topo]::Voltar((New-Object Windows.Interop.WindowInteropHelper $win).Handle, $PID)
    if ($na) { Anotar "voltei pro topo: $((Get-Process -Id $na -ErrorAction Ignore).ProcessName) [$na] estava na frente" }
}

# a extensão trocou este arquivo por uma versão nova: solta a vaga e abre a nova
function SeAtualizou {
    if ($Foto) { return }
    $agora = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc
    if ($agora -eq $versao) { return }
    $timer.Stop()
    try {
        # fecha o handle, não só solta: enquanto existir handle, a nova acha que já tem uma aberta
        $mutex.ReleaseMutex()
        $mutex.Dispose()
        $nova = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pasta', "`"$Pasta`""
        Anotar "arquivo mudou ($(Hora $versao) -> $(Hora $agora)): reabri como [$($nova.Id)]"
    } catch { Anotar "erro ao reabrir: $_"; throw }
    $win.Close()
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Atualizar; Recolocar; NoTopo; SeAtualizou })
$timer.Start()

# teste: depois de desenhar, salva o PNG e, ao lado (.txt), o que viu; e fecha
if ($Foto) {
    $espera = New-Object Windows.Threading.DispatcherTimer
    $espera.Interval = [TimeSpan]::FromMilliseconds(1200)
    $espera.Add_Tick({
        $espera.Stop()
        if ($Cena) {
            $tipo, $t = -split $Cena
            ComecarCena $tipo
            $quadros.Stop()
            Quadro ([double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture))
            $win.UpdateLayout()
        }
        $imagem = [Windows.Media.Imaging.RenderTargetBitmap]::new(320, 440, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $imagem.Render($win.Content)
        $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($imagem))
        $arquivo = [IO.File]::Create($Foto)
        try { $png.Save($arquivo) } finally { $arquivo.Dispose() }
        # -Clicar: o meio da linha daquela sessão, pelo mesmo caminho do clique de verdade
        $alvo = @($painelSessoes.Children | Where-Object { "$($_.Tag)" -eq "sessao:$Clicar" })[0]
        if ($Clicar -and $alvo) {
            $sessao = SessaoNoPonto ($alvo.TranslatePoint([Windows.Point]::new($alvo.ActualWidth / 2, $alvo.ActualHeight / 2), $win))
            if ($sessao) { AbrirSessao $sessao }
        }
        $visto = @(Sessoes ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000) | ForEach-Object {
            "sessao: $($_.name) | hook=$($_.state) | janelinha=$($_.situacao)"
        }) + "clawd: $($passeio.modo)$(if ($luta.tipo) { " ($($luta.tipo))" })" + "usage: $(if ($uso.dados) { 'ok' } else { 'indisponivel' })" +
            "som: $(if ($somDaVez) { $nomeDoSom[$somDaVez] } else { 'nenhum' })" +
            "clique: $(if ($cliqueDaVez) { $cliqueDaVez } else { 'nenhum' })"
        [IO.File]::WriteAllLines("$Foto.txt", [string[]]$visto, [Text.UTF8Encoding]::new($false))
        $win.Close()
    })
    $win.Add_ContentRendered({ $espera.Start() })
}

Atualizar
[void]$win.ShowDialog()
Anotar "fechou ($($Error.Count) erros$(if ($Error.Count) { "; último: $($Error[0])" }))"
