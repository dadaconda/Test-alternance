#requires -Version 5.1
<#
.SYNOPSIS
  Veille automatique des offres d'alternance (Master Finance) : gestion des risques,
  analyse financiere, controle de gestion, conformite, audit...
  Source : API "Offres d'emploi v2" de France Travail (agrege la plupart des jobboards FR).

.DESCRIPTION
  - Ne retient que les contrats en alternance (apprentissage E2 + professionnalisation FS).
  - Fenetre glissante de 24 h par defaut (parametre -Since ou config.json).
  - Repere les contrats explicitement "24 mois" (marqueur, ou filtre dur avec -Strict).
  - Deduplique d'un passage a l'autre (data/seen.json) => met en avant les NOUVELLES offres.
  - Ecrit data/latest.json, data/latest.md et journalise data/history.jsonl.
  - Notification Telegram optionnelle (voir README).

.EXAMPLE
  .\alternance.ps1
  .\alternance.ps1 -Since 12 -Strict
  .\alternance.ps1 -All -Departements "75,92,93,94"
#>
[CmdletBinding()]
param(
  [int]$Since = 0,
  [switch]$All,
  [switch]$Strict,
  [string]$Departements,
  [switch]$Json,
  [switch]$Quiet,
  [int]$MaxPages = 0,
  [switch]$NoWrite,
  [switch]$Demo
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$root     = $PSScriptRoot
$dataDir  = Join-Path $root 'data'
$cacheDir = Join-Path $root '.cache'
New-Item -ItemType Directory -Force -Path $dataDir, $cacheDir | Out-Null

# --------------------------------------------------------------------------------------
# Configuration + secrets
# --------------------------------------------------------------------------------------
function Read-Text([string]$path) { return [IO.File]::ReadAllText($path) }   # UTF-8 fiable (PS 5.1 + 7)

$cfg = Read-Text (Join-Path $root 'config.json') | ConvertFrom-Json

function Import-DotEnv([string]$path) {
  if (-not (Test-Path $path)) { return }
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
    if (-not [Environment]::GetEnvironmentVariable($k)) { [Environment]::SetEnvironmentVariable($k, $v) }
  }
}
Import-DotEnv (Join-Path $root '.env')

$clientId     = $env:FT_CLIENT_ID
$clientSecret = $env:FT_CLIENT_SECRET
$secretsFile  = Join-Path $root 'secrets.local.json'
if ((-not $clientId -or -not $clientSecret) -and (Test-Path $secretsFile)) {
  $s = Read-Text $secretsFile | ConvertFrom-Json
  if (-not $clientId)     { $clientId     = $s.FT_CLIENT_ID }
  if (-not $clientSecret) { $clientSecret = $s.FT_CLIENT_SECRET }
}
if ($Demo -and (-not $clientId -or -not $clientSecret)) { $clientId = 'demo'; $clientSecret = 'demo' }
if (-not $clientId -or -not $clientSecret) {
  Write-Host ""
  Write-Host "  Identifiants France Travail manquants." -ForegroundColor Red
  Write-Host "  1) Cree un compte + une application sur https://francetravail.io"
  Write-Host "  2) Abonne l'application a l'API 'Offres d'emploi v2'"
  Write-Host "  3) Copie .env.example en .env et renseigne FT_CLIENT_ID / FT_CLIENT_SECRET"
  Write-Host ""
  exit 2
}

# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
function Write-Utf8([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-Header($resp, [string]$name) {
  foreach ($k in $resp.Headers.Keys) {
    if ($k -ieq $name) {
      $v = $resp.Headers[$k]
      if ($v -is [Array]) { return [string]$v[0] }
      return [string]$v
    }
  }
  return $null
}

function Remove-Diacritics([string]$s) {
  if (-not $s) { return '' }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $d.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

# --------------------------------------------------------------------------------------
# Auth France Travail (OAuth2 client_credentials, token mis en cache ~20 min)
# --------------------------------------------------------------------------------------
function Get-FtToken {
  $tc = Join-Path $cacheDir 'token.json'
  if (Test-Path $tc) {
    try {
      $c = Read-Text $tc | ConvertFrom-Json
      if ([DateTimeOffset]::Parse($c.expiresAt).UtcDateTime -gt (Get-Date).ToUniversalTime().AddSeconds(60)) {
        return $c.accessToken
      }
    } catch {}
  }
  $baseScope = if ($cfg.scope) { $cfg.scope } else { 'api_offresdemploiv2 o2dsoffre' }
  $uri = 'https://entreprise.francetravail.fr/connexion/oauth2/access_token?realm=%2Fpartenaire'
  $resp = $null
  foreach ($scope in @($baseScope, "$baseScope application_$clientId")) {
    try {
      $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'client_credentials'; client_id = $clientId; client_secret = $clientSecret; scope = $scope
      }
      break
    } catch {}
  }
  if (-not $resp) {
    Write-Host ""
    Write-Host "  Authentification France Travail refusee." -ForegroundColor Red
    Write-Host "  Verifie FT_CLIENT_ID / FT_CLIENT_SECRET et que l'application est bien"
    Write-Host "  abonnee a l'API 'Offres d'emploi v2' sur https://francetravail.io"
    Write-Host ""
    exit 3
  }
  $expiresAt = (Get-Date).ToUniversalTime().AddSeconds([int]$resp.expires_in)
  [pscustomobject]@{ accessToken = $resp.access_token; expiresAt = $expiresAt.ToString('o') } |
    ConvertTo-Json | Set-Content -Path $tc -Encoding UTF8
  return $resp.access_token
}

# --------------------------------------------------------------------------------------
# Recherche paginee
# --------------------------------------------------------------------------------------
$baseSearch = 'https://api.francetravail.io/partenaire/offresdemploi/v2/offres/search'

function Invoke-FtSearch([hashtable]$query) {
  $headers  = @{ Authorization = "Bearer $(Get-FtToken)"; Accept = 'application/json' }
  $pageSize = 150
  $maxP     = if ($MaxPages -gt 0) { $MaxPages } elseif ($cfg.maxPages) { [int]$cfg.maxPages } else { 7 }
  $collected = New-Object System.Collections.Generic.List[object]

  for ($p = 0; $p -lt $maxP; $p++) {
    $start = $p * $pageSize
    if ($start -gt 3149) { break }
    $end = [Math]::Min($start + $pageSize - 1, 3149)

    $params = @{}
    foreach ($k in $query.Keys) { $params[$k] = $query[$k] }
    $params['sort']  = 1
    $params['range'] = "$start-$end"
    $qs  = ($params.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    $url = "$baseSearch`?$qs"

    $resp = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
      try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing
        break
      } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 429 -or ($code -ge 500 -and $code -lt 600)) {
          Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt))); continue
        }
        if ($code -eq 400) { return $collected }   # requete refusee (ex: code ROME inconnu) -> on ignore
        if ($code -eq 401) { Remove-Item (Join-Path $cacheDir 'token.json') -ErrorAction SilentlyContinue; throw }
        throw
      }
    }
    if (-not $resp -or $resp.StatusCode -eq 204) { break }

    $data = $null
    try { $data = $resp.Content | ConvertFrom-Json } catch { break }
    if (-not $data.resultats) { break }
    foreach ($o in $data.resultats) { $collected.Add($o) }

    $total = $null
    $cr = Get-Header $resp 'Content-Range'
    if ($cr -and $cr -match '/(\d+)\s*$') { $total = [int]$Matches[1] }
    if ($data.resultats.Count -lt $pageSize) { break }
    if ($null -ne $total -and ($end + 1) -ge $total) { break }
    Start-Sleep -Milliseconds 200
  }
  return $collected
}

# --------------------------------------------------------------------------------------
# Fenetre temporelle + parametres
# --------------------------------------------------------------------------------------
$hours   = if ($Since -gt 0) { $Since } elseif ($cfg.fenetreHeures) { [int]$cfg.fenetreHeures } else { 24 }
$nowUtc  = (Get-Date).ToUniversalTime()
$minDate = $nowUtc.AddHours(-$hours)
$fmt     = 'yyyy-MM-ddTHH:mm:ssZ'
$minStr  = $minDate.ToString($fmt)
$maxStr  = $nowUtc.ToString($fmt)

$strictDuree = $Strict -or ($cfg.dureeStricteParDefaut -eq $true)

$deptStr = $null
if ($Departements) {
  $deptStr = (($Departements -split '[,;\s]+') | Where-Object { $_ }) -join ','
} elseif ($cfg.departements -and @($cfg.departements).Count -gt 0) {
  $deptStr = (@($cfg.departements)) -join ','
}

# E2 = contrat d'apprentissage, FS = contrat de professionnalisation (l'API accepte la liste "E2,FS")
$natureStr  = (@(if ($cfg.naturesContrat) { $cfg.naturesContrat } else { 'E2', 'FS' })) -join ','
$romeCodes  = @($cfg.codesRome)
$kwQueries  = @($cfg.motsClesRequetes)

# --------------------------------------------------------------------------------------
# Collecte
# --------------------------------------------------------------------------------------
$raw = @{}
function Add-Offers($list, [bool]$viaRome) {
  foreach ($o in $list) {
    if (-not $o.id) { continue }
    if ($raw.ContainsKey($o.id)) {
      if ($viaRome) { $raw[$o.id] | Add-Member -NotePropertyName viaRome -NotePropertyValue $true -Force }
      continue
    }
    $o | Add-Member -NotePropertyName viaRome -NotePropertyValue $viaRome -Force
    $raw[$o.id] = $o
  }
}

Write-Verbose "Fenetre : $minStr -> $maxStr  ($hours h)"
if ($Demo) {
  $samplePath = Join-Path $root 'sample/offres.sample.json'
  Add-Offers ((Read-Text $samplePath | ConvertFrom-Json).resultats) $false
  if (-not $Json) { Write-Host "  [DEMO] jeu de donnees local : $samplePath" -ForegroundColor Magenta }
}
if (-not $Demo) {
  foreach ($rc in $romeCodes) {
    $q = @{ natureContrat = $natureStr; codeROME = $rc; minCreationDate = $minStr; maxCreationDate = $maxStr }
    if ($deptStr) { $q['departement'] = $deptStr }
    Add-Offers (Invoke-FtSearch $q) $true
  }
  foreach ($kw in $kwQueries) {
    $q = @{ natureContrat = $natureStr; motsCles = $kw; minCreationDate = $minStr; maxCreationDate = $maxStr }
    if ($deptStr) { $q['departement'] = $deptStr }
    Add-Offers (Invoke-FtSearch $q) $false
  }
}

# --------------------------------------------------------------------------------------
# Filtrage
# --------------------------------------------------------------------------------------
$financeTerms = @($cfg.motsFinance) | ForEach-Object { Remove-Diacritics $_ }
$excludeTerms = @($cfg.motsExclure) | ForEach-Object { Remove-Diacritics $_ }

function Test-Contains([string]$blob, $terms) {
  foreach ($t in $terms) { if ($t -and $blob.Contains($t)) { return $true } }
  return $false
}
function Test-Duree24([string]$blob) {
  return ($blob -match '(^|[^0-9])24\s*mois' -or $blob -match '(^|[^0-9])2\s*ans' -or
          $blob -match 'deux\s*ans' -or $blob -match '24\s*months')
}

$seenPath = Join-Path $dataDir 'seen.json'
$seen = @()
if (Test-Path $seenPath) { try { $parsedSeen = Read-Text $seenPath | ConvertFrom-Json; $seen = @($parsedSeen) } catch { $seen = @() } }
$seenSet = @{}; foreach ($x in $seen) { $seenSet[$x] = $true }

$offers = New-Object System.Collections.Generic.List[object]
foreach ($o in $raw.Values) {
  $created = $null
  try { $created = [DateTimeOffset]::Parse($o.dateCreation).UtcDateTime } catch { continue }
  if (-not $Demo -and $created -lt $minDate) { continue }

  $blob = ' ' + (Remove-Diacritics ("$($o.intitule) $($o.description) $($o.romeLibelle) $($o.appellationlibelle)")) + ' '

  $isFinance = ($o.viaRome -eq $true) -or (Test-Contains $blob $financeTerms)
  if (-not $isFinance) { continue }

  if (Test-Contains $blob $excludeTerms) {
    if (-not ($blob.Contains('alternance') -or $blob.Contains('apprentissage') -or $blob.Contains('alternant'))) { continue }
  }

  $d24 = [bool](Test-Duree24 $blob)
  if ($strictDuree -and -not $d24) { continue }

  $url = if ($o.origineOffre -and $o.origineOffre.urlOrigine) { $o.origineOffre.urlOrigine }
         else { "https://candidat.francetravail.fr/offres/recherche/detail/$($o.id)" }

  $offers.Add([pscustomobject]@{
    id           = $o.id
    intitule     = [string]$o.intitule
    entreprise   = [string]$o.entreprise.nom
    lieu         = [string]$o.lieuTravail.libelle
    departement  = [string]$o.lieuTravail.departement
    dateCreation = $created.ToString('o')
    contrat      = [string]$o.typeContratLibelle
    nature       = [string]$o.natureContrat
    duree24      = $d24
    dureeLibelle = [string]$o.dureeTravailLibelle
    rome         = [string]$o.romeCode
    romeLibelle  = [string]$o.romeLibelle
    salaire      = [string]$o.salaire.libelle
    url          = $url
    nouvelle     = -not $seenSet.ContainsKey([string]$o.id)
  })
}

$offers = @($offers | Sort-Object { [datetime]$_.dateCreation } -Descending)
$new    = @($offers | Where-Object { $_.nouvelle })

# --------------------------------------------------------------------------------------
# Sorties
# --------------------------------------------------------------------------------------
$payload = [pscustomobject]@{
  generatedAt   = $nowUtc.ToString('o')
  fenetreHeures = $hours
  total         = $offers.Count
  nouvelles     = $new.Count
  strict24mois  = [bool]$strictDuree
  offres        = $offers
}

function Build-Markdown {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("# Offres d'alternance - Finance / Risques / Analyse")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("_Fenetre : $hours h glissantes - genere le $($nowUtc.ToString('yyyy-MM-dd HH:mm')) UTC - source France Travail_")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("**$($offers.Count) offre(s)**, dont **$($new.Count) nouvelle(s)** depuis le dernier passage." + $(if ($strictDuree) { " (filtre 24 mois actif)" } else { "" }))
  [void]$sb.AppendLine()
  $groups = @(
    @{ Title = "## Nouvelles offres"; Items = $new },
    @{ Title = "## Deja vues (fenetre courante)"; Items = @($offers | Where-Object { -not $_.nouvelle }) }
  )
  foreach ($g in $groups) {
    if (-not $g.Items -or $g.Items.Count -eq 0) { continue }
    [void]$sb.AppendLine($g.Title)
    [void]$sb.AppendLine()
    foreach ($o in $g.Items) {
      $flag = if ($o.duree24) { "24 mois OK" } else { "duree a verifier" }
      $ent  = if ($o.entreprise) { $o.entreprise } else { "Entreprise non precisee" }
      [void]$sb.AppendLine("### $($o.intitule)")
      [void]$sb.AppendLine("- $ent - $($o.lieu)")
      [void]$sb.AppendLine("- Publiee le $([datetime]$o.dateCreation | Get-Date -Format 'yyyy-MM-dd HH:mm') UTC")
      [void]$sb.AppendLine("- $($o.contrat) - $flag" + $(if ($o.salaire) { " - $($o.salaire)" } else { "" }))
      [void]$sb.AppendLine("- ROME $($o.rome) - $($o.romeLibelle)")
      [void]$sb.AppendLine("- $($o.url)")
      [void]$sb.AppendLine()
    }
  }
  return $sb.ToString()
}

if (-not $NoWrite) {
  Write-Utf8 (Join-Path $dataDir 'latest.json') ($payload | ConvertTo-Json -Depth 6)
  Write-Utf8 (Join-Path $dataDir 'latest.md')   (Build-Markdown)
  Add-Content -Path (Join-Path $dataDir 'history.jsonl') -Value ($payload | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
  $merged = New-Object System.Collections.Generic.List[string]
  foreach ($x in @($offers | ForEach-Object { [string]$_.id }) + @($seen | ForEach-Object { [string]$_ })) {
    if ($x -and -not $merged.Contains($x)) { $merged.Add($x) }
  }
  if ($merged.Count -gt 8000) { $merged = $merged.GetRange(0, 8000) }
  Write-Utf8 $seenPath (ConvertTo-Json @([string[]]$merged))
}

if ($Json) {
  $payload | ConvertTo-Json -Depth 6
} elseif (-not $Quiet) {
  Write-Host ""
  Write-Host ("  Alternance Finance / Risques / Analyse - {0} h glissantes" -f $hours) -ForegroundColor Cyan
  Write-Host ("  {0} offre(s), {1} nouvelle(s)  -  {2} UTC" -f $offers.Count, $new.Count, $nowUtc.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
  if ($strictDuree) { Write-Host "  Filtre 24 mois : actif" -ForegroundColor DarkCyan }
  Write-Host ""
  $list = if ($All) { $offers } elseif ($new.Count) { $new } else { $offers }
  foreach ($o in $list) {
    $col = if ($o.nouvelle) { 'Green' } else { 'Gray' }
    $tag = if ($o.nouvelle) { '[NEW] ' } else { '      ' }
    $ent = if ($o.entreprise) { $o.entreprise } else { 'Entreprise non precisee' }
    Write-Host ($tag + $o.intitule) -ForegroundColor $col
    Write-Host ("        {0} | {1} | {2} UTC" -f $ent, $o.lieu, ([datetime]$o.dateCreation).ToString('dd/MM HH:mm')) -ForegroundColor DarkGray
    $flag = if ($o.duree24) { '24 mois OK' } else { 'duree ?' }
    Write-Host ("        {0} | {1} | ROME {2}" -f $o.contrat, $flag, $o.rome) -ForegroundColor DarkGray
    Write-Host ("        {0}" -f $o.url) -ForegroundColor Blue
    Write-Host ""
  }
  if (-not $All -and -not $new.Count) {
    Write-Host "  Aucune nouvelle offre depuis le dernier passage (affichage de la fenetre complete)." -ForegroundColor DarkYellow
  }
  Write-Host ("  Details : {0}" -f (Join-Path $dataDir 'latest.md')) -ForegroundColor DarkGray
  Write-Host ""
}

# --------------------------------------------------------------------------------------
# Notification Telegram (optionnelle)
# --------------------------------------------------------------------------------------
if ($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID -and $new.Count -gt 0) {
  $bloc = ($new | Select-Object -First 20 | ForEach-Object { "- $($_.intitule) - $($_.entreprise) ($($_.lieu))`n$($_.url)" }) -join "`n`n"
  $msg  = "$($new.Count) nouvelle(s) alternance finance / risques (fenetre $hours h)`n`n$bloc"
  try {
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" `
      -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $msg; disable_web_page_preview = 'true' } | Out-Null
  } catch { Write-Warning "Notification Telegram echouee : $_" }
}

if ($env:GITHUB_STEP_SUMMARY -and (Test-Path (Join-Path $dataDir 'latest.md'))) {
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value (Read-Text (Join-Path $dataDir 'latest.md')) -Encoding UTF8
}

exit 0
