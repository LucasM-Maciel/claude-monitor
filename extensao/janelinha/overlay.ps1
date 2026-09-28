# Claude Monitor fora do VS Code: janelinha sempre por cima com as sessões do
# Claude Code (arquivos do hook em ~/.claude-monitor/sessions) e o usage
# (mesmo endpoint do /usage, com o login do Claude Code; não renova o token).
# Toca som quando uma sessão passa a esperar você. O Clawd, com a picareta de
# diamante, anda pela borda enquanto algo roda, pula parado em cima quando há
# pergunta/permissão e fica parado em cima quando nada roda.
# Sons e picareta vêm do Minecraft, se ele estiver instalado (extrair_minecraft.ps1);
# senão, sons do Windows e uma picareta desenhada aqui.
# Arrastar: botão esquerdo. Duplo clique: traz o VS Code. Botão direito: "Fechar".
# Passar o mouse numa sessão: o estado dela.
# A extensão abre isto a cada janela do VS Code; o mutex deixa uma só. Quando a
# extensão atualiza este arquivo, a janelinha se reabre sozinha com a versão nova.
# Teste: -Foto arquivo.png desenha, salva e sai (sem internet: o usage vem de -ArquivoUso
# arquivo.json, se passar); -Pasta troca a ~/.claude-monitor por outra.
param([string]$Foto, [string]$Pasta, [string]$ArquivoUso)
Add-Type -AssemblyName PresentationFramework

if (-not $Foto) {
    $primeira = $false
    $mutex = [Threading.Mutex]::new($true, 'ClaudeMonitorOverlay', [ref]$primeira)
    if (-not $primeira) { exit }
}
$versao = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc

if (-not $Pasta) { $Pasta = Join-Path $HOME '.claude-monitor' }
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
        if ($s.pid) { if (-not (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) { return } }
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
        $tocador.Play()
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
        [void]$painelSessoes.Children.Add($linha)
    }
    # pedindo algo (pergunta/permissão) ganha de trabalhando, que ganha de parado
    $situacoes = @($sessoes | ForEach-Object { $_.situacao })
    Clawd $(if ($situacoes -contains 'question' -or $situacoes -contains 'permission') { 'pulando' }
            elseif ($situacoes -contains 'working') { 'andando' } else { 'parado' })

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

# Picareta sem Minecraft: 16x16 desenhada aqui, com o cabo no mesmo pixel da
# textura do jogo. d/c/b = cabeça (contorno, diamante, brilho); k/h = cabo.
$picaretaPropria = @(
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
    '................'
)
$coresPicareta = [ordered]@{ d = '#1B6E73'; c = '#4AEDD9'; b = '#C9FFF6'; k = '#3B2A14'; h = '#8A5A2B' }
function DesenhoPicareta {
    $grupo = New-Object Windows.Media.DrawingGroup
    # retângulo invisível 16x16: sem ele a imagem encolhe pro tamanho do desenho
    [void]$grupo.Children.Add([Windows.Media.GeometryDrawing]::new([Windows.Media.Brushes]::Transparent, $null,
        [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, 16, 16))))
    foreach ($c in $coresPicareta.Keys) {
        $g = New-Object Windows.Media.GeometryGroup
        for ($y = 0; $y -lt 16; $y++) {
            for ($x = 0; $x -lt 16; $x++) {
                if ($picaretaPropria[$y][$x] -ceq $c) { [void]$g.Children.Add([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($x, $y, 1, 1))) }
            }
        }
        [void]$grupo.Children.Add([Windows.Media.GeometryDrawing]::new((Cor $coresPicareta[$c]), $null, $g))
    }
    [Windows.Media.DrawingImage]::new($grupo)
}

# picareta de diamante (textura do Minecraft, se tiver) na mão direita, balançando
# como quem minera; o cabo (canto de baixo à esquerda da textura) fica na mão
$arquivoPicareta = "$Pasta\picareta.png"
$picareta = New-Object Windows.Controls.Image
if (Test-Path $arquivoPicareta) {
    $textura = New-Object Windows.Media.Imaging.BitmapImage
    $textura.BeginInit()
    $textura.UriSource = [Uri]$arquivoPicareta
    $textura.CacheOption = 'OnLoad'
    $textura.EndInit()
    $picareta.Source = $textura
} else {
    $picareta.Source = DesenhoPicareta
    [Windows.Media.RenderOptions]::SetEdgeMode($picareta, 'Aliased')
}
$picareta.Width = 17.6; $picareta.Height = 17.6  # 1,1 por pixel da textura 16x16
[Windows.Media.RenderOptions]::SetBitmapScalingMode($picareta, 'NearestNeighbor')
$cabo = [Windows.Point]::new(2.75, 14.85)  # pixel (2,5; 13,5) da textura
$mao = [Windows.Point]::new(12, -7.5)      # ponta do braço direito do Clawd
[Windows.Controls.Canvas]::SetLeft($picareta, $mao.X - $cabo.X)
[Windows.Controls.Canvas]::SetTop($picareta, $mao.Y - $cabo.Y)
$giro = [Windows.Media.RotateTransform]::new(0, $cabo.X, $cabo.Y)
$picareta.RenderTransform = $giro
$balanco = [Windows.Media.Animation.DoubleAnimation]::new(-25, 15, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(320)))
$balanco.AutoReverse = $true
$balanco.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$balanco.EasingFunction = New-Object Windows.Media.Animation.SineEase
[Windows.Media.Animation.Timeline]::SetDesiredFrameRate($balanco, 40)
$giro.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $balanco)
[void]$pulo.Children.Add($picareta)

# Trilha = borda arredondada do cartão, no sentido horário; o Clawd gira junto
# nas curvas. Refeita quando o cartão muda de tamanho, sem perder o lugar dele.
# Fora do modo 'andando' ele fica parado no meio da borda de cima.
$passeio = @{ relogio = [Diagnostics.Stopwatch]::StartNew(); duracao = 0; inicio = 0; modo = $null }
function Trilha {
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

# 'andando' (algo rodando): anda, pula, troca de perna e minera.
# 'pulando' (pergunta/permissão): parado em cima do cartão, pulando.
# 'parado' (nada rodando): parado em cima do cartão, com as 4 pernas no chão.
function Clawd($modo) {
    if ($passeio.modo -eq $modo) { return }
    $passeio.modo = $modo
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

$win.Add_MouseLeftButtonDown({
    if ($_.ClickCount -eq 2) {
        $shell = New-Object -ComObject WScript.Shell
        if (-not $shell.AppActivate('Visual Studio Code')) { [void]$shell.AppActivate('Cursor') }
        return
    }
    $lugar.arrastando = $true
    try { $win.DragMove() } finally { $lugar.arrastando = $false }
    $lugar.x = $win.Left
    $lugar.y = $win.Top
})
$fechar = New-Object Windows.Controls.MenuItem
$fechar.Header = 'Fechar'
$fechar.Add_Click({ $win.Close() })
$win.ContextMenu = New-Object Windows.Controls.ContextMenu
[void]$win.ContextMenu.Items.Add($fechar)

# a extensão trocou este arquivo por uma versão nova: solta a vaga e abre a nova
function SeAtualizou {
    if ($Foto -or (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc -eq $versao) { return }
    $timer.Stop()
    # fecha o handle, não só solta: enquanto existir handle, a nova acha que já tem uma aberta
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pasta', "`"$Pasta`""
    $win.Close()
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Atualizar; Recolocar; SeAtualizou })
$timer.Start()

# teste: depois de desenhar, salva o PNG e, ao lado (.txt), o que viu; e fecha
if ($Foto) {
    $espera = New-Object Windows.Threading.DispatcherTimer
    $espera.Interval = [TimeSpan]::FromMilliseconds(1200)
    $espera.Add_Tick({
        $espera.Stop()
        $imagem = [Windows.Media.Imaging.RenderTargetBitmap]::new(320, 440, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $imagem.Render($win.Content)
        $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($imagem))
        $arquivo = [IO.File]::Create($Foto)
        try { $png.Save($arquivo) } finally { $arquivo.Dispose() }
        $visto = @(Sessoes ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000) | ForEach-Object {
            "sessao: $($_.name) | hook=$($_.state) | janelinha=$($_.situacao)"
        }) + "clawd: $($passeio.modo)" + "usage: $(if ($uso.dados) { 'ok' } else { 'indisponivel' })" +
            "som: $(if ($somDaVez) { $nomeDoSom[$somDaVez] } else { 'nenhum' })"
        [IO.File]::WriteAllLines("$Foto.txt", [string[]]$visto, [Text.UTF8Encoding]::new($false))
        $win.Close()
    })
    $win.Add_ContentRendered({ $espera.Start() })
}

Atualizar
[void]$win.ShowDialog()
