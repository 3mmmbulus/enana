# Exercise the filesystem APIs with SeSecurityPrivilege actually removed.
# An elevated CI runner otherwise hides the regular user's installation error.
$ErrorActionPreference = 'Stop'
. "$(Split-Path $PSScriptRoot -Parent)\windows\common.ps1"
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class EnanaAclTestToken {
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Privilege { public Luid Id; public uint Attributes; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid id);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateRestrictedToken(SafeAccessTokenHandle existing, uint flags, uint disabledCount, IntPtr disabled, uint deletedCount, ref Privilege deleted, uint restrictedCount, IntPtr restricted, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(SafeAccessTokenHandle token, int type, IntPtr buffer, int length, out int needed);
    public static SafeAccessTokenHandle WithoutAuditPrivilege() {
        SafeAccessTokenHandle source, token;
        if (!OpenProcessToken(GetCurrentProcess(), 0xA, out source)) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (source) {
            Luid id;
            if (!LookupPrivilegeValue(null, "SeSecurityPrivilege", out id)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Privilege removed = new Privilege { Id=id };
            if (!CreateRestrictedToken(source, 0, 0, IntPtr.Zero, 1, ref removed, 0, IntPtr.Zero, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return token;
        }
    }
    public static bool HasAuditPrivilege(SafeAccessTokenHandle token) {
        Luid id;
        if (!LookupPrivilegeValue(null, "SeSecurityPrivilege", out id)) throw new Win32Exception(Marshal.GetLastWin32Error());
        int size;
        GetTokenInformation(token, 3, IntPtr.Zero, 0, out size);
        IntPtr buffer=Marshal.AllocHGlobal(size);
        try {
            if (!GetTokenInformation(token, 3, buffer, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int count=Marshal.ReadInt32(buffer);
            for (int i=0; i<count; i++) {
                Privilege p=(Privilege)Marshal.PtrToStructure(IntPtr.Add(buffer, 4+i*Marshal.SizeOf(typeof(Privilege))), typeof(Privilege));
                if (p.Id.Low==id.Low && p.Id.High==id.High) return true;
            }
            return false;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
$scratch = Join-Path $env:TEMP ('enana-acl-test-'+[Guid]::NewGuid().ToString('N'))
$private = Join-Path $scratch 'private'
$sid = Get-EnanaSid
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$token = [EnanaAclTestToken]::WithoutAuditPrivilege()
try {
    if ([EnanaAclTestToken]::HasAuditPrivilege($token)) { throw 'The regression token still has SeSecurityPrivilege' }
    [Security.Principal.WindowsIdentity]::RunImpersonated($token, [Action]{
        Set-PrivateDirectory $private
        [IO.File]::WriteAllText("$private\data.txt", 'private runtime state')
        Set-PrivateDirectory $private # Existing installs must also work.
        if ([IO.File]::ReadAllText("$private\data.txt") -ne 'private runtime state') { throw 'Private directory is no longer writable/readable' }
        $acl = Get-Acl -LiteralPath $private
        if (!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid) { throw 'Private ownership or inheritance changed' }
        $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 3) { throw 'Unexpected private directory access rules' }
        foreach ($rule in $rules) {
            if ($rule.IsInherited -or $rule.IdentityReference.Value -notin @($sid,'S-1-5-18','S-1-5-32-544') -or $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl') { throw 'Private directory grants unexpected access' }
        }
    })
    Write-Host 'PASS: new and existing private directories work without SeSecurityPrivilege and retain private ownership/access'
    if (Test-EnanaAdmin) {
        $protected = Join-Path $scratch 'protected'
        Set-PrivateDirectory $protected $sid -ReadOnlyUser
        $acl = Get-Acl -LiteralPath $protected
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'TUN snapshot owner is not administrators' }
        $userRules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq $sid})
        if ($userRules.Count -ne 1 -or ($userRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData)) { throw 'TUN snapshot became user writable' }
        Write-Host 'PASS: administrator-owned TUN snapshot remains read only to the user'
    }
} finally {
    $token.Dispose()
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
