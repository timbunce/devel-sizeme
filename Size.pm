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
	size total_size
) ] );

@EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

@EXPORT = qw(
	
);
$VERSION = '0.54';

bootstrap Devel::Size $VERSION;

# Preloaded methods go here.

1;
__END__

=head1 NAME

Devel::Size - Perl extension for finding the memory usage of Perl variables

=head1 SYNOPSIS

  use Devel::Size qw(size total_size);

  my $size = size("A string");

  my @foo = (1, 2, 3, 4, 5);
  my $other_size = size(\@foo);

  my $foo = {a => [1, 2, 3],
	  b => {a => [1, 3, 4]}
         };
  my  $total_size = total_size($foo);

=head1 DESCRIPTION

This module figures out the real sizes of Perl variables in bytes.  
Call functions with a reference to the variable you want the size
of.  If the variable is a plain scalar it returns the size of
the scalar.  If the variable is a hash or an array, use a reference
when calling.

=head1 FUNCTIONS

=head2 size($ref)

The C<size> function returns the amount of memory the variable
returns.  If the variable is a hash or an array, it only reports
the amount used by the structure, I<not> the contents.

=head2 total_size($ref)

The C<total_size> function will traverse the variable and look
at the sizes of contents.  Any references contained in the variable
will also be followed, so this function can be used to get the
total size of a multidimensional data structure.  At the moment
there is no way to get the size of an array or a hash and its
elements without using this function.

=head2 EXPORT

None but default, but optionally C<size> and C<total_size>.

=head1 BUGS

Doesn't currently walk all the bits for code refs, formats, and
IO. Those throw a warning, but a minimum size for them is returned.

=head1 AUTHOR

Dan Sugalski dan@sidhe.org

=head1 SEE ALSO

perl(1).

=cut
