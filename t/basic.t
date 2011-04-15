#!/usr/bin/perl -w

use Test::More tests => 15;
use strict;
use Devel::Size qw(size total_size);
use Scalar::Util qw(weaken);

can_ok ('Devel::Size', qw/
  size
  total_size
  /);

die ("Uhoh, test uses an outdated version of Devel::Size")
  unless is ($Devel::Size::VERSION, '0.72_52', 'VERSION MATCHES');

#############################################################################
# some basic checks:

use vars qw($foo @foo %foo);
$foo = "12";
@foo = (1,2,3);
%foo = (a => 1, b => 2);

my $x = "A string";
my $y = "A much much longer string";        # need to be at least 7 bytes longer for 64 bit
cmp_ok(size($x), '<', size($y), 'size() of strings');
cmp_ok(total_size($x), '<', total_size($y), 'total_size() of strings');

my @x = (1..4);
my @y = (1..200);

my $size_1 = total_size(\@x);
my $size_2 = total_size(\@y);

cmp_ok($size_1, '<', $size_2, 'size() of array refs');

# the arrays alone shouldn't be the same size
$size_1 = size(\@x);
$size_2 = size(\@y);

isnt ( $size_1, $size_2, 'size() of array refs');

#############################################################################
# IV vs IV+PV (bug #17586)

$x = 12;
$y = 12; $y .= '';

$size_1 = size($x);
$size_2 = size($y);

cmp_ok($size_1, '<', $size_2, ' ."" makes string longer');

#############################################################################
# check that the tracking_hash is working

my($a,$b) = (1,2);
my @ary1 = (\$a, \$a);
my @ary2 = (\$a, \$b);

cmp_ok(total_size(\@ary1), '<', total_size(\@ary2),
       'the tracking hash is working');

#############################################################################
# check that circular references don't mess things up

my($c1,$c2); $c2 = \$c1; $c1 = \$c2;

is (total_size($c1), total_size($c2), 'circular references');

#############################################################################
# GLOBS

cmp_ok(total_size(*foo), '>', 0, 'total_size(*foo) > 0');

#############################################################################
# CODE ref

my $code = sub { '1' };

cmp_ok(total_size($code), '>', 0, 'total_size($code) > 0');

##########################################################
# RT#14849 (& RT#26781 and possibly RT#29238?)
cmp_ok( total_size( sub{ do{ my $t=0 }; } ), '>', 0,
	'total_size( sub{ my $t=0 } ) > 0' );

# CPAN RT #58484 and #58485
cmp_ok(total_size(\&total_size), '>', 0, 'total_size(\&total_size) > 0');

use constant LARGE => 'N' x 8192;

cmp_ok (total_size(\&LARGE), '>', 8192,
        'total_size for a constant includes the constant');

{
    my $a = [];
    my $b = \$a;
    weaken $b;
    cmp_ok(total_size($a), '>', total_size([]),
	   'making a weakref upgrades the target to PVMG and adds magic');
}
