BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not ('AiCliRuntime.CodexProcessJob' -as [type])) {
        Add-Type -Path (Join-Path $root 'src/AiCliProfileManager/Support/CodexProcessJob.cs')
    }
}

Describe 'Native Codex process job ownership' {
    It 'cleans its real descendant when root exit=<ExitRoot>, close-only=<CloseOnly>' -ForEach @(
        @{ ExitRoot = $false; CloseOnly = $false },
        @{ ExitRoot = $true; CloseOnly = $false },
        @{ ExitRoot = $false; CloseOnly = $true }
    ) {
        $server = $null
        $child = $null
        $job = [AiCliRuntime.CodexProcessJob]::new()
        try {
            $childProgram = '[void][Console]::ReadLine(); $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=(Get-Command pwsh.exe).Source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true; foreach($arg in @("-NoLogo","-NoProfile","-Command","Start-Sleep -Seconds 60")){[void]$info.ArgumentList.Add($arg)}; $child=[Diagnostics.Process]::Start($info); [Console]::Out.WriteLine($child.Id); [Console]::Out.Flush(); __WAIT__'
            $childProgram = $childProgram.Replace('__WAIT__', $(if ($ExitRoot) { '' } else { '[void][Console]::ReadLine()' }))
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = (Get-Command pwsh.exe).Source
            $info.WorkingDirectory = $TestDrive
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command',$childProgram)) { [void]$info.ArgumentList.Add($arg) }
            $server = [Diagnostics.Process]::Start($info)
            $job.Attach($server)
            $server.StandardInput.WriteLine('START')
            $server.StandardInput.Flush()
            $line = $server.StandardOutput.ReadLineAsync()
            $line.Wait(10000) | Should -BeTrue
            $childId = [int]$line.GetAwaiter().GetResult()
            $child = [Diagnostics.Process]::GetProcessById($childId)
            if ($ExitRoot) { $server.WaitForExit(5000) | Should -BeTrue }
            $job.ActiveProcesses | Should -BeGreaterThan 0
            if ($CloseOnly) { $job.Dispose() }
            else {
                $job.StopAndWait(5000) | Should -BeTrue
                $job.ActiveProcesses | Should -Be 0
            }
            $server.WaitForExit(5000) | Should -BeTrue
            $child.WaitForExit(5000) | Should -BeTrue
        } finally {
            $job.Dispose()
            if ($server) { $server.Dispose() }
            if ($child) { $child.Dispose() }
        }
    }
}