# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..8\n"; }
END {print "not ok 1\n" unless $loaded;}
use Devel::Size qw(size total_size);
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

use vars qw($foo @foo %foo);
$foo = "12";
@foo = (1,2,3);
%foo = (a => 1, b => 2);

my $x = "A string";
my $y = "A longer string";
if (size($x) < size($y)) {
    print "ok 2\n";
} else {
    print "not ok 2\n";
}

if (total_size($x) < total_size($y)) {
    print "ok 3\n";
} else {
    print "not ok 3\n";
}

my @x = (1..4);
my @y = (1..10);

if (size(\@x) < size(\@y)) {
    print "ok 4\n";
} else {
    print "not ok 4\n";
}

if (total_size(\@x) < total_size(\@y)) {
    print "ok 5\n";
} else {
    print "not ok 5\n";
}

# check that the tracking_hash is working

my($a,$b) = (1,2);
my @ary1 = (\$a, \$a);
my @ary2 = (\$a, \$b);

if (total_size(\@ary1) < total_size(\@ary2)) {
    print "ok 6\n";
} else {
    print "not ok 6\n";
}

# check that circular references don't mess things up

my($c1,$c2); $c2 = \$c1; $c1 = \$c2;

if( total_size($c1) == total_size($c2) ) {
    print "ok 7\n";
} else {
    print "not ok 7\n";
}

if (total_size(*foo)) {
   print "ok 8\n";
} else {
  print "not ok 8\n";
}
