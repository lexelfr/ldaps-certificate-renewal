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

Les paramètres FQDN sont désormais **auto-détectés**. Vous pouvez simplement lancer le script sans argument :

```powershell
.\Renew-LDAPSCertificate.ps1
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

### Avec options avancées (IP locales, nettoyage NTDS, suppression clé privée)

```powershell
.\Renew-LDAPSCertificate.ps1 `
    -DomainControllerFQDN "dc01.corp.example.com" `
    -DomainFQDN "corp.example.com" `
    -IncludeLocalIPsInSAN `
    -RemovePrivateKeyFromLocalMachine `
    -RemoveOldCertificateFromNTDS
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
| `DomainControllerFQDN` | ❌ | *auto-détecté* | FQDN du DC cible (ex: `dc01.corp.example.com`) |
| `DomainFQDN` | ❌ | *auto-détecté* | FQDN du domaine AD (ex: `corp.example.com`) |
| `CertificateTemplateName` | ❌ | `NTDSStoreKerberosAuthentication` | Nom interne du template AD CS |
| `LDAPSAlias` | ❌ | — | FQDN du load balancer LDAPS (ajouté aux SANs) |
| `PFXExportPath` | ❌ | `C:\Temp` | Répertoire pour le PFX temporaire |
| `PFXPassword` | ❌ | *auto-généré* | Mot de passe SecureString pour le PFX |
| `DaysBeforeExpiryToRenew` | ❌ | `30` | Seuil en jours pour déclencher le renouvellement |
| `IncludeLocalIPsInSAN` | ❌ | `$false` | Inclure les IPs (IPv4 Unicast) du DC dans le SAN |
| `RemovePrivateKeyFromLocalMachine` | ❌ | `$false` | Supprimer la clé privée de `LocalMachine\My` après export |
| `RemoveOldCertificateFromNTDS` | ❌ | `$false` | Retirer l'ancien certificat de `NTDS\Personal` immédiatement |

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
- 🧹 La clé privée est **conservée par défaut dans `LocalMachine\My`** (peut être retirée via `-RemovePrivateKeyFromLocalMachine` - principe du moindre privilège)
- 📋 Chaque opération est **tracée dans un fichier log horodaté** avec les thumbprints

---

## Automatisation Totale via GPO (Recommandé)

Pour déployer automatiquement cette tâche sur **tous vos Contrôleurs de Domaine** (présents et futurs), il est recommandé de créer une **Group Policy Preference (GPP)**. 

### 1. Préparation
1. Placez le script `Renew-LDAPSCertificate.ps1` dans un partage réseau accessible par tous les DCs, par exemple le **SYSVOL** :
   `\\votredomaine.com\SYSVOL\votredomaine.com\scripts\Renew-LDAPSCertificate.ps1`
2. Assurez-vous que le modèle de certificat AD CS (Template) a les permissions **Read**, **Enroll** et **Autoenroll** pour le groupe "Domain Controllers".
3. L'option "CA Certificate manager approval" **doit être désactivée** sur le template pour que le processus soit 100% autonome.

### 2. Création de la GPO
Créez une GPO liée à l'Unité d'Organisation (OU) `Domain Controllers` et naviguez vers :
**Computer Configuration > Preferences > Control Panel Settings > Scheduled Tasks**

Créez une nouvelle tâche planifiée (At least Windows 7) avec ces paramètres :
- **General** : 
  - Action: `Update` (ou `Replace`)
  - Name: `AutoRenew-LDAPS-Certificate`
  - User Account: `NT AUTHORITY\SYSTEM`
  - Cochez **Run with highest privileges**
- **Triggers** : 
  - *Trigger 1* : **At system startup** (avec un délai de 5 minutes). *Garantit qu'un nouveau DC fraîchement promu obtient son certificat dès son premier redémarrage.*
  - *Trigger 2* : **Daily** à 02:00 AM. *Pour vérifier quotidiennement si le seuil de renouvellement est atteint.*
- **Actions** :
  - Action: `Start a program`
  - Program/script: `powershell.exe`
  - Add arguments: `-ExecutionPolicy Bypass -WindowStyle Hidden -File "\\votredomaine.com\SYSVOL\votredomaine.com\scripts\Renew-LDAPSCertificate.ps1" -IncludeLocalIPsInSAN -RemoveOldCertificateFromNTDS`
  *(Note : plus besoin de spécifier les FQDN, le script les auto-détecte).*

---

## Dépannage

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `Certificat en attente d'approbation` | Template configuré avec approbation CA Manager | Approuver manuellement sur le CA puis relancer |
| `Impossible d'ouvrir le store NTDS\My` | Script non exécuté sur un DC, ou pas Admin | Vérifier le contexte d'exécution |
| `Le certificat n'a pas de clé privée` | Template sans option d'export | Vérifier *Request Handling* dans le template |
| Thumbprint ne correspond pas après import | Délai de propagation NTDS | Attendre 30-60 secondes, retester avec `Test-LDAPSCertificate` |
| `Get-Certificate: template not found` | Nom de template incorrect | Vérifier le *Template name* (pas le Display name) dans la CA |
