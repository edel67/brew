param([string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'PowerShell 5.1 required' }
$results = @()
$LASTEXITCODE = $null
winget.exe --version | Out-Null
$status = $LASTEXITCODE
if ($status -isnot [int] -or $status -ne 0) { throw 'Unexpected real WinGet status/type' }
$results += @{ command='winget --version'; type=$status.GetType().FullName; status=$status }
foreach ($hex in @('00000000','00000001','7FFFFFFF','80000000','8A150014','80070000','DEAD0014','FFFFFFFF')) {
  [IO.File]::WriteAllText((Join-Path $FixtureRoot 'config.txt'), "list:winget=$hex`n")
  $LASTEXITCODE = $null
  $ErrorActionPreference = 'Continue'
  & (Join-Path $FixtureRoot 'fixture.exe') list --source winget | Out-Null
  $status = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($status -isnot [int]) { throw "Unexpected native type for $hex" }
  $normalised = [long]$status -band 4294967295L
  if ($normalised -ne [Convert]::ToInt64($hex,16)) { throw "Changed native bits for $hex" }
  $results += @{ command='native fixture'; hex=$hex; type=$status.GetType().FullName; status=$status; normalised=$normalised }
}
@{ PowerShell=$PSVersionTable.PSVersion.ToString(); cases=$results } | ConvertTo-Json -Depth 5 | Set-Content evidence/native-status.json -Encoding UTF8
# Subsequent Actions steps must not inherit the final deliberate failing exit code.
exit 0
