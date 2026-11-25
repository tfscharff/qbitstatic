#Requires -Version 5.1
#Requires -Modules Pester

Describe "Config Module" {
    BeforeAll {
        $ModulePath = Join-Path $PSScriptRoot "..\modules\Config.psm1"
        Import-Module $ModulePath -Force
    }

    Context "Get-QbitstaticConfig" {
        It "Loads configuration from default path" {
            $configPath = Join-Path $PSScriptRoot "..\config.json"
            $config = Get-QbitstaticConfig -Path $configPath -Force

            $config | Should -Not -BeNullOrEmpty
            $config.QbtWebUrl | Should -Not -BeNullOrEmpty
            $config.PollInterval | Should -BeGreaterThan 0
        }

        It "Expands environment variables in paths" {
            $configPath = Join-Path $PSScriptRoot "..\config.json"
            $config = Get-QbitstaticConfig -Path $configPath -Force

            $config.LogDir | Should -Not -Match "%"
            $config.VpnLogPath | Should -Not -Match "%"
        }

        It "Throws when config file not found" {
            { Get-QbitstaticConfig -Path "C:\nonexistent\config.json" -Force } | Should -Throw
        }

        It "Caches config on subsequent calls" {
            $configPath = Join-Path $PSScriptRoot "..\config.json"
            $config1 = Get-QbitstaticConfig -Path $configPath -Force
            $config2 = Get-QbitstaticConfig

            $config1.QbtWebUrl | Should -Be $config2.QbtWebUrl
        }
    }

    Context "Custom and malformed config files" {
        BeforeAll {
            $script:CfgDir = Join-Path $env:TEMP "qbitstatic-cfg-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:CfgDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item Env:\QBITSTATIC_TEST_DIR -ErrorAction SilentlyContinue
        }

        It "Maps every JSON field to its config key" {
            $path = Join-Path $script:CfgDir "full.json"
            @'
{
  "qbittorrent": { "exePath": "C:\\qbt\\qbt.exe", "webUrl": "http://host:9999", "credentialTarget": "target-x" },
  "protonvpn": { "logPath": "C:\\logs\\client-logs.txt", "portPattern": "Port (\\d+)" },
  "monitoring": { "pollIntervalSeconds": 15, "maxRetries": 4, "retryDelaySeconds": 2 },
  "logging": { "directory": "C:\\qlogs", "fileName": "q.log", "maxSizeMB": 2, "checkInterval": 50 }
}
'@ | Set-Content $path

            $c = Get-QbitstaticConfig -Path $path -Force

            $c.QbtExePath | Should -Be "C:\qbt\qbt.exe"
            $c.QbtWebUrl | Should -Be "http://host:9999"
            $c.CredentialTarget | Should -Be "target-x"
            $c.VpnLogPath | Should -Be "C:\logs\client-logs.txt"
            $c.PortPattern | Should -Be "Port (\d+)"
            $c.PollInterval | Should -Be 15
            $c.MaxRetries | Should -Be 4
            $c.RetryDelay | Should -Be 2
            $c.LogDir | Should -Be "C:\qlogs"
            $c.LogFile | Should -Be "q.log"
            $c.LogMaxSizeMB | Should -Be 2
            $c.LogCheckInterval | Should -Be 50
            Get-ConfigPath | Should -Be $path
        }

        It "Expands a custom environment variable in path fields" {
            $env:QBITSTATIC_TEST_DIR = "C:\expanded"
            $path = Join-Path $script:CfgDir "env.json"
            @'
{
  "qbittorrent": { "exePath": "%QBITSTATIC_TEST_DIR%\\qbt.exe" },
  "protonvpn": { "logPath": "%QBITSTATIC_TEST_DIR%\\client-logs.txt" },
  "logging": { "directory": "%QBITSTATIC_TEST_DIR%\\logs" }
}
'@ | Set-Content $path

            $c = Get-QbitstaticConfig -Path $path -Force

            $c.QbtExePath | Should -Be "C:\expanded\qbt.exe"
            $c.VpnLogPath | Should -Be "C:\expanded\client-logs.txt"
            $c.LogDir | Should -Be "C:\expanded\logs"
        }

        It "Throws on malformed JSON" {
            $path = Join-Path $script:CfgDir "bad.json"
            '{ "qbittorrent": { "webUrl": ' | Set-Content $path

            { Get-QbitstaticConfig -Path $path -Force } | Should -Throw
        }

        It "Returns empty or null values for missing sections (no defaults applied)" {
            $path = Join-Path $script:CfgDir "partial.json"
            '{ "qbittorrent": { "webUrl": "http://localhost:8080" } }' | Set-Content $path

            $c = Get-QbitstaticConfig -Path $path -Force

            $c.QbtWebUrl | Should -Be "http://localhost:8080"
            $c.VpnLogPath | Should -BeNullOrEmpty
            $c.PollInterval | Should -BeNullOrEmpty
            $c.MaxRetries | Should -BeNullOrEmpty
            $c.LogMaxSizeMB | Should -BeNullOrEmpty
        }

        It "Ignores -Path while a cached config exists unless -Force is given" {
            $pathA = Join-Path $script:CfgDir "a.json"
            $pathB = Join-Path $script:CfgDir "b.json"
            '{ "qbittorrent": { "webUrl": "http://a" } }' | Set-Content $pathA
            '{ "qbittorrent": { "webUrl": "http://b" } }' | Set-Content $pathB

            Get-QbitstaticConfig -Path $pathA -Force | Out-Null
            (Get-QbitstaticConfig -Path $pathB).QbtWebUrl | Should -Be "http://a"
            (Get-QbitstaticConfig -Path $pathB -Force).QbtWebUrl | Should -Be "http://b"
        }
    }

    Context "Configuration values" {
        BeforeAll {
            $configPath = Join-Path $PSScriptRoot "..\config.json"
            $config = Get-QbitstaticConfig -Path $configPath -Force
        }

        It "Has valid poll interval" {
            $config.PollInterval | Should -BeGreaterOrEqual 5
            $config.PollInterval | Should -BeLessOrEqual 300
        }

        It "Has valid retry settings" {
            $config.MaxRetries | Should -BeGreaterOrEqual 1
            $config.RetryDelay | Should -BeGreaterOrEqual 1
        }

        It "Has valid log settings" {
            $config.LogMaxSizeMB | Should -BeGreaterThan 0
            $config.LogCheckInterval | Should -BeGreaterThan 0
        }
    }
}
