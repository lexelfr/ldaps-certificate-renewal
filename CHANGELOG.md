# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.0] - 2026-07-01

### Fixed
- **Migration `Get-CimInstance`** : Remplacement de `Get-WmiObject` (déprécié depuis PS 3.0, absent de PS 7+) par `Get-CimInstance` pour la détection du domaine et du rôle DC (2 occurrences).
- **Fuite de handle NTDS** : Le store `NTDS\Personal` est désormais explicitement fermé (`Close()`) dans le bloc `finally` de l'étape 5, évitant un double handle ouvert lors du nettoyage en étape 6.
- **Fallback Pending plus robuste** : Le fallback de sélection du certificat (dans le cas `Pending`) utilise désormais un filtre sur `NotBefore` récent (à moins de 10 minutes) au lieu du Subject, pour éviter de sélectionner un ancien certificat corrompu ou sans SAN.
- **Compatibilité tache planifiée (GPO)** : Remplacement du `Read-Host` interactif (qui bloquait indéfiniment une tâche planifiée non-interactive) par un `Write-Warning` avec continuation automatique.

---

## [1.2.4] - 2026-06-30

### Fixed
- Ajout de l'attribut `[AllowEmptyString()]` à la fonction `Write-Log` pour corriger l'erreur de validation des chaînes vides (ex: `Write-Log -Message ""`).

---

## [1.2.3] - 2026-06-30

### Fixed
- Correction logique majeure dans l'étape 3 : le script utilise désormais *strictement* le certificat qui vient d'être généré, au lieu de rechercher le certificat valide le plus lointain (ce qui risquait de sélectionner un ancien certificat corrompu).

---

## [1.2.2] - 2026-06-30

### Fixed
- Remplacement de la méthode `.NET` `.Export()` par la commande native `Export-PfxCertificate` pour corriger l'erreur d'exportation (`Clé non valide pour l'utilisation dans l'état spécifié`) avec les clés cryptographiques de nouvelle génération (CNG / KSP).

---

## [1.2.1] - 2026-06-30

### Fixed
- Résolution d'un bug de parsing natif à PowerShell 5.1 lié à l'évaluation d'expressions dans des chaînes de caractères.
- Correction d'une erreur d'évaluation (`$false`) dans l'attribut `HelpMessage`.

---

## [1.2.0] - 2026-06-29

### Added
- Auto-détection du FQDN du contrôleur de domaine et du domaine via WMI et variables d'environnement.
- Rendu des paramètres `-DomainControllerFQDN` et `-DomainFQDN` optionnels pour simplifier drastiquement le déploiement via GPO.

---

## [1.1.0] - 2026-06-29

### Added
- Option `-IncludeLocalIPsInSAN` pour ajouter automatiquement les adresses IPv4 Unicast du Contrôleur de Domaine au SAN.
- Option `-RemovePrivateKeyFromLocalMachine` pour gérer la suppression de la clé privée de `LocalMachine\My`. (Par défaut, la clé est maintenant conservée pour plus de compatibilité).
- Option `-RemoveOldCertificateFromNTDS` pour forcer le nettoyage de l'ancien certificat du store NTDS immédiatement après le renouvellement (sans attendre son expiration).

---

## [1.0.0] - 2026-06-28

### Added
- Script principal `Renew-LDAPSCertificate.ps1` avec 7 étapes automatisées :
  - Vérification du certificat existant dans `NTDS\Personal` (seuil configurable)
  - Demande du certificat via `Get-Certificate` auprès d'une CA AD CS
  - Gestion des demandes en attente (approbation CA Manager) avec tentative automatique via `certutil -pulse`
  - Export sécurisé en PFX (mot de passe aléatoire 32 chars si non fourni)
  - Import dans `NTDS\Personal` via l'API Win32 native `Crypt32.dll!CertOpenStore`
  - Nettoyage automatique du PFX temporaire et des certificats NTDS expirés
  - Validation TLS sur le port 636 avec comparaison de thumbprint
- Fonctions utilitaires exposées :
  - `Test-LDAPSCertificate` — affiche le certificat LDAPS actif sur le port 636
  - `Get-NTDSCertificateStatus` — liste les certificats du store `NTDS\Personal`
- Support `WhatIf` pour simulation à sec
- Logging horodaté complet dans `<PFXExportPath>\Logs\`
- `README.md` avec documentation complète, flux d'exécution, guide dépannage
- `.gitignore` adapté (exclusion PFX, logs, clés privées)

### References
- [Deep Dive: Active Directory LDAPS Certificate Selection](https://michaelwaterman.nl/2026/02/03/deep-dive-active-directory-ldaps-certificate-selection/) — Michael Waterman
