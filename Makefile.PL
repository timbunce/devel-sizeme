#!/usr/bin/perl -w
use 5.008;
use ExtUtils::MakeMaker;
use strict;

use Config;
(unpack "B*", pack "N", $Config{ptrsize}) =~ /^0+1(0+)$/
    or die "Your pointer size of $Config{ptrsize} is very confusing";
my $ptr_bits = length $1;

my $svh = "$Config{archlibexp}/CORE/perl.h";
my $vtable_file = 'vtables.inc';

my %vtables;
open FH, "<$svh"
    or die "Can't open $svh ($!) - is your perl install missing its headers?";
while (<FH>) {
    next unless /^\s+(PL_vtbl_[a-z]+),\s*$/ or /^EXT MGVTBL (PL_vtbl_[a-z]+) =/;
    ++$vtables{$1};
}
warn "Didn't find any vtable names in $svh" unless %vtables;
close FH;


my %special = (
	       PL_vtbl_collxfrm => 'USE_LOCALE_COLLATE',
	       PL_vtbl_mutex => 'USE_5005THREADS',
);

open FH, ">$vtable_file" or die "Can't open $vtable_file: $!";
foreach (sort keys %vtables) {
    if ($special{$_}) {
	print FH <<"EOT";
#ifdef $special{$_}
    &$_,
#endif
EOT
    } else {
	print FH "    &$_,\n";
    }
}

close FH or die "Error closing $vtable_file: $!";

WriteMakefile(
	      NAME => 'Devel::Size',
	      VERSION_FROM => 'lib/Devel/Size.pm',
	      DEFINE => "-DALIGN_BITS=$ptr_bits",
	      ($ExtUtils::MakeMaker::VERSION >= 6.47 ? (MIN_PERL_VERSION => '5.008') : ()),
	      ($ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
	      realclean => {FILES=> $vtable_file},
);
