package Devel::SizeMe;

require Devel::Memory;

$ENV{SIZEME} = "|sizeme_store.pl --db sizeme.db";

# It's handy to say "perl -d:SizeMe" but has side effects
# currently we simple disable the debugger (as best we can)
# otherwise it (or rather some bits of $^P) cause memory bloat.
# we might want to provide some smarter compatibility in future.
# We might also want to provide a way to set some bits, such as
# 0x10  Keep info about source lines on which a sub is defined
# 0x100 Provide informative "file" names for evals
# 0x200 Provide informative names to anonymous subroutines
if ($^P) { # default is 0x73f
    warn "Note: Devel::SizeMe currently disables perl debugger mode\n";
    $^P = 0;
}

END {
    Devel::Memory::perl_size();
}

1;
