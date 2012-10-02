package Devel::SizeMe;

# As a handy convenience, make perl -d:SizeMe automatically call heap_size
# in an END block, and also set some $^P flags to get more detail.
my $do_size_at_end; # set true below for "perl -d:SizeMe ..."
BEGIN {
    if ($^P) {
        warn "Note: Devel::SizeMe currently disables perl debugger mode\n";
    warn scalar keys %INC;
        # default $^P set by "perl -d" is 0x73f
        $^P = 0x10  # Keep info about source lines on which a sub is defined
            | 0x100 # Provide informative "file" names for evals
            | 0x200 # Provide informative names to anonymous subroutines;
            ;
        $do_size_at_end = 1;
    }
}

use strict;
use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS $warn $dangle);

require 5.005;
require Exporter;
require XSLoader;

$VERSION = '0.02';
@ISA = qw(Exporter);

@EXPORT_OK = qw(size total_size perl_size heap_size);
%EXPORT_TAGS = ( 'all' => \@EXPORT_OK ); # for use Devel::SizeMe ':all';

$warn = 1;
$dangle = 0; ## Set true to enable warnings about dangling pointers

$ENV{SIZEME} ||= "| sizeme_store.pl --showid --db=sizeme.db";

XSLoader::load( __PACKAGE__);

END {
    Devel::SizeMe::perl_size() if $do_size_at_end;
}

1;
__END__

=pod

Devel::SizeMe - Perl extension for finding the memory usage of Perl variables

=head1 SYNOPSIS

  use Devel::SizeMe qw(size total_size);

  my $size = size("A string");
  my @foo = (1, 2, 3, 4, 5);
  my $other_size = size(\@foo);
  my $total_size = total_size( $ref_to_data );

=head1 DESCRIPTION

Acts like Devel::Size 0.77 if the SIZEME env var is not set.

Except that it also provides perl_size() and heap_size() functions.

If SIZEME env var is set to an empty string then all the *_size functions
dump a textual representation of the memory data to stderr.

If SIZEME env var is set to a string that starts with "|" then the
remainder of the string is taken to be a command name and popen() is used to
start the command and the raw memory data is piped to it.

If SIZEME env var is set to anything else it is treated as the name of a
file the raw memory data should be written to.

The sizeme_store.pl script can be used to process the raw memory data.
Typically run via the SIZEME env var. For example:

    export SIZEME='|./sizeme_store.pl --text'
    export SIZEME='|./sizeme_store.pl --dot=sizeme.dot'
    export SIZEME='|./sizeme_store.pl --db=sizeme.db'

The --text output is similar to the textual representation output by the module
when the SIZEME env var is set to an empty string.

The --dot output is suitable for feeding to Graphviz.

The --db output is a SQLite database. (Very subject to change.)

Example usage:

  SIZEME='|sizeme_store.pl --db=sizeme.db' perl -MDevel::SizeMe=:all -e 'total_size(sub { })'

The sizeme_graph.pl script is a Mojolicious::Lite application that serves data to
an interactive treemap visualization of the memory use. It can be run as:

    sizeme_graph.pl daemon

and then open http://127.0.0.1:3000

Please report bugs to:

    http://rt.cpan.org/NoAuth/Bugs.html?Dist=Devel-SizeMe

=head1 COPYRIGHT

Copyright (C) 2005 Dan Sugalski,
Copyright (C) 2007-2008 Tels,
Copyright (C) 2008 BrowserUK,
Copyright (C) 2011-2012 Nicholas Clark,
Copyright (C) 2012 Tim Bunce.

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl v5.8.8.

=head1 SEE ALSO

perl(1), L<Devel::Size>.

=cut
