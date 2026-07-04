#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Script-scope import: runs during Pester discovery so InModuleScope can find the module.
# APPDATA/LOCALAPPDATA don't exist on Linux but the module reads them at load time.
if (-not $env:APPDATA) { $env:APPDATA = [System.IO.Path]::GetTempPath() }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [System.IO.Path]::GetTempPath() }
Import-Module "$PSScriptRoot/../src/backdrop.psm1" -Force

BeforeAll {
  # Pester does not re-execute the script body during the run phase, so we must re-import here to
  # ensure the module is present when InModuleScope enters it for test execution.
  if (-not $env:APPDATA) { $env:APPDATA = [System.IO.Path]::GetTempPath() }
  if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [System.IO.Path]::GetTempPath() }
  Import-Module "$PSScriptRoot/../src/backdrop.psm1" -Force
}

# All tests run inside the module scope so private functions are directly callable.
InModuleScope backdrop {

  # Pester v5 does not allow BeforeEach directly at the InModuleScope root level; wrap in Describe.
  Describe 'backdrop' {

    BeforeEach {
      # $TestDrive is shared across all tests in a file, so use a unique subdirectory per test.
      $testId = [System.Guid]::NewGuid().ToString('N')
      $script:ConfigDir = Join-Path $TestDrive "config-$testId"
      $script:ConfigFile = Join-Path $script:ConfigDir 'config'
      $script:StateDir = Join-Path $TestDrive "state-$testId"
      $script:Source = 'iotd'
      $script:RotateInterval = 0
      $script:ScreenAspectRatio = 1.7778
      $script:ZoomMinCoverage = 0.55
      $script:TimerTime = '08:00'
      $script:UserAgent = "backdrop/$(($script:Version -split '\.')[0..1] -join '.') (personal daily wallpaper script)"
      New-Item -ItemType Directory -Force -Path $script:ConfigDir, $script:StateDir | Out-Null
    }

    # -------------------------------------------------------------------------
    # Test-ValidSource
    # -------------------------------------------------------------------------

    Describe 'Test-ValidSource' {
      It 'accepts built-in source: <_>' -ForEach @('iotd', 'apod', 'bing', 'wmc', 'eo', 'earth', 'natgeo') {
        Test-ValidSource $_ | Should -BeTrue
      }
      It 'rejects an unknown source' {
        Test-ValidSource 'unknown' | Should -BeFalse
      }
      It 'rejects an empty string' {
        Test-ValidSource '' | Should -BeFalse
      }
    }

    # -------------------------------------------------------------------------
    # Get-BackdropConfigValue
    # -------------------------------------------------------------------------

    Describe 'Get-BackdropConfigValue' {
      It 'returns null when config does not exist' {
        Get-BackdropConfigValue 'source' | Should -BeNullOrEmpty
      }
      It 'reads a simple key = value' {
        Set-Content $script:ConfigFile 'source = bing'
        Get-BackdropConfigValue 'source' | Should -Be 'bing'
      }
      It 'strips surrounding double quotes' {
        Set-Content $script:ConfigFile 'user_agent = "my agent"'
        Get-BackdropConfigValue 'user_agent' | Should -Be 'my agent'
      }
      It 'strips surrounding single quotes' {
        Set-Content $script:ConfigFile "user_agent = 'my agent'"
        Get-BackdropConfigValue 'user_agent' | Should -Be 'my agent'
      }
      It 'ignores comment lines' {
        Set-Content $script:ConfigFile "# source = apod`nsource = wmc"
        Get-BackdropConfigValue 'source' | Should -Be 'wmc'
      }
    }

    # -------------------------------------------------------------------------
    # Initialize-BackdropConfig / Set-BackdropConfigValue
    # -------------------------------------------------------------------------

    Describe 'Initialize-BackdropConfig / Set-BackdropConfigValue' {
      It 'creates the config file with built-in defaults' {
        Initialize-BackdropConfig
        $script:ConfigFile | Should -Exist
        Get-BackdropConfigValue 'source'              | Should -Be 'iotd'
        Get-BackdropConfigValue 'screen_aspect_ratio' | Should -Be '1.7778'
      }
      It 'writes a new key' {
        Initialize-BackdropConfig
        Set-BackdropConfigValue 'source' 'apod'
        Get-BackdropConfigValue 'source' | Should -Be 'apod'
      }
      It 'overwrites an existing key' {
        Initialize-BackdropConfig
        Set-BackdropConfigValue 'source' 'bing'
        Set-BackdropConfigValue 'source' 'wmc'
        Get-BackdropConfigValue 'source' | Should -Be 'wmc'
      }
      It 'preserves other keys when updating one' {
        Initialize-BackdropConfig
        Set-BackdropConfigValue 'source' 'eo'
        Get-BackdropConfigValue 'screen_aspect_ratio' | Should -Be '1.7778'
      }
    }

    # -------------------------------------------------------------------------
    # Import-BackdropConfig
    # -------------------------------------------------------------------------

    Describe 'Import-BackdropConfig' {
      It 'reads config values into module globals' {
        Set-Content $script:ConfigFile @"
screen_aspect_ratio = 2.3333
zoom_min_coverage = 0.75
timer_time = 10:30
rotate_interval = 15
user_agent = test-agent/1.0
"@
        Import-BackdropConfig
        $script:ScreenAspectRatio | Should -Be 2.3333
        $script:ZoomMinCoverage   | Should -Be 0.75
        $script:TimerTime         | Should -Be '10:30'
        $script:RotateInterval    | Should -Be 15
        $script:UserAgent         | Should -Be 'test-agent/1.0'
      }
      It 'leaves globals at defaults when config is missing' {
        Import-BackdropConfig
        $script:ScreenAspectRatio | Should -Be 1.7778
        $script:ZoomMinCoverage   | Should -Be 0.55
        $script:TimerTime         | Should -Be '08:00'
        $script:RotateInterval    | Should -Be 0
      }
    }

    # -------------------------------------------------------------------------
    # Get-ScreenAspectRatio
    # -------------------------------------------------------------------------

    Describe 'Get-ScreenAspectRatio' {
      It 'returns a positive numeric aspect ratio' {
        $ar = Get-ScreenAspectRatio
        $ar | Should -BeOfType [double]
        $ar | Should -BeGreaterThan 0
      }
    }

    # -------------------------------------------------------------------------
    # Get-PictureOption
    # -------------------------------------------------------------------------

    Describe 'Get-PictureOption' {
      It 'returns zoom for a wide image on a 16:9 screen' {
        Mock Get-ImageDimension { @{ Width = 1920; Height = 1080 } }
        Mock Get-ScreenAspectRatio { 1.7778 }
        Get-PictureOption 'dummy.jpg' | Should -Be 'zoom'
      }
      It 'returns scaled for a tall image on a 16:9 screen' {
        Mock Get-ImageDimension { @{ Width = 1080; Height = 1920 } }
        Mock Get-ScreenAspectRatio { 1.7778 }
        Get-PictureOption 'dummy.jpg' | Should -Be 'scaled'
      }
      It 'returns zoom for a square image (coverage 0.5625 >= threshold 0.55)' {
        Mock Get-ImageDimension { @{ Width = 1000; Height = 1000 } }
        Mock Get-ScreenAspectRatio { 1.7778 }
        $script:ZoomMinCoverage = 0.55
        Get-PictureOption 'dummy.jpg' | Should -Be 'zoom'
      }
      It 'returns zoom when image dimensions cannot be read' {
        Mock Get-ImageDimension { $null }
        Get-PictureOption 'dummy.jpg' | Should -Be 'zoom'
      }
    }

    # -------------------------------------------------------------------------
    # Remove-HtmlMarkup
    # -------------------------------------------------------------------------

    Describe 'Remove-HtmlMarkup' {
      It 'removes HTML tags' {
        Remove-HtmlMarkup '<b>Hello</b> <i>World</i>' | Should -Be 'Hello World'
      }
      It 'decodes common HTML entities' {
        Remove-HtmlMarkup '&amp; &lt; &gt; &quot; &#39;' | Should -Be '& < > " '''
      }
      It 'decodes numeric entities with leading zeros' {
        Remove-HtmlMarkup "San Francisco&#039;s Streets" | Should -Be "San Francisco's Streets"
      }
      It 'collapses whitespace' {
        Remove-HtmlMarkup '  foo   bar  ' | Should -Be 'foo bar'
      }
    }

    # -------------------------------------------------------------------------
    # Write-MetaFile / Get-MetaValue
    # -------------------------------------------------------------------------

    Describe 'Write-MetaFile / Get-MetaValue' {
      It 'reads a key from a meta file' {
        $f = Join-Path $script:StateDir 'test.meta'
        Set-Content $f "title = My Image`ndesc = Some desc`nurl = https://example.com/"
        Get-MetaValue $f 'title' | Should -Be 'My Image'
      }
      It 'returns null for a missing file' {
        Get-MetaValue (Join-Path $script:StateDir 'nonexistent.meta') 'title' | Should -BeNullOrEmpty
      }
      It 'returns null for a missing key' {
        $f = Join-Path $script:StateDir 'test.meta'
        Set-Content $f 'url = https://example.com/'
        Get-MetaValue $f 'title' | Should -BeNullOrEmpty
      }
      It 'writes non-empty fields to a .meta file' {
        $dest = Join-Path $script:StateDir 'src-2025-01-01.jpg'
        $null = New-Item $dest -ItemType File -Force
        Write-MetaFile $dest @{ Title = 'Test Image'; Desc = 'A test description'; Url = 'https://example.com/' }
        $meta = [System.IO.Path]::ChangeExtension($dest, 'meta')
        Get-MetaValue $meta 'title' | Should -Be 'Test Image'
        Get-MetaValue $meta 'desc'  | Should -Be 'A test description'
        Get-MetaValue $meta 'url'   | Should -Be 'https://example.com/'
      }
      It 'omits empty fields from the .meta file' {
        $dest = Join-Path $script:StateDir 'src-2025-01-01.jpg'
        $null = New-Item $dest -ItemType File -Force
        Write-MetaFile $dest @{ Title = ''; Desc = ''; Url = 'https://example.com/' }
        $meta = [System.IO.Path]::ChangeExtension($dest, 'meta')
        Get-MetaValue $meta 'title' | Should -BeNullOrEmpty
        Get-MetaValue $meta 'url'   | Should -Be 'https://example.com/'
      }
    }

    # -------------------------------------------------------------------------
    # Get-BackdropSource
    # -------------------------------------------------------------------------

    Describe 'Get-BackdropSource' {
      It 'returns default source when config does not exist' {
        Get-BackdropSource | Should -Be @('iotd')
      }
      It 'returns a single configured source' {
        Set-Content $script:ConfigFile 'source = bing'
        Get-BackdropSource | Should -Be @('bing')
      }
      It 'returns a list for multiple configured sources' {
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        Get-BackdropSource | Should -Be @('iotd', 'apod', 'bing')
      }
      It "expands 'all' to every valid source" {
        Set-Content $script:ConfigFile 'source = all'
        Get-BackdropSource | Should -Be $script:ValidSources
      }
    }

    # -------------------------------------------------------------------------
    # Get-ActiveSource
    # -------------------------------------------------------------------------

    Describe 'Get-ActiveSource' {
      It 'returns the single configured source' {
        Set-Content $script:ConfigFile 'source = apod'
        $script:RotateInterval = 0
        Get-ActiveSource | Should -Be 'apod'
      }
      It 'returns the first source when rotation is disabled' {
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        $script:RotateInterval = 0
        Get-ActiveSource | Should -Be 'iotd'
      }
      It 'returns index 0 at epoch (timestamp=0)' {
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        $script:RotateInterval = 60
        Mock Get-UnixTimestamp { 0 }
        Get-ActiveSource | Should -Be 'iotd'
      }
      It 'advances to the next source after one full interval' {
        # 60 minutes elapsed, interval=60min, 3 sources -> slot 1 -> apod
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        $script:RotateInterval = 60
        Mock Get-UnixTimestamp { 3600 }
        Get-ActiveSource | Should -Be 'apod'
      }
      It 'wraps around after all sources are used' {
        # 180 minutes elapsed, interval=60min, 3 sources -> slot 3 % 3 = 0 -> iotd
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        $script:RotateInterval = 60
        Mock Get-UnixTimestamp { 10800 }
        Get-ActiveSource | Should -Be 'iotd'
      }
      It 'floors partial intervals' {
        # 90 minutes elapsed -> floor(90/60)=1 -> apod
        Set-Content $script:ConfigFile 'source = iotd apod bing'
        $script:RotateInterval = 60
        Mock Get-UnixTimestamp { 5400 }
        Get-ActiveSource | Should -Be 'apod'
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Iotd
    # -------------------------------------------------------------------------

    Describe 'Resolve-Iotd' {
      It 'returns image URL and metadata from RSS feed' {
        Mock Invoke-BackdropRequest {
          @'
<rss><channel><item>
  <title><![CDATA[Test IOTD Image]]></title>
  <description>A test NASA image.</description>
  <link>https://www.nasa.gov/image-of-the-day/test/</link>
  <enclosure url="https://www.nasa.gov/wp-content/uploads/2025/01/test.jpg" type="image/jpeg"/>
</item></channel></rss>
'@
        }
        $r = Resolve-Iotd
        $r.ImageUrls | Should -Be @('https://www.nasa.gov/wp-content/uploads/2025/01/test.jpg')
        $r.Title     | Should -Be 'Test IOTD Image'
        $r.Url       | Should -Be 'https://www.nasa.gov/image-of-the-day/test/'
      }
      It 'returns null when no enclosure URL is present' {
        Mock Invoke-BackdropRequest {
          '<rss><channel><item><title><![CDATA[No Image Today]]></title></item></channel></rss>'
        }
        Resolve-Iotd | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Iotd } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Apod
    # -------------------------------------------------------------------------

    Describe 'Resolve-Apod' {
      It 'returns image URL and metadata from HTML page' {
        Mock Invoke-BackdropRequest {
          @'
<html><body>
<center><b>Starry Night</b><br</center>
<a href="image/2025/starry_night.jpg">image</a>
<b>Explanation:</b> A wonderful view of stars.
</body></html>
'@
        }
        $r = Resolve-Apod
        $r.ImageUrls | Should -Be @('https://apod.nasa.gov/apod/image/2025/starry_night.jpg')
        $r.Title     | Should -Be 'Starry Night'
      }
      It 'returns null when no image link is found' {
        Mock Invoke-BackdropRequest { '<html>No image today.</html>' }
        Resolve-Apod | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Apod } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Bing
    # -------------------------------------------------------------------------

    Describe 'Resolve-Bing' {
      It 'returns 4K and fallback URLs with metadata' {
        Mock Invoke-BackdropRequest {
          '{"images":[{"urlbase":"/th/id/OHR.TestImage","url":"/th/id/OHR.TestImage_1920x1080.jpg","title":"Test Bing Image","copyright":"Test copyright 2025"}]}'
        }
        $r = Resolve-Bing
        $r.ImageUrls[0] | Should -Be 'https://www.bing.com/th/id/OHR.TestImage_UHD.jpg'
        $r.ImageUrls[1] | Should -Be 'https://www.bing.com/th/id/OHR.TestImage_1920x1080.jpg'
        $r.Title        | Should -Be 'Test Bing Image'
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Bing } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Eo
    # -------------------------------------------------------------------------

    Describe 'Resolve-Eo' {
      It 'returns 4K and base URLs with metadata from RSS feed' {
        Mock Invoke-BackdropRequest {
          @'
<rss><channel><item>
  <title><![CDATA[Earth at Night]]></title>
  <link>https://earthobservatory.nasa.gov/images/12345/earth-at-night</link>
  <p>https://assets.science.nasa.gov/dynamicimage/eo/2025/01/photo.jpg</p>
</item></channel></rss>
'@
        }
        $r = Resolve-Eo
        $r.ImageUrls[0] | Should -Be 'https://assets.science.nasa.gov/dynamicimage/eo/2025/01/photo.jpg?w=3840'
        $r.ImageUrls[1] | Should -Be 'https://assets.science.nasa.gov/dynamicimage/eo/2025/01/photo.jpg'
        $r.Title        | Should -Be 'Earth at Night'
      }
      It 'returns null when no asset URL found' {
        Mock Invoke-BackdropRequest {
          '<rss><channel><item><title><![CDATA[No Image]]></title></item></channel></rss>'
        }
        Resolve-Eo | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Eo } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Natgeo
    # -------------------------------------------------------------------------

    Describe 'Resolve-Natgeo' {
      It 'returns high-res and base URLs from og:image' {
        Mock Invoke-BackdropRequest {
          '<meta property="og:image" content="https://i.natgeofe.com/n/abc123/photo.jpg"/>'
        }
        $r = Resolve-Natgeo
        $r.ImageUrls[0] | Should -Be 'https://i.natgeofe.com/n/abc123/photo.jpg?w=5120'
        $r.ImageUrls[1] | Should -Be 'https://i.natgeofe.com/n/abc123/photo.jpg'
      }
      It 'strips the site suffix from og:title' {
        Mock Invoke-BackdropRequest {
          @'
<meta property="og:image" content="https://i.natgeofe.com/n/abc123/photo.jpg"/>
<meta property="og:title" content="Forever in Motion | National Geographic"/>
'@
        }
        (Resolve-Natgeo).Title | Should -Be 'Forever in Motion'
      }
      It 'returns null when no natgeofe og:image is found' {
        Mock Invoke-BackdropRequest {
          '<meta property="og:image" content="https://www.nationalgeographic.com/logo.jpg"/>'
        }
        Resolve-Natgeo | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Natgeo } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Earth
    # -------------------------------------------------------------------------

    Describe 'Resolve-Earth' {
      It 'returns URL and metadata from the article page' {
        Mock Invoke-BackdropRequest {
          param($Uri)
          if ($Uri -match 'gallery') {
            return '<a href="https://www.earth.com/image/test-image/"></a>'
          }
          @'
<meta property="og:title" content="Test Title"/>
<meta property="og:description" content="Test description."/>
<meta property="og:url" content="https://www.earth.com/image/test-image/"/>
"https://cff2.earth.com/uploads/2025/10/01/photo.jpg"
'@
        }
        $r = Resolve-Earth
        $r.ImageUrls | Should -Be @('https://cff2.earth.com/uploads/2025/10/01/photo.jpg')
        $r.Title     | Should -Be 'Test Title'
      }
      It 'returns null when no article link is found' {
        Mock Invoke-BackdropRequest { '<html>no image here</html>' }
        Resolve-Earth | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Earth } | Should -Throw
      }
    }

    # -------------------------------------------------------------------------
    # Resolve-Wmc
    # -------------------------------------------------------------------------

    Describe 'Resolve-Wmc' {
      It 'returns thumbnail and base URLs with metadata' {
        Mock Invoke-BackdropRequest {
          param($Uri)
          if ($Uri -match 'imageinfo') {
            return '{"query":{"pages":{"-1":{"imageinfo":[{"thumburl":"https://upload.wikimedia.org/thumb/photo.jpg","url":"https://upload.wikimedia.org/photo.jpg"}]}}}}'
          }
          if ($Uri -match '\(en\)') {
            return '{"expandtemplates":{"wikitext":"A beautiful photograph of the day."}}'
          }
          return '{"expandtemplates":{"wikitext":"File:Test Photo.jpg"}}'
        }
        $r = Resolve-Wmc
        $r.ImageUrls[0] | Should -Be 'https://upload.wikimedia.org/thumb/photo.jpg'
        $r.ImageUrls[1] | Should -Be 'https://upload.wikimedia.org/photo.jpg'
        $r.Title        | Should -Be 'Test Photo'
      }
      It 'returns null when no file is found' {
        Mock Invoke-BackdropRequest { '{"expandtemplates":{"wikitext":""}}' }
        Resolve-Wmc | Should -BeNull
      }
      It 'throws on network failure' {
        Mock Invoke-BackdropRequest { throw 'network error' }
        { Resolve-Wmc } | Should -Throw
      }
    }

  } # Describe 'backdrop'

} # InModuleScope backdrop
