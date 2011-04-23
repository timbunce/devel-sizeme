#!/usr/bin/perl -w

use strict;
use Test::More tests => 8;
use Devel::Size ':all';

sub zwapp;
sub swoosh($$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$);
sub crunch {
}

my $whack_size = total_size(\&whack);
my $zwapp_size = total_size(\&zwapp);
my $swoosh_size = total_size(\&swoosh);
my $crunch_size = total_size(\&crunch);

cmp_ok($whack_size, '>', 0, 'CV generated at runtime has a size');
cmp_ok($zwapp_size, '>', $whack_size,
       'CV stubbed at compiletime is larger (CvOUTSIDE is set and followed)');
cmp_ok(length prototype \&swoosh, '>', 0, 'prototype has a length');
cmp_ok($swoosh_size, '>', $zwapp_size + length prototype \&swoosh,
       'prototypes add to the size');
cmp_ok($crunch_size, '>', $zwapp_size, 'sub bodies add to the size');

my $anon_proto = sub ($$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$) {};
my $anon_size = total_size(sub {});
my $anon_proto_size = total_size($anon_proto);
cmp_ok($anon_size, '>', 0, 'anonymous subroutines have a size');
cmp_ok(length prototype $anon_proto, '>', 0, 'prototype has a length');
cmp_ok($anon_proto_size, '>', $anon_size + length prototype $anon_proto,
       'prototypes add to the size');
