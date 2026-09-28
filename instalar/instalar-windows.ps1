# Instala o Claude Monitor no Windows: a extensão no VS Code/Cursor, os hooks no
# Claude Code, a janelinha e, se tiver Minecraft, os sons e a picareta do jogo.
# Quem chama é o instalar-windows.cmd (duplo clique). Rodar de novo não estraga:
# reinstala por cima.
# Testes: -SemAtalho (não cria atalho na Área de Trabalho), -SemAbrir (não abre a janelinha).
param([switch]$SemAtalho, [switch]$SemAbrir)
if ($env:CLAUDE_MONITOR_TESTE) { $SemAtalho = $true; $SemAbrir = $true }  # teste pelo .cmd

function Passo($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "   OK  $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }
function Falhou($t) { Write-Host ''; Write-Host "   XX  $t" -ForegroundColor Red; exit 1 }

$casa = $env:USERPROFILE
$pasta = Join-Path $casa '.claude-monitor'
$vsix = Get-ChildItem (Join-Path $PSScriptRoot 'claude-monitor-*.vsix') -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $vsix) { Falhou "Não achei o claude-monitor-*.vsix na pasta $PSScriptRoot. Extraia o .zip inteiro antes de rodar." }
$versao = $vsix.BaseName -replace '^claude-monitor-', ''
Write-Host "Claude Monitor $versao" -ForegroundColor Cyan

Passo 'Procurando o VS Code / Cursor'
$editores = @()
foreach ($e in @(
        @{ nome = 'VS Code'; cmd = 'code.cmd'; fixos = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") },
        @{ nome = 'Cursor'; cmd = 'cursor.cmd'; fixos = @("$env:LOCALAPPDATA\Programs\cursor\resources\app\bin\cursor.cmd") })) {
    $exe = (Get-Command $e.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $exe) { $exe = $e.fixos | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if ($exe) { $editores += @{ nome = $e.nome; exe = $exe }; Ok "$($e.nome): $exe" }
}
if (-not $editores) { Falhou 'Não achei o VS Code nem o Cursor. Instale o VS Code (https://code.visualstudio.com) e rode de novo.' }

Passo 'Instalando a extensão'
foreach ($e in $editores) {
    $saida = & $e.exe --install-extension $vsix.FullName --force 2>&1
    if ($LASTEXITCODE -ne 0) { Aviso "$($e.nome) não aceitou a extensão:"; $saida | ForEach-Object { Write-Host "       $_" } }
    else { Ok $e.nome }
}

Passo 'Copiando os arquivos pra ~/.claude-monitor'
# os mesmos que a extensão copia quando o VS Code abre; aqui já saem de dentro do .vsix (é um zip)
New-Item -ItemType Directory -Force $pasta | Out-Null
$temp = Join-Path ([IO.Path]::GetTempPath()) "claude-monitor-$PID"
New-Item -ItemType Directory -Force $temp | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($vsix.FullName)
try {
    $copias = @{
        'out/hook.js' = $pasta; 'out/processes.js' = $pasta; 'out/install.js' = $temp
        'janelinha/overlay.ps1' = $pasta; 'janelinha/extrair_minecraft.ps1' = $pasta
    }
    foreach ($nome in $copias.Keys) {
        $entrada = $zip.GetEntry("extension/$nome")
        if (-not $entrada) { Falhou "O .vsix está incompleto (falta $nome). Baixe de novo." }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, (Join-Path $copias[$nome] (Split-Path $nome -Leaf)), $true)
    }
} finally { $zip.Dispose() }
# a extensão só recopia quando a versão muda
[IO.File]::WriteAllText((Join-Path $pasta 'versao-janelinha'), $versao)
Ok $pasta

Passo 'Ligando o Claude Code na extensão (hooks)'
$node = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $node -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Aviso 'Falta o Node.js: o Claude Code usa ele pra avisar quais sessões estão rodando.'
    $r = Read-Host '       Instalar agora? (S/n)'
    if ($r -notmatch '^[nN]') {
        winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        $node = @("$env:ProgramFiles\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
}
if ($node) {
    $saida = & $node -e "require(process.argv[1]).installHooks()" (Join-Path $temp 'install.js') 2>&1
    if ($LASTEXITCODE -eq 0) { Ok 'hooks no ~/.claude/settings.json (cópia do anterior em settings.json.bak-claude-monitor)' }
    else { Aviso "Não consegui mexer no ~/.claude/settings.json: $saida"; Aviso 'Depois, no VS Code: Ctrl+Shift+P > "Claude Monitor: Instalar hooks no Claude Code".' }
} else {
    Aviso 'Sem Node.js as sessões não aparecem. Instale a versão LTS em https://nodejs.org e rode este instalador de novo.'
}
Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue

Passo 'Minecraft (opcional)'
& (Join-Path $pasta 'extrair_minecraft.ps1')

if (-not $SemAtalho) {
    Passo 'Atalho "Claude Monitor" na Área de Trabalho (reabre a janelinha)'
    $atalho = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Monitor.lnk'))
    $atalho.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $atalho.Arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$pasta\overlay.ps1`""
    $atalho.WindowStyle = 7  # minimizado
    $atalho.Save()
    Ok 'feito'
}

if (-not $SemAbrir) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$pasta\overlay.ps1`""
}

Write-Host ''
Write-Host 'Pronto! A janelinha aparece no canto de baixo à direita.' -ForegroundColor Green
Write-Host 'Feche e abra o VS Code de novo. Sessões do Claude que já estavam abertas'
Write-Host 'precisam ser reabertas pra aparecer (as novas aparecem sozinhas).'
