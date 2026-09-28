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
Add-Type -AssemblyName System.IO.Compression.FileSystem, System.Drawing

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
    Verdade ($todos.Count -ge 6) "só achei $($todos.Count) .ps1"
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
foreach ($cenario in 'misto', 'andando', 'parado', 'vazio') {
    Teste "cenário '$cenario': mostra exatamente o esperado" {
        $pasta = "$tmp\cenario $cenario ção"  # espaço e acento no caminho
        $r = Rodar $node @("$raiz\testes\cenarios.js", $pasta, $cenario, "$PID")
        Verdade ($r.codigo -eq 0) $r.saida
        if ($cenario -eq 'andando') { PngMagenta "$pasta\picareta.png" }
        $foto = "$Saida\windows-$cenario.png"
        Remove-Item "$foto*" -ErrorAction SilentlyContinue
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $overlay, '-Foto', $foto, '-Pasta', $pasta)
        if (Test-Path "$pasta\uso.json") { $argumentos += '-ArquivoUso', "$pasta\uso.json" }
        $r = Rodar powershell.exe $argumentos 60
        Verdade ($r.codigo -eq 0 -and (Test-Path "$foto.txt")) "a janelinha não terminou direito: $($r.saida)"
        Igual (Ler "$pasta\esperado.txt") (Ler "$foto.txt") 'o que a janelinha mostrou'
        Verdade ((Get-Item $foto).Length -gt 2000) 'print vazio'
        Verdade ([Pixels]::Contar($foto, 24, 24, 24, 6) -gt 5000) 'cadê o cartão escuro?'
        Verdade ([Pixels]::Contar($foto, 215, 119, 87, 12) -gt 30) 'cadê o Clawd (laranja)?'
        if ($cenario -eq 'andando') { Verdade ([Pixels]::Contar($foto, 255, 0, 255, 30) -gt 5) 'não usou a picareta.png' }
        else { Verdade ([Pixels]::Contar($foto, 74, 237, 217, 30) -gt 5) 'cadê a picareta desenhada (ciano)?' }
    }
}
Teste "cores das bolinhas e das barras no cenário 'misto'" {
    $foto = "$Saida\windows-misto.png"
    foreach ($c in @(@('verde (trabalhando)', 34, 197, 94), @('vermelha (terminou)', 239, 68, 68), @('azul (pergunta)', 96, 165, 250),
                     @('amarela (permissão)', 250, 204, 21), @('laranja (7d em 85%)', 245, 158, 11))) {
        Verdade ([Pixels]::Contar($foto, $c[1], $c[2], $c[3], 25) -gt 10) "cadê a cor $($c[0])?"
    }
}
Teste "barra vermelha quando o 5h passa de 95% (cenário 'andando')" {
    Verdade ([Pixels]::Contar("$Saida\windows-andando.png", 239, 68, 68, 25) -gt 10) 'barra não ficou vermelha'
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
        (Get-Item $copia).LastWriteTimeUtc = [DateTime]::UtcNow
        Verdade ($primeira.WaitForExit(15000)) 'não percebeu que o arquivo mudou'
        $nova = $null
        for ($i = 0; $i -lt 40 -and -not $nova; $i++) { Start-Sleep -Milliseconds 250; $nova = & $janelinhas | Where-Object ProcessId -ne $primeira.Id }
        Verdade $nova 'não reabriu depois de mudar'
        $nova | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    }
}

Write-Host ''
Write-Host 'Minecraft'
$scriptMc = "$tmp\vsix\extension\janelinha\extrair_minecraft.ps1"
$pathSemFfmpeg = "$env:WINDIR\system32;$env:WINDIR;$env:WINDIR\System32\WindowsPowerShell\v1.0"
Teste 'sem Minecraft: avisa, não quebra e não cria nada' {
    $casa = "$tmp\mc0\casa"; New-Item -ItemType Directory -Force $casa, "$tmp\mc0\appdata" | Out-Null
    $r = ComAmbiente @{ APPDATA = "$tmp\mc0\appdata"; USERPROFILE = $casa } { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptMc) }
    Verdade ($r.codigo -eq 0) $r.saida
    Verdade ($r.saida -match 'Minecraft Java n.o encontrado') $r.saida
    Verdade (-not (Test-Path "$casa\.claude-monitor\picareta.png")) 'criou picareta do nada'
}

# Minecraft de mentira: índice, um jar de verdade (zip) e um jar de mod pra ignorar
function MinecraftFalso($appdata, [switch]$ComSons) {
    $mc = "$appdata\.minecraft"
    New-Item -ItemType Directory -Force "$mc\assets\indexes", "$mc\versions\1.21.4", "$mc\versions\fabric-loader-1.21" | Out-Null
    $png = "$tmp\textura.png"; PngMagenta $png
    foreach ($jar in "$mc\versions\1.21.4\1.21.4.jar", "$mc\versions\fabric-loader-1.21\outro-nome.jar") {
        $z = [IO.Compression.ZipFile]::Open($jar, 'Create')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $png, 'assets/minecraft/textures/item/diamond_pickaxe.png')
        $z.Dispose()
    }
    $objetos = @{}
    if ($ComSons) {
        foreach ($som in 'random/orb', 'mob/villager/idle1') {
            $hash = -join ((1..40) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
            $pastaObj = "$mc\assets\objects\$($hash.Substring(0, 2))"
            New-Item -ItemType Directory -Force $pastaObj | Out-Null
            # vorbis nativo: nem todo ffmpeg tem o libvorbis (o do Homebrew não tem)
            & ffmpeg -loglevel error -f lavfi -i 'sine=frequency=660:duration=0.2' -c:a vorbis -strict -2 -ac 2 "$pastaObj\$hash.ogg"
            Move-Item "$pastaObj\$hash.ogg" "$pastaObj\$hash"
            $objetos["minecraft/sounds/$som.ogg"] = @{ hash = $hash; size = 1 }
        }
    }
    @{ objects = $objetos } | ConvertTo-Json -Depth 5 | Set-Content "$mc\assets\indexes\17.json" -Encoding ASCII
}
Teste 'com Minecraft e sem ffmpeg: pega a picareta do jar certo e explica como ter os sons' {
    $casa = "$tmp\mc1\casa"; New-Item -ItemType Directory -Force $casa | Out-Null
    MinecraftFalso "$tmp\mc1\appdata"
    $r = ComAmbiente @{ APPDATA = "$tmp\mc1\appdata"; USERPROFILE = $casa; PATH = $pathSemFfmpeg } {
        Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptMc)
    }
    Verdade ($r.codigo -eq 0) $r.saida
    Verdade (Test-Path "$casa\.claude-monitor\picareta.png") "não extraiu a picareta: $($r.saida)"
    Verdade ($r.saida -match '1\.21\.4\.jar') "pegou o jar errado: $($r.saida)"
    Verdade ($r.saida -match 'winget install Gyan\.FFmpeg') $r.saida
}
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Teste 'com Minecraft e ffmpeg: gera os .wav (XP em 3 tons) e recarrega a janelinha' {
        $casa = "$tmp\mc2\casa"; New-Item -ItemType Directory -Force "$casa\.claude-monitor" | Out-Null
        Set-Content "$casa\.claude-monitor\overlay.ps1" '# janelinha'
        (Get-Item "$casa\.claude-monitor\overlay.ps1").LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
        MinecraftFalso "$tmp\mc2\appdata" -ComSons
        $r = ComAmbiente @{ APPDATA = "$tmp\mc2\appdata"; USERPROFILE = $casa } { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptMc) 120 }
        Verdade ($r.codigo -eq 0) $r.saida
        foreach ($f in 'xp1', 'xp2', 'xp3', 'aldeao_hmm1') { Verdade (Test-Path "$casa\.claude-monitor\sons\$f.wav") "falta $f.wav: $($r.saida)" }
        Verdade ($r.saida -match 'aldeao_hmm2.*n.o est') "som que falta no índice devia só avisar: $($r.saida)"
        Verdade ((Get-Item "$casa\.claude-monitor\overlay.ps1").LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-5)) 'não cutucou a janelinha pra recarregar'
        Verdade ($r.saida -match 'Pronto!') $r.saida
    }
    Teste 'com Minecraft e ffmpeg, mas sem nenhum som baixado: não diz "Pronto!"' {
        $casa = "$tmp\mc3\casa"; New-Item -ItemType Directory -Force $casa | Out-Null
        MinecraftFalso "$tmp\mc3\appdata"
        $r = ComAmbiente @{ APPDATA = "$tmp\mc3\appdata"; USERPROFILE = $casa } { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptMc) 120 }
        Verdade ($r.codigo -eq 0) $r.saida
        Verdade ($r.saida -match 'Nenhum som convertido' -and $r.saida -notmatch 'Pronto!') $r.saida
    }
} else { Write-Host '  --  sem ffmpeg nesta máquina: pulei a conversão dos sons' -ForegroundColor Yellow }

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
    PATH = "$bin;$(Split-Path $node);$pathSemFfmpeg"
}
$instalador = "$pacote\arquivos\instalar-windows.ps1"
Teste 'instala: extensão no VS Code e no Cursor, arquivos, versão e hooks' {
    $r = ComAmbiente $ambiente { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') 120 }
    Verdade ($r.codigo -eq 0) "saiu com $($r.codigo): $($r.saida)"
    foreach ($editor in 'code', 'cursor') {
        $log = Get-Content "$bin\$editor.log" -Raw
        Verdade ($log -match '--install-extension' -and $log -match [regex]::Escape("claude-monitor-$versao.vsix") -and $log -match '--force') "$editor recebeu: $log"
    }
    foreach ($f in 'hook.js', 'processes.js', 'overlay.ps1', 'extrair_minecraft.ps1') { Verdade (Test-Path "$casa\.claude-monitor\$f") "falta $f" }
    Verdade (-not (Test-Path "$casa\.claude-monitor\install.js")) 'install.js sobrou na pasta'
    Igual $versao ([IO.File]::ReadAllText("$casa\.claude-monitor\versao-janelinha")) 'versão marcada'
    $hooks = (Get-Content "$casa\.claude\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).hooks
    foreach ($e in 'UserPromptSubmit', 'Stop', 'Notification', 'SessionEnd') { Verdade (@($hooks.$e).Count -eq 1) "hook $e" }
}
Teste 'rodar o instalador de novo não duplica os hooks' {
    $r = ComAmbiente $ambiente { Rodar powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instalador, '-SemAtalho', '-SemAbrir') 120 }
    Verdade ($r.codigo -eq 0) $r.saida
    $hooks = (Get-Content "$casa\.claude\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).hooks
    Verdade (@($hooks.Stop).Count -eq 1) 'duplicou'
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
}
Teste 'instalar-windows.cmd rodado de dentro do .zip (sem extrair): pede pra extrair' {
    New-Item -ItemType Directory -Force "$tmp\sem-extrair" | Out-Null
    Copy-Item "$pacote\instalar-windows.cmd" "$tmp\sem-extrair\"
    $r = RodarLinha cmd.exe "/d /s /c `"`"$tmp\sem-extrair\instalar-windows.cmd`" < nul`""
    Verdade ($r.codigo -eq 1 -and $r.saida -match 'Extraia o .zip') $r.saida
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ''
if ($script:falhas) { Write-Host "$($script:falhas) de $($script:total) testes FALHARAM" -ForegroundColor Red; exit 1 }
Write-Host "$($script:total) testes ok" -ForegroundColor Green
