# Testes do Windows, no PowerShell 5.1 (o que vem no Windows dos amigos):
#   npm run empacotar
#   powershell -ExecutionPolicy Bypass -File testes\windows\testes.ps1
# Testa o dist\ClaudeMonitor.zip (o que o amigo baixa). Não mexe na sua
# ~/.claude-monitor, no seu VS Code, nem na internet: tudo roda numa casa de
# mentira, com "VS Code" e "Cursor" de mentira que só anotam o que receberam.
# Os prints da janelinha ficam em testes\saida\ (ou em -Saida).
# Texto que vem do console de outro PowerShell chega sem acento: nos -match,
# "." no lugar da letra acentuada.
param([string]$Saida)

$raiz = (Resolve-Path "$PSScriptRoot\..\..").Path
if (-not $Saida) { $Saida = Join-Path $raiz 'testes\saida' }
New-Item -ItemType Directory -Force $Saida | Out-Null
$tmp = Join-Path ([IO.Path]::GetTempPath()) "cm-testes-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$script:falhas = 0; $script:total = 0

function Teste($nome, [scriptblock]$corpo) {
    $script:total++
    try { & $corpo; Write-Host "  ok  $nome" -ForegroundColor Green }
    catch {
        $script:falhas++
        Write-Host "  XX  $nome" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Verdade($condicao, $mensagem) { if (-not $condicao) { throw $mensagem } }
function Igual($esperado, $veio, $mensagem) {
    if ($esperado -cne $veio) { throw "$mensagem`n--- esperado:`n$esperado`n--- veio:`n$veio" }
}
function Ler($arquivo) { [IO.File]::ReadAllText($arquivo, $utf8).Replace("`r`n", "`n").TrimEnd() }

# roda um bloco com variáveis de ambiente trocadas (os filhos herdam)
function ComAmbiente($variaveis, [scriptblock]$bloco) {
    $antes = @{}
    foreach ($k in $variaveis.Keys) { $antes[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $variaveis[$k]) }
    try { & $bloco } finally { foreach ($k in $antes.Keys) { [Environment]::SetEnvironmentVariable($k, $antes[$k]) } }
}
# processo filho com prazo: travou = falha (e mata). Rodar monta a linha com as
# aspas do padrão do Windows; RodarLinha recebe a linha pronta (o cmd tem regra própria).
function Rodar($exe, [string[]]$argumentos, $prazo = 60) {
    $linha = ($argumentos | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' '
    RodarLinha $exe $linha $prazo
}
function RodarLinha($exe, [string]$linha, $prazo = 60) {
    $info = New-Object Diagnostics.ProcessStartInfo $exe, $linha
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($info)
    $saidaTarefa = $p.StandardOutput.ReadToEndAsync()
    $erroTarefa = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($prazo * 1000)) { $p.Kill(); throw "$exe travou (passou de $prazo s)" }
    [pscustomobject]@{ codigo = $p.ExitCode; saida = $saidaTarefa.Result + $erroTarefa.Result }
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
public static class Pixels {
    // quantos pixels (quase opacos) têm essa cor, com tolerância por canal
    public static int Contar(string arquivo, int r, int g, int b, int tol) {
        using (var bmp = new System.Drawing.Bitmap(arquivo)) {
            int n = 0;
            for (int y = 0; y < bmp.Height; y++)
                for (int x = 0; x < bmp.Width; x++) {
                    var c = bmp.GetPixel(x, y);
                    if (c.A > 200 && System.Math.Abs(c.R - r) <= tol && System.Math.Abs(c.G - g) <= tol && System.Math.Abs(c.B - b) <= tol) n++;
                }
            return n;
        }
    }
}
'@
Add-Type -AssemblyName System.IO.Compression.FileSystem, System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Janelas {
    delegate bool Cada(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(Cada cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr depois, int x, int y, int cx, int cy, uint f);
    // a janela visível do processo (a da janelinha é a única: o console vem escondido)
    public static IntPtr DoProcesso(int pid) {
        IntPtr achou = IntPtr.Zero;
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) { achou = h; return false; } return true; }, IntPtr.Zero);
        return achou;
    }
    // janelas visíveis sem "sempre por cima" na frente de h
    public static int NormaisAcima(IntPtr h) {
        int n = 0;
        for (IntPtr w = GetWindow(h, 3); w != IntPtr.Zero; w = GetWindow(w, 3))
            if (IsWindowVisible(w) && (GetWindowLong(w, -20) & 0x8) == 0) n++;
        return n;
    }
    // põe h logo abaixo de outra janela (sem mover nem ativar)
    public static void Abaixo(IntPtr h, IntPtr de) { SetWindowPos(h, de, 0, 0, 0, 0, 0x13); }
}
'@

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -ne 5) { Write-Host '  (atenção: os amigos rodam o 5.1; rode com powershell.exe)' -ForegroundColor Yellow }

# --- o pacote que o amigo baixa ---
$zip = Join-Path $raiz 'dist\ClaudeMonitor.zip'
if (-not (Test-Path $zip)) { Write-Host 'Falta o dist\ClaudeMonitor.zip: rode npm run empacotar' -ForegroundColor Red; exit 1 }
$versao = (Get-Content (Join-Path $raiz 'extensao\package.json') -Raw | ConvertFrom-Json).version
[IO.Compression.ZipFile]::ExtractToDirectory($zip, "$tmp\baixado")
$pacote = "$tmp\baixado\ClaudeMonitor"
$vsix = "$pacote\arquivos\claude-monitor-$versao.vsix"
[IO.Compression.ZipFile]::ExtractToDirectory($vsix, "$tmp\vsix")
$overlay = "$tmp\vsix\extension\janelinha\overlay.ps1"
$node = (Get-Command node.exe).Source

Write-Host ''
Write-Host 'Sintaxe'
Teste 'todos os .ps1 (do repositório e do pacote) abrem no PowerShell 5.1' {
    $todos = @(Get-ChildItem $raiz -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\node_modules\\' }) +
             @(Get-ChildItem "$tmp\vsix", "$tmp\baixado" -Recurse -Filter *.ps1)
    # repo: overlay, instalador e este; pacote: overlay e instalador
    Verdade ($todos.Count -ge 5) "só achei $($todos.Count) .ps1"
    foreach ($f in $todos) {
        $erros = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$erros)
        Verdade (-not $erros) "$($f.Name): $($erros | Select-Object -First 1)"
    }
}
# PowerShell não diferencia maiúscula: $Uso e $uso são a MESMA variável (já apagou o usage uma vez)
Teste 'nenhuma variável com o mesmo nome em maiúscula/minúscula diferente' {
    foreach ($f in Get-ChildItem $raiz -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\node_modules\\' }) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $nomes = $ast.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
            ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique -CaseSensitive
        $grupos = @($nomes | Group-Object { $_.ToLower() } | Where-Object { $_.Count -gt 1 })
        Verdade (-not $grupos) "$($f.Name): $(($grupos | ForEach-Object { $_.Group -join '/' }) -join ', ')"
    }
}

Write-Host ''
Write-Host 'Janelinha (cenários de testes\cenarios.js; prints em testes\saida)'
# picareta de teste magenta: prova que a textura do Minecraft, quando existe, é a usada
function PngMagenta($arquivo) {
    $b = New-Object Drawing.Bitmap 16, 16
    for ($i = 2; $i -lt 14; $i++) { $b.SetPixel($i, 15 - $i, [Drawing.Color]::Magenta); $b.SetPixel($i, 14 - $i, [Drawing.Color]::Magenta) }
    $b.Save($arquivo, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
}
foreach ($cenario in 'misto', 'andando', 'parado', 'vazio', 'levelup', 'xp-rodando', 'xp-esperando', 'aldeao', 'clique', 'pedra', 'bug', 'atualizar') {
    Teste "cenário '$cenario': mostra exatamente o esperado" {
        $pasta = "$tmp\cenario $cenario ção"  # espaço e acento no caminho
        $r = Rodar $node @("$raiz\testes\cenarios.js", $pasta, $cenario, "$PID")
        Verdade ($r.codigo -eq 0) $r.saida
        if ($cenario -eq 'andando') { PngMagenta "$pasta\picareta.png" }
        if ($cenario -eq 'pedra') { PngMagenta "$pasta\diamante.png" }  # o diamante que sobe
        $foto = "$Saida\windows-$cenario.png"
        Remove-Item "$foto*" -ErrorAction SilentlyContinue
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $overlay, '-Foto', $foto, '-Pasta', $pasta)
        if (Test-Path "$pasta\uso.json") { $argumentos += '-ArquivoUso', "$pasta\uso.json" }
        if (Test-Path "$pasta\clicar.txt") { $argumentos += '-Clicar', [IO.File]::ReadAllText("$pasta\clicar.txt") }
        if (Test-Path "$pasta\cena.txt") { $argumentos += '-Cena', [IO.File]::ReadAllText("$pasta\cena.txt") }
        $r = Rodar powershell.exe $argumentos 60
        Verdade ($r.codigo -eq 0 -and (Test-Path "$foto.txt")) "a janelinha não terminou direito: $($r.saida)"
        Igual (Ler "$pasta\esperado.txt") (Ler "$foto.txt") 'o que a janelinha mostrou'
        Verdade ((Get-Item $foto).Length -gt 2000) 'print vazio'
        Verdade ([Pixels]::Contar($foto, 24, 24, 24, 6) -gt 5000) 'cadê o cartão escuro?'
        Verdade ([Pixels]::Contar($foto, 215, 119, 87, 12) -gt 30) 'cadê o Clawd (laranja)?'
        if ($cenario -eq 'andando') { Verdade ([Pixels]::Contar($foto, 255, 0, 255, 30) -gt 5) 'não usou a picareta.png' }
        elseif ($cenario -eq 'pedra') { Verdade ([Pixels]::Contar($foto, 255, 0, 255, 30) -gt 5) 'cadê o diamante (diamante.png) subindo?' }
        else { Verdade ([Pixels]::Contar($foto, 74, 237, 217, 30) -gt 5) 'cadê a ferramenta desenhada (ciano)?' }
        if ($cenario -eq 'bug') { Verdade ([Pixels]::Contar($foto, 239, 68, 68, 20) -gt 20) 'o bug não ficou vermelho com a espadada' }
        if ($cenario -eq 'atualizar') { Verdade ([Pixels]::Contar($foto, 167, 139, 250, 25) -gt 10) 'cadê o aviso roxo da versão nova?' }
        if ($cenario -eq 'misto') { Verdade ([Pixels]::Contar($foto, 167, 139, 250, 25) -lt 3) 'aviso roxo sem versão nova' }
        Verdade (-not (Test-Path "$pasta\janelinha.log")) 'o -Foto anotou no diário'
    }
}
Teste "cores das bolinhas e das barras no cenário 'misto'" {
    $foto = "$Saida\windows-misto.png"
    foreach ($c in @(@('verde (trabalhando)', 34, 197, 94), @('vermelha (terminou)', 239, 68, 68), @('azul (pergunta)', 96, 165, 250),
                     @('amarela (permissão)', 250, 204, 21), @('laranja (7d em 85%)', 245, 158, 11))) {
        Verdade ([Pixels]::Contar($foto, $c[1], $c[2], $c[3], 25) -gt 10) "cadê a cor $($c[0])?"
    }
}
# trabalhando pulsa (quem não distingue verde de vermelho vê o movimento); terminou não
Teste "bolinha verde pulsa e a vermelha não (cenário 'xp-rodando', fase 0 e 0.5)" {
    $pasta = "$tmp\cenario xp-rodando ção"  # o do laço acima: uma terminou, outra trabalhando
    $fotos = foreach ($fase in '0', '0.5') {
        $foto = "$Saida\windows-pulso-$fase.png"
        Remove-Item "$foto*" -ErrorAction SilentlyContinue
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $overlay, '-Foto', $foto, '-Pasta', $pasta, '-Pulso', $fase)
        if (Test-Path "$pasta\uso.json") { $argumentos += '-ArquivoUso', "$pasta\uso.json" }
        $r = Rodar powershell.exe $argumentos 60
        Verdade ($r.codigo -eq 0 -and (Test-Path $foto)) "a janelinha não terminou direito: $($r.saida)"
        $foto
    }
    $verde = @($fotos | ForEach-Object { [Pixels]::Contar($_, 34, 197, 94, 25) })
    $vermelho = @($fotos | ForEach-Object { [Pixels]::Contar($_, 239, 68, 68, 25) })
    Verdade ($verde[0] - $verde[1] -ge 20) "a bolinha verde não apagou no meio do pulso (verde: $($verde -join ' -> '))"
    Verdade ($vermelho[1] -ge $vermelho[0] - 10) "a vermelha apagou junto: só a verde pulsa (vermelho: $($vermelho -join ' -> '))"
}
Teste "barra vermelha quando o 5h passa de 95% (cenário 'andando')" {
    Verdade ([Pixels]::Contar("$Saida\windows-andando.png", 239, 68, 68, 25) -gt 10) 'barra não ficou vermelha'
}
# O DragMove roda os timers do Clawd dentro do clique e o PowerShell acha variável pela
# pilha: um $alvo no clique trocou a pedra da cena e derrubou a janelinha (29/09, 0.5.2)
Teste 'nomes do clique: nenhuma variável do clique tem o nome de uma do script' {
    $raizAst = [Management.Automation.Language.Parser]::ParseFile($overlay, [ref]$null, [ref]$null)
    $atribuidas = { param($bloco) @($bloco.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [Management.Automation.Language.VariableExpressionAst] }, $false) | ForEach-Object { $_.Left.VariablePath.UserPath }) }
    $clique = $raizAst.Find({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_MouseLeftButtonDown' }, $true)
    Verdade $clique 'não achei o $win.Add_MouseLeftButtonDown'
    $doScript = & $atribuidas $raizAst
    $comuns = @(& $atribuidas $clique.Arguments[0].ScriptBlock | Where-Object { $_ -in $doScript } | Sort-Object -Unique)
    Verdade (-not $comuns) "variável do clique com nome de uma do script: $($comuns -join ', ')"
}

$mutexAberto = $null
if ([Threading.Mutex]::TryOpenExisting('ClaudeMonitorOverlay', [ref]$mutexAberto)) {
    $mutexAberto.Dispose()
    Write-Host '  --  janelinha de verdade aberta nesta máquina: pulei "uma só" e "se atualiza sozinha" (rodam no CI)' -ForegroundColor Yellow
} else {
    Teste 'uma janelinha só, e ela se reabre sozinha quando o arquivo muda' {
        $copia = "$tmp\auto\overlay.ps1"
        New-Item -ItemType Directory -Force (Split-Path $copia) | Out-Null
        Copy-Item $overlay $copia
        $pasta = "$tmp\auto\casa"
        New-Item -ItemType Directory -Force "$pasta\sessions" | Out-Null
        $abrir = { Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$copia`"", '-Pasta', "`"$pasta`"" }
        $janelinhas = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$copia*" }) }
        $primeira = & $abrir
        $m = $null
        for ($i = 0; $i -lt 40 -and -not [Threading.Mutex]::TryOpenExisting('ClaudeMonitorOverlay', [ref]$m); $i++) { Start-Sleep -Milliseconds 250 }
        Verdade $m 'a janelinha não abriu'
        $m.Dispose()
        $segunda = & $abrir
        Verdade ($segunda.WaitForExit(15000)) 'a 2ª janelinha não desistiu (ficariam duas)'
        # "sempre por cima" quebrado (visto de verdade): janela normal na frente; em até 2 s ela volta pro topo
        $hj = [IntPtr]::Zero
        for ($i = 0; $i -lt 40 -and $hj -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $hj = [Janelas]::DoProcesso($primeira.Id) }
        Verdade ($hj -ne [IntPtr]::Zero) 'não achei a janela da janelinha'
        $normal = New-Object Windows.Forms.Form -Property @{ ShowInTaskbar = $false; StartPosition = 'Manual'; Location = [Drawing.Point]::new(-3000, 0) }
        $normal.Show()
        try {
            [Janelas]::Abaixo($hj, $normal.Handle)
            Verdade ([Janelas]::NormaisAcima($hj) -gt 0) 'não consegui pôr uma janela normal na frente dela'
            # DoEvents: janela sem resposta por 5 s vira "fantasma" do Windows
            for ($i = 0; $i -lt 30 -and [Janelas]::NormaisAcima($hj) -gt 0; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
            Verdade ([Janelas]::NormaisAcima($hj) -eq 0) 'ficou atrás da janela normal'
        } finally { $normal.Close() }
        (Get-Item $copia).LastWriteTimeUtc = [DateTime]::UtcNow
        Verdade ($primeira.WaitForExit(15000)) 'não percebeu que o arquivo mudou'
        $nova = $null
        for ($i = 0; $i -lt 40 -and -not $nova; $i++) { Start-Sleep -Milliseconds 250; $nova = & $janelinhas | Where-Object ProcessId -ne $primeira.Id }
        Verdade $nova 'não reabriu depois de mudar'
        $novaId = @($nova)[0].ProcessId
        # o diário conta a história toda: abriu, a 2ª desistiu, se reabriu na nova, a velha fechou
        $diario = "$pasta\janelinha.log"
        for ($i = 0; $i -lt 40 -and -not ((Test-Path $diario) -and (Ler $diario) -match "\[$novaId\] abriu"); $i++) { Start-Sleep -Milliseconds 250 }
        $nova | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        $texto = Ler $diario
        foreach ($esperado in "\[$($primeira.Id)\] abriu: arquivo de \S+ \S+ \(pai \d+ ", "\[$($segunda.Id)\] saiu: já tem uma aberta \(pai ",
                             "\[$($primeira.Id)\] voltei pro topo: powershell \[$PID\] estava na frente",
                             "\[$($primeira.Id)\] arquivo mudou \(\S+ \S+ -> \S+ \S+\): reabri como \[$novaId\]",
                             "\[$novaId\] abriu: arquivo de ", "\[$($primeira.Id)\] fechou \(\d+ erros") {
            Verdade ($texto -match $esperado) "faltou no diário: $esperado`n$texto"
        }
    }
}

Write-Host ''
Write-Host 'Minecraft (servidor da Mojang de mentira: testes\mojang-falso.js)'
$scriptMc = "$tmp\vsix\extension\janelinha\minecraft.js"
$pathSemFfmpeg = "$env:WINDIR\system32;$env:WINDIR;$env:WINDIR\System32\WindowsPowerShell\v1.0"
# fica no ar até o fim: o instalador também baixa dele
$mojang = Start-Process $node -ArgumentList "`"$raiz\testes\mojang-falso.js`"" -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\mojang.txt"
for ($i = 0; $i -lt 100 -and -not (Get-Content "$tmp\mojang.txt" -ErrorAction Ignore); $i++) { Start-Sleep -Milliseconds 100 }
$urlMojang = Get-Content "$tmp\mojang.txt" -TotalCount 1
Teste 'baixa os sons e as texturas, sem Minecraft nem ffmpeg, e recarrega a janelinha' {
    $casa = "$tmp\mc1\casa"; New-Item -ItemType Directory -Force "$casa\.claude-monitor" | Out-Null
    Set-Content "$casa\.claude-monitor\overlay.ps1" '# janelinha'
    (Get-Item "$casa\.claude-monitor\overlay.ps1").LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
    $r = ComAmbiente @{ USERPROFILE = $casa; PATH = $pathSemFfmpeg; CLAUDE_MONITOR_MOJANG = $urlMojang } { Rodar $node @($scriptMc) }
    Verdade ($r.codigo -eq 0) $r.saida
    foreach ($f in 'xp1', 'xp2', 'xp3', 'levelup', 'aldeao_hmm1', 'aldeao_hmm2', 'gato') { Verdade (Test-Path "$casa\.claude-monitor\sons\$f.wav") "falta $f.wav: $($r.saida)" }
    foreach ($f in 'picareta', 'espada', 'diamante', 'pedra') { Verdade (Test-Path "$casa\.claude-monitor\$f.png") "falta $f.png: $($r.saida)" }
    # o mesmo tocador da janelinha: Load() recusa .wav que ele não entende
    foreach ($wav in Get-ChildItem "$casa\.claude-monitor\sons\*.wav") { (New-Object Media.SoundPlayer $wav.FullName).Load() }
    Verdade ((Get-Item "$casa\.claude-monitor\overlay.ps1").LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-5)) 'não cutucou a janelinha pra recarregar'
    Verdade ($r.saida -match 'Pronto!') $r.saida
}
Teste 'sem internet: explica como tentar de novo, não quebra e não cria nada' {
    $casa = "$tmp\mc2\casa"; New-Item -ItemType Directory -Force $casa | Out-Null
    $r = ComAmbiente @{ USERPROFILE = $casa; CLAUDE_MONITOR_MOJANG = 'http://127.0.0.1:9' } { Rodar $node @($scriptMc) }
    Verdade ($r.codigo -eq 1) "$($r.codigo): $($r.saida)"
    Verdade ($r.saida -match 'Usar sons do Minecraft' -and $r.saida -notmatch 'Pronto!') $r.saida
    Verdade (-not (Test-Path "$casa\.claude-monitor\sons")) 'criou a pasta de sons sem ter som'
}

Write-Host ''
Write-Host 'Instalador (casa de mentira com espaço e acento, como "C:\Users\João Silva")'
$casa = "$tmp\Users\João Silva"
$bin = "$tmp\bin falso"
New-Item -ItemType Directory -Force $casa, $bin, "$tmp\local", "$tmp\progs", "$tmp\appdata" | Out-Null
foreach ($editor in 'code', 'cursor') {
    [IO.File]::WriteAllText("$bin\$editor.cmd", "@echo %* >> `"%~dp0$editor.log`"`r`n@exit /b 0`r`n")
}
$ambiente = @{
    USERPROFILE = $casa; LOCALAPPDATA = "$tmp\local"; ProgramFiles = "$tmp\progs"; APPDATA = "$tmp\appdata"
    PATH = "$bin;$(Split-Path $node);$pathSemFfmpeg"; CLAUDE_MONITOR_MOJANG = $urlMojang
}
$instalador = "$pacote\arquivos\instalar-windows.ps1"
Teste 'instala: extensão no VS Code e no Cursor, arquivos, versão e hooks' {
    $r = ComAmbiente $ambiente { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') 120 }
    Verdade ($r.codigo -eq 0) "saiu com $($r.codigo): $($r.saida)"
    foreach ($editor in 'code', 'cursor') {
        $log = Get-Content "$bin\$editor.log" -Raw
        Verdade ($log -match '--install-extension' -and $log -match [regex]::Escape("claude-monitor-$versao.vsix") -and $log -match '--force') "$editor recebeu: $log"
    }
    foreach ($f in 'hook.js', 'processes.js', 'overlay.ps1', 'minecraft.js', 'vorbis.min.js') { Verdade (Test-Path "$casa\.claude-monitor\$f") "falta $f" }
    Verdade (Test-Path "$casa\.claude-monitor\sons\levelup.wav") "não baixou os sons do Minecraft: $($r.saida)"
    Verdade (-not (Test-Path "$casa\.claude-monitor\install.js")) 'install.js sobrou na pasta'
    Igual $versao ([IO.File]::ReadAllText("$casa\.claude-monitor\versao-janelinha")) 'versão marcada'
    Verdade ((Get-Content "$casa\.claude-monitor\janelinha.log" -Raw) -match "\[instalador \d+\] copiou a janelinha $([regex]::Escape($versao))") 'não anotou no diário da janelinha'
    $hooks = (Get-Content "$casa\.claude\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).hooks
    foreach ($e in 'UserPromptSubmit', 'Stop', 'Notification', 'SessionEnd') { Verdade (@($hooks.$e).Count -eq 1) "hook $e" }
}
Teste 'rodar o instalador de novo não duplica os hooks' {
    $r = ComAmbiente $ambiente { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') 120 }
    Verdade ($r.codigo -eq 0) $r.saida
    $hooks = (Get-Content "$casa\.claude\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).hooks
    Verdade (@($hooks.Stop).Count -eq 1) 'duplicou'
}
Teste 'com o code.cmd do Cursor na frente do PATH: instala no VS Code de verdade' {
    $shim = "$tmp\Programs\cursor\resources\app\codeBin"
    New-Item -ItemType Directory -Force $shim | Out-Null
    [IO.File]::WriteAllText("$shim\code.cmd", "@echo %* >> `"%~dp0code.log`"`r`n@exit /b 0`r`n")
    Remove-Item "$bin\code.log" -ErrorAction SilentlyContinue
    $comShim = $ambiente.Clone(); $comShim.PATH = "$shim;$($ambiente.PATH)"
    $r = ComAmbiente $comShim { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') 120 }
    Verdade ($r.codigo -eq 0) $r.saida
    Verdade (-not (Test-Path "$shim\code.log")) "usou o code.cmd do Cursor como se fosse o VS Code: $($r.saida)"
    Verdade ((Get-Content "$bin\code.log" -Raw) -match '--install-extension') "o VS Code não recebeu a extensão: $($r.saida)"
}
Teste 'o hook instalado funciona de verdade, pelo cmd e pelo bash, com acento no caminho' {
    $comando = ((Get-Content "$casa\.claude\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).hooks.UserPromptSubmit)[0].hooks[0].command
    # o bash (Git Bash) é o shell que o Claude Code usa no Windows
    $bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    foreach ($shell in @('cmd') + @($(if ($bash) { 'bash' }))) {
        $entrada = "$tmp\entrada-$shell.json"
        [IO.File]::WriteAllText($entrada, "{`"session_id`":`"via-$shell`",`"cwd`":`"C:\\projeto`"}")
        $r = ComAmbiente $ambiente {
            if ($shell -eq 'cmd') { RodarLinha cmd.exe "/d /s /c `"$comando < `"$entrada`"`"" }
            else { Rodar $bash @('-c', "$comando < '$($entrada.Replace('\', '/'))'") }
        }
        Verdade (Test-Path "$casa\.claude-monitor\sessions\via-$shell.json") "pelo $shell não gravou a sessão: $($r.saida)"
    }
    Verdade $bash 'sem Git Bash nesta máquina: testei só pelo cmd'
}
Teste 'sem VS Code nem Cursor: explica e sai com erro' {
    $semEditor = $ambiente.Clone(); $semEditor.PATH = "$(Split-Path $node);$pathSemFfmpeg"
    $r = ComAmbiente $semEditor { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') }
    Verdade ($r.codigo -eq 1 -and $r.saida -match 'N.o achei o VS Code') "$($r.codigo): $($r.saida)"
}
Teste 'instalar-windows.cmd (o duplo clique) instala, com os acentos certos na tela' {
    $comTeste = $ambiente.Clone(); $comTeste.CLAUDE_MONITOR_TESTE = '1'
    $r = ComAmbiente $comTeste { RodarLinha cmd.exe "/d /s /c `"`"$pacote\instalar-windows.cmd`" < nul`"" 120 }
    Verdade ($r.saida -match 'Pronto!') $r.saida
    # o .cmd troca o console pra UTF-8: o amigo tem que ver os acentos certos
    Verdade ($r.saida -match 'canto de baixo à direita') "acento embaralhado na tela do amigo: $($r.saida)"
    Verdade ($r.saida -match 'Pronto! A janelinha já está com os sons do Minecraft') "acento embaralhado no Minecraft: $($r.saida)"
}
Teste 'instalar-windows.cmd rodado de dentro do .zip (sem extrair): pede pra extrair' {
    New-Item -ItemType Directory -Force "$tmp\sem-extrair" | Out-Null
    Copy-Item "$pacote\instalar-windows.cmd" "$tmp\sem-extrair\"
    $r = RodarLinha cmd.exe "/d /s /c `"`"$tmp\sem-extrair\instalar-windows.cmd`" < nul`""
    Verdade ($r.codigo -eq 1 -and $r.saida -match 'Extraia o .zip') $r.saida
}

Stop-Process -Id $mojang.Id -ErrorAction Ignore
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ''
if ($script:falhas) { Write-Host "$($script:falhas) de $($script:total) testes FALHARAM" -ForegroundColor Red; exit 1 }
Write-Host "$($script:total) testes ok" -ForegroundColor Green
