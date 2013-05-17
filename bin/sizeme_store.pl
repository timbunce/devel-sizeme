#!/usr/bin/env perl

=head1 NAME

sizeme_store.pl - process and store the raw data stream from Devel::SizeMe

=head1 SYNOPSIS

    sizeme_store.pl [--text] [--dot=sizeme.dot] [--db=sizeme.db]

Typically used with Devel::SizeMe via the C<SIZEME> env var:

    export SIZEME='|sizeme_store.pl --text'
    export SIZEME='|sizeme_store.pl --dot=sizeme.dot'
    export SIZEME='|sizeme_store.pl --db=sizeme.db'

=head1 DESCRIPTION

Reads the raw memory data from Devel::SizeMe and processes the tree
via a stack, propagating data such as totals, up the tree nodes
as the data streams through.  Output completed nodes in the request formats.

The --text output is similar to the textual representation output by the module
when the SIZEME env var is set to an empty string.

The --dot output is suitable for feeding to Graphviz. (On OSX the Graphviz
application will be started automatically.)

The --db output is a SQLite database. The db schema is very subject to change.
This output is destined to be the primary one. The other output types will
probably become separate programs that read the db.

=head1 TODO

Current implementation is all very alpha and rather hackish.

Refactor to separate the core code into a module.

Move the output formats into separate modules, which should probably read from
the db so the db becomes the canonical source of data.

Import constants from XS.

=cut

# Needs to be generalized to support pluggable output formats.
# Actually it needs to be split so sizeme_store.pl only does the store
# and another program drives the output with plugins.
# Making nodes into (lightweight fast) objects would be smart.
# Tests would be even smarter!
#
# When working on this code it's important to have a sense of the flow.
# Specifically the way that depth drives the completion of nodes.
# It's a depth-first stream processing machine, which only ever holds
# a single stack of the currently incomplete nodes, which is always the same as
# the current depth. I.e., when a node of depth N arrives, all nodes >N are
# popped off the stack and 'completed', each rippling data up to its parent.

use strict;
use warnings;
use autodie;

use DBI qw(looks_like_number);
use DBD::SQLite;
use JSON::XS;
use Devel::Dwarn;
use Data::Dumper;
use Getopt::Long;
use Carp qw(carp croak confess);

# XXX import these from the XS code
use constant NPtype_NAME     => 0x01;
use constant NPtype_LINK     => 0x02;
use constant NPtype_SV       => 0x03;
use constant NPtype_MAGIC    => 0x04;
use constant NPtype_OP       => 0x05;

use constant NPattr_LEAFSIZE => 0x00;
use constant NPattr_LABEL    => 0x01;
use constant NPattr_PADFAKE  => 0x02;
use constant NPattr_PADNAME  => 0x03;
use constant NPattr_PADTMP   => 0x04;
use constant NPattr_NOTE     => 0x05;
use constant NPattr_ADDR     => 0x06;
use constant NPattr_REFCNT   => 0x07;
my @attr_type_name = (qw(size NAME PADFAKE my PADTMP NOTE ADDR REFCNT)); # XXX get from XS in some way


GetOptions(
    'text!' => \my $opt_text,
    'dot=s' => \my $opt_dot,
    'graphml=s' => \my $opt_graphml,
    'db=s'  => \my $opt_db,
    'verbose|v!' => \my $opt_verbose,
    'debug|d!' => \my $opt_debug,
    'showid!' => \my $opt_showid,
    'open!' => \my $opt_open,
) or exit 1;

$| = 1 if $opt_debug;
my $run_size = 0;
my $total_size = 0;

my $j = JSON::XS->new->ascii->pretty(0);

my ($dbh, $node_ins_sth);
if ($opt_db) {
    $dbh = DBI->connect("dbi:SQLite:dbname=$opt_db","","", {
        RaiseError => 1, PrintError => 0, AutoCommit => 0
    });
    $dbh->do("PRAGMA synchronous = OFF");
}

my @outputs;
my @stack;
my %seqn2node;


my %links_to_addr;
my %node_id_of_addr;
sub note_item_addr {
    my ($addr, $id) = @_;
    # for items with addr we record the id of the item
    warn "already seen node_id_of_addr $addr (old $node_id_of_addr{$addr}, new $id)\n"
        if $node_id_of_addr{$addr};
    $node_id_of_addr{$addr} = $id;
    Dwarn { node_id_of_addr => $id } if $opt_debug;
}

sub note_link_to_addr {
    my ($addr, $id) = @_;
    # for links with addr we build a list of all the link ids
    # associated with an addr
    ++$links_to_addr{$addr}{$id};
    Dwarn { links_to_addr => $links_to_addr{$addr} } if $opt_debug;
}




sub enter_node {
    my $x = shift;
    warn ">> enter_node $x->{id}\n" if $opt_debug;
    return $x;
}


sub leave_node {
    my $x = shift;
    confess unless defined $x->{id};
    warn "<< leave_node $x->{id}\n" if $opt_debug;
    #delete $seqn2node{$x->{id}};

    my $self_size = 0; $self_size += $_ for values %{$x->{leaves}};
    $x->{self_size} = $self_size;

    my $parent = $stack[-1];

    if ($x->{name} eq 'elem'
        and defined(my $index = $x->{attr}{+NPattr_NOTE}{i})
    ) {
        # give a better name to the link
        my $padlist;
        if (@stack >= 3 && ($padlist=$stack[-3])->{name} eq 'PADLIST') {
            # elem link <- SV(PVAV) <- elem link <- PADLIST
            my $padnames = $padlist->{attr}{+NPattr_PADNAME} || [];
            if (my $padname = $padnames->[$index]) {
                $x->{name} = "my($padname)";
            }
            else {
                $x->{name} = ($index) ? "PAD[$index]" : '@_';
            }
        }
        elsif (@stack >= 1 && ($padlist=$stack[-1])->{name} eq 'PADLIST') {
            my $padnames = $padlist->{attr}{+NPattr_PADNAME} || [];
            $x->{name} = "Pad$index";
        }
        else {
            $x->{name} = "[$index]";
        }
    }

    if ($parent) {
        # link to parent
        $x->{parent_id} = $parent->{id};
        # accumulate into parent
        $parent->{kids_node_count} += 1 + ($x->{kids_node_count}||0);
        $parent->{kids_size} += $self_size + $x->{kids_size};
        push @{$parent->{child_id}}, $x->{id};
    }
    else {
        $x->{kids_node_count} ||= 0;
    }

    $_->leave_node($x) for (@outputs);

    # output
    # ...
    if ($dbh) {
        my $attr_json = $j->encode($x->{attr});
        my $leaves_json = $j->encode($x->{leaves});
        $node_ins_sth->execute(
            $x->{id}, $x->{name}, $x->{attr}{label}, $x->{type}, $x->{depth}, $x->{parent_id},
            $x->{self_size}, $x->{kids_size}, $x->{kids_node_count},
            $x->{child_id} ? join(",", @{$x->{child_id}}) : undef,
            $attr_json, $leaves_json,
        );
        # XXX attribs
    }

    return $x;
}

my $indent = ":   ";

while (<>) {
    warn "\t\t\t\t== $_" if $opt_debug;
    chomp;

    my ($type, $id, $val, $name, $extra) = split / /, $_, 5;

    if ($type =~ s/^-//) {     # Node type ($val is depth)

        printf "%s%s%s %s [#%d @%d]\n", $indent x $val, $name,
                ($type == NPtype_LINK) ? "->" : "",
                $extra||'', $id, $val
            if $opt_text;

        # this is the core driving logic

        while ($val < @stack) {
            my $x = leave_node(pop @stack);
            warn "N $id d$val ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n"
                if $opt_verbose;
        }

        die "panic: stack already has item at depth $val" if $stack[$val];
        die "Depth out of sync\n" if $val != @stack;

        my $node = enter_node({
            id => $id, type => $type, name => $name, extra => $extra,
            attr => { }, leaves => {}, depth => $val, self_size=>0, kids_size=>0
        });

        $stack[$val] = $node;
        $seqn2node{$id} = $node;

        # if parent is a link that has an addr
        # then copy that addr to this item
        if ($type != NPtype_LINK
            and $val
            and (my $addr = $stack[-2]{attr}{addr})
        ) {
            warn "noted addr from parent\n";
            note_item_addr($addr, $id);
        }

    }

    # --- Leaf name and memory size
    elsif ($type eq "L") {
        my $node = $seqn2node{$id} || die;
        $node->{leaves}{$name} += $val;
        $run_size += $val;
        printf "%s+%d=%d %s\n", $indent x ($node->{depth}+1), $val, $run_size, $name
            if $opt_text;
    }

    # --- Attribute type, name and value (all rather hackish)
    elsif (looks_like_number($type)) {
        my $node = $seqn2node{$id} || die;
        my $attr = $node->{attr} || die;

        # attributes where the string is a key (or always empty and the type is the key)
        if ($type == NPattr_LABEL or $type == NPattr_NOTE) {
            printf "%s~%s(%s) %d [t%d]\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $name, $val, $type
                if $opt_text;
            warn "Node $id already has attribute $type:$name (value $attr->{$type}{$name})\n"
                if exists $attr->{$type}{$name};
            $attr->{$type}{$name} = $val;
            #Dwarn $attr;
            if ($type == NPattr_NOTE) {
            }
            elsif ($type == NPattr_LABEL) {
                $attr->{label} = $name if !$val; # XXX hack
            }
        }
        elsif ($type == NPattr_ADDR) {
            printf "%s~%s %d 0x%x [t%d]\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $val, $val, $type
                if $opt_text;
            #$attr->{NPattr_NOTE()}{'addr'} = $val;
            $attr->{addr} = $val;
            # for SVs we see all the link addrs before the item addr
            # for hek's etc we see the item addr before the link addrs
            if ($node->{type} == NPtype_LINK) {
                note_link_to_addr($val, $id);
            }
            else {
                note_item_addr($val, $id);
            }
        }
        elsif (NPattr_PADFAKE==$type or NPattr_PADTMP==$type or NPattr_PADNAME==$type) {
            printf "%s~%s('%s') %d [t%d]\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $name, $val, $type
                if $opt_text;
            warn "Node $id already has attribute $type:$name (value $attr->{$type}[$val])\n"
                if defined $attr->{$type}[$val];
            $attr->{+NPattr_PADNAME}[$val] = $name; # store all as NPattr_PADNAME
        }
        elsif (NPattr_REFCNT==$type) {
            printf "%s~%s %d\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $val
                if $opt_text;
            $attr->{refcnt} = $val;
        }
        else {
            printf "%s~%s %d [t%d]\n", $indent x ($node->{depth}+1), $name, $val, $type
                if $opt_text;
            warn "Unknown attribute type '$type' on line $. ($_)";
        }
    }
    elsif ($type eq 'S') { # start of a run
        die "Unexpected start token" if @stack;

        if ($opt_dot) {
            my $out = Devel::SizeMe::Output::Graphviz->new(file => $opt_dot);
            $out->start_event_stream;
            push @outputs, $out;
        }

        if ($opt_graphml) {
            my $out = Devel::SizeMe::Output::Easy->new(file => $opt_graphml, as => 'as_graphml');
            $out->start_event_stream;
            push @outputs, $out;
        }

        if ($dbh) {
            # XXX add a size_run table records each run
            # XXX pick a table name to store the run nodes in
            #$run_ins_sth->execute(
            my $table = "node";
            $dbh->do("DROP TABLE IF EXISTS $table");
            $dbh->do(qq{
                CREATE TABLE $table (
                    id integer primary key,
                    name text,
                    title text,
                    type integer,
                    depth integer,
                    parent_id integer,

                    self_size integer,
                    kids_size integer,
                    kids_node_count integer,
                    child_ids text,
                    attr_json text,
                    leaves_json text
                )
            });
            $node_ins_sth = $dbh->prepare(qq{
                INSERT INTO $table VALUES (?,?,?,?,?,?,  ?,?,?,?,?,?)
            });
        }
    }
    elsif ($type eq 'E') { # end of a run

        my $top = $stack[0]; # grab top node before we pop all the nodes
        leave_node(pop @stack) while @stack;

        # if nothing output (ie size(undef))
        $top ||= { self_size=>0, kids_size=>0, kids_node_count=>0 };

        my $top_size = $top->{self_size}+$top->{kids_size};

        printf "Stored %d nodes totalling %s [lines=%d size=%d write=%.2fs]\n",
            1+$top->{kids_node_count}, fmt_size($top_size),
            $., $top_size, $val;
        # the duration here ($val) is from Devel::SizeMe perspective
        # ie doesn't include time to read file/pipe and commit to database.

        if ($opt_verbose or $run_size != $top_size) {
            warn "EOF ends $top->{id} d$top->{depth}: size $top->{self_size}+$top->{kids_size}\n";
            warn Dumper($top);
        }
        #die "panic: seqn2node should be empty ". Dumper(\%seqn2node) if %seqn2node;

        $_->end_event_stream for @outputs;

        $dbh->commit if $dbh;
    }
    else {
        warn "Invalid type '$type' on line $. ($_)";
        next;
    }

    $dbh->commit if $dbh and $id % 10_000 == 0;
}
die "EOF without end token" if @stack;

@outputs = (); # DESTROY


sub fmt_size {
    my $size = shift;
    my $kb = $size / 1024;
    return $size if $kb < 5;
    return sprintf "%.1fKb", $kb if $kb < 1000;
    return sprintf "%.1fMb", $kb/1024;
}


BEGIN {
package Devel::SizeMe::Output;
use Moo;
use autodie;
use Carp qw(croak);
use HTML::Entities qw(encode_entities);;

has file => (is => 'ro');

my %pending_links;

sub start_event_stream {
    my ($self) = @_;
    $self->create_output;
    $self->write_prologue;
}

sub end_event_stream {
    my ($self) = @_;

    $self->write_pending_links;
    $self->write_dangling_links;
    $self->write_epilogue;

    $self->close_output;
    $self->view_output if $opt_open;
}

sub write_prologue {
}
sub write_epilogue {
}

sub assign_link_to_item {
    my ($self, $link_node, $child, $attr) = @_;
    $attr ||= {};

    my $child_id = (ref $child) ? $child->{id} : $child;

    warn "assign_link_to_item $link_node->{id} -> $child_id @{[ %$attr ]}\n";
    warn "$link_node->{id} is not a link"
        if $link_node->{type} != ::NPtype_LINK;
    # XXX add check that $link_node is 'dangling'
    # XXX add check that $child is not a link

    my $cur = $pending_links{ $link_node->{id} }{ $child_id } ||= {};
    $cur->{hard} ||= $attr->{hard}; # hard takes precedence
}

sub assign_addr_to_link {
    my ($self, $addr, $link) = @_;

    if (my $id = $node_id_of_addr{$addr}) {
        # link to an addr for which we already have the node
        warn "LINK addr $link->{id} -> $id\n";
        $self->assign_link_to_item($link, $id, { hard => 0 });
    }
    else {
        # link to an addr for which we don't have node yet
        warn "link $link->{id} has addr $addr which has no associated node yet\n"
            if $opt_debug;
        # queue XXX
    }
}

sub resolve_addr_to_item {
    my ($self, $addr, $item) = @_;

    my $links_hashref = $links_to_addr{$addr}
        or return; # we've no links waiting for this addr

    my @links = map { $seqn2node{$_} } keys %$links_hashref;
    for my $link_node (@links) {
        # skip link if it's the one that's the actual parent
        # (because that'll get its own link drawn later)
        # current that's identified by not having a parent_id (yet)
        next if not $link_node->{parent_id};
        warn "ITEM addr link $link_node->{id} ($seqn2node{$link_node->{parent_id}}{id}) -> $item->{id}\n";
        $self->assign_link_to_item($link_node, $item->{id}, { hard => 0 });
    }
}


sub write_pending_links {
    my $self = shift;
    warn "write_pending_links\n"
        if $opt_debug;
    while ( my ($link_id, $dests) = each %pending_links) {
        my $link_node = $seqn2node{$link_id} or die "No node for id $link_id";
        while ( my ($dest_id, $attr) = each %$dests) {
            $self->emit_link($link_id, $dest_id, $attr);
        }
    }
}

sub write_dangling_links {
    my $self = shift;

    warn "write_dangling_links\n"
        if $opt_debug;
    while ( my ($addr, $link_ids) = each %links_to_addr ) {
        next if $node_id_of_addr{$addr}; # not dangling
        my @link_ids = keys %$link_ids;

        # one of the links that points to this addr has
        # attributes that describe the addr being pointed to
        my @link_attr = grep { $_->{refcnt} } map { $seqn2node{$_}->{attr} } @link_ids;
        warn "multiple links to addr $addr have refcnt attr"
            if @link_attr > 1;
        my $attr = $link_attr[0];

        $self->emit_addr_node($addr, $attr);

        for my $link_id (@link_ids) {
            $self->emit_link($link_id, $addr, { kind => 'addr' });
        }
    }
}

sub view_output {
    my $self = shift;

    my $file = $self->file;
    if ($file ne '/dev/tty') {
        system("cat $file") if $opt_debug;
    }
}


sub enter_node {
    return shift;
}

sub leave_item_node {
    my ($self, $item_node) = @_;
    $self->emit_item_node($item_node, { label => $self->fmt_item_label($item_node) });
    if (my $addr = $item_node->{attr}{addr}) {
        $self->resolve_addr_to_item($addr, $item_node);
    }
}

sub leave_link_node {
    my ($self, $link_node) = @_;
    my @kids = @{$link_node->{child_id}||[]};
    warn "panic: NPtype_LINK has more than one child: @kids"
        if @kids > 1;
    for my $child_id (@kids) {
        $self->assign_link_to_item($link_node, $child_id, { hard => 1 });
    }
    # if this link has an address
    if (my $addr = $link_node->{attr}{addr}) {
        $self->assign_addr_to_link($addr, $link_node);
    }
}

sub leave_node {
    my ($self, $node) = @_;
    return $self->leave_item_node($node) if $node->{type} != ::NPtype_LINK;
    return $self->leave_link_node($node);
}


} # Devel::SizeMe::Output


# http://www.graphviz.org/content/attrs
BEGIN {
package Devel::SizeMe::Output::Graphviz;
use Moo;
use autodie;
use Carp qw(croak);
use HTML::Entities qw(encode_entities);;

extends 'Devel::SizeMe::Output';

has fh => (is => 'rw');

*fmt_size = \&main::fmt_size;

sub create_output {
    my $self = shift;
    open my $fh, ">", $self->file;
    $self->fh($fh);
    $self->fh->autoflush if $opt_debug;
}

sub close_output {
    my $self = shift;
    close($self->fh);
    $self->fh(undef);
}

sub view_output {
    my $self = shift;
    $self->SUPER::view_output(@_);

    my $file = $self->file;
    if ($file ne '/dev/tty') {
        #system("dot -Tsvg $file > sizeme.svg && open sizeme.svg");
        #system("open sizeme.html") if $^O eq 'darwin'; # OSX
        system("open -a Graphviz $file") if $^O eq 'darwin'; # OSX
    }
}

sub write_prologue {
    my $self = shift;
    my $fh = $self->fh or return;
    $self->SUPER::write_prologue(@_);
    print $fh "digraph {\n"; # }
    print $fh "graph [overlap=false]\n"; # target="???", URL="???"
}

sub write_epilogue {
    my $self = shift;
    my $fh = $self->fh or return;
    $self->SUPER::write_epilogue(@_);
    # { - balancing brace for the next line:
    print $fh "}\n";
}

sub emit_link {
    my ($self, $link_id, $dest_id, $attr) = @_;
    my $fh = $self->fh or return;
    my $link_node = $seqn2node{$link_id} or die "No node for id $link_id";

    my @link_attr = ("id=$link_id");
    if ($attr->{kind} and $attr->{kind} eq 'addr') {
        push @link_attr, 'arrowhead="empty"', 'style="dotted"';
    }
    else {
        push @link_attr, ($attr->{hard}) ? () : ('style="dashed"');
    }

    (my $link_name = $link_node->{name}) =~ s/->$//; # XXX hack
    push @link_attr, (sprintf "label=%s", _dotlabel($link_name, $link_node));
    printf $fh qq{n%d -> n%d [%s];\n},
        $link_node->{parent_id}, $dest_id, join(",", @link_attr);
}

sub emit_addr_node {
    my ($self, $addr, $attr) = @_;
    my $fh = $self->fh or return;
    my @label = sprintf("0x%x", $addr);
    unshift @label, $attr->{label} if $attr->{label};
    push    @label, "refcnt=$attr->{refcnt}" if $attr->{refcnt};
    # output a dummy node for this addr for the links to connect to
    my @node_attr = ('color="grey60"', 'style="rounded,dotted"');
    push @node_attr, (sprintf "label=%s", _dotlabel(\@label));
    printf $fh qq{n%d [%s];\n},
        $addr, join(",", @node_attr);
}

sub emit_item_node {
    my ($self, $item_node, $attr) = @_;
    my $fh = $self->fh or return;
    my $name = $attr->{label};
    my @node_attr = ( "id=$item_node->{id}" );
    push @node_attr, sprintf("label=%s", _dotlabel($name, $item_node))
        if $name;
    printf $fh qq{n%d [ %s ];\n}, $item_node->{id}, join(",", @node_attr);
}

sub fmt_item_label {
    my ($self, $item_node) = @_;
    my @name;
    push @name, "\"$item_node->{attr}{label}\""
        if $item_node->{attr}{label};
    push @name, $item_node->{name};
    if ($item_node->{kids_size}) {
        push @name, sprintf " %s+%s=%s",
            fmt_size($item_node->{self_size}),
            fmt_size($item_node->{kids_size}),
            fmt_size($item_node->{self_size}+$item_node->{kids_size});
    }
    else {
        push @name, sprintf " +%s",
            fmt_size($item_node->{self_size});
    }
    return \@name;
}


sub _dotlabel {
    my ($name, $node) = @_;
    my @names = (ref $name) ? @$name : ($name);
    $name = join "\\n", map {
        # escape unprintables XXX correct sins against unicode
        s/([\000-\037\200-\237])/sprintf("\\x%02x",ord($1))/eg;
        encode_entities($_)
    } @names;
    $name .= "\\n#$node->{id}" if $opt_showid && $node;
    return qq{"$name"};
}

} # END

BEGIN {
package Devel::SizeMe::Output::Easy;
use Moo;
use autodie;
use Graph::Easy;
use Carp qw(croak);
use HTML::Entities qw(encode_entities);;

extends 'Devel::SizeMe::Output';

has as => (is => 'rw', required => 1);
has graph => (is => 'rw');

*fmt_size = \&main::fmt_size;

sub create_output {
    my $self = shift;
    my $graph = Graph::Easy->new();
    $self->graph($graph);
}

sub close_output {
    my $self = shift;
    open my $fh, ">", $self->file;
    my $as = $self->as; # method name
    print $fh $self->graph->$as();
    close $fh;
    $self->file;
}

sub view_output {
    my $self = shift;
    $self->SUPER::view_output(@_);

    my $file = $self->file;
    if ($file ne '/dev/tty') {
        #system("dot -Tsvg $file > sizeme.svg && open sizeme.svg");
        #system("open sizeme.html") if $^O eq 'darwin'; # OSX
        #system("open -a Graphviz $file") if $^O eq 'darwin'; # OSX
    }
}

sub emit_link {
    my ($self, $link_id, $dest_id, $attr) = @_;

    my $link_node = $seqn2node{$link_id} or die "No node for id $link_id";
    my $edge = $self->graph->add_edge($link_node->{parent_id}, $dest_id);

    (my $link_name = $link_node->{name}) =~ s/->$//; # XXX hack
    my %attr = ( label => $link_name );

    if ($attr->{kind} and $attr->{kind} eq 'addr') {
        $attr{style} = 'dotted';
    }
    else {
        $attr{style} = 'dotted' if not $attr->{hard};
    }
    $edge->set_attributes(\%attr);
}

sub emit_addr_node {
    my ($self, $addr, $attr) = @_;
    my $node = $self->graph->add_node($addr);

    my @label = sprintf("0x%x", $addr);
    unshift @label, $attr->{label} if $attr->{label};
    push    @label, "refcnt=$attr->{refcnt}" if $attr->{refcnt};

    my %attr = (
        label => join("\n", @label),
        color => "grey60",
    );

    $node->set_attributes(\%attr);
}

sub emit_item_node {
    my ($self, $item_node, $attr) = @_;
    my $node = $self->graph->add_node($item_node->{id});
    my %attr = (
        label => $attr->{label},
    );
    $node->set_attributes(\%attr);
}

sub fmt_item_label {
    my ($self, $item_node) = @_;
    my @name;
    push @name, "\"$item_node->{attr}{label}\""
        if $item_node->{attr}{label};
    push @name, $item_node->{name};
    if ($item_node->{kids_size}) {
        push @name, sprintf " %s+%s=%s",
            fmt_size($item_node->{self_size}),
            fmt_size($item_node->{kids_size}),
            fmt_size($item_node->{self_size}+$item_node->{kids_size});
    }
    else {
        push @name, sprintf " +%s",
            fmt_size($item_node->{self_size});
    }
    encode_entities($_, '\x00-\x1f') for @name;
    return join("\n", @name);
}

} # END


=for This is out of date but gives you an idea of the data and stream

SV(PVAV) fill=1/1       [#1 @0] 
:   +64 sv =64 
:   +16 av_max =80 
:   AVelem->        [#2 @1] 
:   :   SV(RV)      [#3 @2] 
:   :   :   +24 sv =104 
:   :   :   RV->        [#4 @3] 
:   :   :   :   SV(PVAV) fill=-1/-1     [#5 @4] 
:   :   :   :   :   +64 sv =168 
:   AVelem->        [#6 @1] 
:   :   SV(IV)      [#7 @2] 
:   :   :   +24 sv =192 
192 at -e line 1.
=cut
__DATA__
N 1 0 SV(PVAV) fill=1/1
L 1 64 sv
L 1 16 av_max
N 2 1 AVelem->
N 3 2 SV(RV)
L 3 24 sv
N 4 3 RV->
N 5 4 SV(PVAV) fill=-1/-1
L 5 64 sv
N 6 1 AVelem->
N 7 2 SV(IV)
L 7 24 sv
