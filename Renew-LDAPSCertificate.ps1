#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Renouvellement automatisé du certificat LDAPS et placement dans le store NTDS.

.DESCRIPTION
    Ce script automatise le processus complet de renouvellement du certificat LDAPS
    sur un Contrôleur de Domaine Active Directory, incluant :
      - La demande du certificat auprès d'une CA d'entreprise
      - L'approbation de la demande (si autorisée)
      - La récupération du certificat émis
      - L'export en format PFX
      - L'import dans le store NTDS\Personal (le store prioritaire pour LDAPS)
      - La validation que le bon certificat est utilisé sur le port 636

    Basé sur l'article "Deep Dive: Active Directory LDAPS Certificate Selection"
    par Michael Waterman
    https://michaelwaterman.nl/2026/02/03/deep-dive-active-directory-ldaps-certificate-selection/

    IMPORTANT : Ce script doit être exécuté directement sur le Contrôleur de Domaine
    cible, ou via PowerShell Remoting (Enter-PSSession / Invoke-Command).

.PARAMETER DomainControllerFQDN
    Le nom de domaine complet (FQDN) du Contrôleur de Domaine cible.
    (Auto-détecté par défaut). Exemple : dc01.corp.example.com

.PARAMETER DomainFQDN
    Le nom de domaine complet du domaine Active Directory.
    (Auto-détecté par défaut). Exemple : corp.example.com

.PARAMETER CertificateTemplateName
    Le nom interne du modèle de certificat à utiliser.
    Par défaut : "NTDSStoreKerberosAuthentication"

.PARAMETER LDAPSAlias
    Le FQDN du load balancer ou alias LDAPS (facultatif).
    Exemple : ldaps.corp.example.com

.PARAMETER PFXExportPath
    Chemin du répertoire où exporter temporairement le fichier PFX.
    Par défaut : C:\Temp

.PARAMETER PFXPassword
    Mot de passe pour protéger le fichier PFX exporté.
    Si non fourni, le script en génère un aléatoire sécurisé.

.PARAMETER DaysBeforeExpiryToRenew
    Nombre de jours avant expiration à partir desquels déclencher le renouvellement.
    Par défaut : 30

.PARAMETER IncludeLocalIPsInSAN
    Inclure automatiquement toutes les adresses IP (IPv4 Unicast) du DC dans le SAN du certificat.

.PARAMETER RemovePrivateKeyFromLocalMachine
    Supprimer la clé privée du store LocalMachine\My après l'export PFX. (Par défaut, elle est conservée).

.PARAMETER RemoveOldCertificateFromNTDS
    Retirer le certificat existant (même s'il n'est pas encore expiré) du store NTDS après le renouvellement.

.EXAMPLE
    # Renouvellement simple sur le DC local
    .\Renew-LDAPSCertificate.ps1 -DomainControllerFQDN "dc01.corp.example.com" -DomainFQDN "corp.example.com"

.EXAMPLE
    # Avec alias LDAPS et seuil personnalisé
    .\Renew-LDAPSCertificate.ps1 `
        -DomainControllerFQDN "dc01.corp.example.com" `
        -DomainFQDN "corp.example.com" `
        -LDAPSAlias "ldaps.corp.example.com" `
        -PFXExportPath "C:\Certs" `
        -DaysBeforeExpiryToRenew 60

.EXAMPLE
    # Via PowerShell Remoting depuis une station de gestion
    $Session = New-PSSession -ComputerName "dc01.corp.example.com" -UseSSL
    Invoke-Command -Session $Session -FilePath ".\Renew-LDAPSCertificate.ps1" `
        -ArgumentList "dc01.corp.example.com", "corp.example.com"

.EXAMPLE
    # Afficher l'état du certificat LDAPS actif (après avoir chargé le script)
    . .\Renew-LDAPSCertificate.ps1
    Test-LDAPSCertificate -HostName "dc01.corp.example.com"
    Get-NTDSCertificateStatus

.EXAMPLE
    # Renouvellement avec inclusion des IPs locales et nettoyage agressif
    .\Renew-LDAPSCertificate.ps1 `
        -DomainControllerFQDN "dc01.corp.example.com" `
        -DomainFQDN "corp.example.com" `
        -IncludeLocalIPsInSAN `
        -RemoveOldCertificateFromNTDS

.NOTES
    Auteur    : Script basé sur les travaux de Michael Waterman
    Version   : 1.3.0
    Date      : 2026-07-01

    PREREQUIS :
    - Execution en tant qu administrateur local sur le DC
    - Un modele de certificat AD CS configure avec :
        * EKU : Kerberos Authentication (1.3.6.1.5.2.3.5)
                OU Server Authentication (1.3.6.1.5.5.7.3.1)
        * La cle privee doit etre exportable ("Allow private key to be exported")
        * Subject Name : "Supply in the request"
        * Approbation du CA Manager (recommande)
    - Les permissions d enrollment sur le modele de certificat

    SECURITE :
    - Le fichier PFX temporaire est supprime apres import dans le store NTDS
    - La cle privee est conservee par defaut dans LocalMachine\My (optionnel via -RemovePrivateKeyFromLocalMachine)
    - Les logs sont horodates et incluent les thumbprints pour auditabilite
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false, Position = 0,
        HelpMessage = "FQDN du Controleur de Domaine cible (auto-detecte si non fourni)")]
    [string]$DomainControllerFQDN,

    [Parameter(Mandatory = $false, Position = 1,
        HelpMessage = "FQDN du domaine Active Directory (auto-detecte si non fourni)")]
    [string]$DomainFQDN,

    [Parameter(Mandatory = $false,
        HelpMessage = "Nom interne du modele de certificat AD CS")]
    [string]$CertificateTemplateName = "NTDSStoreKerberosAuthentication",

    [Parameter(Mandatory = $false,
        HelpMessage = "FQDN du load balancer ou alias LDAPS (facultatif)")]
    [string]$LDAPSAlias,

    [Parameter(Mandatory = $false,
        HelpMessage = "Chemin du repertoire pour l export PFX temporaire")]
    [string]$PFXExportPath = "C:\Temp",

    [Parameter(Mandatory = $false,
        HelpMessage = "Mot de passe PFX (genere automatiquement si non fourni)")]
    [SecureString]$PFXPassword,

    [Parameter(Mandatory = $false,
        HelpMessage = "Jours avant expiration pour declencher le renouvellement")]
    [ValidateRange(1, 365)]
    [int]$DaysBeforeExpiryToRenew = 30,

    [Parameter(Mandatory = $false,
        HelpMessage = "Inclure automatiquement toutes les adresses IP (IPv4 Unicast) du DC dans le SAN du certificat")]
    [switch]$IncludeLocalIPsInSAN,

    [Parameter(Mandatory = $false,
        HelpMessage = "Supprimer la cle privee du store LocalMachine\My apres l'export PFX (par defaut: faux)")]
    [switch]$RemovePrivateKeyFromLocalMachine,

    [Parameter(Mandatory = $false,
        HelpMessage = "Retirer le certificat existant (meme s'il n'est pas encore expire) du store NTDS apres le renouvellement")]
    [switch]$RemoveOldCertificateFromNTDS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Auto-detection des noms si non fournis (ideal pour les Taches Planifiees GPO)
if ([string]::IsNullOrWhiteSpace($DomainFQDN)) {
    try {
        # Get-CimInstance est la methode moderne (Get-WmiObject est deprecated depuis PS 3.0 et absent de PS 7+)
        $DomainFQDN = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
    } catch {
        throw "Impossible de detecter automatiquement le nom du domaine. Veuillez specifier -DomainFQDN."
    }
}

if ([string]::IsNullOrWhiteSpace($DomainControllerFQDN)) {
    $DomainControllerFQDN = "$env:COMPUTERNAME.$DomainFQDN".ToLower()
}

#region Utilitaires

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR", "STEP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "INFO"    { Write-Host $logEntry -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "STEP"    { Write-Host "`n$logEntry" -ForegroundColor Magenta }
    }

    if ($script:LogFilePath) {
        $logEntry | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
}

function New-SecureRandomPassword {
    $chars   = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}|;:,.<>?'
    $rng     = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes   = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    $rng.Dispose()
    return $password
}

function Get-ServiceCertificateStore {
    <#
    .SYNOPSIS
        Ouvre le store de certificats d un service Windows (ex: NTDS\My).

    .DESCRIPTION
        Utilise les API Win32 natives (Crypt32.dll) pour acceder aux stores de
        certificats des services Windows, qui ne sont pas accessibles via les
        cmdlets standard PowerShell.
        Methode documentee par Michael Waterman dans son article sur LDAPS.

    .PARAMETER ServiceName
        Nom du service Windows (ex: NTDS).

    .PARAMETER StoreName
        Nom du store (ex: My = Personal).

    .PARAMETER OpenFlags
        Flags d ouverture du store.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$ServiceName,

        [Parameter(Mandatory = $false)]
        [string]$StoreName = "My",

        [Parameter(Mandatory = $false)]
        [System.Security.Cryptography.X509Certificates.OpenFlags]
        $OpenFlags = [System.Security.Cryptography.X509Certificates.OpenFlags]::MaxAllowed
    )

    begin {
        if (-not ([System.Management.Automation.PSTypeName]'X509NativeMethods.NativeMethods').Type) {
            $typeDefinition = @"
using Microsoft.Win32.SafeHandles;
using System;
using System.Runtime.InteropServices;

namespace X509NativeMethods
{
    public class NativeMethods
    {
        [DllImport("Crypt32.dll")]
        public static extern bool CertCloseStore(
            IntPtr hCertStore,
            uint dwFlags);

        [DllImport("Crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeX509Store CertOpenStore(
            IntPtr lpszStoreProvider,
            uint dwEncodingType,
            IntPtr hCryptProv,
            uint dwFlags,
            string pvPara);
    }

    public class SafeX509Store : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeX509Store() : base(true) { }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.CertCloseStore(handle, 0);
        }
    }
}
"@
            Add-Type -TypeDefinition $typeDefinition -Language CSharp
        }

        # CERT_STORE_PROV_SYSTEM_W = 10
        $provider  = [IntPtr]::new(10)
        # CERT_SYSTEM_STORE_SERVICES = 0x00050000 | CERT_STORE_OPEN_EXISTING_FLAG = 0x00000004
        $baseFlags = (0x00050000 -bor 0x00000004)
        $flagType  = [System.Security.Cryptography.X509Certificates.OpenFlags]

        $openMode   = [int]$OpenFlags -band 3
        $accessFlag = switch ($openMode) {
            0 { 0x00008000 }  # ReadOnly
            2 { 0x00001000 }  # ReadWrite
            default { 0 }
        }
        $baseFlags = $baseFlags -bor $accessFlag

        if ($OpenFlags.HasFlag($flagType::OpenExistingOnly)) {
            $baseFlags = $baseFlags -bor 0x00004000
        }
        if ($OpenFlags.HasFlag($flagType::IncludeArchived)) {
            $baseFlags = $baseFlags -bor 0x00000200
        }
    }

    process {
        $handle    = [X509NativeMethods.NativeMethods]::CertOpenStore(
            $provider, 0, [IntPtr]::Zero, $baseFlags, "$ServiceName\$StoreName"
        )
        $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()

        if ($handle.IsInvalid) {
            $win32Exception = [System.ComponentModel.Win32Exception]$lastError
            Write-Error -Message "Impossible d ouvrir le store '$ServiceName\$StoreName': $($win32Exception.Message)" `
                        -Exception $win32Exception
            return
        }

        try {
            [System.Security.Cryptography.X509Certificates.X509Store]::new($handle.DangerousGetHandle())
        }
        finally {
            $handle.Dispose()
        }
    }
}

function Get-CertificateFromTlsHandshake {
    <#
    .SYNOPSIS
        Recupere le certificat presente par un serveur lors d une connexion TLS.

    .PARAMETER HostName
        Nom d hote ou FQDN du serveur.

    .PARAMETER Port
        Port TCP a utiliser (636 pour LDAPS).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$HostName,

        [Parameter(Mandatory = $false)]
        [int]$Port = 636
    )

    $tcp  = $null
    $ssl  = $null
    $cert = $null

    try {
        $tcp   = [System.Net.Sockets.TcpClient]::new($HostName, $Port)
        $state = @{}
        $ssl   = [System.Net.Security.SslStream]::new(
            $tcp.GetStream(),
            $false,
            {
                param($Sender, $Certificate, $Chain, $SslPolicyErrors)
                $state.cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Certificate)
                return $true
            }
        )
        $ssl.AuthenticateAsClient($HostName)
        $cert = $state.cert
    }
    catch {
        Write-Log -Message "Impossible de contacter $($HostName):$Port - $($_.Exception.Message)" -Level "WARNING"
    }
    finally {
        if ($ssl) { $ssl.Dispose()  }
        if ($tcp) { $tcp.Dispose()  }
    }

    return $cert
}

function Get-NTDSCertificates {
    [CmdletBinding()]
    param()

    try {
        $store = Get-ServiceCertificateStore -ServiceName "NTDS" -StoreName "My" `
                    -OpenFlags ([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        return $store.Certificates
    }
    catch {
        Write-Log -Message "Impossible de lire le store NTDS\Personal : $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Test-CertificateNeedsRenewal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DaysBeforeExpiry
    )

    Write-Log -Message "Verification du certificat LDAPS existant dans le store NTDS..." -Level "STEP"

    $ntdsCerts = Get-NTDSCertificates
    if (-not $ntdsCerts -or $ntdsCerts.Count -eq 0) {
        Write-Log -Message "Aucun certificat trouve dans NTDS\Personal. Renouvellement necessaire." -Level "WARNING"
        return $true
    }

    $bestCert = $ntdsCerts |
        Where-Object { $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $bestCert) {
        Write-Log -Message "Tous les certificats NTDS sont expires. Renouvellement necessaire." -Level "WARNING"
        return $true
    }

    $daysRemaining = ($bestCert.NotAfter - (Get-Date)).Days
    Write-Log -Message "Certificat NTDS actuel : Thumbprint=$($bestCert.Thumbprint)" -Level "INFO"
    Write-Log -Message "  Subject   : $($bestCert.Subject)" -Level "INFO"
    Write-Log -Message "  Expiration: $($bestCert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')) ($daysRemaining jours restants)" -Level "INFO"

    if ($daysRemaining -le $DaysBeforeExpiry) {
        Write-Log -Message "Le certificat expire dans $daysRemaining jour(s) (seuil: $DaysBeforeExpiry). Renouvellement necessaire." -Level "WARNING"
        return $true
    }

    Write-Log -Message "Le certificat est valide pour encore $daysRemaining jour(s). Aucun renouvellement necessaire." -Level "SUCCESS"
    return $false
}

#endregion

#region Logique Principale

function Invoke-LDAPSCertificateRenewal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    # --- Initialisation du log ---
    $logDir             = Join-Path $PFXExportPath "Logs"
    $script:LogFilePath = Join-Path $logDir "LDAPSRenewal_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Write-Log -Message "================================================================" -Level "INFO"
    Write-Log -Message "  Renouvellement du certificat LDAPS - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"
    Write-Log -Message "  DC cible              : $DomainControllerFQDN" -Level "INFO"
    Write-Log -Message "  Domaine               : $DomainFQDN" -Level "INFO"
    Write-Log -Message "  Template              : $CertificateTemplateName" -Level "INFO"
    if ($LDAPSAlias) {
        Write-Log -Message "  Alias LDAPS           : $LDAPSAlias" -Level "INFO"
    }
    Write-Log -Message "  Seuil renouvellement  : $DaysBeforeExpiryToRenew jour(s)" -Level "INFO"
    Write-Log -Message "================================================================" -Level "INFO"

    # --- Etape 0 : Verification ---
    $needsRenewal = Test-CertificateNeedsRenewal -DaysBeforeExpiry $DaysBeforeExpiryToRenew
    if (-not $needsRenewal) {
        Write-Log -Message "Operation terminee : aucun renouvellement requis." -Level "SUCCESS"
        return
    }

    # --- Etape 1 : Preparation ---
    Write-Log -Message "ETAPE 1 : Preparation de l environnement" -Level "STEP"

    if (-not (Test-Path $PFXExportPath)) {
        if ($PSCmdlet.ShouldProcess($PFXExportPath, "Creer le repertoire d export PFX")) {
            New-Item -ItemType Directory -Path $PFXExportPath -Force | Out-Null
            Write-Log -Message "Repertoire cree : $PFXExportPath" -Level "INFO"
        }
    }

    if (-not $PFXPassword) {
        $plainPassword = New-SecureRandomPassword
        $PFXPassword   = ConvertTo-SecureString -String $plainPassword -Force -AsPlainText
        Write-Log -Message "Mot de passe PFX genere automatiquement (32 caracteres aleatoires)." -Level "INFO"
    }

    $dnsSANs = @($DomainControllerFQDN, $DomainFQDN)
    if ($LDAPSAlias -and $LDAPSAlias -ne "") {
        $dnsSANs += $LDAPSAlias
    }
    if ($IncludeLocalIPsInSAN) {
        Write-Log -Message "Recuperation des adresses IP locales du DC..." -Level "INFO"
        try {
            # Recupere les IPs IPv4 Unicast, excluant loopback/APIPA
            $ips = Get-NetIPAddress -AddressFamily IPv4 -Type Unicast -ErrorAction Stop | 
                   Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | 
                   Select-Object -ExpandProperty IPAddress
            if ($ips) {
                $dnsSANs += $ips
            }
        }
        catch {
            Write-Log -Message "Avertissement: Impossible de recuperer les IPs locales. $($_.Exception.Message)" -Level "WARNING"
        }
    }
    Write-Log -Message "SANs configures : $($dnsSANs -join ', ')" -Level "INFO"

    $pfxFileName = "ldaps_$(($DomainControllerFQDN -split '\.')[0])_$(Get-Date -Format 'yyyyMMdd_HHmmss').pfx"
    $pfxFilePath = Join-Path $PFXExportPath $pfxFileName

    # --- Etape 2 : Demande du certificat ---
    Write-Log -Message "ETAPE 2 : Demande du certificat aupres de la CA" -Level "STEP"

    $enrollResult = $null
    try {
        if ($PSCmdlet.ShouldProcess($DomainControllerFQDN, "Demander le certificat LDAPS (template: $CertificateTemplateName)")) {
            Write-Log -Message "Soumission de la demande de certificat..." -Level "INFO"

            $enrollResult = Get-Certificate `
                -Template          $CertificateTemplateName `
                -SubjectName       "cn=$DomainControllerFQDN" `
                -DnsName           $dnsSANs `
                -CertStoreLocation "cert:\LocalMachine\My" `
                -ErrorAction Stop

            Write-Log -Message "Demande soumise. Statut : $($enrollResult.Status)" -Level "INFO"

            if ($enrollResult.Status -eq "Issued") {
                Write-Log -Message "Certificat emis immediatement." -Level "SUCCESS"
                Write-Log -Message "Thumbprint : $($enrollResult.Certificate.Thumbprint)" -Level "INFO"
            }
            elseif ($enrollResult.Status -eq "Pending") {
                Write-Log -Message "La demande est en attente d approbation par le CA Manager." -Level "WARNING"
                Write-Log -Message "Thumbprint de la demande : $($enrollResult.Request.Thumbprint)" -Level "INFO"
                Write-Log -Message "" -Level "INFO"
                Write-Log -Message "ACTION REQUISE : Approuvez la demande sur votre serveur CA :" -Level "WARNING"
                Write-Log -Message "  1. Ouvrez 'Certification Authority' sur le serveur CA" -Level "INFO"
                Write-Log -Message "  2. Naviguez vers 'Pending Requests'" -Level "INFO"
                Write-Log -Message "  3. Clic droit sur la demande -> All Tasks -> Issue" -Level "INFO"
                Write-Log -Message "  4. Relancez ensuite certutil -pulse sur ce DC" -Level "INFO"
                Write-Log -Message "" -Level "INFO"

                Write-Log -Message "Tentative de recuperation automatique via certutil -pulse..." -Level "INFO"
                & certutil -pulse 2>&1 | Out-String | ForEach-Object {
                    if ($_.Trim()) { Write-Log -Message $_.Trim() -Level "INFO" }
                }

                Start-Sleep -Seconds 5

                # Filtre sur NotBefore recent pour eviter de recuperer un ancien certificat
                # qui aurait un Subject correspondant mais ne serait pas la demande courante
                $recentThreshold = (Get-Date).AddMinutes(-10)
                $issuedCert = Get-ChildItem "Cert:\LocalMachine\My" |
                    Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.NotBefore -gt $recentThreshold } |
                    Sort-Object NotBefore -Descending |
                    Select-Object -First 1

                if (-not $issuedCert) {
                    try {
                        $pendingRequest = Get-ChildItem "Cert:\LocalMachine\Request\" -ErrorAction SilentlyContinue |
                            Where-Object { $_.Thumbprint -eq $enrollResult.Request.Thumbprint }
                        if ($pendingRequest) {
                            Write-Log -Message "Recuperation du certificat via la demande en attente..." -Level "INFO"
                            Get-Certificate -Request $pendingRequest -ErrorAction Stop | Out-Null
                        }
                    }
                    catch {
                        Write-Log -Message "Recuperation automatique impossible. Approbation manuelle requise." -Level "ERROR"
                        throw "Certificat en attente d approbation. Thumbprint de la demande : $($enrollResult.Request.Thumbprint)"
                    }
                }
            }
            else {
                throw "Statut d enrollment inattendu : $($enrollResult.Status)"
            }
        }
    }
    catch {
        if ($_.Exception.Message -like "*en attente*") { throw }
        Write-Log -Message "Erreur lors de la demande de certificat : $($_.Exception.Message)" -Level "ERROR"
        throw
    }

    # --- Etape 3 : Localisation du certificat emis ---
    Write-Log -Message "ETAPE 3 : Localisation du certificat emis dans LocalMachine\My" -Level "STEP"

    Start-Sleep -Seconds 2

    $issuedCert = $null
    if ($enrollResult -and $enrollResult.Status -eq "Issued" -and $enrollResult.Certificate) {
        # Utiliser STRICTEMENT le certificat qui vient d'être émis
        $issuedCert = Get-Item -Path "cert:\LocalMachine\My\$($enrollResult.Certificate.Thumbprint)" -ErrorAction SilentlyContinue
        if (-not $issuedCert) {
            $issuedCert = $enrollResult.Certificate
        }
    }
    else {
        # Fallback (ex: cas d'une demande Pending approuvée manuellement)
        $issuedCert = Get-ChildItem "Cert:\LocalMachine\My" |
            Where-Object {
                $_.Subject -like "*$DomainControllerFQDN*" -and
                $_.NotAfter -gt (Get-Date) -and
                $_.HasPrivateKey
            } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
    }

    if (-not $issuedCert) {
        throw "Impossible de localiser le certificat emis dans Cert:\LocalMachine\My"
    }

    Write-Log -Message "Certificat localise : Thumbprint=$($issuedCert.Thumbprint)" -Level "SUCCESS"
    Write-Log -Message "  Subject  : $($issuedCert.Subject)" -Level "INFO"
    Write-Log -Message "  NotAfter : $($issuedCert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "INFO"

    if (-not $issuedCert.HasPrivateKey) {
        throw "Le certificat n a pas de cle privee. Verifiez que le template permet l export de la cle privee."
    }

    # --- Etape 4 : Export en PFX ---
    Write-Log -Message "ETAPE 4 : Export du certificat en format PFX" -Level "STEP"

    try {
        if ($PSCmdlet.ShouldProcess($pfxFilePath, "Exporter le certificat en PFX")) {
            # Utilisation de Export-PfxCertificate (PKI module) pour supporter les cles CNG (KSP) 
            # contrairement a la methode .NET .Export() qui echoue sur PS 5.1 avec les templates V3/V4
            Export-PfxCertificate -Cert $issuedCert -FilePath $pfxFilePath -Password $PFXPassword -Force | Out-Null
            Write-Log -Message "PFX exporte : $pfxFilePath" -Level "SUCCESS"

            if ($RemovePrivateKeyFromLocalMachine) {
                Write-Log -Message "Suppression du certificat du store LocalMachine\My..." -Level "INFO"
                $myStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                    [System.Security.Cryptography.X509Certificates.StoreName]::My,
                    [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
                )
                $myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                try {
                    $myStore.Remove($issuedCert)
                    Write-Log -Message "Certificat supprime du store LocalMachine\My." -Level "INFO"
                }
                finally {
                    $myStore.Close()
                }
            } else {
                Write-Log -Message "Conservation du certificat dans le store LocalMachine\My (comportement par defaut)." -Level "INFO"
            }
        }
    }
    catch {
        Write-Log -Message "Erreur lors de l export PFX : $($_.Exception.Message)" -Level "ERROR"
        throw
    }

    # --- Etape 5 : Import dans le store NTDS\Personal ---
    Write-Log -Message "ETAPE 5 : Import du certificat dans le store NTDS\Personal" -Level "STEP"

    $ntdsStore = $null
    try {
        if ($PSCmdlet.ShouldProcess("NTDS\Personal", "Importer le certificat PFX")) {
            $keyStorageFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags](
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
            )
            $newCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                (Resolve-Path $pfxFilePath).Path,
                $PFXPassword,
                $keyStorageFlags
            )

            Write-Log -Message "Ouverture du store NTDS\Personal en ecriture..." -Level "INFO"
            $ntdsStore = Get-ServiceCertificateStore -ServiceName "NTDS" -StoreName "My" `
                            -OpenFlags ([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

            $ntdsStore.Add($newCert)
            Write-Log -Message "Certificat importe dans NTDS\Personal avec succes !" -Level "SUCCESS"
            Write-Log -Message "  Thumbprint : $($newCert.Thumbprint)" -Level "INFO"

            $script:NewCertThumbprint = $newCert.Thumbprint
        }
    }
    catch {
        Write-Log -Message "Erreur lors de l import dans NTDS\Personal : $($_.Exception.Message)" -Level "ERROR"
        throw
    }
    finally {
        # Fermeture explicite du handle NTDS pour eviter les fuites de ressources
        if ($ntdsStore) { $ntdsStore.Close() }

        if (Test-Path $pfxFilePath) {
            if ($PSCmdlet.ShouldProcess($pfxFilePath, "Supprimer le fichier PFX temporaire")) {
                Remove-Item -Path $pfxFilePath -Force
                Write-Log -Message "Fichier PFX temporaire supprime : $pfxFilePath" -Level "INFO"
            }
        }
    }

    # --- Etape 6 : Nettoyage des anciens certificats NTDS ---
    Write-Log -Message "ETAPE 6 : Nettoyage des anciens certificats dans NTDS\Personal" -Level "STEP"

    try {
        $ntdsStoreRead = Get-ServiceCertificateStore -ServiceName "NTDS" -StoreName "My" `
                            -OpenFlags ([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $allNTDSCerts  = $ntdsStoreRead.Certificates

        $certsToRemove = $allNTDSCerts | Where-Object {
            ( $_.NotAfter -lt (Get-Date) -or $RemoveOldCertificateFromNTDS ) -and
            $_.Thumbprint -ne $script:NewCertThumbprint
        }

        if ($certsToRemove -and $certsToRemove.Count -gt 0) {
            Write-Log -Message "Suppression de $($certsToRemove.Count) ancien(s) certificat(s) du store NTDS..." -Level "INFO"
            foreach ($oldCert in $certsToRemove) {
                $statusMsg = if ($oldCert.NotAfter -lt (Get-Date)) { "expire" } else { "remplace" }
                Write-Log -Message "  Suppression : $($oldCert.Thumbprint) ($statusMsg le $($oldCert.NotAfter.ToString('yyyy-MM-dd')))" -Level "INFO"
                if ($PSCmdlet.ShouldProcess($oldCert.Thumbprint, "Supprimer l'ancien certificat NTDS")) {
                    $ntdsStoreRead.Remove($oldCert)
                }
            }
        }
        else {
            Write-Log -Message "Aucun certificat expire ou ancien a supprimer du store NTDS." -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Avertissement lors du nettoyage NTDS : $($_.Exception.Message)" -Level "WARNING"
    }

    # --- Etape 7 : Validation LDAPS ---
    Write-Log -Message "ETAPE 7 : Validation du certificat LDAPS sur le port 636" -Level "STEP"

    Write-Log -Message "Attente de 5 secondes pour que le service NTDS prenne en compte le nouveau certificat..." -Level "INFO"
    Start-Sleep -Seconds 5

    $validationCert = Get-CertificateFromTlsHandshake -HostName $DomainControllerFQDN -Port 636

    if ($validationCert) {
        Write-Log -Message "Certificat presente sur le port 636 :" -Level "INFO"
        Write-Log -Message "  Thumbprint : $($validationCert.Thumbprint)" -Level "INFO"
        Write-Log -Message "  Subject    : $($validationCert.Subject)" -Level "INFO"
        Write-Log -Message "  NotAfter   : $($validationCert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "INFO"

        if ($script:NewCertThumbprint -and
            $validationCert.Thumbprint -eq $script:NewCertThumbprint) {
            Write-Log -Message "VALIDATION REUSSIE : Le nouveau certificat est bien utilise pour LDAPS !" -Level "SUCCESS"
        }
        elseif ($script:NewCertThumbprint) {
            Write-Log -Message "ATTENTION : Le certificat presente ($($validationCert.Thumbprint)) ne correspond pas" -Level "WARNING"
            Write-Log -Message "           au nouveau certificat importe ($script:NewCertThumbprint)." -Level "WARNING"
            Write-Log -Message "           Delai de propagation possible. Retestez dans quelques minutes." -Level "WARNING"
        }
    }
    else {
        Write-Log -Message "Impossible de valider le certificat sur le port 636." -Level "WARNING"
        Write-Log -Message "Verifiez que le port 636 est accessible et que le service NTDS tourne." -Level "WARNING"
    }

    # --- Resume final ---
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "================================================================" -Level "INFO"
    Write-Log -Message "  RENOUVELLEMENT TERMINE" -Level "SUCCESS"
    if ($script:NewCertThumbprint) {
        Write-Log -Message "  Nouveau Thumbprint : $script:NewCertThumbprint" -Level "INFO"
    }
    Write-Log -Message "  Log sauvegarde dans : $script:LogFilePath" -Level "INFO"
    Write-Log -Message "================================================================" -Level "INFO"
}

#endregion

#region Fonctions Publiques Exportees

function Test-LDAPSCertificate {
    <#
    .SYNOPSIS
        Teste et affiche le certificat LDAPS actif sur un Controleur de Domaine.

    .PARAMETER HostName
        FQDN du Controleur de Domaine a tester.

    .PARAMETER Port
        Port LDAPS (par defaut 636).

    .EXAMPLE
        Test-LDAPSCertificate -HostName "dc01.corp.example.com"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $false)]
        [int]$Port = 636
    )

    Write-Host ""
    Write-Host "[TEST LDAPS] Connexion a $($HostName):$Port..." -ForegroundColor Cyan

    $cert = Get-CertificateFromTlsHandshake -HostName $HostName -Port $Port

    if ($cert) {
        $daysRemaining = ($cert.NotAfter - (Get-Date)).Days
        $status = if ($daysRemaining -gt 30) { "OK" }
                  elseif ($daysRemaining -gt 0) { "ATTENTION - Bientot expire" }
                  else { "EXPIRE" }
        $color  = if ($daysRemaining -gt 30) { "Green" }
                  elseif ($daysRemaining -gt 0) { "Yellow" }
                  else { "Red" }

        Write-Host ""
        Write-Host "  Certificat LDAPS actif [$status]" -ForegroundColor $color
        Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
        Write-Host "  Subject    : $($cert.Subject)" -ForegroundColor White
        Write-Host "  Thumbprint : $($cert.Thumbprint)" -ForegroundColor White
        Write-Host "  Delivre par: $($cert.Issuer)" -ForegroundColor White
        Write-Host ('  Valide du  : {0}' -f $cert.NotBefore.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor White
        Write-Host ('  Expire le  : {0} ({1} jours)' -f $cert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'), $daysRemaining) -ForegroundColor $color

        $sanExt = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
        if ($sanExt) {
            Write-Host "  SANs       : $($sanExt.Format($false))" -ForegroundColor White
        }
        Write-Host ""
        return $cert
    }
    else {
        Write-Host ""
        Write-Host "  Impossible de recuperer le certificat LDAPS sur $($HostName):$Port" -ForegroundColor Red
        Write-Host "  Verifiez la connectivite reseau et que le service AD DS fonctionne." -ForegroundColor Yellow
        Write-Host ""
        return $null
    }
}

function Get-NTDSCertificateStatus {
    <#
    .SYNOPSIS
        Affiche l etat de tous les certificats dans le store NTDS\Personal.

    .EXAMPLE
        Get-NTDSCertificateStatus
    #>
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "[NTDS STORE] Certificats dans NTDS\Personal :" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray

    $certs = Get-NTDSCertificates

    if (-not $certs -or $certs.Count -eq 0) {
        Write-Host "  Aucun certificat trouve dans le store NTDS\Personal." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    foreach ($cert in $certs) {
        $daysRemaining = ($cert.NotAfter - (Get-Date)).Days
        $status = if ($daysRemaining -gt 30) { "[VALIDE]" }
                  elseif ($daysRemaining -gt 0) { "[BIENTOT EXPIRE]" }
                  else { "[EXPIRE]" }
        $color  = if ($daysRemaining -gt 30) { "Green" }
                  elseif ($daysRemaining -gt 0) { "Yellow" }
                  else { "Red" }

        Write-Host ""
        Write-Host "  $status $($cert.Subject)" -ForegroundColor $color
        Write-Host "    Thumbprint : $($cert.Thumbprint)" -ForegroundColor White
        Write-Host ('    Expire le  : {0} ({1} jours)' -f $cert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'), $daysRemaining) -ForegroundColor $color
        
        $pkStatus = if ($cert.HasPrivateKey) { 'Oui [OK]' } else { 'Non [MANQUANTE]' }
        $pkColor  = if ($cert.HasPrivateKey) { 'Green' } else { 'Red' }
        Write-Host ('    Cle privee : {0}' -f $pkStatus) -ForegroundColor $pkColor
    }
    Write-Host ""
}

#endregion

# ─── Point d entree principal ───────────────────────────────────────────────

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Ce script doit etre execute en tant qu Administrateur."
}

$dcRole = $null
try {
    # Get-CimInstance est la methode moderne (Get-WmiObject est deprecated depuis PS 3.0 et absent de PS 7+)
    $dcRole = (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
    if ($dcRole -lt 4) {
        # Read-Host est incompatible avec les taches planifiees non-interactives (GPO).
        # On emets un avertissement et on continue automatiquement pour garantir l'execution en mode non-interactif.
        Write-Warning "ATTENTION : Ce serveur ne semble pas etre un Controleur de Domaine (DomainRole=$dcRole). Continuation automatique..."
    }
}
catch {
    Write-Warning "Impossible de verifier le role du serveur. Continuation..."
}

Invoke-LDAPSCertificateRenewal
