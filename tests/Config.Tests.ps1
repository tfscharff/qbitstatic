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
