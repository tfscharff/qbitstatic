#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Credential Manager integration via P/Invoke.
#>

$script:CredApiLoaded = $false
$script:CredentialTarget = "qbitstatic-qbittorrent"

function Initialize-CredentialApi {
    <#
    .SYNOPSIS
        Load the Credential Manager API via P/Invoke.
    #>
    param([string]$Target)

    if ($Target) {
        $script:CredentialTarget = $Target
    }

    if ($script:CredApiLoaded) { return }

    Add-Type -MemberDefinition @"
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredWrite(ref CREDENTIAL cred, int flags);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredDelete(string target, int type, int reserved);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr cred);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct CREDENTIAL {
    public int Flags, Type; public string TargetName, Comment;
    public long LastWritten;
    public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist, AttributeCount; public IntPtr Attributes;
    public string TargetAlias, UserName;
}
"@ -Namespace CredManager -Name Api -ErrorAction SilentlyContinue

    $script:CredApiLoaded = $true
}

function Save-Credential {
    <#
    .SYNOPSIS
        Save credentials to Windows Credential Manager.
    .PARAMETER Credential
        The PSCredential to save.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    Initialize-CredentialApi

    $pw = $Credential.GetNetworkCredential().Password
    $pwBytes = [Text.Encoding]::Unicode.GetBytes($pw)
    $blob = [Runtime.InteropServices.Marshal]::AllocHGlobal($pwBytes.Length)

    try {
        [Runtime.InteropServices.Marshal]::Copy($pwBytes, 0, $blob, $pwBytes.Length)

        $cred = New-Object CredManager.Api+CREDENTIAL
        $cred.Type = 1  # CRED_TYPE_GENERIC
        $cred.TargetName = $script:CredentialTarget
        $cred.UserName = $Credential.UserName
        $cred.CredentialBlob = $blob
        $cred.CredentialBlobSize = $pwBytes.Length
        $cred.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE

        if (-not [CredManager.Api]::CredWrite([ref]$cred, 0)) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed with error code: $err"
        }

        return $true
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blob)
    }
}

function Get-StoredCredential {
    <#
    .SYNOPSIS
        Retrieve credentials from Windows Credential Manager.
    .OUTPUTS
        PSCredential or $null if not found.
    #>
    Initialize-CredentialApi

    $ptr = [IntPtr]::Zero
    if (-not [CredManager.Api]::CredRead($script:CredentialTarget, 1, 0, [ref]$ptr)) {
        return $null
    }

    try {
        $c = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [Type][CredManager.Api+CREDENTIAL])
        if ($c.CredentialBlobSize -eq 0) { return $null }

        $pw = [Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob, $c.CredentialBlobSize / 2)
        return [PSCredential]::new($c.UserName, (ConvertTo-SecureString $pw -AsPlainText -Force))
    }
    finally {
        [CredManager.Api]::CredFree($ptr)
    }
}

function Remove-StoredCredential {
    <#
    .SYNOPSIS
        Remove credentials from Windows Credential Manager.
    #>
    Initialize-CredentialApi

    if ([CredManager.Api]::CredDelete($script:CredentialTarget, 1, 0)) {
        return $true
    }
    return $false
}

function Get-CredentialTarget {
    return $script:CredentialTarget
}

Export-ModuleMember -Function Initialize-CredentialApi, Save-Credential, Get-StoredCredential, Remove-StoredCredential, Get-CredentialTarget
