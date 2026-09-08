# Veille alternance — Master Finance (risques / analyse financière)

Bot qui va chercher **les offres d'alternance publiées dans les dernières 24 h** (fenêtre
glissante) correspondant à un **Master Finance** : gestion des risques, analyse financière,
contrôle de gestion, conformité, audit, trésorerie, marchés…

- **Source** : API officielle *« Offres d'emploi v2 »* de **France Travail** — elle agrège
  Pôle Emploi + la plupart des jobboards partenaires (Apec, HelloWork, Indeed, LinkedIn…).
- **Contrats retenus** : apprentissage (`E2`) **et** professionnalisation (`FS`).
- **Durée 24 mois** : repérée automatiquement (marqueur `24 mois OK`), ou filtre strict avec `-Strict`.
- **Anti-doublon** : d'un passage à l'autre, seules les **nouvelles** offres sont mises en avant.
- **Zéro dépendance** : un script PowerShell (déjà présent sur Windows). Rien à installer.

---

## 1. Pré-requis : une clé API France Travail (gratuit, 2 min)

1. Créer un compte sur <https://francetravail.io> → **« Mes applications »** → **Créer une application**.
2. Dans l'application, **s'abonner à l'API « Offres d'emploi v2 »**.
3. Noter l'**Identifiant client** et la **Clé secrète**.

## 2. Installation en une commande

```bash
git clone https://github.com/dadaconda/Test-alternance.git
cd Test-alternance
copy .env.example .env
```

Ouvre `.env` et colle tes identifiants :

```
FT_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
FT_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 3. Lancer — LA commande

```bash
run.cmd
```

(équivalent : `powershell -ExecutionPolicy Bypass -File alternance.ps1`)

Sortie : tableau dans le terminal + fichiers dans `data/` :

| Fichier | Contenu |
|---|---|
| `data/latest.md` | Les offres, lisibles, avec liens |
| `data/latest.json` | Les offres structurées (pour réutilisation) |
| `data/history.jsonl` | Journal de tous les passages |
| `data/seen.json` | Mémoire des offres déjà vues (anti-doublon) |

### Options

| Commande | Effet |
|---|---|
| `run.cmd` | Fenêtre 24 h, affiche les nouvelles offres |
| `run.cmd -Since 48` | Fenêtre de 48 h |
| `run.cmd -Strict` | Ne garde que les contrats explicitement **24 mois / 2 ans** |
| `run.cmd -All` | Affiche toutes les offres de la fenêtre (pas seulement les nouvelles) |
| `run.cmd -Departements "75,92,93,94"` | Restreint à des départements |
| `run.cmd -Json` | Sortie JSON brute (pipeline / intégration) |
| `run.cmd -Demo` | Démo hors-ligne avec un jeu d'exemple (aucune clé requise) |

Essaie tout de suite sans clé :

```bash
run.cmd -Demo
```

## 4. Personnaliser la recherche

Tout est dans [`config.json`](config.json) :

- `fenetreHeures` : taille de la fenêtre glissante (24 par défaut).
- `codesRome` : codes métier ciblés (C1201, C1202, M1201, M1202, M1204).
- `motsClesRequetes` : requêtes plein-texte lancées sur l'API.
- `motsFinance` : mots-clés qui qualifient une offre comme « finance » (filtre côté client).
- `motsExclure` : termes qui écartent une offre (ex. `stagiaire`).
- `departements` : liste par défaut (vide = toute la France).

## 5. Automatiser (exécution planifiée)

### Option A — GitHub Actions (recommandé, tourne dans le cloud)

Le workflow [`.github/workflows/alternance.yml`](.github/workflows/alternance.yml) s'exécute
**toutes les heures**, recommite `data/latest.md` et affiche le résultat dans le résumé du job.

1. Pousser le repo sur GitHub.
2. **Settings → Secrets and variables → Actions** → ajouter `FT_CLIENT_ID` et `FT_CLIENT_SECRET`
   (et éventuellement `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`).
3. **Settings → Actions → General → Workflow permissions** → *Read and write permissions*.
4. Onglet **Actions** → *Veille alternance finance* → *Run workflow* pour un premier essai.

### Option B — Planificateur de tâches Windows

```powershell
schtasks /Create /SC HOURLY /TN "Veille alternance finance" ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"%CD%\alternance.ps1\" -Quiet" /F
```

## 6. Notifications Telegram (optionnel)

Renseigne `TELEGRAM_BOT_TOKEN` et `TELEGRAM_CHAT_ID` dans `.env` (ou en secrets GitHub) :
à chaque passage, les **nouvelles** offres sont envoyées dans le chat.
Token via [@BotFather](https://t.me/BotFather), `chat_id` via [@userinfobot](https://t.me/userinfobot).

---

### Notes

- « 24 h glissantes » = `minCreationDate = maintenant − 24 h`, `maxCreationDate = maintenant`
  (paramètres natifs de l'API). Relance le bot aussi souvent que tu veux : l'anti-doublon
  évite de revoir les mêmes offres.
- La détection « 24 mois » lit le titre + la description ; par défaut les offres sans durée
  explicite sont **gardées** et marquées `durée à vérifier`. Utilise `-Strict` pour ne
  garder que les 24 mois certains.
- API France Travail : usage gratuit, ~1 M d'appels/mois, réservé à un usage non commercial.
