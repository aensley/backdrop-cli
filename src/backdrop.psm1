# backdrop.psm1 - set a new desktop wallpaper every day from various sources
# Sources: apod bing earth eo iotd natgeo wmc

#region Module state

$script:Version = '1.6.1'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'backdrop'
$script:ConfigDir = Join-Path $env:APPDATA 'backdrop'
$script:ConfigFile = Join-Path $script:ConfigDir 'config'
$script:ValidSources = @('apod', 'bing', 'earth', 'iotd', 'natgeo', 'eo', 'wmc')
$script:TaskName = 'backdrop'

# Built-in defaults (overridden by config file)
$script:Source = 'iotd'
$script:RotateInterval = 0
$script:ScreenAspectRatio = 1.7778
$script:ZoomMinCoverage = 0.55
$script:UserAgent = "backdrop/$(($script:Version -split '\.')[0..1] -join '.') (personal daily wallpaper script)"
$script:TimerTime = '08:00'

$null = New-Item -ItemType Directory -Force -Path $script:StateDir, $script:ConfigDir

#endregion

#region Helpers

function Invoke-BackdropRequest {
  param([string]$Uri, [int]$TimeoutSec = 30)
  $ProgressPreference = 'SilentlyContinue'
  (Invoke-WebRequest -Uri $Uri -UseBasicParsing -UserAgent $script:UserAgent `
    -TimeoutSec $TimeoutSec -ErrorAction Stop).Content
}

function Save-BackdropFile {
  param([string]$Uri, [string]$OutFile, [int]$TimeoutSec = 120)
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $Uri -UseBasicParsing -UserAgent $script:UserAgent `
    -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
}

function Remove-HtmlMarkup {
  param($s)
  if ($s -is [System.Xml.XmlNode]) { $s = $s.InnerText }
  if (-not $s) { return '' }
  $s = [string]$s
  $s = $s -replace '<[^>]+>', ''
  try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $s = [System.Web.HttpUtility]::HtmlDecode($s)
  }
  catch { $null = $_ }
  ($s -replace '\s+', ' ').Trim()
}

#endregion

#region Config

function Get-BackdropConfigValue {
  param([string]$Key)
  if (-not (Test-Path $script:ConfigFile)) { return $null }
  $content = Get-Content $script:ConfigFile -Raw -ErrorAction SilentlyContinue
  if (-not $content) { return $null }
  if ($content -match "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$") {
    $v = $Matches[1]
    if ($v -match '^"(.+)"$' -or $v -match "^'(.+)'$") { return $Matches[1] }
    return $v
  }
  return $null
}

function Set-BackdropConfigValue {
  param([string]$Key, [string]$Value)
  Initialize-BackdropConfig
  $content = Get-Content $script:ConfigFile -Raw -ErrorAction SilentlyContinue
  if (-not $content) { $content = '' }
  if ($content -match "(?m)^\s*$([regex]::Escape($Key))\s*=") {
    $content = $content -replace "(?m)^(\s*$([regex]::Escape($Key))\s*=\s*).*", "`${1}$Value"
  }
  else {
    $content = $content.TrimEnd() + "`n$Key = $Value`n"
  }
  Set-Content -Path $script:ConfigFile -Value $content -NoNewline
}

function Initialize-BackdropConfig {
  if (Test-Path $script:ConfigFile) { return }
  Set-Content -Path $script:ConfigFile -Value @"
# backdrop configuration  (key = value; lines starting with # are ignored)

# Active wallpaper source(s): iotd | apod | bing | wmc | eo | earth | natgeo
# Single source:    source = iotd
# Multiple sources: source = iotd apod bing
# All sources:      source = all
# Also settable with: backdrop set <source> [source...]
source = $($script:Source)

# How often to rotate between sources, in minutes (0 = disabled).
# Only applies when multiple sources are configured.
# Also settable with: backdrop set-rotate-interval <minutes>
rotate_interval = $($script:RotateInterval)

# Screen aspect ratio used only if auto-detection fails.
# 16:9 = 1.7778   16:10 = 1.6   21:9 = 2.3333   4:3 = 1.3333
screen_aspect_ratio = $($script:ScreenAspectRatio)

# Crop tolerance for choosing zoom vs scaled.
zoom_min_coverage = $($script:ZoomMinCoverage)

# HTTP User-Agent string sent with all requests.
# user_agent = backdrop/1.6 (personal daily wallpaper script)

# Time of day to run the daily wallpaper update (HH:MM, 24-hour format).
# Also settable with: backdrop set-time HH:MM
timer_time = $($script:TimerTime)
"@
}

function Import-BackdropConfig {
  Initialize-BackdropConfig
  $v = Get-BackdropConfigValue 'screen_aspect_ratio'
  if ($v) { $script:ScreenAspectRatio = [double]$v }
  $v = Get-BackdropConfigValue 'zoom_min_coverage'
  if ($v) { $script:ZoomMinCoverage = [double]$v }
  $v = Get-BackdropConfigValue 'user_agent'
  if ($v) { $script:UserAgent = $v }
  $v = Get-BackdropConfigValue 'timer_time'
  if ($v) { $script:TimerTime = $v }
  $v = Get-BackdropConfigValue 'rotate_interval'
  if ($v -match '^\d+$') { $script:RotateInterval = [int]$v }
}

#endregion

#region Source resolvers
# Each returns a hashtable: Title, Desc, Url (source page), ImageUrls (array, best first).
# Returns $null when the source has no image today (e.g. APOD video day).
# Throws on network failure.

function Resolve-Iotd {
  $feed = Invoke-BackdropRequest 'https://www.nasa.gov/feeds/iotd-feed/'
  [xml]$xml = $feed
  $item = @($xml.rss.channel.item)[0]
  $imageUrl = $item.enclosure.url
  if (-not $imageUrl) { return $null }
  @{
    Title     = Remove-HtmlMarkup $item.title
    Desc      = Remove-HtmlMarkup $item.description
    Url       = if ($item.link) { $item.link } else { 'https://www.nasa.gov/image-of-the-day/' }
    ImageUrls = @($imageUrl)
  }
}

function Resolve-Apod {
  $page = Invoke-BackdropRequest 'https://apod.nasa.gov/apod/astropix.html'
  $rel = $null
  if ($page -match '(?i)href="(image/[^"]+\.(jpg|jpeg|png|gif))"') { $rel = $Matches[1] }
  if (-not $rel) { return $null }
  $title = ''
  $m = [regex]::Match($page, '(?i)<center>\s*<b>([^<]+)</b>\s*<br')
  if ($m.Success) { $title = Remove-HtmlMarkup $m.Groups[1].Value }
  $desc = ''
  $m = [regex]::Match($page, '(?is)<b>\s*Explanation:\s*</b>(.*?)(?=<p>|<hr|</body>)')
  if ($m.Success) {
    $desc = ($m.Groups[1].Value -replace '<[^>]+>', '') -replace '\s+', ' '
    $desc = $desc.Trim()
    if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 400) }
  }
  @{
    Title     = $title
    Desc      = $desc
    Url       = 'https://apod.nasa.gov/apod/astropix.html'
    ImageUrls = @("https://apod.nasa.gov/apod/$rel")
  }
}

function Resolve-Bing {
  $json = Invoke-BackdropRequest 'https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US'
  $img = ($json | ConvertFrom-Json).images[0]
  $urls = @()
  if ($img.urlbase) { $urls += "https://www.bing.com$($img.urlbase)_UHD.jpg" }
  if ($img.url) { $urls += "https://www.bing.com$($img.url)" }
  if (-not $urls) { return $null }
  @{
    Title     = $img.title
    Desc      = $img.copyright
    Url       = 'https://www.bing.com/'
    ImageUrls = $urls
  }
}

function Resolve-Wmc {
  $date = Get-Date -Format 'yyyy-MM-dd'
  $resp = Invoke-BackdropRequest "https://commons.wikimedia.org/w/api.php?action=expandtemplates&format=json&prop=wikitext&text=%7B%7BPotd/$date%7D%7D"
  $file = ($resp | ConvertFrom-Json).expandtemplates.wikitext
  if (-not $file) { return $null }
  $title = ($file -replace '^File:', '') -replace '\.[^.]+$', '' -replace '_', ' '
  $desc = ''
  try {
    $dresp = Invoke-BackdropRequest "https://commons.wikimedia.org/w/api.php?action=expandtemplates&format=json&prop=wikitext&text=%7B%7BPotd/$($date)%20(en)%7D%7D"
    $rawDesc = ($dresp | ConvertFrom-Json).expandtemplates.wikitext
    $rawDesc = $rawDesc -replace '\[\[(?:[^|\]]*\|)?([^\]]*)\]\]', '$1' -replace '\{\{[^}]*\}\}', ''
    $desc = ($rawDesc -replace '\s+', ' ').Trim()
    if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) }
  }
  catch { $null = $_ }
  $enc = [Uri]::EscapeDataString($file)
  $iresp = Invoke-BackdropRequest "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url&iiurlwidth=3840&titles=File:$enc"
  $info = (($iresp | ConvertFrom-Json).query.pages.PSObject.Properties | Select-Object -First 1).Value.imageinfo[0]
  $urls = @()
  if ($info.thumburl) { $urls += $info.thumburl }
  if ($info.url) { $urls += $info.url }
  if (-not $urls) { return $null }
  @{
    Title     = Remove-HtmlMarkup $title
    Desc      = Remove-HtmlMarkup $desc
    Url       = "https://commons.wikimedia.org/wiki/File:$([Uri]::EscapeDataString(($file -replace '^File:', '')))"
    ImageUrls = $urls
  }
}

function Resolve-Eo {
  $feed = Invoke-BackdropRequest 'https://earthobservatory.nasa.gov/feeds/image-of-the-day.rss'
  $m = [regex]::Match($feed, '(?is)<item>(.*?)</item>')
  if (-not $m.Success) { return $null }
  $item = $m.Groups[1].Value
  $imgUrl = $null
  if ($item -match '(?i)(https://assets\.science\.nasa\.gov/dynamicimage/[^"?]+\.(jpg|jpeg|png))') {
    $imgUrl = $Matches[1]
  }
  if (-not $imgUrl) { return $null }
  $title = ''
  if ($item -match '(?i)<title[^>]*><!\[CDATA\[([^\]]+)\]\]>') { $title = $Matches[1] }
  elseif ($item -match '(?i)<title[^>]*>([^<]+)</title>') { $title = $Matches[1] }
  $link = ''
  if ($item -match '(?i)<link>([^<]+)</link>') { $link = $Matches[1] }
  elseif ($item -match '(?i)(https://earthobservatory\.nasa\.gov/images/\d+[^"< ]*)') { $link = $Matches[1] }
  @{
    Title     = Remove-HtmlMarkup $title
    Desc      = ''
    Url       = if ($link) { $link.Trim() } else { 'https://earthobservatory.nasa.gov/' }
    ImageUrls = @("${imgUrl}?w=3840", $imgUrl)
  }
}

function Resolve-Natgeo {
  $page = Invoke-BackdropRequest 'https://www.nationalgeographic.com/photo-of-the-day/'
  $url = $null
  if ($page -match '(?i)property="og:image"\s+content="(https://i\.natgeofe\.com/[^"]+)"') { $url = $Matches[1] }
  if (-not $url) { return $null }
  $ogTitle = ''
  $ogDesc = ''
  $ogUrl = ''
  if ($page -match '(?i)property="og:title"\s+content="([^"]+)"') { $ogTitle = $Matches[1] -replace ' \|.*', '' }
  if ($page -match '(?i)property="og:description"\s+content="([^"]+)"') { $ogDesc = $Matches[1] }
  if ($page -match '(?i)property="og:url"\s+content="([^"]+)"') { $ogUrl = $Matches[1] }
  @{
    Title     = Remove-HtmlMarkup $ogTitle
    Desc      = Remove-HtmlMarkup $ogDesc
    Url       = if ($ogUrl) { $ogUrl } else { 'https://www.nationalgeographic.com/photo-of-the-day/' }
    ImageUrls = @("${url}?w=5120", $url)
  }
}

function Resolve-Earth {
  $page = Invoke-BackdropRequest 'https://www.earth.com/gallery/images-of-the-day/'
  $articleUrl = $null
  if ($page -match '(?i)href="(https://www\.earth\.com/image/[^"]+)"') { $articleUrl = $Matches[1] }
  if (-not $articleUrl) { return $null }
  $article = Invoke-BackdropRequest $articleUrl
  $url = $null
  if ($article -match '(?i)(https://cff2\.earth\.com/uploads/[^"]+\.(jpg|jpeg|png))') { $url = $Matches[1] }
  if (-not $url) { return $null }
  $ogTitle = ''
  $ogDesc = ''
  $ogUrl = ''
  if ($article -match '(?i)property="og:title"\s+content="([^"]+)"') { $ogTitle = $Matches[1] }
  if ($article -match '(?i)property="og:description"\s+content="([^"]+)"') { $ogDesc = $Matches[1] }
  if ($article -match '(?i)property="og:url"\s+content="([^"]+)"') { $ogUrl = $Matches[1] }
  @{
    Title     = Remove-HtmlMarkup $ogTitle
    Desc      = Remove-HtmlMarkup $ogDesc
    Url       = if ($ogUrl) { $ogUrl } else { $articleUrl }
    ImageUrls = @($url)
  }
}

#endregion

#region Geometry

function Get-ImageDimension {
  param([string]$Path)
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $img = [System.Drawing.Image]::FromFile($Path)
    $dims = @{ Width = $img.Width; Height = $img.Height }
    $img.Dispose()
    return $dims
  }
  catch {
    return $null
  }
}

function Get-ScreenAspectRatio {
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($s.Height -gt 0) { return [double]$s.Width / $s.Height }
  }
  catch { $null = $_ }
  return [double]$script:ScreenAspectRatio
}

function Get-PictureOption {
  param([string]$Path)
  $dims = Get-ImageDimension $Path
  if (-not $dims -or $dims.Width -le 0 -or $dims.Height -le 0) { return 'zoom' }
  $iar = [double]$dims.Width / $dims.Height
  $sar = Get-ScreenAspectRatio
  $cov = if ($iar -lt $sar) { $iar / $sar } else { $sar / $iar }
  if ($cov -ge $script:ZoomMinCoverage) { 'zoom' } else { 'scaled' }
}

#endregion

#region Wallpaper

if (-not ([System.Management.Automation.PSTypeName]'BackdropWallpaper').Type) {
  Add-Type @'
using System.Runtime.InteropServices;
public class BackdropWallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
}

function Set-Wallpaper {
  param([string]$Path, [string]$Option)
  # WallpaperStyle: 10=Fill (zoom/crop), 6=Fit (scaled/letterbox)
  $style = if ($Option -eq 'zoom') { '10' } else { '6' }
  Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $style
  Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0'
  [BackdropWallpaper]::SystemParametersInfo(20, 0, $Path, 3) | Out-Null
}

#endregion

#region Scheduling

function Invoke-TimerConfig {
  $action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NonInteractive -WindowStyle Hidden -Command `"Import-Module backdrop; backdrop update`""

  if ($script:RotateInterval -gt 0) {
    $timeTrigger = New-ScheduledTaskTrigger -Daily -At '00:00'
    $timeTrigger.Repetition.Interval = "PT$($script:RotateInterval)M"
    $timeTrigger.Repetition.Duration = 'P1D'
  }
  else {
    $timeTrigger = New-ScheduledTaskTrigger -Daily -At $script:TimerTime
  }

  $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $logon.Delay = 'PT2M'

  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -StartWhenAvailable -MultipleInstances IgnoreNew

  $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Set-ScheduledTask -TaskName $script:TaskName -Action $action `
      -Trigger @($timeTrigger, $logon) -Principal $principal -Settings $settings | Out-Null
  }
  else {
    Register-ScheduledTask -TaskName $script:TaskName -Action $action `
      -Trigger @($timeTrigger, $logon) -Principal $principal -Settings $settings | Out-Null
  }
}

#endregion

#region Source and meta helpers

function Get-BackdropSource {
  $s = Get-BackdropConfigValue 'source'
  if ($s) {
    if ($s -eq 'all') { return $script:ValidSources }
    return @($s -split '\s+')
  }
  return @($script:Source)
}

function Get-UnixTimestamp { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-ActiveSource {
  $srcs = @(Get-BackdropSource)
  if ($srcs.Count -le 1 -or $script:RotateInterval -le 0) {
    if ($srcs.Count -gt 0) { return $srcs[0] } else { return $script:Source }
  }
  $idx = [Math]::Floor((Get-UnixTimestamp) / 60 / $script:RotateInterval) % $srcs.Count
  return $srcs[$idx]
}

function Test-ValidSource {
  param([string]$s)
  $script:ValidSources -contains $s
}

function Write-MetaFile {
  param([string]$Dest, [hashtable]$Meta)
  $metaPath = [System.IO.Path]::ChangeExtension($Dest, 'meta')
  $lines = @()
  if ($Meta.Title) { $lines += "title = $($Meta.Title)" }
  if ($Meta.Desc) {
    $d = $Meta.Desc
    if ($d.Length -gt 200) { $d = $d.Substring(0, 200) }
    $lines += "desc = $d"
  }
  if ($Meta.Url) { $lines += "url = $($Meta.Url)" }
  Set-Content -Path $metaPath -Value $lines
}

function Get-MetaValue {
  param([string]$MetaFile, [string]$Key)
  if (-not (Test-Path $MetaFile)) { return $null }
  $content = Get-Content $MetaFile -Raw -ErrorAction SilentlyContinue
  if ($content -match "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$") { return $Matches[1] }
  return $null
}

#endregion

#region Core

function Invoke-ApplyWallpaper {
  param([string]$Src, [bool]$Force = $false)
  if (-not (Test-ValidSource $Src)) {
    throw "backdrop: unknown source '$Src' (valid: $($script:ValidSources -join ', '))"
  }

  $dest = Join-Path $script:StateDir "$Src-$(Get-Date -Format 'yyyy-MM-dd').jpg"

  if ((Test-Path $dest) -and -not $Force) {
    $opt = Get-PictureOption $dest
    Set-Wallpaper $dest $opt
    Set-Content -Path (Join-Path $script:StateDir 'current') -Value $dest
    $dims = Get-ImageDimension $dest
    $dimsStr = if ($dims) { "$($dims.Width)x$($dims.Height)" } else { 'unknown' }
    Write-Host "backdrop: set from $Src [$dimsStr, $opt] -> $dest (cached)"
    return
  }

  $result = switch ($Src) {
    'iotd' { Resolve-Iotd }
    'apod' { Resolve-Apod }
    'bing' { Resolve-Bing }
    'wmc' { Resolve-Wmc }
    'eo' { Resolve-Eo }
    'natgeo' { Resolve-Natgeo }
    'earth' { Resolve-Earth }
  }

  if ($null -eq $result) {
    Write-Host "backdrop: $Src has no image today (e.g. APOD video day); wallpaper unchanged."
    return
  }

  $ok = $false
  foreach ($url in $result.ImageUrls) {
    try { Save-BackdropFile $url $dest; $ok = $true; break } catch { $null = $_ }
  }
  if (-not $ok) { throw "backdrop: could not download any image for $Src" }

  $opt = Get-PictureOption $dest
  Set-Wallpaper $dest $opt
  Set-Content -Path (Join-Path $script:StateDir 'current') -Value $dest
  Write-MetaFile $dest $result

  Get-ChildItem $script:StateDir -File |
  Where-Object { $_.Extension -in @('.jpg', '.meta') -and $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

  $dims = Get-ImageDimension $dest
  $dimsStr = if ($dims) { "$($dims.Width)x$($dims.Height)" } else { 'unknown' }
  Write-Host "backdrop: set from $Src [$dimsStr, $opt] -> $dest"
}

#endregion

#region Commands

function Invoke-BackdropUpdate {
  param([switch]$Force)
  Invoke-ApplyWallpaper (Get-ActiveSource) $Force.IsPresent
}

function Invoke-BackdropRandom {
  param([switch]$Force)
  Invoke-ApplyWallpaper ($script:ValidSources | Get-Random) $Force.IsPresent
}

function Invoke-BackdropEnable {
  Invoke-TimerConfig
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task -and $task.State -eq 'Disabled') {
    Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
  }
  if ($script:RotateInterval -gt 0) {
    Write-Host "backdrop: timer enabled (rotating every $($script:RotateInterval) min)."
  }
  else {
    Write-Host "backdrop: daily timer enabled (runs at $($script:TimerTime))."
  }
  Invoke-BackdropUpdate
}

function Invoke-BackdropDisable {
  Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Out-Null
  Write-Host "backdrop: daily timer disabled."
}

function Invoke-BackdropSetTime {
  param([string]$Time)
  if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
    throw "backdrop: set-time: expected HH:MM (24-hour), e.g. 08:00"
  }
  $script:TimerTime = $Time
  Set-BackdropConfigValue 'timer_time' $Time
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Invoke-TimerConfig
    Write-Host "backdrop: timer time set to $Time and task updated."
  }
  else {
    Write-Host "backdrop: timer time set to $Time (run 'backdrop enable' to start the timer)."
  }
}

function Invoke-BackdropSetRotateInterval {
  param([string]$Minutes)
  if ($Minutes -notmatch '^\d+$') {
    throw "backdrop: set-rotate-interval: expected number of minutes (0 to disable), e.g. 60"
  }
  $script:RotateInterval = [int]$Minutes
  Set-BackdropConfigValue 'rotate_interval' $Minutes
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Invoke-TimerConfig
    if ([int]$Minutes -gt 0) {
      Write-Host "backdrop: rotate interval set to $Minutes min and task updated."
    }
    else {
      Write-Host "backdrop: rotation disabled, task reset to daily at $($script:TimerTime)."
    }
  }
  else {
    if ([int]$Minutes -gt 0) {
      Write-Host "backdrop: rotate interval set to $Minutes min (run 'backdrop enable' to start the timer)."
    }
    else {
      Write-Host "backdrop: rotation disabled (run 'backdrop enable' to start the daily timer)."
    }
  }
}

function Invoke-BackdropSet {
  param([string[]]$Sources, [bool]$Force = $false)
  if (-not $Sources -or $Sources.Count -eq 0) {
    throw "backdrop: set: choose one or more sources ($($script:ValidSources -join ', ')) or 'all'"
  }
  if ($Sources.Count -eq 1 -and $Sources[0] -eq 'all') { $Sources = $script:ValidSources }
  foreach ($s in $Sources) {
    if (-not (Test-ValidSource $s)) {
      throw "backdrop: set: unknown source '$s' (valid: $($script:ValidSources -join ', '))"
    }
  }
  Set-BackdropConfigValue 'source' ($Sources -join ' ')
  $timerChanged = $false
  if ($Sources.Count -gt 1) {
    if ($script:RotateInterval -le 0) {
      $script:RotateInterval = 30
      Set-BackdropConfigValue 'rotate_interval' '30'
      $timerChanged = $true
    }
    Write-Host "backdrop: active sources: $($Sources -join ' ') (rotating every $($script:RotateInterval) min)"
  }
  else {
    if ($script:RotateInterval -gt 0) {
      $script:RotateInterval = 0
      Set-BackdropConfigValue 'rotate_interval' '0'
      $timerChanged = $true
    }
    Write-Host "backdrop: active source is now '$($Sources[0])'"
  }
  if ($timerChanged) {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) { Invoke-TimerConfig }
  }
  Invoke-ApplyWallpaper (Get-ActiveSource) $Force
}

function Invoke-BackdropStatus {
  Write-Host "backdrop v$($script:Version)"
  Write-Host ''

  $activeSrcs = @(Get-BackdropSource)
  $activeSrc = Get-ActiveSource
  $latest = $null

  $currentFile = Join-Path $script:StateDir 'current'
  if (Test-Path $currentFile) {
    $p = (Get-Content $currentFile -Raw).Trim()
    if (Test-Path $p) { $latest = $p }
  }
  if (-not $latest) {
    $latest = Get-ChildItem $script:StateDir -Filter "$activeSrc-*.jpg" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  }

  $displayedSrc = $activeSrc
  if ($latest) {
    $candidate = [System.IO.Path]::GetFileNameWithoutExtension($latest) -replace '-\d{4}-\d{2}-\d{2}$', ''
    if (Test-ValidSource $candidate) { $displayedSrc = $candidate }
  }

  if ($activeSrcs.Count -gt 1) {
    $labeled = ($activeSrcs | ForEach-Object { if ($_ -eq $displayedSrc) { "[$_]" } else { $_ } }) -join ' '
    Write-Host "Active sources: $labeled"
  }
  else {
    Write-Host "Active source:  $activeSrc"
  }

  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task -and $task.State -ne 'Disabled') {
    if ($script:RotateInterval -gt 0) {
      Write-Host "Timer:          enabled (rotating every $($script:RotateInterval) min)"
    }
    else {
      Write-Host "Timer:          enabled (runs at $($script:TimerTime))"
    }
  }
  else {
    Write-Host "Timer:          disabled"
  }

  Write-Host ''
  if ($latest) {
    Write-Host "Current image:  $latest"
    $metaFile = [System.IO.Path]::ChangeExtension($latest, 'meta')
    $mv = Get-MetaValue $metaFile 'title'
    if ($mv) {
      if ($mv.Length -gt 77) { $mv = $mv.Substring(0, 77) + '...' }
      Write-Host "Title:          $mv"
    }
    $mv = Get-MetaValue $metaFile 'desc'
    if ($mv) {
      if ($mv.Length -gt 77) { $mv = $mv.Substring(0, 77) + '...' }
      Write-Host "Description:    $mv"
    }
    $mv = Get-MetaValue $metaFile 'url'
    if ($mv) { Write-Host "URL:            $mv" }
  }

  $styleNum = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallpaperStyle
  $styleStr = switch ($styleNum) { '10' { 'zoom' } '6' { 'scaled' } default { "style=$styleNum" } }
  Write-Host ''
  Write-Host "Display method: windows, $styleStr"
  Write-Host "Aspect ratio:   $(Get-ScreenAspectRatio), $($script:ZoomMinCoverage) min coverage"
  Write-Host "Config file:    $($script:ConfigFile)"
  Write-Host ''
  Write-Host "Use 'backdrop help' for usage information."
  Write-Host ''
}

function Invoke-BackdropUpgrade {
  Write-Host "backdrop: checking for updates (current: v$($script:Version))..."
  $apiResp = Invoke-BackdropRequest 'https://api.github.com/repos/aensley/backdrop/releases/latest' -TimeoutSec 15
  $release = $apiResp | ConvertFrom-Json
  $latestTag = $release.tag_name
  $latestVer = $latestTag.TrimStart('v')
  if ([version]$latestVer -le [version]$script:Version) {
    Write-Host "backdrop: already up to date (v$($script:Version))."
    return
  }
  Write-Host "backdrop: upgrading v$($script:Version) -> v$latestVer..."
  $rawUrl = "https://raw.githubusercontent.com/aensley/backdrop/$latestTag/src/backdrop.psm1"
  $modPath = (Get-Module backdrop -ErrorAction SilentlyContinue).Path
  if (-not $modPath) { throw 'backdrop: upgrade: could not locate installed module path' }
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    Save-BackdropFile $rawUrl $tmp -TimeoutSec 60
    Copy-Item $tmp $modPath -Force
    Write-Host "backdrop: upgraded to v$latestVer. Restart PowerShell to use the new version."
  }
  finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-BackdropUninstall {
  param([switch]$Purge)
  Disable-ScheduledTask  -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
  $modDir = Split-Path -Parent (Get-Module backdrop -ErrorAction SilentlyContinue).Path
  if ($modDir -and (Test-Path $modDir)) { Remove-Item $modDir -Recurse -Force }
  if ($Purge) {
    Remove-Item $script:ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:StateDir  -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'backdrop: uninstalled. Config and cached wallpapers removed.'
  }
  else {
    Write-Host 'backdrop: uninstalled.'
    Write-Host "Note: config and cached wallpapers were not removed. Run 'backdrop uninstall --purge' to delete them."
  }
}

function Invoke-BackdropHelp {
  Write-Host @"
backdrop v$($script:Version)

Usage: backdrop <command>

Commands:
  status                          Show the active source and last image (default command)
  update [--force]                Refresh wallpaper from the active source
  set <source...> [--force]       Switch active source(s) and refresh now; use 'all' for all sources
  set-time <HH:MM>                Set the daily run time (24-hour); updates task if active
  set-rotate-interval <minutes>   Set rotation interval in minutes; 0 to disable rotation
  random [--force]                Refresh from a randomly chosen source (does not change active source)
  enable                          Enable the scheduled task
  disable                         Disable the scheduled task
  upgrade                         Check for and install the latest version from GitHub
  uninstall [--purge]             Remove backdrop and (with --purge) delete config and cached wallpapers
  help                            Show this help

Sources:
  bing    Bing image of the day
  earth   Earth.com Image of the Day
  apod    NASA Astronomy Picture of the Day
  eo      NASA Earth Observatory Image of the Day
  iotd    NASA Image of the Day (default)
  natgeo  National Geographic Photo of the Day
  wmc     Wikimedia Commons Picture of the Day
"@
}

#endregion

#region Dispatch

function backdrop {
  <#
    .SYNOPSIS
    Set a new desktop wallpaper every day from various sources.
    .DESCRIPTION
    Downloads the image of the day from a configurable source and sets it as the desktop wallpaper.
    Run 'backdrop help' for available commands and sources.
    #>
  param(
    [Parameter(Position = 0)]
    [string]$Command = 'status',
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Rest
  )

  if ($Command -ne 'uninstall') { Import-BackdropConfig }

  $force = $Rest -contains '--force'
  $filteredArgs = @($Rest | Where-Object { $_ -ne '--force' })

  try {
    switch ($Command) {
      { $_ -in 'update', 'refresh' } { Invoke-BackdropUpdate  -Force:$force }
      { $_ -in 'set', 'use' } { Invoke-BackdropSet -Sources $filteredArgs -Force $force }
      'status' { Invoke-BackdropStatus }
      'random' { Invoke-BackdropRandom  -Force:$force }
      'enable' { Invoke-BackdropEnable }
      'disable' { Invoke-BackdropDisable }
      'set-time' { Invoke-BackdropSetTime ($filteredArgs | Select-Object -First 1) }
      'set-rotate-interval' { Invoke-BackdropSetRotateInterval ($filteredArgs | Select-Object -First 1) }
      'upgrade' { Invoke-BackdropUpgrade }
      'uninstall' { Invoke-BackdropUninstall -Purge:($Rest -contains '--purge') }
      { $_ -in '-h', '--help', 'help' } { Invoke-BackdropHelp }
      default { throw "backdrop: unknown command '$Command' (try: backdrop help)" }
    }
  }
  catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
  }
}

Export-ModuleMember -Function 'backdrop'

#endregion
