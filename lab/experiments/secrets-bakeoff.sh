#!/usr/bin/env bash
# =============================================================================
# lab/experiments/secrets-bakeoff.sh — the same scenario for every way of keeping secrets in a Git repository
#
# Candidates: sops+age, git-crypt, pass, ansible-vault. Everything runs in a temporary directory with a throwaway
# GPG home, so your own keyring and repositories are never touched. Tools are looked for on PATH and in
# $TIDEPOOL_TOOLS (default ~/lab/tidepool/tools); none needs root.
#
# The scenario, for each candidate (secrets are random canary strings so a leak can be found by grep):
#   T1  no canary appears in any commit of the repository, raw blobs included
#   T2  a fresh clone plus ONLY the key gives back every secret (the workstation is lost, the key is not)
#   T3  a fresh clone WITHOUT the key gives back nothing
#   T4  what a reader of the repository can see: the names of the secrets? of the files?
#   T5  the key is replaced with a new one: the new key works, the old key does not read the new content
#
# Usage: lab/experiments/secrets-bakeoff.sh [sops|git-crypt|pass|vault ...]   (no argument: all)
# =============================================================================
set -uo pipefail

TOOLS="${TIDEPOOL_TOOLS:-$HOME/lab/tidepool/tools}"
PY_VENV="${TIDEPOOL_ANSIBLE_VENV:-$HOME/lab/tidepool/ansible-venv}"
export PATH="$TOOLS:$PY_VENV/bin:$PATH"
PASS="bash $(ls "$TOOLS"/password-store-*/src/password-store.sh 2>/dev/null | head -1)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GNUPGHOME="$WORK/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

DB=$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')
SMTP=$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')
BORG=$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')
PLAIN="DB_PASSWORD: $DB
SMTP_PASSWORD: $SMTP
BORG_PASSPHRASE: $BORG"

declare -A RESULT
say() { printf '  %-5s %-4s %s\n' "$1" "$2" "$3"; RESULT["$1/$2"]="$3"; }
ok()  { say "$1" "$2" "PASS $3"; }
bad() { say "$1" "$2" "FAIL $3"; }

gitq() { git -c user.name=lab -c user.email=lab@example.invalid -c commit.gpgsign=false "$@"; }
leaks() { # leaks <repo>: number of canaries found in the raw blobs of every commit
    local r="$1" n=0 c revs
    for c in "$DB" "$SMTP" "$BORG"; do
        mapfile -t revs < <(git -C "$r" rev-list --all)
        git -C "$r" grep -a -q "$c" "${revs[@]}" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}
new_gpg_key() { # new_gpg_key <name>: throwaway key without passphrase, prints its fingerprint
    gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key "$1 <$1@example.invalid>" default default 0 >/dev/null 2>&1
    gpg --list-keys --with-colons "$1@example.invalid" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'
}
all_found() { # all_found <text>: are the three canaries in the text?
    [[ "$1" == *"$DB"* && "$1" == *"$SMTP"* && "$1" == *"$BORG"* ]]
}
none_found() { [[ "$1" != *"$DB"* && "$1" != *"$SMTP"* && "$1" != *"$BORG"* ]]; }

# ---------------------------------------------------------------- negative control
# Secrets committed in clear text. T1 and T3 MUST fail here: if they do not, the tests cannot be trusted.
cand_plain() {
    local n=plain d="$WORK/plain" out
    mkdir -p "$d"; git -C "$d" init -q
    echo "$PLAIN" > "$d/secrets.yaml"
    gitq -C "$d" add -A; gitq -C "$d" commit -q -m secrets
    [ "$(leaks "$d")" = 0 ] && ok $n T1 "no canary in any commit" || bad $n T1 "canary found in the repository"
    git clone -q "$d" "$WORK/plain-clone"
    out=$(cat "$WORK/plain-clone/secrets.yaml")
    none_found "$out" && ok $n T3 "no key, no secrets" || bad $n T3 "secrets readable without the key"
}

# ---------------------------------------------------------------- sops + age
cand_sops() {
    local n=sops d="$WORK/sops" k="$WORK/sops-key1" k2="$WORK/sops-key2" out r2 pub
    age-keygen -o "$k" >/dev/null 2>&1; pub=$(age-keygen -y "$k")
    mkdir -p "$d"; git -C "$d" init -q
    printf 'creation_rules:\n  - path_regex: secrets\\.yaml$\n    age: %s\n' "$pub" > "$d/.sops.yaml"
    echo "$PLAIN" > "$WORK/plain.yaml"
    (cd "$d" && SOPS_AGE_KEY_FILE="$k" sops --encrypt --filename-override secrets.yaml "$WORK/plain.yaml" > secrets.yaml)
    gitq -C "$d" add -A; gitq -C "$d" commit -q -m secrets
    # T1
    [ "$(leaks "$d")" = 0 ] && ok $n T1 "no canary in any commit" || bad $n T1 "canary found in the repository"
    # T2 / T3
    git clone -q "$d" "$WORK/sops-clone"
    out=$(cd "$WORK/sops-clone" && SOPS_AGE_KEY_FILE="$k" sops --decrypt secrets.yaml 2>&1)
    all_found "$out" && ok $n T2 "fresh clone + key gives every secret" || bad $n T2 "restore failed"
    out=$(cd "$WORK/sops-clone" && SOPS_AGE_KEY_FILE="$WORK/none" sops --decrypt secrets.yaml 2>&1)
    none_found "$out" && ok $n T3 "no key, no secrets" || bad $n T3 "secrets readable without the key"
    # T4
    out=$(git -C "$d" show HEAD:secrets.yaml)
    [[ "$out" == *DB_PASSWORD* ]] && say $n T4 "INFO names of the secrets are visible (values are not); one line changes when one value changes"
    # T5: replace the recipient, re-encrypt
    age-keygen -o "$k2" >/dev/null 2>&1; r2=$(age-keygen -y "$k2")
    printf 'creation_rules:\n  - path_regex: secrets\\.yaml$\n    age: %s\n' "$r2" > "$d/.sops.yaml"
    (cd "$d" && SOPS_AGE_KEY_FILE="$k" sops updatekeys --yes secrets.yaml >/dev/null 2>&1)
    gitq -C "$d" commit -q -am rotate
    out=$(cd "$d" && SOPS_AGE_KEY_FILE="$k2" sops --decrypt secrets.yaml 2>&1)
    local old; old=$(cd "$d" && SOPS_AGE_KEY_FILE="$k" sops --decrypt secrets.yaml 2>&1)
    if all_found "$out" && none_found "$old"; then ok $n T5 "one command (sops updatekeys): new key reads, old key does not"; else bad $n T5 "rotation did not work"; fi
}

# ---------------------------------------------------------------- git-crypt
cand_git_crypt() {
    local n=git-crypt d="$WORK/gc" fpr fpr2 out
    fpr=$(new_gpg_key gc1)
    mkdir -p "$d"; git -C "$d" init -q
    (cd "$d" && git-crypt init >/dev/null 2>&1 && git-crypt add-gpg-user --trusted "$fpr" >/dev/null 2>&1)
    printf 'secrets.yaml filter=git-crypt diff=git-crypt\n.gitattributes !filter !diff\n' > "$d/.gitattributes"
    echo "$PLAIN" > "$d/secrets.yaml"
    gitq -C "$d" add -A; gitq -C "$d" commit -q -m secrets
    [ "$(leaks "$d")" = 0 ] && ok $n T1 "no canary in any commit (blobs are encrypted)" || bad $n T1 "canary found in the repository"
    # T2: a fresh clone is locked; unlock with the key
    git clone -q "$d" "$WORK/gc-clone" 2>/dev/null
    out=$(cd "$WORK/gc-clone" && cat secrets.yaml 2>&1)
    none_found "$out" && ok $n T3 "locked clone shows no secrets" || bad $n T3 "secrets readable in a locked clone"
    (cd "$WORK/gc-clone" && git-crypt unlock >/dev/null 2>&1)
    out=$(cd "$WORK/gc-clone" && cat secrets.yaml 2>&1)
    all_found "$out" && ok $n T2 "fresh clone + GPG key gives every secret" || bad $n T2 "restore failed"
    out=$(git -C "$d" show HEAD:secrets.yaml | head -c 40 | od -c | head -1)
    say $n T4 "INFO the file is one opaque binary blob: no names, one changed value rewrites the whole file"
    # T5: adding a user is easy, removing one is not (the symmetric key stays the same)
    fpr2=$(new_gpg_key gc2)
    (cd "$d" && git-crypt add-gpg-user --trusted "$fpr2" >/dev/null 2>&1)
    say $n T5 "LIMIT can add a recipient with one command, but cannot remove one: the repository key stays the same. Real rotation means a new repository or a rewritten history"
}

# ---------------------------------------------------------------- pass
cand_pass() {
    local n=pass d="$WORK/pass" fpr fpr2 out
    fpr=$(new_gpg_key pass1)
    export PASSWORD_STORE_DIR="$d"
    $PASS init "$fpr" >/dev/null 2>&1
    git -C "$d" init -q
    printf '%s' "$DB" | $PASS insert -e -f prod/db_password >/dev/null 2>&1
    printf '%s' "$SMTP" | $PASS insert -e -f prod/smtp_password >/dev/null 2>&1
    printf '%s' "$BORG" | $PASS insert -e -f prod/borg_passphrase >/dev/null 2>&1
    gitq -C "$d" add -A; gitq -C "$d" commit -q -m secrets
    [ "$(leaks "$d")" = 0 ] && ok $n T1 "no canary in any commit" || bad $n T1 "canary found in the repository"
    git clone -q "$d" "$WORK/pass-clone"
    export PASSWORD_STORE_DIR="$WORK/pass-clone"
    out="$($PASS show prod/db_password 2>&1) $($PASS show prod/smtp_password 2>&1) $($PASS show prod/borg_passphrase 2>&1)"
    all_found "$out" && ok $n T2 "fresh clone + GPG key gives every secret" || bad $n T2 "restore failed"
    # T3: same clone, but a GPG home without the private key
    local saved="$GNUPGHOME"; export GNUPGHOME="$WORK/gnupg-empty"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    out="$($PASS show prod/db_password 2>&1) $($PASS show prod/smtp_password 2>&1)"
    export GNUPGHOME="$saved"
    none_found "$out" && ok $n T3 "no key, no secrets" || bad $n T3 "secrets readable without the key"
    say $n T4 "INFO one file per secret, and the FILE NAMES are visible (prod/db_password); a changed value rewrites only that file"
    # T5: re-initialise with a new key: every entry is re-encrypted
    fpr2=$(new_gpg_key pass2)
    export PASSWORD_STORE_DIR="$d"
    $PASS init "$fpr2" >/dev/null 2>&1
    out="$($PASS show prod/db_password 2>&1)"
    [[ "$out" == *"$DB"* ]] && ok $n T5 "one command (pass init <new key>) re-encrypts every entry" || bad $n T5 "rotation did not work"
    unset PASSWORD_STORE_DIR
}

# ---------------------------------------------------------------- ansible-vault
cand_vault() {
    local n=vault d="$WORK/vault" k="$WORK/vault-pw1" k2="$WORK/vault-pw2" out
    head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$k"
    head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$k2"
    mkdir -p "$d"; git -C "$d" init -q
    echo "$PLAIN" > "$d/secrets.yaml"
    ansible-vault encrypt --vault-password-file "$k" "$d/secrets.yaml" >/dev/null 2>&1
    gitq -C "$d" add -A; gitq -C "$d" commit -q -m secrets
    [ "$(leaks "$d")" = 0 ] && ok $n T1 "no canary in any commit" || bad $n T1 "canary found in the repository"
    git clone -q "$d" "$WORK/vault-clone"
    out=$(ansible-vault view --vault-password-file "$k" "$WORK/vault-clone/secrets.yaml" 2>&1)
    all_found "$out" && ok $n T2 "fresh clone + vault password gives every secret" || bad $n T2 "restore failed"
    out=$(ansible-vault view --vault-password-file "$k2" "$WORK/vault-clone/secrets.yaml" 2>&1)
    none_found "$out" && ok $n T3 "wrong password, no secrets" || bad $n T3 "secrets readable without the password"
    say $n T4 "INFO the file is one opaque text blob (\$ANSIBLE_VAULT header): no names, one changed value rewrites the whole file"
    cp "$WORK/vault-clone/secrets.yaml" "$WORK/v.bak"
    (cd "$d" && ansible-vault rekey --vault-password-file "$k" --new-vault-password-file "$k2" secrets.yaml >/dev/null 2>&1)
    out=$(ansible-vault view --vault-password-file "$k2" "$d/secrets.yaml" 2>&1)
    local old; old=$(ansible-vault view --vault-password-file "$k" "$d/secrets.yaml" 2>&1)
    if all_found "$out" && none_found "$old"; then ok $n T5 "one command (ansible-vault rekey); one shared password, no per-person keys"; else bad $n T5 "rotation did not work"; fi
}

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(sops git-crypt pass vault)
# The control always runs first
echo "== plain (negative control: T1 and T3 must FAIL)"
cand_plain
if [[ "${RESULT[plain/T1]}" == FAIL* && "${RESULT[plain/T3]}" == FAIL* ]]; then
    echo "  control OK: the tests do detect a leak"
else
    echo "  CONTROL BROKEN: the tests did not detect a plain-text repository, do not trust the results"; exit 99
fi
for c in "${want[@]}"; do
    echo "== $c"
    case "$c" in
        sops) cand_sops ;;
        git-crypt) cand_git_crypt ;;
        pass) cand_pass ;;
        vault) cand_vault ;;
        *) echo "unknown candidate: $c" ;;
    esac
done

echo; echo "== summary (FAIL lines are the ones that matter)"
fails=0
for key in $(printf '%s\n' "${!RESULT[@]}" | sort | grep -v '^plain/'); do
    case "${RESULT[$key]}" in FAIL*) echo "  $key: ${RESULT[$key]}"; fails=$((fails + 1)) ;; esac
done
echo "failures: $fails"
exit "$fails"
