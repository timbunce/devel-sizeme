use strict;
use Test::More;
use lib qw(t/lib);
use SizemeTest;

run_test_group(lines => [<DATA>]);

done_testing;

__DATA__
pushnode,foo,1
addsize,sz,3
