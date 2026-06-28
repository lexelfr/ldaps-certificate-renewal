# LDAPS Certificate Renewal Script

Script PowerShell pour automatiser le renouvellement du certificat LDAPS et son placement dans le store `NTDS\Personal` sur les Contrôleurs de Domaine Active Directory.

**Basé sur** : [Deep Dive: Active Directory LDAPS Certificate Selection](https://michaelwaterman.nl/2026/02/03/deep-dive-active-directory-ldaps-certificate-selection/) par Michael Waterman

---

## Pourquoi le store NTDS ?

Active Directory sélectionne le certificat LDAPS selon un ordre de priorité de stores :

```
NTDS\Personal  >  LocalMachine\My
```

Placer le certificat dans `NTDS\Personal` (store du service NTDS) garantit qu'**il sera toujours préféré**, même si d'autres certificats Server Authentication sont présents dans `LocalMachine\My`. C'est le mécanisme documenté par Michael Waterman pour rendre la sélection du certificat LDAPS **déterministe et contrôlable**.

---

## Prérequis

### Côté Contrôleur de Domaine
- Windows Server 2016 ou supérieur
- PowerShell 5.1 ou supérieur
- Exécution en tant qu'**Administrateur local**
- Accès réseau au serveur CA d'entreprise (AD CS)

### Côté AD CS — Modèle de certificat
Créer un modèle de certificat (basé sur *Kerberos Authentication*) avec ces paramètres :

| Onglet | Paramètre | Valeur |
|--------|-----------|--------|
| **General** | Nom du modèle | `NTDSStoreKerberosAuthentication` |
| **Request Handling** | Allow private key to be exported | ✅ Activé |
| **Subject Name** | Build from this Active Directory information | ❌ Désactivé |
| **Subject Name** | Supply in the request | ✅ Activé |
| **Security** | Autoenroll (Domain Controllers) | ❌ Désactivé |
| **Issuance Requirements** | CA Certificate manager approval | ✅ Activé (recommandé) |
| **Extensions** | Application Policies | Kerberos Authentication |

> **Note** : Désactiver l'autoenrollment est intentionnel. On contrôle manuellement le placement dans NTDS.

---

## Utilisation

### Usage basique (sur le DC directement)

```powershell
.\Renew-LDAPSCertificate.ps1 `
    -DomainControllerFQDN "dc01.corp.example.com" `
    -DomainFQDN "corp.example.com"
```

### Avec alias load balancer et seuil personnalisé

```powershell
.\Renew-LDAPSCertificate.ps1 `
    -DomainControllerFQDN "dc01.corp.example.com" `
    -DomainFQDN "corp.example.com" `
    -LDAPSAlias "ldaps.corp.example.com" `
    -PFXExportPath "C:\Certs" `
    -DaysBeforeExpiryToRenew 60
```

### Via PowerShell Remoting (depuis une station de gestion / PAW)

```powershell
$Session = New-PSSession -ComputerName "dc01.corp.example.com" -UseSSL
Invoke-Command -Session $Session -FilePath ".\Renew-LDAPSCertificate.ps1" `
    -ArgumentList "dc01.corp.example.com", "corp.example.com"
```

### Simulation (WhatIf)

```powershell
.\Renew-LDAPSCertificate.ps1 `
    -DomainControllerFQDN "dc01.corp.example.com" `
    -DomainFQDN "corp.example.com" `
    -WhatIf
```

### Fonctions utilitaires (dot-sourcing)

```powershell
# Charger les fonctions sans lancer le renouvellement
. .\Renew-LDAPSCertificate.ps1 -DomainControllerFQDN x -DomainFQDN x -WhatIf

# Tester le certificat LDAPS actif
Test-LDAPSCertificate -HostName "dc01.corp.example.com"

# Voir l'état du store NTDS
Get-NTDSCertificateStatus
```

---

## Paramètres

| Paramètre | Obligatoire | Défaut | Description |
|-----------|-------------|--------|-------------|
| `DomainControllerFQDN` | ✅ | — | FQDN du DC cible (ex: `dc01.corp.example.com`) |
| `DomainFQDN` | ✅ | — | FQDN du domaine AD (ex: `corp.example.com`) |
| `CertificateTemplateName` | ❌ | `NTDSStoreKerberosAuthentication` | Nom interne du template AD CS |
| `LDAPSAlias` | ❌ | — | FQDN du load balancer LDAPS (ajouté aux SANs) |
| `PFXExportPath` | ❌ | `C:\Temp` | Répertoire pour le PFX temporaire |
| `PFXPassword` | ❌ | *auto-généré* | Mot de passe SecureString pour le PFX |
| `DaysBeforeExpiryToRenew` | ❌ | `30` | Seuil en jours pour déclencher le renouvellement |

---

## Flux d'exécution

```
┌─────────────────────────────────────────────────────────────────┐
│  Etape 0 : Verification                                          │
│    └─ Lire NTDS\Personal → certificat valide ? jours restants ?  │
│         Non renouvellement nécessaire → EXIT                     │
├─────────────────────────────────────────────────────────────────┤
│  Etape 1 : Preparation                                           │
│    └─ Créer répertoires, générer mot de passe PFX, lister SANs  │
├─────────────────────────────────────────────────────────────────┤
│  Etape 2 : Demande de certificat                                 │
│    └─ Get-Certificate → LocalMachine\My                         │
│         Pending → certutil -pulse (récupération automatique)    │
├─────────────────────────────────────────────────────────────────┤
│  Etape 3 : Localisation du certificat emis                       │
│    └─ Chercher dans Cert:\LocalMachine\My (HasPrivateKey=true)  │
├─────────────────────────────────────────────────────────────────┤
│  Etape 4 : Export PFX + nettoyage LocalMachine\My               │
│    └─ Export avec clé privée → supprimer de LocalMachine\My     │
├─────────────────────────────────────────────────────────────────┤
│  Etape 5 : Import dans NTDS\Personal                             │
│    └─ API Win32 Crypt32.dll → CertOpenStore(NTDS\My)            │
│    └─ X509Store.Add(certificate)                                 │
├─────────────────────────────────────────────────────────────────┤
│  Etape 6 : Nettoyage                                             │
│    └─ Supprimer PFX temporaire + certificats NTDS expirés        │
├─────────────────────────────────────────────────────────────────┤
│  Etape 7 : Validation                                            │
│    └─ Connexion TLS port 636 → comparer thumbprints             │
└─────────────────────────────────────────────────────────────────┘
```

---

## SANs du certificat générés

Le script configure automatiquement ces Subject Alternative Names (DNS) :

| SAN | Description |
|-----|-------------|
| `dc01.corp.example.com` | FQDN du Contrôleur de Domaine |
| `corp.example.com` | FQDN du domaine (pour LDAP DNS round-robin) |
| `ldaps.corp.example.com` | Alias load balancer (si `-LDAPSAlias` fourni) |

---

## Sécurité

- 🔐 Le PFX est **protégé par un mot de passe aléatoire 32 caractères** (si non fourni)
- 🗑️ Le fichier PFX temporaire est **supprimé automatiquement** après import
- 🧹 La clé privée est **retirée de `LocalMachine\My`** après export (principe du moindre privilège)
- 📋 Chaque opération est **tracée dans un fichier log horodaté** avec les thumbprints

---

## Automatisation via Tâche Planifiée

```powershell
# Créer une tâche planifiée pour vérifier tous les 7 jours
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument @"
-NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Renew-LDAPSCertificate.ps1" `
-DomainControllerFQDN "$($env:COMPUTERNAME).$((Get-WmiObject Win32_ComputerSystem).Domain)" `
-DomainFQDN "$((Get-WmiObject Win32_ComputerSystem).Domain)" `
-DaysBeforeExpiryToRenew 60
"@

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "02:00AM"

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName "LDAPS Certificate Renewal" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Renouvellement automatique du certificat LDAPS dans NTDS\Personal"
```

---

## Dépannage

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `Certificat en attente d'approbation` | Template configuré avec approbation CA Manager | Approuver manuellement sur le CA puis relancer |
| `Impossible d'ouvrir le store NTDS\My` | Script non exécuté sur un DC, ou pas Admin | Vérifier le contexte d'exécution |
| `Le certificat n'a pas de clé privée` | Template sans option d'export | Vérifier *Request Handling* dans le template |
| Thumbprint ne correspond pas après import | Délai de propagation NTDS | Attendre 30-60 secondes, retester avec `Test-LDAPSCertificate` |
| `Get-Certificate: template not found` | Nom de template incorrect | Vérifier le *Template name* (pas le Display name) dans la CA |
