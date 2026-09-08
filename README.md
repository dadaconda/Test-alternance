# Veille alternance — Master Finance (risques / analyse financière) — LinkedIn

Bot qui va chercher **sur LinkedIn** les offres d'**alternance publiées dans les dernières 24 h**
(fenêtre glissante) pour un **Master Finance** : gestion des risques, analyse financière,
contrôle de gestion, conformité, audit, trésorerie, marchés…

- **Source** : endpoint public *jobs-guest* de LinkedIn — **aucun compte, aucune clé API**.
- **Fenêtre 24 h** : filtre natif LinkedIn `f_TPR` (recalculé selon `-Since`).
- **Alternance uniquement** + **finance uniquement** : filtres mots-clés (titre + description).
- **Durée 24 mois** : repérée automatiquement (`24 mois OK`), ou filtre strict avec `-Strict`.
- **Anti-doublon** : d'un passage à l'autre, seules les **nouvelles** offres sont mises en avant.
- **Zéro dépendance / zéro config** : un script PowerShell, déjà présent sur Windows.

---

## Installation + lancement — une commande

```bash
git clone https://github.com/dadaconda/Test-alternance.git
cd Test-alternance
.\run.cmd
```

(sous PowerShell, le préfixe `.\` est obligatoire ; équivalent : `powershell -ExecutionPolicy Bypass -File alternance.ps1`)

Pour essayer immédiatement avec un jeu d'exemple hors-ligne :

```bash
.\run.cmd -Demo
```

Résultat : un tableau dans le terminal + des fichiers dans `data/` :

| Fichier | Contenu |
|---|---|
| `data/latest.md` | Les offres, lisibles, avec liens LinkedIn |
| `data/latest.json` | Les offres structurées |
| `data/history.jsonl` | Journal de tous les passages |
| `data/seen.json` | Mémoire anti-doublon |

### Options

| Commande | Effet |
|---|---|
| `.\run.cmd` | Fenêtre 24 h, affiche les nouvelles offres |
| `.\run.cmd -Since 48` | Fenêtre de 48 h |
| `.\run.cmd -Strict` | Ne garde que les contrats explicitement **24 mois / 2 ans** |
| `.\run.cmd -All` | Affiche toutes les offres de la fenêtre (pas seulement les nouvelles) |
| `.\run.cmd -NoEnrich` | Plus rapide : ne télécharge pas le détail de chaque offre |
| `.\run.cmd -Pages 6` | Va chercher plus de pages par requête (défaut 4) |
| `.\run.cmd -Json` | Sortie JSON brute |
| `.\run.cmd -Demo` | Démo hors-ligne |

## Personnaliser la recherche — `config.json`

- `requetes` : liste `{ keywords, location }` envoyées à LinkedIn (mots-clés + lieu).
- `motsAlternance` : termes qui prouvent que l'offre est en alternance (cherchés dans le titre + l'entreprise).
- `motsFinanceTitre` : vocabulaire finance cherché **uniquement dans le titre** de l'offre
  (les descriptions sont trop bruitées et faisaient remonter des postes QSE/RH/paie…).
  Ajoute tes propres termes si tu veux élargir (ex. `"comptab"`, `"accountant"`, `"esg"`, `"data analyst"`).
- `enrichirDescription` : `true` = ouvre chaque offre retenue pour lire la description
  (sert surtout à détecter « 24 mois »), au prix de requêtes supplémentaires.
- `pagesMax`, `pauseMs`, `enrichMax` : volume et politesse des requêtes.

Chaque offre affiche le `mot-cle` finance qui l'a fait retenir — pratique pour ajuster la liste.

## Automatiser

### GitHub Actions (`.github/workflows/alternance.yml`)

S'exécute toutes les 3 h, recommit `data/latest.md`, affiche le résultat dans le résumé du job.
Pousser le repo, activer *Settings → Actions → General → Workflow permissions → Read and write*.

> ⚠️ LinkedIn bloque fréquemment les IP des serveurs GitHub. Le workflow ne casse pas en cas de
> blocage (`continue-on-error`), mais **l'exécution en local (chez toi) est bien plus fiable**.

### Planificateur de tâches Windows

```powershell
schtasks /Create /SC HOURLY /TN "Veille alternance finance" ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"%CD%\alternance.ps1\" -Quiet" /F
```

## Notifications Telegram (optionnel)

`copy .env.example .env`, renseigne `TELEGRAM_BOT_TOKEN` et `TELEGRAM_CHAT_ID` :
les **nouvelles** offres sont poussées dans le chat à chaque passage.

---

### Notes

- Le bot lit l'endpoint **public** `linkedin.com/jobs-guest/...` (pages d'offres visibles sans
  connexion). Reste raisonnable sur la fréquence : `pauseMs` impose une pause entre chaque requête.
- Sans connexion, LinkedIn n'expose pas de filtre « type de contrat » : le tri alternance se fait
  sur les mots-clés. Ajuste `motsFinance` / `motsExclure` dans `config.json` si le tri est trop
  large ou trop strict.
- La détection « 24 mois » lit titre + description ; par défaut les offres sans durée explicite
  sont **gardées** et marquées `durée à vérifier`. `-Strict` ne garde que les 24 mois certains.
- Si le bot ne renvoie rien et affiche un avertissement anti-robot : réessaie plus tard, ou
  augmente `pauseMs`.
