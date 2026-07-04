@{
  ModuleVersion     = '1.6.1'
  GUID              = '3D6C8A5B-1F2E-4A0D-9B7C-E6F5D4C3B2A1'
  Author            = 'Andrew Ensley'
  Description       = 'Set a new desktop wallpaper every day from various sources (apod, bing, earth, eo, iotd, natgeo, wmc)'
  PowerShellVersion = '5.1'
  RootModule        = 'backdrop.psm1'
  FunctionsToExport = @('backdrop')
  PrivateData       = @{
    PSData = @{
      Tags       = @('wallpaper', 'desktop', 'background', 'Windows')
      ProjectUri = 'https://github.com/aensley/backdrop'
      LicenseUri = 'https://github.com/aensley/backdrop/blob/main/LICENSE'
    }
  }
}
