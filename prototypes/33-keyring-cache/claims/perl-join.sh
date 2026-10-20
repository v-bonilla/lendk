#!/bin/sh
# PROTOTYPE for #33, throwaway. Join a fresh anonymous session keyring with perl's syscall(), then
# exec "$@": what a test harness can do on a host with no keyutils. perl-base is essential on
# Debian and Ubuntu. keyctl is system call 250 on x86_64 and 219 on aarch64.
case $(uname -m) in x86_64) nr=250 ;; aarch64) nr=219 ;; *) echo "perl-join: unknown arch" >&2; exit 1 ;; esac
exec perl -e 'my $nr = shift; syscall($nr, 1, 0) >= 0 or die "perl-join: $!\n"; exec @ARGV or die "perl-join: exec: $!\n"' "$nr" "$@"
