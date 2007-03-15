#!/usr/bin/perl -w

use Test::More;
use strict;
   
my $tests;

BEGIN
   {
   chdir 't' if -d 't';
   plan tests => 5;

   use lib '../lib';
   use lib '../blib/arch';
   use_ok('Devel::Size');
   }

can_ok ('Devel::Size', qw/
  size
  total_size
  /);

Devel::Size->import( qw(size total_size) );

die ("Uhoh, test uses outdated version of Devel::Size")
  unless is ($Devel::Size::VERSION, '0.67', 'VERSION MATCHES');

#############################################################################
# #24846 (Does not correctly recurse into references in a PVNV-type scalar)

my $size = 100;
my $hash = {};

my $empty_hash = total_size($hash);

$hash->{a} = 0/1;
$hash->{a} = [];

my $hash_size = total_size($hash);
my $element_size = total_size($hash->{a});

ok ($element_size < $hash_size, "element < hash with one element");

my $array_size = total_size([0..$size]) - total_size( [] );

$hash->{a} = [0..$size];
my $full_hash = total_size($hash);

#print "$full_hash\n";
#print "$array_size\n";
#print "$hash_size\n";
#print "$element_size\n";

# the total size is:

# the contents of the array (array size)
# the hash
# the PVNV in the hash
# the RV inside the PVNV

is ($full_hash, $array_size + $hash_size, 'properly recurses into PVNV');

