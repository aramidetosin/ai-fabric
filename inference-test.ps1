# inference-test.ps1: call every model on the ai-fabric inference gateway once and report what came back (Windows).
#   .\inference-test.ps1              test every model
#   .\inference-test.ps1 -SaveKey     store the bearer key locally (prompts, never echoes)
#   .\inference-test.ps1 -Match gpt   test only the models whose name matches "gpt"
#
# The bearer key is NEVER stored in this file. It is read from $env:LITELLM_KEY, or from %USERPROFILE%\.ai-fabric\inference-key.
# Get it with:  ssh -t site-a /root/ai-fabric/show-creds.sh    then run  .\inference-test.ps1 -SaveKey
#
# The model UUIDs are the gateway's route ids, from `gen-inference.py ai-fabric map` on the lab host. Not secret.
# Refresh after a redeploy with:  ssh site-a python3 /root/ai-fabric/scripts/gen-inference.py ai-fabric map
param([switch]$SaveKey, [string]$Match = "", [string]$ApiHost = "inference.platform.lab.ai",
      [string]$Prompt = "Reply with exactly: OK")

$KeyFile = Join-Path $env:USERPROFILE ".ai-fabric\inference-key"
$Models = [ordered]@{
  "deepseek-ai/DeepSeek-V4-Pro-0813" = "565df347-26cb-598a-b838-b7e9531f00fa"
  "qwen/qwen-2.5-72b-instruct"       = "5bfb8175-7fd3-54d7-b4a3-128daf1b7479"
  "openai/gpt-4o-mini"               = "3fda6363-9031-5ce4-919c-232ebeede362"
  "Qwen/Qwen2.5-0.5B-Instruct"       = "1f6e4487-6ee5-56a7-bf59-bcc2d839c8f3"
}

if ($SaveKey) {
  New-Item -ItemType Directory -Force -Path (Split-Path $KeyFile) | Out-Null
  $sec = Read-Host -AsSecureString "inference bearer key (sk-aif-...)"
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if (-not $plain) { Write-Error "nothing entered, key file unchanged"; exit 1 }
  [System.IO.File]::WriteAllText($KeyFile, $plain)
  # Readable only by this account. Use the real current identity: over SSH $env:USERDOMAIN is often empty, so
  # "$env:USERDOMAIN\$env:USERNAME" fails to translate and the file would silently keep its inherited permissions.
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $acl = Get-Acl $KeyFile; $acl.SetAccessRuleProtection($true, $false); $acl.SetOwner((New-Object System.Security.Principal.NTAccount($me)))
  $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
  Set-Acl $KeyFile $acl
  "saved to $KeyFile (this account only)"; exit 0
}

$Key = $env:LITELLM_KEY
if (-not $Key -and (Test-Path $KeyFile)) { $Key = (Get-Content $KeyFile -Raw).Trim() }
if (-not $Key) { Write-Error "no bearer key: set `$env:LITELLM_KEY or run  .\inference-test.ps1 -SaveKey   (get it from: ssh -t site-a /root/ai-fabric/show-creds.sh)"; exit 1 }

# GetHostAddresses honours the hosts file; Resolve-DnsName queries DNS only and comes back empty for a hosts entry
$addr = try { ([System.Net.Dns]::GetHostAddresses($ApiHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString } catch { "UNRESOLVED" }
"{0} -> {1}   (host {2})`n" -f $ApiHost, $addr, $env:COMPUTERNAME
"{0,-34} {1,-8} {2,-8} {3}" -f "MODEL", "HTTP", "TIME", "REPLY"

$rc = 0
foreach ($m in $Models.Keys) {
  if ($Match -and $m -notlike "*$Match*") { continue }
  $url = "https://$ApiHost/models/$($Models[$m])/proxy/v1/chat/completions"
  $body = @{ model = $m; messages = @(@{ role = "user"; content = $Prompt }); max_tokens = 24 } | ConvertTo-Json -Depth 5 -Compress
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 90 -ContentType "application/json" `
           -Headers @{ Authorization = "Bearer $Key" } -Body $body -ErrorAction Stop
    $sw.Stop(); $reply = $r.choices[0].message.content
    "{0,-34} {1,-8} {2,-8} {3}" -f $m, 200, ("{0:N1}s" -f $sw.Elapsed.TotalSeconds), $reply
  } catch {
    $sw.Stop(); $rc = 1
    $code = try { [int]$_.Exception.Response.StatusCode } catch { "ERR" }
    "{0,-34} {1,-8} {2,-8} {3}" -f $m, $code, ("{0:N1}s" -f $sw.Elapsed.TotalSeconds), ($_.Exception.Message -replace "`r?`n", " ").Substring(0, [Math]::Min(70, $_.Exception.Message.Length))
  }
}
exit $rc
