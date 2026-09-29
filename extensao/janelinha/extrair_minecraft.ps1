# Tira do Minecraft Java instalado (~/.minecraft) o que a janelinha usa e grava
# em ~/.claude-monitor:
#  - picareta.png, espada.png, diamante.png, pedra.png (texturas de diamante da
#    versão mais nova instalada: a pedra é o minério de diamante)
#  - sons\*.wav   (dos assets; precisa do ffmpeg: winget install Gyan.FFmpeg)
# Sem Minecraft, a janelinha usa os sons do Windows e uma picareta desenhada.
# Os arquivos não vão junto no pacote porque são da Mojang: cada um tira do seu jogo.
# Pra trocar/adicionar som, mexa na lista e rode de novo:
#   powershell -ExecutionPolicy Bypass -File extrair_minecraft.ps1
# (os nomes dos sons estão em ~/.minecraft/assets/indexes/*.json)
$sons = [ordered]@{
    'xp'          = 'random/orb'           # pegar XP
    'levelup'     = 'random/levelup'
    'pop'         = 'random/pop'           # pegar item
    'aldeao_hmm1' = 'mob/villager/idle1'
    'aldeao_hmm2' = 'mob/villager/idle2'
    'aldeao_sim'  = 'mob/villager/yes1'
    'pling'       = 'note/pling'           # note block
    'sino'        = 'note/bell'
    'bigorna'     = 'random/anvil_land'
    'gato'        = 'mob/cat/meow1'
}
$tons = @{ 'xp' = 0.8, 1.0, 1.25 }  # como o jogo, o XP muda de tom a cada vez: xp1, xp2, xp3

$mc = "$env:APPDATA\.minecraft"
$destino = Join-Path $env:USERPROFILE '.claude-monitor'
if (-not (Test-Path "$mc\assets\indexes")) {
    Write-Host 'Minecraft Java não encontrado — a janelinha fica com os sons do Windows.'
    exit
}

# texturas: textures/item e block (1.13+) ou items e blocks (antigas), do jar mais novo que tiver
$texturas = [ordered]@{ picareta = 'items?/diamond_pickaxe'; espada = 'items?/diamond_sword'; diamante = 'items?/diamond'; pedra = 'blocks?/diamond_ore' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$jar = Get-ChildItem "$mc\versions\*\*.jar" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
    Where-Object { $_.BaseName -eq $_.Directory.Name } | Select-Object -First 1
if ($jar) {
    $zip = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
    try {
        foreach ($nome in $texturas.Keys) {
            $png = $zip.Entries | Where-Object { $_.FullName -match "^assets/minecraft/textures/$($texturas[$nome])\.png$" } | Select-Object -First 1
            if ($png) {
                New-Item -ItemType Directory -Force $destino | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($png, (Join-Path $destino "$nome.png"), $true)
                Write-Host "$nome.png (de $($jar.Name))"
            }
        }
    } finally { $zip.Dispose() }
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host 'Pra usar os sons do Minecraft falta o ffmpeg. Instale com:  winget install Gyan.FFmpeg'
    Write-Host 'e rode de novo (no VS Code: Ctrl+Shift+P > "Claude Monitor: Usar sons do Minecraft").'
    exit
}
$indice = Get-ChildItem "$mc\assets\indexes\*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$objetos = (Get-Content $indice.FullName -Raw | ConvertFrom-Json).objects
$saida = Join-Path $destino 'sons'
New-Item -ItemType Directory -Force $saida | Out-Null
$feitos = 0

foreach ($nome in $sons.Keys) {
    $hash = $objetos."minecraft/sounds/$($sons[$nome]).ogg".hash
    if (-not $hash) { Write-Warning "$nome ($($sons[$nome])) não está no Minecraft"; continue }
    $ogg = "$mc\assets\objects\$($hash.Substring(0, 2))\$hash"
    if (-not (Test-Path $ogg)) { Write-Warning "$nome ainda não foi baixado pelo Minecraft"; continue }
    $variantes = if ($tons[$nome]) { $tons[$nome] } else { @(1.0) }
    $taxa = [int](ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 $ogg)
    for ($i = 0; $i -lt $variantes.Count; $i++) {
        $wav = if ($variantes.Count -gt 1) { "$saida\$nome$($i + 1).wav" } else { "$saida\$nome.wav" }
        # muda o tom mudando a taxa (como o jogo faz) e volta pra 44100 pro .wav
        $filtro = 'asetrate={0},aresample=44100,volume=0.8' -f [int]($taxa * $variantes[$i])
        ffmpeg -y -loglevel error -i $ogg -ac 1 -af $filtro -sample_fmt s16 $wav
        if ($LASTEXITCODE -eq 0) { Write-Host (Split-Path $wav -Leaf); $feitos++ }
    }
}
# a janelinha aberta vê o overlay.ps1 "mudar" e se reabre já com os sons
$overlay = Join-Path $destino 'overlay.ps1'
if (Test-Path $overlay) { (Get-Item $overlay).LastWriteTimeUtc = [DateTime]::UtcNow }
if ($feitos -eq 0) {
    Write-Host 'Nenhum som convertido (veja os avisos acima). Abra o Minecraft uma vez, pra ele baixar os sons, e rode de novo.'
} else {
    Write-Host 'Pronto! A janelinha já está com os sons do Minecraft.'
}
