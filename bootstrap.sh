#!/usr/bin/env bash
# Monte une machine de travail AD Lab sur une Debian fraîche, en une fois.
#
# Deux jetons suffisent : celui de Claude Code et celui de GitHub. Aucun n'est
# passé en argument (une ligne de commande se lit dans « ps »), aucun n'est
# affiché, aucun n'atterrit dans l'historique du shell.
#
#   sudo bash bootstrap.sh
#
# À lancer en root sur une machine JETABLE. Il crée un compte avec « sudo »
# sans mot de passe et y fait tourner un agent en régime non interactif : ça ne
# se défend que sur une machine qu'on réinstalle sans regret.
set -Eeuo pipefail

readonly USER_NAME="${ADLAB_USER:-lab}"
readonly REPO_DIR="${ADLAB_REPO_DIR:-/opt/platform}"
readonly REPO_URL="${ADLAB_REPO_URL:-https://github.com/daubercyanthony-dotcom/platform}"
readonly RUNTIME_DIR="${ADLAB_RUNTIME_DIR:-/etc/daubercy-lab}"
readonly ENV_FILE="$RUNTIME_DIR/cycle.env"

log()   { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die()   { printf '\nERREUR : %s\n' "$*" >&2; exit 2; }
title() { printf '\n== %s ==\n' "$*"; }
say()   { printf '%s\n' "$*"; }

# Sans ça, une commande qui échoue tue le script sur son seul message d'erreur
# et « BOOTSTRAP_OK » manque à l'appel — ce qui se remarque si on lit la fin,
# et pas du tout si on lit en diagonale. Le premier vrai passage a buté
# exactement là-dessus : un helper non défini, sur la dernière ligne utile.
trap 'printf "\nBOOTSTRAP_ECHEC : ligne %s, code %s. Rien de plus n'"'"'a été fait.\n" "$LINENO" "$?" >&2' ERR
note()  { printf '  %s\n' "$*"; }

# Lecture silencieuse depuis le terminal et non depuis l'entrée standard : le
# script peut arriver par un tube (« curl … | bash »), auquel cas « read »
# mangerait le script lui-même.
ask_secret() {
  local label="$1" answer=''
  [[ -r /dev/tty ]] || die "pas de terminal pour saisir « $label » ; utiliser la variable d'environnement"
  printf '  %s : ' "$label" >&2
  read -rs answer </dev/tty
  printf '\n' >&2
  printf '%s' "$answer"
}

as_user() { sudo -u "$USER_NAME" -H bash -lc "$1"; }

usage() {
  cat <<'TEXT'
Usage : sudo bash bootstrap.sh [options]

  --c VALEUR     jeton Claude Code      (aussi : --claude, --c=VALEUR)
  --g VALEUR     jeton GitHub           (aussi : --github, --g=VALEUR)
  -h, --help     ce message

Trois façons de donner un jeton, de la plus sûre à la plus rapide :

  1. Rien du tout      le script les demande au clavier, invisibles à la frappe
  2. Un fichier        --c @/chemin/jeton-claude     (le fichier est lu, pas la
                       ligne de commande : rien dans « ps », rien dans l'historique)
  3. En clair          --c "sk-…"                   le plus rapide

La troisième laisse le jeton dans « ps » le temps de l'installation et dans
l'historique de ton shell ensuite. Sur une machine jetable à un seul
utilisateur c'est un risque faible et assumé — le script te dira comment
effacer l'historique à la fin.

Les variables ADLAB_CLAUDE_TOKEN et ADLAB_GITHUB_TOKEN font la même chose que
les options, sans passer par la ligne de commande.
TEXT
}

# Un jeton donné par « @fichier » est lu dans le fichier : c'est le compromis
# qui garde la rapidité d'une option sans l'exposition d'un argument.
depuis_option() {
  local valeur="$1"
  if [[ "$valeur" == @* ]]; then
    local fichier="${valeur#@}"
    [[ -r "$fichier" ]] || die "fichier de jeton illisible : $fichier"
    # Sans le saut de ligne final : il ferait partie de la valeur.
    printf '%s' "$(<"$fichier")"
  else
    printf '%s' "$valeur"
  fi
}

opt_claude=''
opt_github=''
en_clair=0

while (($#)); do
  case "$1" in
    --c|--claude|-c)
      [[ $# -ge 2 ]] || die "$1 attend une valeur"
      [[ "$2" == @* ]] || en_clair=1
      opt_claude="$(depuis_option "$2")"; shift 2 ;;
    --c=*|--claude=*)
      [[ "${1#*=}" == @* ]] || en_clair=1
      opt_claude="$(depuis_option "${1#*=}")"; shift ;;
    --g|--github|-g)
      [[ $# -ge 2 ]] || die "$1 attend une valeur"
      [[ "$2" == @* ]] || en_clair=1
      opt_github="$(depuis_option "$2")"; shift 2 ;;
    --g=*|--github=*)
      [[ "${1#*=}" == @* ]] || en_clair=1
      opt_github="$(depuis_option "${1#*=}")"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue : $1" ;;
  esac
done

# ---------------------------------------------------------------- 0. contrôles

[[ "$(id -u)" == 0 ]] || die 'à lancer en root (sudo bash bootstrap.sh)'
command -v apt-get >/dev/null || die 'machine non Debian/Ubuntu : apt-get absent'

title 'Ce qui va être installé'
note "Compte de travail   $USER_NAME, avec sudo sans mot de passe"
note "Dépôt               $REPO_URL → $REPO_DIR"
note 'Paquets             curl, git, ca-certificates, sudo — et rien de plus'
note 'Agent               Claude Code, lancé en veille par systemd'
note "Jetons              $ENV_FILE et ~$USER_NAME/.git-credentials, en 0600"

# ------------------------------------------------------------------ 1. jetons

title 'Jetons'
claude_token="${opt_claude:-${ADLAB_CLAUDE_TOKEN:-}}"
github_token="${opt_github:-${ADLAB_GITHUB_TOKEN:-}}"
[[ -n "$claude_token" ]] || claude_token="$(ask_secret 'Jeton Claude Code (invisible à la frappe)')"
[[ -n "$github_token" ]] || github_token="$(ask_secret 'Jeton GitHub (invisible à la frappe)')"
[[ -n "$claude_token" ]] || die 'jeton Claude Code vide'
[[ -n "$github_token" ]] || die 'jeton GitHub vide'
note 'Les deux jetons sont en mémoire ; ils ne seront ni affichés ni journalisés.'
if ((en_clair)); then
  note 'Un jeton est arrivé en clair sur la ligne de commande : voir le rappel à la fin.'
fi

# ----------------------------------------------------------------- 2. paquets

title 'Paquets'
# Le strict nécessaire pour cloner le dépôt et poser l'agent, et rien d'autre.
# Docker, le client PostgreSQL, python3-venv, openssl : ce sont les prérequis
# de la PLATEFORME, pas de cette amorce. C'est la session qui les installe,
# avec le « sudo » qu'on lui donne plus bas, et c'est « install/socle.sh » qui
# possède la liste. Deux listes de paquets pour la même machine finiraient par
# diverger, et l'écart ne se verrait que sur une machine neuve, des semaines
# plus tard.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git ca-certificates sudo >/dev/null
note 'curl, git, ca-certificates, sudo'
note 'Le reste appartient à la plateforme : la session l’installera elle-même.'

# ------------------------------------------------------------------ 3. compte

title 'Compte de travail'
if id -u "$USER_NAME" >/dev/null 2>&1; then
  note "$USER_NAME existe déjà, conservé"
else
  useradd --create-home --shell /bin/bash "$USER_NAME"
  note "$USER_NAME créé"
fi
# C'est CE droit qui rend l'amorce suffisante : la session installera tout le
# reste elle-même. Sans lui, il faudrait tout prévoir ici, et on serait de
# nouveau à deux endroits pour la même chose.
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" >"/etc/sudoers.d/$USER_NAME"
chmod 0440 "/etc/sudoers.d/$USER_NAME"
note 'sudo sans mot de passe — de quoi installer le reste sans repasser par ici'

home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[[ -n "$home" ]] || die "pas de répertoire personnel pour $USER_NAME"

# ------------------------------------------------------- 4. identifiants Git

title 'Identifiants Git'
umask 077
credentials="$home/.git-credentials"
# Forme « x-access-token:<jeton> », celle qu'utilise GitHub Actions ; elle vaut
# pour les jetons classiques comme pour les jetons à portée fine. On ne la
# suppose pas : le clone qui suit la met à l'épreuve tout de suite.
printf 'https://x-access-token:%s@github.com\n' "$github_token" >"$credentials"
chown "$USER_NAME:$USER_NAME" "$credentials"
chmod 0600 "$credentials"
as_user "git config --global credential.helper store"
as_user "git config --global user.name 'AD Lab'"
as_user "git config --global user.email '$USER_NAME@$(hostname -f 2>/dev/null || hostname)'"
note "$credentials en 0600 ; le jeton n'est écrit nulle part ailleurs"

# --------------------------------------------------------------- 5. le dépôt

title 'Dépôt'
install -d -o "$USER_NAME" -g "$USER_NAME" "$REPO_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  as_user "git -C '$REPO_DIR' pull --ff-only" \
    || die "le dépôt existe mais ne se met pas à jour ; le regarder avant de continuer"
  note 'dépôt déjà présent, mis à jour'
else
  # Premier vrai essai du jeton GitHub. S'il est faux, ça casse ici, avec un
  # message clair, et rien d'autre n'a encore été démarré.
  as_user "git clone --quiet '$REPO_URL' '$REPO_DIR'" \
    || die "clone impossible : jeton GitHub invalide, expiré, ou sans accès à ce dépôt"
  note "cloné dans $REPO_DIR"
fi
chown -R "$USER_NAME:$USER_NAME" "$REPO_DIR"

# --------------------------------------------------------- 6. l'agent Claude

title 'Claude Code'
if as_user "test -x '$home/.local/bin/claude'"; then
  note 'déjà installé, conservé'
else
  as_user "curl -fsSL https://claude.ai/install.sh | bash" >/dev/null \
    || die "installation de Claude Code impossible"
fi
if ! grep -q '.local/bin' "$home/.bashrc" 2>/dev/null; then
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' >>"$home/.bashrc"
  chown "$USER_NAME:$USER_NAME" "$home/.bashrc"
fi
version="$(as_user "'$home/.local/bin/claude' --version" 2>/dev/null || true)"
[[ -n "$version" ]] || die "« claude --version » ne répond pas"
note "$version"

# « --version » ne prouve que l'installation. Une seule vraie question prouve
# le jeton, et c'est la différence entre « installé » et « éprouvé ». Le jeton
# passe par l'environnement du processus, jamais par la ligne de commande :
# « ps » ne montrera que « sudo -u … bash -lc … ».
note 'Première question posée à l’agent, pour éprouver le jeton…'
reponse="$(CLAUDE_CODE_OAUTH_TOKEN="$claude_token" \
  sudo -u "$USER_NAME" -H --preserve-env=CLAUDE_CODE_OAUTH_TOKEN \
  bash -lc "'$home/.local/bin/claude' -p 'Réponds exactement ce mot et rien d’autre : PRET'" 2>&1 || true)"
if [[ "$reponse" != *PRET* ]]; then
  printf '%s\n' "$reponse" >&2
  die 'l’agent n’a pas répondu : jeton Claude Code invalide, expiré, ou accès réseau bloqué'
fi
note 'Jeton Claude Code accepté, réponse obtenue'

# ------------------------------------------------------------- 7. le service

title 'Veille'
install -d -m 0700 "$RUNTIME_DIR"
temporary="$ENV_FILE.tmp"
rm -f "$temporary"
install -m 0600 /dev/null "$temporary"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$claude_token" >"$temporary"
mv -f "$temporary" "$ENV_FILE"
note "jeton Claude dans $ENV_FILE, 0600, root seulement"

unset claude_token github_token

bash "$REPO_DIR/install/service.sh" apply

title 'Terminé'
note "Journal en direct    journalctl -fu daubercy-cycle.service"
note "Contrôles            sudo bash $REPO_DIR/install/service.sh doctor"
note "Arrêter la veille    sudo bash $REPO_DIR/install/service.sh stop"
printf '\n'
note 'La veille ne lancera un cycle que si WORK.md change dans le dépôt.'
note 'Rien à faire sur cette machine : la consigne arrive par Git.'

if ((en_clair)); then
  title 'Un dernier geste'
  say "Un jeton est passé en clair sur la ligne de commande. Il n'est plus dans"
  say "« ps » — le script se termine — mais il est dans l'historique de ton"
  say 'shell. Pour l’en sortir, dans le shell où tu as tapé la commande :'
  printf '\n    history -d $((HISTCMD-1)) 2>/dev/null; history -c; history -w\n\n'
  say 'La prochaine fois, « --c @/chemin/fichier » évite le problème à la source,'
  say 'et « --c » sans valeur en environnement le demande au clavier.'
  say 'Et de toute façon : ces jetons sont révocables, révoque-les quand la'
  say 'machine part à la poubelle.'
fi
log 'BOOTSTRAP_OK'
