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
	size
) ] );

@EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

@EXPORT = qw(
	
);
$VERSION = '0.03';

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

=head1 DESCRIPTION

This module figures out the real sizes of perl variables. Call it with
a reference to the variable you want the size of. If you pass in a
plain scalar it returns the size of that scalar. (Just be careful if
you're asking for the size of a reference, as it'll follow the
reference if you don't reference it first)

=head2 EXPORT

None by default.

=head1 BUGS

Only does plain scalars, hashes, and arrays. No sizes for globs or code refs. Yet.

Also, this module currently only returns the size used by the variable
itself, I<not> the contents of arrays or hashes, nor does it follow
references past one level. That's for later.

=head1 AUTHOR

Dan Sugalski dan@sidhe.org

=head1 SEE ALSO

perl(1).

=cut
