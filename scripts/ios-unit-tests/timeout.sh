#!/bin/sh
# [T-ios-unit-test-infra] `timeout SECONDS cmd...` for macOS, which ships no timeout(1).
# perl's alarm() sends SIGALRM after the deadline; exec keeps the child in the same PID.
exec perl -e 'my $sec = shift @ARGV; $SIG{ALRM} = sub { kill "TERM", $pid if $pid; exit 124 }; $pid = fork; if (!$pid) { exec @ARGV; exit 127 } alarm $sec; waitpid $pid, 0; exit($? >> 8)' "$@"
