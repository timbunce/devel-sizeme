#!/usr/bin/perl -w

# IMPORTANT NOTE:
#
# When testing total_size(), always remember that it dereferences things, so
# total_size([]) will NOT return the size of the ref + the array, it will only
# return the size of the array alone!

use Test::More tests => 3 + 4 *12;
use strict;
use Devel::Size ':all';


#############################################################################
# verify that pointer sizes in array slots are sensible:
# create an array with 4 slots, 2 of them used
my $array = [ 1,2,3,4 ]; pop @$array; pop @$array;

# the total size minus the array itself minus two scalars is 4 slots
my $ptr_size = total_size($array) - total_size( [] ) - total_size(1) * 2;

is ($ptr_size % 4, 0, '4 pointers are dividable by 4');
isnt ($ptr_size, 0, '4 pointers are not zero');

# size of one slot ptr
$ptr_size /= 4;

#############################################################################
# assert hash and hash key size

my $hash = {};
$hash->{a} = 1;
is (total_size($hash),
    total_size( { a => undef } ) + total_size(1) - total_size(undef),
    'assert hash and hash key size');

#############################################################################
# #24846 (Does not correctly recurse into references in a PVNV-type scalar)

# run the following tests with different sizes

for my $size (2, 3, 7, 100)
  {
  my $hash = { a => 1 };

  # hash + key minus the value
  my $hash_size = total_size($hash) - total_size(1);

  $hash->{a} = 0/1;
  $hash->{a} = [];

  my $pvnv_size = total_size(\$hash->{a}) - total_size([]);
  # size of one ref
  my $ref_size = total_size(\\1) - total_size(1);

  # $hash->{a} is now a PVNV, e.g. a scalar NV and a ref to an array:
#  SV = PVNV(0x81ff9a8) at 0x8170d48
#  REFCNT = 1
#  FLAGS = (ROK)
#  IV = 0
#  NV = 0
#  RV = 0x81717bc
#  SV = PVAV(0x8175d6c) at 0x81717bc
#    REFCNT = 1
#    FLAGS = ()
#    IV = 0
#    NV = 0
#    ARRAY = 0x0
#    FILL = -1
#    MAX = -1
#    ARYLEN = 0x0
#    FLAGS = (REAL)
#  PV = 0x81717bc ""
#  CUR = 0
#  LEN = 0

  # Compare this to a plain array ref
#SV = RV(0x81a2834) at 0x8207a2c
#  REFCNT = 1
#  FLAGS = (TEMP,ROK)
#  RV = 0x8170b44
#  SV = PVAV(0x8175d98) at 0x8170b44
#    REFCNT = 2
#    FLAGS = ()
#    IV = 0
#    NV = 0
#    ARRAY = 0x0
#    FILL = -1
#    MAX = -1
#    ARYLEN = 0x0

  # Get the size of the PVNV and the contained array
  my $element_size = total_size(\$hash->{a});

  cmp_ok($element_size, '<', total_size($hash), "element < hash with one element");
  cmp_ok($element_size, '>', total_size(\[]), "PVNV + [] > [] alone");

  # Dereferencing the PVNV (the argument to total_size) leaves us with
  # just the array, and this should be equal to a dereferenced array:
  is (total_size($hash->{a}), total_size([]), '[] vs. []');

  # the hash with one key
  # the PVNV in the hash
  # the RV inside the PVNV
  # the contents of the array (array size)

  my $full_hash = total_size($hash);
  my $array_size = total_size([]);
  is ($full_hash, $element_size + $hash_size, 'properly recurses into PVNV');
  is ($full_hash, $array_size + $pvnv_size + $hash_size, 'properly recurses into PVNV');

  $hash->{a} = [0..$size];

  # the outer references stripped away, so they should be the same
  is (total_size([0..$size]), total_size( $hash->{a} ), "hash element vs. array");

  # the outer references included, one is just a normal ref, while the other
  # is a PVNV, so they shouldn't be the same:
  isnt (total_size(\[0..$size]), total_size( \$hash->{a} ), "[0..size] vs PVNV");
  # and the plain ref should be smaller
  cmp_ok(total_size(\[0..$size]), '<', total_size( \$hash->{a} ), "[0..size] vs. PVNV");

  $full_hash = total_size($hash);
  $element_size = total_size(\$hash->{a});
  $array_size = total_size(\[0..$size]);

  print "# full_hash = $full_hash\n";
  print "# hash_size = $hash_size\n";
  print "# array size: $array_size\n";
  print "# element size: $element_size\n";
  print "# ref_size = $ref_size\n";
  print "# pvnv_size: $pvnv_size\n";

  # the total size is:

  # the hash with one key
  # the PVNV in the hash
  # the RV inside the PVNV
  # the contents of the array (array size)

  is ($full_hash, $element_size + $hash_size, 'properly recurses into PVNV');
#  is ($full_hash, $array_size + $pvnv_size + $hash_size, 'properly recurses into PVNV');

#############################################################################
# repeat the former test, but mix in some undef elements

  $array_size = total_size(\[0..$size, undef, undef]);

  $hash->{a} = [0..$size, undef, undef];
  $element_size = total_size(\$hash->{a});
  $full_hash = total_size($hash);

  print "# full_hash = $full_hash\n";
  print "# hash_size = $hash_size\n";
  print "# array size: $array_size\n";
  print "# element size: $element_size\n";
  print "# ref_size = $ref_size\n";
  print "# pvnv_size: $pvnv_size\n";

  is ($full_hash, $element_size + $hash_size, 'properly recurses into PVNV');

#############################################################################
# repeat the former test, but use a pre-extended array

  $array = [ 0..$size, undef, undef ]; pop @$array;

  $array_size = total_size($array);
  my $scalar_size = total_size(1) * (1+$size) + total_size(undef) * 1 + $ptr_size
    + $ptr_size * ($size + 2) + total_size([]);
  is ($scalar_size, $array_size, "computed right size if full array");

  $hash->{a} = [0..$size, undef, undef]; pop @{$hash->{a}};
  $full_hash = total_size($hash);
  $element_size = total_size(\$hash->{a});
  $array_size = total_size(\$array);

  print "# full_hash = $full_hash\n";
  print "# hash_size = $hash_size\n";
  print "# array size: $array_size\n";
  print "# element size: $element_size\n";
  print "# ref_size = $ref_size\n";
  print "# pvnv_size: $pvnv_size\n";

  is ($full_hash, $element_size + $hash_size, 'properly handles undef/non-undef inside arrays');

  } # end for different sizes
