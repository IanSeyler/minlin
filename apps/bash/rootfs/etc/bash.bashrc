# Read by every interactive bash; login shells (ssh) get here via /etc/profile.

[ -z "$PS1" ] && return

# user@host:dir, then # for root or $ for anyone else. The host is the
# hostname from the ip= boot parameter (GUEST_NAME), minlin by default.
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
