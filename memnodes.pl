#!/bin/env perl

use strict;
use warnings;

use DBI qw(looks_like_number);
use DBD::SQLite;
use JSON::XS;

use Getopt::Long;

GetOptions(
    'json!' => \my $opt_json,
    'dot!' => \my $opt_dot,
    'db=s'  => \my $opt_db,
    'verbose|v!' => \my $opt_verbose,
    'debug|d!' => \my $opt_debug,
) or exit 1;

my $j = JSON::XS->new->ascii->pretty(0);

my $dbh = DBI->connect("dbi:SQLite:dbname=$opt_db","","", {
    RaiseError => 1, PrintError => 0, AutoCommit => 0
});
$dbh->do("PRAGMA synchronous = OFF");
$dbh->do("DROP TABLE IF EXISTS node");
$dbh->do(q{
    CREATE TABLE node (
        id integer primary key,
        name text,
        title text,
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
my $node_ins_sth = $dbh->prepare(q{
    INSERT INTO node VALUES (?,?,?,?,?,  ?,?,?,?,?,?)
});

my @stack;
my %seqn2node;

    my $dotnode = sub {
        my $name = shift;
        $name =~ s/"/\\"/g;
        return '"'.$name.'"';
    };

print "memnodes = [" if $opt_json;

if ($opt_dot) {
    print "digraph {\n"; # }
    print "graph [overlap=false]\n"; # target="???", URL="???"
}


sub enter_node {
    my $x = shift;
    if ($opt_json) {
        print "    " x $x->{depth};
        print qq({ "id": "$x->{id}", "name": "$x->{name}", "depth":$x->{depth}, "children":[ \n);
    }
    if ($opt_dot) {
        #printf $fh qq{\tn%d [ %s ]\n}, $x->{id}, $dotnode->($x->{name});
        #print qq({ "id": "$x->{id}", "name": "$x->{name}", "depth":$x->{depth}, "children":[ \n);
    }
    return;
}

sub leave_node {
    my $x = shift;
    delete $seqn2node{$x->{id}};

    my $self_size = 0; $self_size += $_  for values %{$x->{leaves}};
    $x->{self_size} = $self_size;

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
    if ($opt_json) {
        print "    " x $x->{depth};
        my $size = $self_size + $x->{kids_size};
        print qq(], "data":{ "\$area": $size } },\n);
    }
    if ($opt_dot) {
        my @attr = (sprintf "label=%s", $dotnode->($x->{name}));
        push @attr, "shape=point" if $x->{type} == 2;
        printf qq{n%d [ %s ];\n}, $x->{id}, join(",", @attr);
        printf qq{n%d -> n%d;\n}, $parent->{id}, $x->{id} if $parent;
    }
    if ($dbh) {
        my $attr_json = $j->encode($x->{attr});
        my $leaves_json = $j->encode($x->{leaves});
        $node_ins_sth->execute(
            $x->{id}, $x->{name}, $x->{title}, $x->{depth}, $x->{parent_id},
            $x->{self_size}, $x->{kids_size}, $x->{kids_node_count},
            $x->{child_id} ? join(",", @{$x->{child_id}}) : undef,
            $attr_json, $leaves_json,
        );
        # XXX attribs
    }
    return;
}


while (<>) {
    chomp;
    my ($type, $id, $val, $name, $extra) = split / /, $_, 5;
    if ($type =~ s/^-//) {     # Node type ($val is depth)
        while ($val < @stack) {
            leave_node(my $x = pop @stack);
            warn "N $id d$val ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n"
                if $opt_verbose;
        }
        die 1 if $stack[$val];
        my $node = $stack[$val] = { id => $id, type => $type, name => $name, extra => $extra, attr => {}, leaves => {}, depth => $val, self_size=>0, kids_size=>0 };
        enter_node($node);
        $seqn2node{$id} = $node;
    }
    elsif ($type eq "L") {  # Leaf name and memory size
        my $node = $seqn2node{$id} || die;
        $node->{leaves}{$name} += $val;
    }
    elsif (looks_like_number($type)) {  # Attribute type, name and value
        my $node = $seqn2node{$id} || die;
        my $attr = $node->{attr} || die;
        if ($type == 1) { # NPattr_NAME
            warn "Node $id already has attribute $type:$name (value $attr->{$type}{$name})\n"
                if exists $attr->{$type}{$name};
            $attr->{$type}{$name} = $val || $id;
            warn "A \@$id: '$name' $val\n";
            $node->{title} = $name if $type == 1 and !$val;
        }
        elsif (2 <= $type and $type <= 4) { # NPattr_PAD*
            warn "Node $id already has attribute $type:$name (value $attr->{$type}[$val])\n"
                if defined $attr->{$type}[$val];
            $attr->{$type}[$val] = $name;
        }
        else {
            warn "Invalid attribute type '$type' on line $. ($_)";
        }
    }
    else {
        warn "Invalid type '$type' on line $. ($_)";
        next;
    }
    $dbh->commit if $dbh and $id % 10_000 == 0;
}

my $x;
while (@stack > 1) {
    leave_node($x = pop @stack) while @stack;
    warn "EOF ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n";
}
print " ];\n" if $opt_json;
print "}\n" if $opt_dot;

$dbh->commit if $dbh;

use Data::Dumper;
warn Dumper(\$x);
warn Dumper(\%seqn2node);

=for
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
