# Run only on a fresh GitHub-hosted Windows VM. No desktop or interactive login is required.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CandidateDirectory,
  [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,40}$')][string]$FixtureId,
  [Parameter(Mandatory)][string]$EvidenceRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Require ($env:RUNNER_OS -eq 'Windows' -and $env:PROOF_RUNNER_ENVIRONMENT -eq 'github-hosted') 'This proof requires a fresh GitHub-hosted Windows VM.'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Require ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Runner must have administrator authority.'
$uac = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA
Require ($uac -eq 0) 'Runner UAC must already be disabled; this proof does not change host policy.'
$node = (Get-Command node.exe -CommandType Application).Source
$npm = Join-Path (Split-Path $node) 'node_modules/npm/bin/npm-cli.js'
Require (Test-Path -LiteralPath $npm) 'Qualified Node installation has no npm CLI.'
$sourceCommit = '220a33b236cea0981e3d2da35a42a667f9e729b9'
$stableVersion = '2026.10.5'
$stableIntegrity = 'sha512-9rCuXMweqVKZIK3KBtGcLzesz9G6+FmQ30lvwomRhmcNWDcOtlBoqdLbPditoJMuTP55jPqXpt1AA0L8tSzFHg=='
$candidate = Get-Content -LiteralPath (Join-Path $CandidateDirectory 'candidate.json') -Raw | ConvertFrom-Json
$tarball = (Resolve-Path -LiteralPath (Join-Path $CandidateDirectory 'openclaw-176872.tgz')).Path
Require ($candidate.sourceCommit -eq $sourceCommit -and $candidate.build.commit -eq $sourceCommit) 'Candidate identity differs from the reviewed source.'
Require ((Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant() -eq $candidate.sha256) 'Candidate artifact digest differs.'
$root = Join-Path $env:RUNNER_TEMP ('openclaw-176872-upgrade-' + $FixtureId)
$accountHome = [Environment]::GetFolderPath('UserProfile')
$profile = 'proof-176872-upgrade-' + $FixtureId
$state = Join-Path $accountHome ('.openclaw-' + $profile)
$config = Join-Path $state 'openclaw.json'
$taskName = 'OpenClaw Gateway (' + $profile + ')'
$qualificationName = 'OpenClaw Proof 176872 S4U ' + $FixtureId
$token = 'synthetic-176872-upgrade-' + $FixtureId
$prefix = Join-Path $root 'install'
$cli = Join-Path $prefix 'node_modules/openclaw/openclaw.mjs'
Require (-not (Test-Path -LiteralPath $root)) 'Fixture root already exists.'
Require (-not (Test-Path -LiteralPath $state)) 'Canonical fixture profile already exists.'
Require (-not (Test-Path -LiteralPath $EvidenceRoot)) 'Evidence directory already exists.'
Require (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'Fixture Task already exists.'
Require (-not (Get-ScheduledTask -TaskName $qualificationName -ErrorAction SilentlyContinue)) 'Qualification Task already exists.'
$null = New-Item -ItemType Directory -Path $root,$state,$EvidenceRoot
foreach ($directory in @('install','temp','npm-cache','npm-config','appdata','localappdata')) { $null = New-Item -ItemType Directory -Path (Join-Path $root $directory) }
$userConfig = Join-Path $root 'npm-config/user.npmrc'
$globalConfig = Join-Path $root 'npm-config/global.npmrc'
Set-Content -LiteralPath $userConfig -Value ''
Set-Content -LiteralPath $globalConfig -Value ''
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$records = [Collections.Generic.List[object]]::new()
$summary = [ordered]@{ result='running'; sourceCommit=$sourceCommit; candidate=$candidate; stableVersion=$stableVersion; fixture=$FixtureId; port=$port; administrator=$true; uacDisabled=$true; interactive=[Environment]::UserInteractive; phases=@(); cleanup='pending' }
function Scrub([string]$Text) {
  if ($null -eq $Text) { return '' }
  return $Text.Replace($token,'<synthetic-token>').Replace($identity.Name,'<runner-account>').Replace($identity.User.Value,'<runner-sid>').Replace($accountHome,'<runner-home>')
}
function Save-Summary { $summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'summary.json') }
function Invoke-Owned([string]$Label,[string[]]$Arguments,[int]$TimeoutSeconds=180) {
  $start = [Diagnostics.ProcessStartInfo]::new($node)
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WorkingDirectory=$root
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  foreach ($key in @($start.Environment.Keys)) {
    if ($key -match '^(OPENCLAW_|CLAWDBOT_|MOLTBOT_|NPM_CONFIG_|ACTIONS_|GITHUB_)' -or $key -in @('NODE_OPTIONS','NODE_PATH','NODE_EXTRA_CA_CERTS','GH_TOKEN','NPM_TOKEN','NODE_AUTH_TOKEN','OPENAI_API_KEY','ANTHROPIC_API_KEY','GEMINI_API_KEY','GOOGLE_API_KEY','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','SSH_AUTH_SOCK')) { $null=$start.Environment.Remove($key) }
  }
  $overrides = @{
    HOME=$accountHome; USERPROFILE=$accountHome; OPENCLAW_HOME=$accountHome; OPENCLAW_PROFILE=$profile
    OPENCLAW_STATE_DIR=$state; OPENCLAW_CONFIG_PATH=$config
    APPDATA=(Join-Path $root 'appdata'); LOCALAPPDATA=(Join-Path $root 'localappdata')
    TEMP=(Join-Path $root 'temp'); TMP=(Join-Path $root 'temp'); TMPDIR=(Join-Path $root 'temp')
    NPM_CONFIG_CACHE=(Join-Path $root 'npm-cache'); NPM_CONFIG_USERCONFIG=$userConfig
    NPM_CONFIG_GLOBALCONFIG=$globalConfig; NPM_CONFIG_PREFIX=$prefix; NPM_CONFIG_REGISTRY='https://registry.npmjs.org/'
    OPENCLAW_NO_PROMPT='1'; OPENCLAW_NO_ONBOARD='1'; NO_COLOR='1'; FORCE_COLOR='0'
  }
  foreach ($key in $overrides.Keys) { $start.Environment[$key]=[string]$overrides[$key] }
  $start.Environment['PATH']=(Split-Path $node)+';'+$prefix+';'+$start.Environment['PATH']
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new(); $process.StartInfo=$start
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $null=$process.Start()
  $stdoutTask=$process.StandardOutput.ReadToEndAsync(); $stderrTask=$process.StandardError.ReadToEndAsync()
  $timedOut=-not $process.WaitForExit($TimeoutSeconds*1000)
  if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
  $stdout=$stdoutTask.GetAwaiter().GetResult(); $stderr=$stderrTask.GetAwaiter().GetResult()
  $exitCode=$process.ExitCode; $process.Dispose(); $clock.Stop()
  Scrub $stdout | Set-Content -LiteralPath (Join-Path $EvidenceRoot ($Label+'.stdout.log'))
  Scrub $stderr | Set-Content -LiteralPath (Join-Path $EvidenceRoot ($Label+'.stderr.log'))
  $records.Add([ordered]@{label=$Label;exitCode=$exitCode;timedOut=$timedOut;seconds=[Math]::Round($clock.Elapsed.TotalSeconds,1)})
  $records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'commands.json')
  Require (-not $timedOut) "$Label exceeded its $TimeoutSeconds second command budget."
  Require ($exitCode -eq 0) "$Label exited $exitCode; inspect its sanitized command logs."
  return $stdout
}
function Parse-CliJson([string]$Output) {
  $lines=$Output -split '\r?\n'
  for ($i=0;$i -lt $lines.Length;$i++) {
    if ($lines[$i] -match '^\s*[\{\[]') {
      try { return (($lines[$i..($lines.Length-1)] -join "`n") | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
  }
  throw 'CLI did not return parseable JSON.'
}
function Read-Build { return (Get-Content -LiteralPath (Join-Path $prefix 'node_modules/openclaw/dist/build-info.json') -Raw | ConvertFrom-Json) }
function Assert-Ready([string]$Label,[object]$Build) {
  $deadline=[DateTime]::UtcNow.AddSeconds(180)
  $ready=$false
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $health=Invoke-WebRequest -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 5
      $readiness=Invoke-WebRequest -Uri "http://127.0.0.1:$port/readyz" -TimeoutSec 5
      if ($health.StatusCode -eq 200 -and $readiness.StatusCode -eq 200) { $ready=$true;break }
    } catch {}
    Start-Sleep -Milliseconds 500
  }
  Require $ready "$Label never became HTTP ready."
  $status=Parse-CliJson (Invoke-Owned ($Label+'-status') @($cli,'--profile',$profile,'gateway','status','--deep','--json') 120)
  Require ($status.service.loaded -eq $true -and $status.service.runtime.status -eq 'running') "$Label native service is not running."
  Require ($status.rpc.ok -eq $true -and $status.rpc.server.buildId -eq $Build.buildId) "$Label RPC did not attest the expected build."
  Require ($status.gateway.port -eq $port) "$Label status selected another port."
  Require ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') "$Label native Task Scheduler state is not Running."
  [xml]$xml=Export-ScheduledTask -TaskName $taskName
  Require ([string]$xml.Task.Principals.Principal.LogonType -eq 'S4U') "$Label did not retain the native S4U policy."
  Require ($xml.OuterXml.Contains($state)) "$Label Task action does not reference the fixture profile."
  $summary.phases += [ordered]@{name=$Label;build=$Build;healthz=200;readyz=200;rpc=$true;nativeRuntime='running';logonType='S4U'}
  Save-Summary
}
function Cleanup-Owned {
  $qualification=Get-ScheduledTask -TaskName $qualificationName -ErrorAction SilentlyContinue
  if ($qualification) { Stop-ScheduledTask -TaskName $qualificationName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $qualificationName -Confirm:$false }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    $xml=Export-ScheduledTask -TaskName $taskName
    Require ($xml.Contains($state)) 'Cleanup refused a Task outside the fixture profile.'
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  foreach ($owned in @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine.Contains($root) -or $_.CommandLine.Contains($state)) })) { Stop-Process -Id $owned.ProcessId -Force -ErrorAction SilentlyContinue }
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  do {
    $remaining=@(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine.Contains($root) -or $_.CommandLine.Contains($state)) })
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
  Require ($remaining.Count -eq 0) 'Fixture process cleanup did not complete.'
  Require (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'Fixture Task remains after cleanup.'
  $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
  try { $probe.Start() } finally { $probe.Stop() }
  if (Test-Path -LiteralPath $state) {
    $resolved=(Resolve-Path -LiteralPath $state).Path
    Require ($resolved -eq [IO.Path]::GetFullPath((Join-Path $accountHome ('.openclaw-'+$profile)))) 'Canonical profile cleanup path differs.'
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
try {
  Save-Summary
  # Real S4U launch proves the batch-logon prerequisite without requiring a desktop session.
  $marker=Join-Path $root 's4u-qualified.txt'
  $scheduler=New-Object -ComObject Schedule.Service; $scheduler.Connect()
  $definition=$scheduler.NewTask(0)
  $definition.Principal.UserId=$identity.Name; $definition.Principal.LogonType=2; $definition.Principal.RunLevel=0
  $definition.Settings.Enabled=$true; $definition.Settings.AllowDemandStart=$true
  $definition.Settings.DisallowStartIfOnBatteries=$false; $definition.Settings.StopIfGoingOnBatteries=$false
  $definition.Settings.ExecutionTimeLimit='PT1M'; $null=$definition.Triggers.Create(8)
  $action=$definition.Actions.Create(0); $action.Path=$node
  $action.Arguments='-e "require(''node:fs'').writeFileSync(process.argv[1],''qualified'')" "'+$marker+'"'
  $folder=$scheduler.GetFolder('\'); $registered=$folder.RegisterTaskDefinition($qualificationName,$definition,6,$identity.Name,$null,2,$null)
  $null=$registered.Run($null)
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
  Require ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw) -eq 'qualified') 'Native S4U task did not execute; runner is unqualified.'
  $folder.DeleteTask($qualificationName,0); $summary.s4uPrerequisite='passed'; Save-Summary
  $metadata=Invoke-RestMethod -Uri 'https://registry.npmjs.org/openclaw/latest'
  Require ($metadata.version -eq $stableVersion -and $metadata.dist.integrity -eq $stableIntegrity) 'Latest stable changed; this pinned proof must be reviewed before execution.'
  $summary.stableArtifact=[ordered]@{version=$metadata.version;tarball=$metadata.dist.tarball;integrity=$metadata.dist.integrity}; Save-Summary
  $null=Invoke-Owned 'node-version' @('--version')
  $null=Invoke-Owned 'npm-version' @($npm,'--version')
  $null=Invoke-Owned 'install-published-package' @($npm,'install','--global','--prefix',$prefix,('openclaw@'+$stableVersion),'--no-audit','--no-fund') 900
  $stableBuild=Read-Build
  Require ($stableBuild.version -eq $stableVersion -and $stableBuild.commit -ne $sourceCommit) 'Baseline is not the published runtime.'
  $fixtureConfig=@{gateway=@{mode='local';bind='loopback';port=$port;auth=@{mode='token';token=$token};controlUi=@{enabled=$false}};plugins=@{enabled=$false};agents=@{defaults=@{heartbeat=@{every='0m'}}}}
  $fixtureConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config
  $installed=Parse-CliJson (Invoke-Owned 'published-service-install' @($cli,'--profile',$profile,'gateway','install','--force','--runtime','node','--port',[string]$port,'--json') 300)
  Require ($installed.ok -eq $true) 'Published service install did not report success.'
  Assert-Ready 'published' $stableBuild
  # This call begins in the published package. It stages and activates the candidate itself.
  $updated=Parse-CliJson (Invoke-Owned 'published-driver-update' @($cli,'--profile',$profile,'update','--tag',('file:'+$tarball.Replace('\','/')),'--yes','--json') 2100)
  Require ($updated.status -eq 'ok') 'Published updater did not finish successfully.'
  $afterBuild=Read-Build
  Require ($afterBuild.commit -eq $sourceCommit -and $afterBuild.buildId -eq $candidate.build.buildId) 'Installed build differs from the verified candidate artifact.'
  Assert-Ready 'candidate' $afterBuild
  $afterConfig=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
  Require ($afterConfig.gateway.port -eq $port -and $afterConfig.gateway.auth.token -eq $token -and $afterConfig.plugins.enabled -eq $false) 'Upgrade changed fixture gateway settings.'
  $summary.result='passed'
} catch {
  $summary.result='failed'; $summary.failure=Scrub $_.Exception.Message
} finally {
  try { Cleanup-Owned; $summary.cleanup='passed' } catch { $summary.result='failed'; $summary.cleanup='failed'; $summary.cleanupFailure=Scrub $_.Exception.Message }
  Save-Summary
}
if ($summary.result -ne 'passed') { throw ('Native upgrade proof failed; inspect summary.json and sanitized logs in '+$EvidenceRoot) }
Write-Output 'Published-driver upgrade, candidate native S4U service readiness, RPC identity, and cleanup passed.'
