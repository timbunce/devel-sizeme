#!/usr/bin/perl -w
use 5.005;
use ExtUtils::MakeMaker;
use strict;

use Config;
(unpack "B*", pack "N", $Config{ptrsize}) =~ /^0+1(0+)$/
    or die "Your pointer size of $Config{ptrsize} is very confusing";
my $ptr_bits = length $1;

WriteMakefile(
    OPTIMIZE => "-g",
    NAME => 'Devel::Memory',
    VERSION_FROM => 'lib/Devel/Memory.pm',
    DEFINE => "-DALIGN_BITS=$ptr_bits",
    PREREQ_PM => {
        'Test::More' => 0,
        'JSON::XS' => 0,
        'HTML::Entities' => 0,
        'Mojolicious::Lite' => 0,
        'Devel::Dwarn' => 0,
        XSLoader => 0,
        ORLite => 0,
    },
    EXE_FILES => [ 'bin/dmemtree.pl' ],
    (eval $ExtUtils::MakeMaker::VERSION >= 6.47 ? (MIN_PERL_VERSION => '5.005') : ()),
    (eval $ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
);
