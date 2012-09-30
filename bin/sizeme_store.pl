#!/usr/bin/env perl

# Read the raw memory data from Devel::Memory and process the tree
# (as a stack, propagating data such as totals, up the tree).
# Output completed nodes in the request formats.
# Needs to be generalized to support pluggable output formats.
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
use HTML::Entities qw(encode_entities);;
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
use constant NPattr_NAME     => 0x01;
use constant NPattr_PADFAKE  => 0x02;
use constant NPattr_PADNAME  => 0x03;
use constant NPattr_PADTMP   => 0x04;
use constant NPattr_NOTE     => 0x05;
use constant NPattr_PRE_ATTR => 0x06;
my @attr_type_name = (qw(size NAME PADFAKE my PADTMP NOTE PREATTR)); # XXX get from XS in some way


GetOptions(
    'text!' => \my $opt_text,
    'dot=s' => \my $opt_dot,
    'db=s'  => \my $opt_db,
    'verbose|v!' => \my $opt_verbose,
    'debug|d!' => \my $opt_debug,
    'showid!' => \my $opt_showid,
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

my @stack;
my %seqn2node;

my $dotnode = sub {
    my $name = encode_entities(shift);
    $name =~ s/"/\\"/g;
    return '"'.$name.'"';
};


my $dot_fh;

sub fmt_size {
    my $size = shift;
    my $kb = $size / 1024;
    return $size if $kb < 5;
    return sprintf "%.1fKb", $kb if $kb < 1000;
    return sprintf "%.1fMb", $kb/1024;
}


sub enter_node {
    my $x = shift;
    warn ">> enter_node $x->{id}\n" if $opt_debug;

    my $parent = $stack[-1];
    if ($parent) {

        if ($x->{name} eq 'AVelem' and $parent->{name} eq 'SV(PVAV)') {
            my $index = $x->{attr}{+NPattr_NOTE}{i};
            Dwarn $x->{attr};
            Dwarn $index;
            # If node is an AVelem of a CvPADLIST propagate pad name to AVelem
            if (@stack >= 4 and (my $cvpl = $stack[-4])->{name} eq 'CvPADLIST') {
                my $padnames = $cvpl->{_cached}{padnames} ||= do {
                    my @names = @{ $cvpl->{attr}{+NPattr_PADNAME} || []};
                    $_ = "my(".($_||'').")" for @names;
                    $names[0] = '@_';
                    \@names;
                };
                $x->{name} = (defined $index and $padnames->[$index]) || "?";
                $x->{name} =~ s/my\(SVs_PADTMP\)/PADTMP/; # XXX hack for neatness
            }
            else {
                $x->{name} = "[$index]" if defined $index;
            }
        }

    }

    return $x;
}


sub leave_node {
    my $x = shift;
    confess unless defined $x->{id};
    warn "<< leave_node $x->{id}\n" if $opt_debug;
    delete $seqn2node{$x->{id}};

    my $self_size = 0; $self_size += $_ for values %{$x->{leaves}};
    $x->{self_size} = $self_size;

    if ($x->{name} eq 'AVelem') {
        my $index = $x->{attr}{+NPattr_NOTE}{i};
        $x->{name} = "[$index]" if defined $index;
    }

    my $parent = $stack[-1];
    if ($parent) {
        # link to parent
        $x->{parent_id} = $parent->{id};
        # accumulate into parent
        $parent->{kids_node_count} += 1 + ($x->{kids_node_count}||0);
        $parent->{kids_size} += $self_size + $x->{kids_size};
        push @{$parent->{child_id}}, $x->{id};
    }

    # output
    # ...
    if ($opt_dot) {
        printf "// n%d parent=%s(type=%s)\n", $x->{id},
                $parent ? $parent->{id} : "",
                $parent ? $parent->{type} : ""
            if 0;

        if ($x->{type} != NPtype_LINK) {
            my $name = $x->{title} ? "\"$x->{title}\" $x->{name}" : $x->{name};

            if ($x->{kids_size}) {
                $name .= sprintf " %s+%s=%s", fmt_size($x->{self_size}), fmt_size($x->{kids_size}), fmt_size($x->{self_size}+$x->{kids_size});
            }
            else {
                $name .= sprintf " +%s", fmt_size($x->{self_size});
            }
            $name .= " $x->{id}" if $opt_showid;

            my @node_attr = (
                sprintf("label=%s", $dotnode->($name)),
                "id=$x->{id}",
            );
            printf $dot_fh qq{n%d [ %s ];\n}, $x->{id}, join(",", @node_attr);
        }
        else { # NPtype_LINK
            my @kids = @{$x->{child_id}};
            die "panic: NPtype_LINK has more than one child: @kids"
                if @kids > 1;
            for my $child_id (@kids) { # wouldn't work right, eg id= attr
                #die Dwarn $x;
                my @link_attr = ("id=$x->{id}");
                (my $link_name = $x->{name}) =~ s/->$//;
                push @link_attr, (sprintf "label=%s", $dotnode->($link_name));
                printf $dot_fh qq{n%d -> n%d [%s];\n},
                    $x->{parent_id}, $child_id, join(",", @link_attr);
            }
        }

    }
    if ($dbh) {
        my $attr_json = $j->encode($x->{attr});
        my $leaves_json = $j->encode($x->{leaves});
        $node_ins_sth->execute(
            $x->{id}, $x->{name}, $x->{title}, $x->{type}, $x->{depth}, $x->{parent_id},
            $x->{self_size}, $x->{kids_size}, $x->{kids_node_count},
            $x->{child_id} ? join(",", @{$x->{child_id}}) : undef,
            $attr_json, $leaves_json,
        );
        # XXX attribs
    }

    return $x;
}

my $indent = ":   ";
my $pending_pre_attr = {};

while (<>) {
    warn "== $_" if $opt_debug;
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
        die "panic: stack already has item at depth $val"
            if $stack[$val];
        die "Depth out of sync\n" if $val != @stack;
        my $node = enter_node({
            id => $id, type => $type, name => $name, extra => $extra,
            attr => { %$pending_pre_attr },
            leaves => {}, depth => $val, self_size=>0, kids_size=>0
        });
        %$pending_pre_attr = ();
        $stack[$val] = $node;
        $seqn2node{$id} = $node;
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

        # attributes to queue up and apply to the next node
        if (NPattr_PRE_ATTR == $type) {
            $pending_pre_attr->{$name} = $val;
        }
        # attributes where the string is a key (or always empty and the type is the key)
        elsif ($type == NPattr_NAME or $type == NPattr_NOTE) {
            printf "%s~%s(%s) %d [t%d]\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $name, $val, $type
                if $opt_text;
            warn "Node $id already has attribute $type:$name (value $attr->{$type}{$name})\n"
                if exists $attr->{$type}{$name};
            $attr->{$type}{$name} = $val;
            Dwarn $attr;
            $node->{title} = $name if $type == NPattr_NAME and !$val; # XXX hack
        }
        # attributes where the number is a key (or always zero)
        elsif (NPattr_PADFAKE==$type or NPattr_PADTMP==$type or NPattr_PADNAME==$type) {
            printf "%s~%s('%s') %d [t%d]\n", $indent x ($node->{depth}+1), $attr_type_name[$type], $name, $val, $type
                if $opt_text;
            warn "Node $id already has attribute $type:$name (value $attr->{$type}[$val])\n"
                if defined $attr->{$type}[$val];
            $attr->{+NPattr_PADNAME}[$val] = $name; # store all as NPattr_PADNAME
        }
        else {
            printf "%s~%s %d [t%d]\n", $indent x ($node->{depth}+1), $name, $val, $type
                if $opt_text;
            warn "Invalid attribute type '$type' on line $. ($_)";
        }
    }
    elsif ($type eq 'S') { # start of a run
        die "Unexpected start token" if @stack;
        if ($opt_dot) {
            open $dot_fh, ">$opt_dot";
            print $dot_fh "digraph {\n"; # }
            print $dot_fh "graph [overlap=false]\n"; # target="???", URL="???"
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

        my $top_size = $top->{self_size}+$top->{kids_size};

        printf "Stored %d nodes (${.}n) sizing %s (%d) in %.2fs\n",
            $top->{kids_node_count}, fmt_size($top_size), $top_size,
            $val;
        # the duration here ($val) is from Devel::SizeMe perspective
        # ie doesn't include time to read file/pipe and commit to database.

        if ($opt_verbose or $run_size != $top_size) {
            warn "EOF ends $top->{id} d$top->{depth}: size $top->{self_size}+$top->{kids_size}\n";
            warn Dumper($top);
        }
        die "panic: seqn2node should be empty ". Dumper(\%seqn2node)
            if %seqn2node;
        %$pending_pre_attr = ();

        if ($dot_fh) {
            print $dot_fh "}\n";
            close $dot_fh;
            system("open -a Graphviz $opt_dot") if $^O eq 'darwin'; # OSX
        }

        $dbh->commit if $dbh;
    }
    else {
        warn "Invalid type '$type' on line $. ($_)";
        next;
    }

    $dbh->commit if $dbh and $id % 10_000 == 0;
}
die "EOF without end token" if @stack;


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
