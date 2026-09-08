#requires -Version 5.1
<#
.SYNOPSIS
  Veille des offres d'alternance (Master Finance) sur LinkedIn : gestion des risques,
  analyse financiere, controle de gestion, conformite, audit...

.DESCRIPTION
  - Interroge l'endpoint public "jobs-guest" de LinkedIn (aucun compte / aucune cle requis).
  - Fenetre glissante de 24 h par defaut (filtre natif LinkedIn f_TPR ; parametre -Since).
  - Ne garde que les offres en alternance ET liees a la finance (mots-cles configurables).
  - Repere les contrats "24 mois" (marqueur, ou filtre dur avec -Strict).
  - Deduplique d'un passage a l'autre (data/seen.json) => met en avant les NOUVELLES offres.
  - Ecrit data/latest.json, data/latest.md et journalise data/history.jsonl.
  - Notification Telegram optionnelle (voir README).

.EXAMPLE
  .\alternance.ps1
  .\alternance.ps1 -Since 12 -Strict
  .\alternance.ps1 -All -NoEnrich
  .\alternance.ps1 -Demo
#>
[CmdletBinding()]
param(
  [int]$Since = 0,
  [switch]$All,
  [switch]$Strict,
  [switch]$Json,
  [switch]$Quiet,
  [int]$Pages = 0,
  [switch]$NoEnrich,
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

function Read-Text([string]$path) { return [IO.File]::ReadAllText($path) }     # UTF-8 fiable (PS 5.1 + 7)
function Write-Utf8([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Import-DotEnv([string]$path) {
  if (-not (Test-Path $path)) { return }
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('='); if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim(); $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
    if (-not [Environment]::GetEnvironmentVariable($k)) { [Environment]::SetEnvironmentVariable($k, $v) }
  }
}
Import-DotEnv (Join-Path $root '.env')

$cfg = Read-Text (Join-Path $root 'config.json') | ConvertFrom-Json

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
function Strip-Html([string]$h) {
  if (-not $h) { return '' }
  $t = [regex]::Replace($h, '(?s)<script.*?</script>', ' ')
  $t = [regex]::Replace($t, '(?s)<style.*?</style>', ' ')
  $t = $t -replace '<[^>]+>', ' '
  $t = [Net.WebUtility]::HtmlDecode($t)
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

# --------------------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------------------
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$rng = New-Object Random
$pauseMs = if ($cfg.pauseMs) { [int]$cfg.pauseMs } else { 2000 }

function Get-Html([string]$url) {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      $r = Invoke-WebRequest -Uri $url -Headers @{
        'User-Agent'      = $UA
        'Accept'          = 'text/html,application/xhtml+xml'
        'Accept-Language' = 'fr-FR,fr;q=0.9,en;q=0.8'
      } -Method Get -UseBasicParsing -TimeoutSec 30
      return [string]$r.Content
    } catch {
      $code = $null
      try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -or $code -eq 403) {
        $wait = 20 * $attempt
        Write-Warning "LinkedIn a repondu $code - pause $wait s (anti-robot)."
        Start-Sleep -Seconds $wait; continue
      }
      if ($code -eq 400 -or $code -eq 404) { return '' }   # plus de pages
      if ($attempt -eq 4) { throw }
      Start-Sleep -Seconds (3 * $attempt)
    }
  }
  return ''
}
function Wait-Politely { Start-Sleep -Milliseconds ($pauseMs + $rng.Next(0, 1400)) }

# --------------------------------------------------------------------------------------
# Parsing des cartes d'offres
# --------------------------------------------------------------------------------------
function Parse-Cards([string]$html) {
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $html) { return $out }
  $ids = [regex]::Matches($html, 'urn:li:jobPosting:(\d+)')
  for ($i = 0; $i -lt $ids.Count; $i++) {
    $s = $ids[$i].Index
    $e = if ($i + 1 -lt $ids.Count) { $ids[$i + 1].Index } else { $html.Length }
    $seg = $html.Substring($s, $e - $s)
    $id = $ids[$i].Groups[1].Value

    $title = ''
    $m = [regex]::Match($seg, '(?s)base-search-card__title">(.*?)</h3>')
    if ($m.Success) { $title = Strip-Html $m.Groups[1].Value }

    $company = ''
    $m = [regex]::Match($seg, '(?s)base-search-card__subtitle">(.*?)</h4>')
    if ($m.Success) { $company = Strip-Html $m.Groups[1].Value }

    $loc = ''
    $m = [regex]::Match($seg, '(?s)job-search-card__location">(.*?)</span>')
    if ($m.Success) { $loc = Strip-Html $m.Groups[1].Value }

    $date = ''
    $m = [regex]::Match($seg, 'listdate[^"]*"[^>]*datetime="([^"]+)"')
    if ($m.Success) { $date = $m.Groups[1].Value }

    $out.Add([pscustomobject]@{
      id = $id; intitule = $title; entreprise = $company; lieu = $loc
      listdate = $date; url = "https://www.linkedin.com/jobs/view/$id"
    })
  }
  return $out
}

# --------------------------------------------------------------------------------------
# Parametres de fenetre
# --------------------------------------------------------------------------------------
$hours   = if ($Since -gt 0) { $Since } elseif ($cfg.fenetreHeures) { [int]$cfg.fenetreHeures } else { 24 }
$nowUtc  = (Get-Date).ToUniversalTime()
$minDate = $nowUtc.AddHours(-$hours)
$fTpr    = 'r' + ([int]($hours * 3600))
$pagesMax = if ($Pages -gt 0) { $Pages } elseif ($cfg.pagesMax) { [int]$cfg.pagesMax } else { 4 }

$termsAlt = @($cfg.motsAlternance)   | ForEach-Object { Remove-Diacritics $_ }
$termsFin = @($cfg.motsFinanceTitre) | ForEach-Object { Remove-Diacritics $_ }
function Has([string]$blob, $terms) { foreach ($t in $terms) { if ($t -and $blob.Contains($t)) { return $true } }; return $false }
function Matched([string]$blob, $terms) { foreach ($t in $terms) { if ($t -and $blob.Contains($t)) { return $t.Trim() } }; return $null }
function Test-Duree24([string]$b) {
  return ($b -match '(^|[^0-9])24\s*mois' -or $b -match '(^|[^0-9])2\s*ans' -or $b -match 'deux\s*ans' -or $b -match '24\s*months')
}

# --------------------------------------------------------------------------------------
# Collecte
# --------------------------------------------------------------------------------------
$cards = @{}
if ($Demo) {
  $sp = Join-Path $root 'sample/offres.sample.json'
  foreach ($c in (Read-Text $sp | ConvertFrom-Json)) { $cards[[string]$c.id] = $c }
  if (-not $Json) { Write-Host "  [DEMO] jeu de donnees local : $sp" -ForegroundColor Magenta }
} else {
  $base = 'https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search'
  foreach ($q in @($cfg.requetes)) {
    $kw = [Uri]::EscapeDataString([string]$q.keywords)
    $lo = [Uri]::EscapeDataString([string]$q.location)
    for ($p = 0; $p -lt $pagesMax; $p++) {
      $url = "$base`?keywords=$kw&location=$lo&f_TPR=$fTpr&sortBy=DD&start=$($p * 10)"
      $html = Get-Html $url
      $batch = Parse-Cards $html
      if ($batch.Count -eq 0) { break }
      foreach ($c in $batch) { if (-not $cards.ContainsKey($c.id)) { $cards[$c.id] = $c } }
      Wait-Politely
    }
  }
  if ($cards.Count -eq 0) {
    Write-Warning "Aucune carte recuperee. LinkedIn bloque peut-etre les requetes depuis cette IP (essaie plus tard, ou en local plutot qu'en CI)."
  }
}

# --------------------------------------------------------------------------------------
# Filtrage + enrichissement (description)
# --------------------------------------------------------------------------------------
$enrich = $cfg.enrichirDescription -and -not $NoEnrich -and -not $Demo
$enrichMax = if ($cfg.enrichMax) { [int]$cfg.enrichMax } else { 70 }
$strictDuree = $Strict -or ($cfg.dureeStricteParDefaut -eq $true)

$seenPath = Join-Path $dataDir 'seen.json'
$seen = @()
if (Test-Path $seenPath) { try { $seen = @((Read-Text $seenPath | ConvertFrom-Json)) } catch { $seen = @() } }
$seenSet = @{}; foreach ($x in $seen) { $seenSet[[string]$x] = $true }

# Selection : alternance (titre + entreprise) ET signal finance PRECIS dans le TITRE.
$candidates = New-Object System.Collections.Generic.List[object]
foreach ($c in $cards.Values) {
  $altBlob   = ' ' + (Remove-Diacritics ("$($c.intitule) $($c.entreprise)")) + ' '
  $titleBlob = ' ' + (Remove-Diacritics ([string]$c.intitule)) + ' '
  if (-not (Has $altBlob $termsAlt)) { continue }
  $hit = Matched $titleBlob $termsFin
  if (-not $hit) { continue }
  $c | Add-Member -NotePropertyName finHit -NotePropertyValue $hit -Force
  $candidates.Add($c)
}

$enriched = 0
$offers = New-Object System.Collections.Generic.List[object]
foreach ($c in $candidates) {
  $desc = ''
  if ($enrich -and $enriched -lt $enrichMax) {
    $d = Get-Html "https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/$($c.id)"
    $enriched++
    Wait-Politely
    $m = [regex]::Match($d, '(?s)show-more-less-html__markup[^>]*>(.*?)</div>')
    if ($m.Success) { $desc = Strip-Html $m.Groups[1].Value }
    if (-not $c.entreprise) {
      $mc = [regex]::Match($d, '(?s)topcard__org-name-link[^>]*>(.*?)</a>')
      if ($mc.Success) { $c.entreprise = Strip-Html $mc.Groups[1].Value }
    }
  }
  $blob = ' ' + (Remove-Diacritics ("$($c.intitule) $desc")) + ' '

  $d24 = [bool](Test-Duree24 $blob)
  if ($strictDuree -and -not $d24) { continue }

  $listUtc = $null
  if ($c.listdate) {
    try {
      $listUtc = [DateTimeOffset]::Parse($c.listdate, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
    } catch {}
  }

  $offers.Add([pscustomobject]@{
    id           = [string]$c.id
    intitule     = [string]$c.intitule
    entreprise   = [string]$c.entreprise
    lieu         = [string]$c.lieu
    datePubliee  = $(if ($listUtc) { $listUtc.ToString('yyyy-MM-dd') } else { '' })
    duree24      = $d24
    matchFinance = [string]$c.finHit
    url          = [string]$c.url
    nouvelle     = -not $seenSet.ContainsKey([string]$c.id)
  })
}

$offers = @($offers | Sort-Object -Property @{ Expression = 'datePubliee'; Descending = $true }, @{ Expression = 'nouvelle'; Descending = $true })
$new    = @($offers | Where-Object { $_.nouvelle })

# --------------------------------------------------------------------------------------
# Sorties
# --------------------------------------------------------------------------------------
$payload = [pscustomobject]@{
  generatedAt   = $nowUtc.ToString('o')
  source        = 'linkedin'
  fenetreHeures = $hours
  total         = $offers.Count
  nouvelles     = $new.Count
  strict24mois  = [bool]$strictDuree
  offres        = $offers
}

function Build-Markdown {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("# Offres d'alternance - Finance / Risques / Analyse (LinkedIn)")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("_Fenetre : $hours h glissantes - genere le $($nowUtc.ToString('yyyy-MM-dd HH:mm')) UTC_")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("**$($offers.Count) offre(s)**, dont **$($new.Count) nouvelle(s)** depuis le dernier passage." + $(if ($strictDuree) { " (filtre 24 mois actif)" } else { "" }))
  [void]$sb.AppendLine()
  foreach ($g in @(
      @{ t = "## Nouvelles offres"; items = $new },
      @{ t = "## Deja vues (fenetre courante)"; items = @($offers | Where-Object { -not $_.nouvelle }) })) {
    if (-not $g.items -or $g.items.Count -eq 0) { continue }
    [void]$sb.AppendLine($g.t); [void]$sb.AppendLine()
    foreach ($o in $g.items) {
      $flag = if ($o.duree24) { "24 mois OK" } else { "duree a verifier" }
      $ent = if ($o.entreprise) { $o.entreprise } else { "Entreprise non precisee" }
      [void]$sb.AppendLine("### $($o.intitule)")
      [void]$sb.AppendLine("- $ent - $($o.lieu)" + $(if ($o.datePubliee) { " - publiee $($o.datePubliee)" } else { "" }))
      [void]$sb.AppendLine("- $flag" + $(if ($o.matchFinance) { " - mot-cle : $($o.matchFinance)" } else { "" }))
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
  Write-Host ("  Alternance Finance / Risques / Analyse (LinkedIn) - {0} h glissantes" -f $hours) -ForegroundColor Cyan
  Write-Host ("  {0} offre(s), {1} nouvelle(s)  -  {2} UTC" -f $offers.Count, $new.Count, $nowUtc.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
  if ($strictDuree) { Write-Host "  Filtre 24 mois : actif" -ForegroundColor DarkCyan }
  Write-Host ""
  $list = if ($All) { $offers } elseif ($new.Count) { $new } else { $offers }
  foreach ($o in $list) {
    $col = if ($o.nouvelle) { 'Green' } else { 'Gray' }
    $tag = if ($o.nouvelle) { '[NEW] ' } else { '      ' }
    $ent = if ($o.entreprise) { $o.entreprise } else { 'Entreprise non precisee' }
    Write-Host ($tag + $o.intitule) -ForegroundColor $col
    Write-Host ("        {0} | {1}{2}" -f $ent, $o.lieu, $(if ($o.datePubliee) { " | $($o.datePubliee)" } else { "" })) -ForegroundColor DarkGray
    Write-Host ("        {0}" -f $(if ($o.duree24) { '24 mois OK' } else { 'duree ?' })) -ForegroundColor DarkGray
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
  $msg = "$($new.Count) nouvelle(s) alternance finance / risques - LinkedIn (fenetre $hours h)`n`n$bloc"
  try {
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" `
      -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $msg; disable_web_page_preview = 'true' } | Out-Null
  } catch { Write-Warning "Notification Telegram echouee : $_" }
}

# --------------------------------------------------------------------------------------
# Export Notion (base "SUIVI ALTERNANCE") - optionnel
# --------------------------------------------------------------------------------------
$notionToken = $env:NOTION_TOKEN
$notionDb    = if ($env:NOTION_DB_ID) { ($env:NOTION_DB_ID -replace '-', '') } elseif ($cfg.notionDbId) { ([string]$cfg.notionDbId -replace '-', '') } else { $null }

if ($notionToken -and $notionDb -and -not $Demo) {
  $nh = @{ Authorization = "Bearer $notionToken"; 'Notion-Version' = '2022-06-28' }
  $dejaNotion = @{}
  try {
    $cursor = $null
    do {
      $qb = @{ page_size = 100 }
      if ($cursor) { $qb['start_cursor'] = $cursor }
      $qr = Invoke-RestMethod -Method Post -Uri "https://api.notion.com/v1/databases/$notionDb/query" `
        -Headers $nh -ContentType 'application/json' -Body ($qb | ConvertTo-Json)
      foreach ($row in $qr.results) {
        $rt = $row.properties.'ID LinkedIn'.rich_text
        if ($rt -and $rt.Count -gt 0) { $dejaNotion[[string]$rt[0].plain_text] = $true }
      }
      $cursor = if ($qr.has_more) { $qr.next_cursor } else { $null }
    } while ($cursor)
  } catch {
    Write-Warning "Notion : lecture de la base impossible ($_). Verifie NOTION_TOKEN et le partage de la base avec l'integration."
  }

  $pushErr = $null
  $pushed = 0
  foreach ($o in $offers) {
    if ($dejaNotion.ContainsKey([string]$o.id)) { continue }
    $props = @{
      'Nom'             = @{ title = @(@{ text = @{ content = ($o.intitule) } }) }
      'Entreprise'      = @{ rich_text = @(@{ text = @{ content = ("$($o.entreprise)") } }) }
      'Lieu'            = @{ rich_text = @(@{ text = @{ content = ("$($o.lieu)") } }) }
      'Offre'           = @{ url = $o.url }
      '24 mois'         = @{ checkbox = [bool]$o.duree24 }
      'Mot-clé finance' = @{ rich_text = @(@{ text = @{ content = ("$($o.matchFinance)") } }) }
      'Source'          = @{ select = @{ name = 'LinkedIn' } }
      'Statut'          = @{ select = @{ name = 'À traiter' } }
      'ID LinkedIn'     = @{ rich_text = @(@{ text = @{ content = ([string]$o.id) } }) }
    }
    if ($o.datePubliee) { $props['Date de publication'] = @{ date = @{ start = $o.datePubliee } } }
    $body = @{ parent = @{ database_id = $notionDb }; properties = $props } | ConvertTo-Json -Depth 12
    try {
      Invoke-RestMethod -Method Post -Uri 'https://api.notion.com/v1/pages' -Headers $nh `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
      $pushed++
      $dejaNotion[[string]$o.id] = $true
      Start-Sleep -Milliseconds 350
    } catch { $pushErr = "$_" }
  }
  if ($pushErr) { Write-Warning "Notion : au moins une offre n'a pas pu etre ajoutee ($pushErr)" }
  if (-not $Quiet -and -not $Json) {
    Write-Host ("  Notion 'SUIVI ALTERNANCE' : {0} offre(s) ajoutee(s)." -f $pushed) -ForegroundColor DarkGreen
  }
}

if ($env:GITHUB_STEP_SUMMARY -and (Test-Path (Join-Path $dataDir 'latest.md'))) {
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value (Read-Text (Join-Path $dataDir 'latest.md')) -Encoding UTF8
}

exit 0
