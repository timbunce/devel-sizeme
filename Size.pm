package Devel::Size;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $AUTOLOAD %EXPORT_TAGS);

require Exporter;
require DynaLoader;

@ISA = qw(Exporter DynaLoader);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Devel::Size ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
%EXPORT_TAGS = ( 'all' => [ qw(
	size, total_size
) ] );

@EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

@EXPORT = qw(
	
);
$VERSION = '0.52';

bootstrap Devel::Size $VERSION;

# Preloaded methods go here.

1;
__END__
# Below is stub documentation for your module. You better edit it!

=head1 NAME

Devel::Size - Perl extension for finding the memory usage of perl variables

=head1 SYNOPSIS

  use Devel::Size qw(size);
  $size = size("abcde");
  $other_size = size(\@foo);

  $foo = {a => [1, 2, 3],
	  b => {a => [1, 3, 4]}
         };
  $total_size = total_size($foo);

=head1 DESCRIPTION

This module figures out the real sizes of perl variables. Call it with
a reference to the variable you want the size of. If you pass in a
plain scalar it returns the size of that scalar. (Just be careful if
you're asking for the size of a reference, as it'll follow the
reference if you don't reference it first)

The C<size> function returns the amount of memory the variable
uses. If the variable is a hash or array, it only reports the amount
used by the variable structure, I<not> the contents.

The C<total_size> function will walk the variable and look at the
sizes of the contents. If the variable contains references those
references will be walked, so if you have a multidimensional data
structure you'll get the total structure size. (There isn't, at the
moment, a way to get the size of an array or hash and its elements
without a full walk)

=head2 EXPORT

None by default.

=head1 BUGS

Doesn't currently walk all the bits for code refs, globs, formats, and
IO. Those throw a warning, but a minimum size for them is returned.

=head1 AUTHOR

Dan Sugalski dan@sidhe.org

=head1 SEE ALSO

perl(1).

=cut
