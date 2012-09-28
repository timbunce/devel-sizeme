package Devel::Memory;

use strict;
use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS $warn $dangle);

require 5.005;
require Exporter;
require XSLoader;

@ISA = qw(Exporter);

@EXPORT_OK = qw(size total_size perl_size);

# This allows declaration   use Devel::Memory ':all';
%EXPORT_TAGS = ( 'all' => \@EXPORT_OK );

$VERSION = '0.01';

XSLoader::load( __PACKAGE__);

$warn = 1;
$dangle = 0; ## Set true to enable warnings about dangling pointers

1;
__END__

=pod

Devel::Memory - Perl extension for finding the memory usage of Perl variables

=head1 SYNOPSIS

  use Devel::Memory qw(size total_size);

  my $size = size("A string");
  my @foo = (1, 2, 3, 4, 5);
  my $other_size = size(\@foo);
  my $total_size = total_size( $ref_to_data );

=head1 DESCRIPTION

Acts like Devel::Size 0.77 if the PERL_DMEM env var is not set.

Except that it also provides perl_size() and heap_size() functions.

If PERL_DMEM env var is set to an empty string then all the *_size functions
dump a textual representation of the memory data to stderr.

If PERL_DMEM env var is set to a string that starts with "|" then the
remainder of the string is taken to be a command name and popen() is used to
start the command and the raw memory data is piped to it.

If PERL_DMEM env var is set to anything else it is treated as the name of a
file the raw memory data should be written to.

The dmemtree.pl script can be used to process the raw memory data.
Typically run via the PERL_DMEM env var. For example:

    export PERL_DMEM='|./dmemtree.pl --text'
    export PERL_DMEM='|./dmemtree.pl --dot=dmemtree.dot'
    export PERL_DMEM='|./dmemtree.pl --db=dmemtree.db'

The --text output is similar to the textual representation output by the module
when the PERL_DMEM env var is set to an empty string.

The --dot output is suitable for feeding to Graphviz.

The --db output is a SQLite database. (Very subject to change.)

Example usage:

  PERL_DMEM='|dmemtree.pl --db=dmemtree.db' perl -MDevel::Memory=:all -e 'total_size(sub { })'

The dmemview.pl script is a Mojolicious::Lite application that serves data to
an interactive treemap visualization of the memory use. It can be run as:

    dmemview.pl daemon

and then open http://127.0.0.1:3000

Please report bugs to:

    http://rt.cpan.org/NoAuth/Bugs.html?Dist=Devel-Memory

=head1 COPYRIGHT

Copyright (C) 2005 Dan Sugalski,
Copyright (C) 2007-2008 Tels,
Copyright (C) BrowserUK 2008,
Copyright (C) 2011-2012 Nicholas Clark,
Copyright (C) 2012 Tim Bunce.

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl v5.8.8.

=head1 SEE ALSO

perl(1), L<Devel::Size>.

=cut
