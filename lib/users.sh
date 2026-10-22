# shellcheck shell=bash
# Declarative user management:  CSV  ->  plan  ->  apply.  Managed accounts carry the tag [sysops] in their comment (GECOS).
# CSV columns: username,fullname,groups(;-separated),shell,sudo(yes/no),ssh_public_key,expires(YYYY-MM-DD or empty)

PW=""; GR=""
_files() { PW="$UROOT/etc/passwd"; GR="$UROOT/etc/group"; }
_ru() { [[ -n $UROOT ]] && printf -- '-R\n%s\n' "$UROOT"; }      # root flag for shadow-utils tools
_run() { local a=(); [[ -n $UROOT ]] && a=(-R "$UROOT"); local c=$1; shift; "$c" "${a[@]}" "$@"; }
u_exists() { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' "$PW"; }
u_field()  { awk -F: -v u="$1" -v n="$2" '$1==u{print $n}' "$PW"; }
u_groups() { awk -F: -v u="$1" '{n=split($4,m,","); for(i=1;i<=n;i++) if(m[i]==u) print $1}' "$GR" | sort | tr '\n' ' '; }
g_exists() { awk -F: -v g="$1" '$1==g{f=1} END{exit !f}' "$GR"; }
sudo_group() { g_exists sudo && echo sudo || { g_exists wheel && echo wheel || echo sudo; }; }
is_managed() { [[ $(u_field "$1" 5) == *"[sysops]"* ]]; }

emit() { # sign color text
  printf ' %s%s%s %s\n' "$2" "$1" "$OFF" "$3"
}

user_sync() {
  local file=${1:-} apply=0 prune=0; shift || true
  while (( $# )); do case $1 in --apply) apply=1;; --prune) prune=1;; *) die "unknown option $1";; esac; shift; done
  [[ -r $file ]] || die "usage: sysops user sync users.csv [--apply] [--prune]"
  _files; [[ -r $PW ]] || die "cannot read $PW"
  (( apply )) || printf '%sPLAN%s (nothing changes without --apply)\n' "$BLD" "$OFF"
  local n_c=0 n_m=0 n_ok=0 n_l=0 listed=" " user full groups shell sudo key exp
  while IFS=, read -r user full groups shell sudo key exp; do
    [[ -z $user || $user == username || $user == \#* ]] && continue
    [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { warn "invalid username '$user' skipped"; continue; }
    listed+="$user "
    shell=${shell:-/bin/bash}; groups=${groups//;/,}
    local want_groups=$groups; [[ $sudo == yes ]] && want_groups+="${want_groups:+,}$(sudo_group)"
    local g; for g in ${want_groups//,/ }; do g_exists "$g" || { emit "+" "$GRN" "group $g (new)"; (( apply )) && { _run groupadd "$g"; journal group_create "$g"; }; }; done
    if ! u_exists "$user"; then
      emit "+" "$GRN" "create user ${BLD}$user${OFF} ($full) groups=[${want_groups:-none}] shell=$shell${exp:+ expires=$exp}"
      n_c=$((n_c+1))
      if (( apply )); then
        local args=(-m -s "$shell" -c "$full [sysops]"); [[ -n $want_groups ]] && args+=(-G "$want_groups")
        [[ -n $exp ]] && args+=(-e "$exp")
        _run useradd "${args[@]}" "$user" || die "useradd failed for $user"
        journal user_create "$user" "groups=$want_groups shell=$shell"
        install_key "$user" "$key"
      fi
    else
      local changes="" cur_shell cur_groups; cur_shell=$(u_field "$user" 7); cur_groups=$(u_groups "$user")
      [[ $cur_shell != "$shell" ]] && changes+="shell $cur_shell -> $shell; "
      local missing=""; for g in ${want_groups//,/ }; do [[ " $cur_groups" == *" $g "* ]] || missing+="$g "; done
      [[ -n $missing ]] && changes+="add to groups: $missing; "
      local extra=""; if is_managed "$user"; then for g in $cur_groups; do [[ ",$want_groups," == *",$g,"* ]] || extra+="$g "; done; fi
      [[ -n $extra ]] && changes+="remove from groups: $extra; "
      local haskey=1; [[ -n $key ]] && ! grep -qF -- "$key" "$UROOT$(u_field "$user" 6)/.ssh/authorized_keys" 2>/dev/null && { haskey=0; changes+="install ssh key; "; }
      if [[ -z $changes ]]; then emit "=" "$DIM" "$user unchanged"; n_ok=$((n_ok+1))
      else
        emit "~" "$YEL" "modify ${BLD}$user${OFF}: $changes"; n_m=$((n_m+1))
        if (( apply )); then
          [[ $cur_shell != "$shell" ]] && _run usermod -s "$shell" "$user"
          if is_managed "$user"; then _run usermod -G "$want_groups" "$user"          # exact list: adds AND removes
          elif [[ -n $missing ]]; then _run usermod -a -G "$(echo "$missing" | xargs | tr ' ' ',')" "$user"; fi
          (( haskey )) || install_key "$user" "$key"
          journal user_modify "$user" "$changes"
        fi
      fi
    fi
  done < "$file"
  if (( prune )); then
    local u
    while IFS=: read -r u _ _ _ gecos _; do
      [[ $gecos == *"[sysops]"* && $listed != *" $u "* ]] || continue
      local ex today; ex=$(awk -F: -v u="$u" '$1==u{print $8}' "$UROOT/etc/shadow" 2>/dev/null); today=$(( $(date +%s) / 86400 ))
      [[ -n $ex ]] && (( ex <= today )) && continue                 # already expired/locked by a previous run
      emit "-" "$RED" "lock ${BLD}$u${OFF}: managed account is not in the file anymore"; n_l=$((n_l+1))
      (( apply )) && { user_lock "$u"; journal user_lock "$u" "pruned by sync"; }
    done < "$PW"
  fi
  printf '\n%s create, %s modify, %s lock, %s unchanged%s\n' "$n_c" "$n_m" "$n_l" "$n_ok" "$( ((apply)) && echo ' (applied, journal: '"$STATE"'/journal.jsonl)' || echo ' (dry-run)')"
}

install_key() { # user key
  [[ -n $2 ]] || return 0
  local home; home=$UROOT$(u_field "$1" 6)
  mkdir -p "$home/.ssh"; chmod 700 "$home/.ssh"
  grep -qF -- "$2" "$home/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$2" >> "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"; chown -R "$(u_field "$1" 3):$(u_field "$1" 4)" "$home/.ssh" 2>/dev/null || true
}

user_lock() { # lock password + expire account + kill sessions (live only)
  _run usermod -L -e 1 "$1" 2>/dev/null || _run usermod -L "$1"
  [[ -z $UROOT ]] && pkill -KILL -u "$1" 2>/dev/null || true
}

user_offboard() { # lock, remove ssh keys + sudo rights, archive home, keep the account record (reversible)
  local u=${1:-} apply=0; [[ ${2:-} == --apply ]] && apply=1
  _files; u_exists "$u" || die "no such user: $u"
  [[ $u == root ]] && die "refusing to offboard root"
  printf '%sOFFBOARD %s%s %s\n' "$BLD" "$u" "$OFF" "$( ((apply)) || echo '(dry-run, add --apply)')"
  local home=$UROOT$(u_field "$u" 6) arch="${SYSOPS_ARCHIVE_DIR:-$STATE/archive}"
  emit "-" "$RED" "lock password, expire account, kill sessions"
  emit "-" "$RED" "remove ~/.ssh/authorized_keys and sudo/wheel membership"
  emit "+" "$GRN" "archive home -> $arch/$u-$(date +%F).tar.gz (mode 600, sha256 recorded)"
  (( apply )) || return 0
  user_lock "$u"
  rm -f "$home/.ssh/authorized_keys"
  local keep="" g; for g in $(u_groups "$u"); do [[ $g == sudo || $g == wheel || $g == admin ]] || keep+="${keep:+,}$g"; done
  _run usermod -G "$keep" "$u"                                   # exact list without the admin groups
  mkdir -p "$arch"; chmod 700 "$arch"
  if [[ -d $home ]]; then
    tar -czf "$arch/$u-$(date +%F).tar.gz" -C "$(dirname "$home")" "$(basename "$home")" && chmod 600 "$arch/$u-$(date +%F).tar.gz"
    ( cd "$arch" && sha256sum "$u-$(date +%F).tar.gz" >> SHA256SUMS )
  fi
  journal user_offboard "$u" "archive=$arch"
  printf '%sdone.%s Account is locked, data archived. Delete later with: sysops user delete %s --apply\n' "$GRN" "$OFF" "$u"
}

user_delete() {
  local u=${1:-} apply=0; [[ ${2:-} == --apply ]] && apply=1
  _files; u_exists "$u" || die "no such user: $u"; [[ $u == root ]] && die "refusing to delete root"
  is_managed "$u" || die "$u is not a sysops-managed account ([sysops] tag missing); refusing. Use userdel yourself."
  printf 'would delete %s and its home directory%s\n' "$u" "$( ((apply)) && echo ' - DOING IT' || echo ' (dry-run, add --apply)')"
  (( apply )) || return 0
  _run userdel -r "$u" 2>/dev/null || _run userdel "$u"; journal user_delete "$u"
}

user_audit() { # who is dangerous or stale?
  _files; local days=${1:-90}; local found=0 u uid shell gecos home
  printf '%sUser audit%s (%s)\n' "$BLD" "$OFF" "${UROOT:-this system}"
  while IFS=: read -r u _ uid _ gecos home shell; do
    (( uid >= 1000 && uid < 60000 )) || [[ $u == root ]] || continue
    local flags=""
    local st; st=$(awk -F: -v u="$u" '$1==u{print $2}' "$UROOT/etc/shadow" 2>/dev/null)
    [[ -z $st && -r $UROOT/etc/shadow ]] && flags+="EMPTY-PASSWORD "
    [[ $st == '!'* || $st == '*' ]] && flags+="locked "
    [[ $(u_groups "$u") =~ (sudo|wheel|admin) ]] && flags+="sudo "
    [[ $shell == */nologin || $shell == */false ]] && flags+="no-shell "
    [[ -d $UROOT$home ]] || flags+="NO-HOME "
    local mx; mx=$(awk -F: -v u="$u" '$1==u{print $5}' "$UROOT/etc/shadow" 2>/dev/null); [[ -z $mx || $mx == 99999 ]] && [[ $flags != *locked* ]] && flags+="pw-never-expires "
    [[ -s $UROOT$home/.ssh/authorized_keys ]] && flags+="ssh-key "
    [[ $gecos == *"[sysops]"* ]] && flags+="managed "
    local color=$OFF; [[ $flags == *EMPTY-PASSWORD* ]] && color=$RED; [[ $flags == *sudo* && $color == "$OFF" ]] && color=$YEL
    printf ' %s%-14s uid=%-6s %s%s\n' "$color" "$u" "$uid" "$flags" "$OFF"; found=1
  done < "$PW"
  [[ -z $UROOT ]] && command -v lastlog >/dev/null && { printf '\nNever logged in or inactive > %s days:\n' "$days"; lastlog -b "$days" 2>/dev/null | awk 'NR>1 && $1 != "" {print "  " $0}' | head -15; }
  return 0
}
