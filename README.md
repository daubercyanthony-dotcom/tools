# tools

Ce qui doit être téléchargeable **sans identifiant**. Le reste de la
plateforme vit dans un dépôt privé ; ce dépôt-ci ne contient que l'amorce, et
aucun secret — c'est précisément pourquoi il peut être public.

## Deux amorces, deux noms

Ce script monte **l'usine** : le compte, les paquets dont elle a besoin, le
dépôt privé, et les trois pièces qui la font tourner — **Claude Code** qui
écrit, **codex** qui relit, **le superviseur** qui enchaîne. Il n'installe pas
le labo — le labo s'installe par `install/all.sh apply`, dans le dépôt privé,
et pose lui-même ses propres prérequis Debian.

Les deux s'appelaient « bootstrap » et se confondaient. Celui-ci s'appelle
désormais `bootstrap-claude.sh` ; l'ancienne URL `bootstrap.sh` ne répond plus.

## `bootstrap-claude.sh` — monter une machine de travail en une fois

Sur une Debian fraîche, en root :

```bash
curl -fsSLO https://raw.githubusercontent.com/daubercyanthony-dotcom/tools/main/bootstrap-claude.sh
sudo bash bootstrap-claude.sh
```

Ou en une seule ligne, sans rien taper :

```bash
sudo bash bootstrap-claude.sh --c "jeton-claude" --g "jeton-github"
```

Il lui faut **deux jetons** :

| Jeton | Ce qu'il sert à faire | Portée conseillée |
|---|---|---|
| **Claude Code** | faire tourner l'agent | obtenu par `claude setup-token` sur ton poste |
| **GitHub** | cloner le dépôt privé et y pousser | *fine-grained*, ce seul dépôt, `Contents: read & write`, avec une date d'expiration |

Puis, sans rien demander d'autre : `curl git ca-certificates sudo npm`, le
compte de travail avec `sudo` sans mot de passe, les identifiants Git, le
clone du dépôt privé, Claude Code, le relecteur `codex` et son compte sans
pouvoir, et le superviseur attaché à systemd.

`npm` est la seule exception à la règle « rien que le strict nécessaire » :
`codex` est un paquet npm, et le relecteur fait partie de l'usine que ce
script monte. Ce n'est pas la liste de la plateforme qu'on recopie, c'est le
prérequis de ce qu'on installe.

**Un geste humain reste à faire, et un seul** : connecter le relecteur. Voir
« Après », plus bas — tant qu'il n'est pas fait, le labo tourne sans
relecture, sans erreur et sans avertissement.

**Ce script installe l'agent, pas la plateforme.** Docker, le client
PostgreSQL, `python3-venv`, `openssl` sont les prérequis de la plateforme :
c'est la session qui les installe, avec le `sudo` qu'on lui donne ici, et
c'est `install/socle.sh` qui possède la liste. Deux listes de paquets pour la
même machine finiraient par diverger, et l'écart ne se verrait que sur une
machine neuve, des semaines plus tard.

Attendu à la fin : la ligne `BOOTSTRAP_OK`.

### Trois façons de les donner

| | Comment | Ce que ça coûte |
|---|---|---|
| **Au clavier** | `sudo bash bootstrap-claude.sh` | rien ; invisible à la frappe, rien dans `ps`, rien dans l'historique |
| **Par fichier** | `--c @/chemin/jeton --g @/chemin/autre` | rien non plus : c'est le fichier qui est lu, pas la ligne de commande |
| **En clair** | `--c "…" --g "…"` | le plus rapide. Le jeton est visible dans `ps` le temps de l'installation, et reste dans l'historique de ton shell |

Les variables `ADLAB_CLAUDE_TOKEN` et `ADLAB_GITHUB_TOKEN` font la même chose
que les options sans passer par la ligne de commande.

La troisième forme existe parce qu'elle est pratique, et le script ne fait pas
semblant qu'elle est gratuite : quand un jeton arrive en clair, il te rappelle
à la fin comment le sortir de l'historique. Sur une machine jetable à un seul
utilisateur, dont les jetons sont dédiés et révocables, c'est un risque faible
et assumé.

### Ce qu'il fait des jetons

- Aucun n'est affiché, ni au clavier, ni dans la sortie, ni dans le journal.
- Le jeton GitHub va dans `~/.git-credentials` (0600) ; le jeton Claude dans
  `/etc/daubercy-lab/cycle.env` (0600, root), lu par systemd avant qu'il ne
  descende sur le compte de travail. Ni l'un ni l'autre n'est écrit dans une
  unité systemd, dans `~/.bashrc`, ou dans Git.
- Les deux sont **éprouvés, pas supposés** : le jeton GitHub par le clone, le
  jeton Claude par une vraie question posée à l'agent. Un jeton faux casse
  l'installation à l'endroit exact où il est faux, avec un message qui le dit.

### Réglages

| Variable | Défaut | |
|---|---|---|
| `ADLAB_USER` | `lab` | compte de travail |
| `ADLAB_REPO_DIR` | `/opt/platform` | où cloner |
| `ADLAB_REPO_URL` | le dépôt privé `platform` | quoi cloner |
| `ADLAB_CLAUDE_TOKEN` | — | évite la saisie au clavier |
| `ADLAB_GITHUB_TOKEN` | — | idem |

## Ce que ça suppose

Une machine **jetable**. Le script crée un compte avec `sudo` sans mot de
passe et y fait tourner un agent en régime non interactif : ça ne se défend
que sur une machine qu'on réinstalle sans regret, qui ne porte aucun secret de
production, et dont les jetons sont dédiés et révocables.

Enlève une seule de ces conditions et ce script n'est plus défendable.

## Après — connecter le relecteur

**C'est le seul geste que l'amorce ne peut pas faire.** `codex login
--device-auth` affiche un code court qu'un humain approuve depuis un autre
appareil : approuver un code, c'est prouver une identité, et un processus sans
humain ne le fait pas. `install/codex.sh apply` prépare tout et **imprime la
commande exacte** — avec le bon `CODEX_HOME` — à la fin de son passage.

L'autorisation par code d'appareil doit être activée dans les réglages de
sécurité du compte, sinon la commande refuse.

Puis :

```bash
sudo bash /opt/platform/install/codex.sh doctor
```

Tant que ce geste n'est pas fait, la règle `sur_revue_absente = ENCHAINER`
laisse passer **chaque** cycle sans relecture, sans erreur et sans
avertissement. C'est le comportement prévu ; il n'apparaîtra dans aucun
journal.

## Après — la file

Le superviseur lit `work/*.md` dans le dépôt, lance **un** cycle, le fait
relire, instruit les objections, puis passe au suivant. Les consignes arrivent
par Git. Ce qui a tourné descend dans `work/archive/` : `work/` ne porte que
ce qui reste à faire, et c'est ce qu'une machine neuve lira.

```bash
journalctl -fu daubercy-superviseur.service          # suivre en direct
sudo bash /opt/platform/install/superviseur.sh doctor
sudo bash /opt/platform/install/superviseur.sh essai      # un tour, visible
sudo bash /opt/platform/install/superviseur.sh revenir    # retour à la veille
```

Il a remplacé la veille (`daubercy-cycle.service`) le 2026-09-18 : celle-ci
enchaînait les cycles **sans les faire relire**. Une unité `daubercy-cycle`
en `failed` sur une machine à jour n'est pas une panne — c'est l'unité
retirée.

### Il reste le labo à installer

```bash
sudo bash /opt/platform/install/all.sh apply
```

Un étage mérite d'être nommé : **`codex`, le relecteur que le superviseur
appelle**. Sans lui, la règle « sur revue absente : enchaîner » s'applique à
chaque cycle, et le labo livre du code que personne n'a relu. Ça n'apparaît
dans aucun message d'erreur : c'est le comportement prévu.
