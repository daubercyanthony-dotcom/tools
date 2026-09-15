# tools

Ce qui doit être téléchargeable **sans identifiant**. Le reste de la
plateforme vit dans un dépôt privé ; ce dépôt-ci ne contient que l'amorce, et
aucun secret — c'est précisément pourquoi il peut être public.

## `bootstrap.sh` — monter une machine de travail en une fois

Sur une Debian fraîche, en root :

```bash
curl -fsSLO https://raw.githubusercontent.com/daubercyanthony-dotcom/tools/main/bootstrap.sh
sudo bash bootstrap.sh
```

Ou en une seule ligne, sans rien taper :

```bash
sudo bash bootstrap.sh --c "jeton-claude" --g "jeton-github"
```

Il lui faut **deux jetons** :

| Jeton | Ce qu'il sert à faire | Portée conseillée |
|---|---|---|
| **Claude Code** | faire tourner l'agent | obtenu par `claude setup-token` sur ton poste |
| **GitHub** | cloner le dépôt privé et y pousser | *fine-grained*, ce seul dépôt, `Contents: read & write`, avec une date d'expiration |

Puis, sans rien demander d'autre : les paquets (docker, compose, client
PostgreSQL, python3-venv, openssl), le compte de travail avec `sudo` sans mot
de passe, les identifiants Git, le clone du dépôt privé, Claude Code, et la
veille attachée à systemd.

Attendu à la fin : la ligne `BOOTSTRAP_OK`.

### Trois façons de les donner

| | Comment | Ce que ça coûte |
|---|---|---|
| **Au clavier** | `sudo bash bootstrap.sh` | rien ; invisible à la frappe, rien dans `ps`, rien dans l'historique |
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

## Après

Rien à faire sur la machine. La veille surveille `WORK.md` dans le dépôt et
lance un cycle dès que la consigne change — la consigne arrive par Git.

```bash
journalctl -fu daubercy-cycle.service          # suivre en direct
sudo bash /opt/platform/install/service.sh doctor
sudo bash /opt/platform/install/service.sh stop
```
