#!/bin/env perl

use strict;
use warnings;

use DBI;
use DBD::SQLite;

use Getopt::Long;

GetOptions(
    'json!' => \my $opt_json,
    'db=s'  => \my $opt_db,
) or exit 1;

my $dbh = DBI->connect("dbi:SQLite:dbname=$opt_db","","", {
    RaiseError => 1, PrintError => 0, AutoCommit => 0
});
$dbh->do("PRAGMA synchronous = OFF");
$dbh->do("DROP TABLE IF EXISTS node");
$dbh->do(q{
    CREATE TABLE node (
        id integer primary key,
        name text,
        depth integer,
        parent_id integer,

        self_size integer,
        kids_size integer,
        kids_node_count integer,
        child_ids text
    )
});
my $node_ins_sth = $dbh->prepare(q{
    INSERT INTO node VALUES (?,?,?,?,  ?,?,?,?)
});

my @stack;
my %seqn2node;

sub enter_node {
    my $x = shift;
    if ($opt_json) {
        print "    " x $x->{depth};
        print qq({ "id": "$x->{id}", "name": "$x->{name}", "depth":$x->{depth}, "children":[ \n);
    }
    return;
}

sub leave_node {
    my $x = shift;
    delete $seqn2node{$x->{id}};
    my $self_size = 0; $self_size += $_  for values %{$x->{leaves}};
    $x->{self_size} = $self_size;
    if (my $parent = $stack[-1]) {
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
    if ($dbh) {
        $node_ins_sth->execute(
            $x->{id}, $x->{name}, $x->{depth}, $x->{parent_id},
            $x->{self_size}, $x->{kids_size}, $x->{kids_node_count},
            $x->{child_id} ? join(",", @{$x->{child_id}}) : undef
        );
        # XXX attribs
    }
    return;
}

print "memnodes = [" if $opt_json;

while (<>) {
    chomp;
    my ($type, $id, $val, $name, $extra) = split / /, $_, 5;
    if ($type eq "N") {     # Node ($val is depth)
        while ($val < @stack) {
            leave_node(my $x = pop @stack);
            warn "N $id d$val ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n";
        }
        die 1 if $stack[$val];
        my $node = $stack[$val] = { id => $id, name => $name, extra => $extra, attr => [], leaves => {}, depth => $val, self_size=>0, kids_size=>0 };
        enter_node($node);
        $seqn2node{$id} = $node;
    }
    elsif ($type eq "L") {  # Leaf name and memory size
        my $node = $seqn2node{$id} || die;
        $node->{leaves}{$name} += $val;
    }
    elsif ($type eq "A") {  # Attribute name and value
        my $node = $seqn2node{$id} || die;
        push @{ $node->{attr} }, $name, $val; # pairs
    }
    else {
        warn "Invalid type '$type' on line $. ($_)";
    }
    $dbh->commit if $dbh and $id % 10_000 == 0;
}

my $x;
while (@stack > 1) {
    leave_node($x = pop @stack) while @stack;
    warn "EOF ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n";
}
print " ];\n" if $opt_json;

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
