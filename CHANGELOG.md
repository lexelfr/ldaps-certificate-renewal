# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
