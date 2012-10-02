#!/usr/bin/env perl

use strict;
use warnings;

use Mojolicious::Lite;
use JSON::XS;
use Getopt::Long;
use Storable qw(dclone);
use Devel::Dwarn;

=pod NOTE

    Needs to be run from the static/. directory.
    For example:

        ./sizeme_graph.pl daemon

=pod TODO

    Move all the static files into the DATA section of ths script so the script
    is entirely self-contained and doesn't need any static files installed.
    Or, work out how to install the static files and reference them from the script.

    Remove ORLite (for now)

    Make the treemap resize to fit the browser window (as NYTProf does).

    Protect against nodes with thousands of children
        perhaps replace all with single merged child that has no children itself
        but just a warning as a title.

=cut

GetOptions(
    'db=s' => \(my $opt_db = '../sizeme.db'),
    'showid!' => \my $opt_showid,
    'debug!' => \my $opt_debug,
) or exit 1;

#warn "Reading from $opt_db\n";

# XXX currently uses ORLite but doesn't actually make use of it in any useful way
# should be removed and replaced with plain DBI till we have an obvious need for it
use ORLite {
    file => '../sizeme.db',
    package => "SizeMe",
    #user_version => 1,
    readonly => 1,
    #unicode => 1,
};

my $j = JSON::XS->new;

# Documentation browser under "/perldoc"
plugin 'PODRenderer';

get '/' => sub {
    my $self = shift;
    $self->render('index');
};


# /jit_tree are AJAX requests from the treemap visualization
get '/jit_tree/:id/:depth' => sub {
    my $self = shift;

    my $id = $self->stash('id');
    my $depth = $self->stash('depth');

    # hack, would be best done on the client side
    my $logarea = (defined $self->param('logarea'))
        ? $self->param('logarea')
        : Mojo::URL->new($self->req->headers->referrer)->query->param('logarea');

    my $node_tree = _fetch_node_tree($id, $depth);
    my $jit_tree = _transform_node_tree($node_tree, sub {
        my ($node) = @_;
        my $children = delete $node->{children}; # XXX edits the src tree
        my $area = $node->{self_size}+$node->{kids_size};
        $node->{'$area'} = ($logarea) ? log($area) : $area; # XXX move to jit js
        my $jit_node = {
            id   => $node->{id},
            name => ($node->{title} || $node->{name}).($opt_showid ? " #$node->{id}" : ""),
            data => $node,
        };
        $jit_node->{children} = $children if $children;
        return $jit_node;
    });

    if(1){ # debug
        use Devel::Dwarn;
        use Data::Dump qw(pp);
        local $jit_tree->{children};
        pp(dclone($jit_tree)); # dclone to avoid stringification
    }

    $self->render_json($jit_tree);
};


sub _fetch_node_tree {
    my ($id, $depth) = @_;

    warn "#$id fetching\n"
        if $opt_debug;
    my $node = SizeMe->selectrow_hashref("select * from node where id = ?", undef, $id)
        or die "Node '$id' not found"; # shouldn't die
    $node->{$_} += 0 for (qw(child_count kids_node_count kids_size self_size));
    $node->{leaves} = $j->decode(delete $node->{leaves_json});
    $node->{attr}   = $j->decode(delete $node->{attr_json});
    $node->{name} .= "->" if $node->{type} == 2 && $node->{name};

    if ($node->{child_ids}) {
        my @child_ids = split /,/, $node->{child_ids};
        my $children;

        # if this node has only one child then we merge that child into this node
        # this makes the treemap more usable
        if (@child_ids == 1
            #        && $node->{type} == 2 # only collapse links XXX
        ) {
            warn "#$id fetch only child $child_ids[0]\n"
                if $opt_debug;
            my $child = _fetch_node_tree($child_ids[0], $depth); # same depth
            # merge node into child
            # XXX id, depth, parent_id
            warn "Merged $node->{name} (#$node->{id} d$node->{depth}) with only child $child->{name} #$child->{id}\n"
                if $opt_debug;
            $child->{name} = "$node->{name} $child->{name}";
            $child->{$_} += $node->{$_} for (qw(self_size));
            $child->{$_}  = $node->{$_} for (qw(parent_id));

            $child->{title} = join " ", grep { defined && length } $child->{title}, $node->{title};
            #warn "Titled $child->{title}" if $child->{title};

            # somewhat hackish attribute merging
            for my $attr_type (keys %{ $node->{attr} }) {
                my $src = $node->{attr}{$attr_type};
                if (ref $src eq 'HASH') { # eg NPattr_NAME: {attr}{1}{$name} = $value
                    my $dst = $child->{attr}{$attr_type} ||= {};
                    for my $k (keys %$src) {
                        warn "Node $child->{id} attr $attr_type:$k=$dst->{$k} overwritten by $src->{$k}\n"
                            if defined $dst->{$k};
                        $dst->{$k} = $src->{$k};
                    }
                }
                elsif (ref $src eq 'ARRAY') { # eg NPattr_PADNAME: {attr}{2}[$val] = $name
                    my $dst = $child->{attr}{$attr_type} ||= [];
                    my $idx = @$src;
                    while (--$idx >= 0) {
                        warn "Node $child->{id} attr $attr_type:$idx=$dst->[$idx] overwritten by $src->[$idx]\n"
                            if defined $dst->[$idx];
                        $dst->[$idx] = $src->[$idx];
                    }
                }
                else { # assume scalar
                    warn "Node $child->{id} attr $attr_type=$child->{attr}{$attr_type} overwritten by $src\n"
                        if exists $child->{attr}{$attr_type};
                    $child->{attr}{$attr_type} = $src;
                }
            }

            $child->{leaves}{$_} += $node->{leaves}{$_}
                for keys %{ $node->{leaves} };

            $child->{_ids_merged} .= ",$node->{id}";
            my @child_ids = split /,/, $node->{child_ids};
            $child->{child_count} = @child_ids;

            $node = $child; # use the merged child as this node
        }
        if ($depth) { # recurse to required depth
            $children = [ map { _fetch_node_tree($_, $depth-1) } @child_ids ];
            $node->{children} = $children;
            $node->{child_count} = @$children;
        }
    }
    return $node;
}


sub _transform_node_tree {  # recurse depth first
    my ($node, $transform) = @_;
    if (my $children = $node->{children}) {
        $_ = _transform_node_tree($_, $transform) for @$children;
    }
    return $transform->($node);
}


app->start;

__DATA__
@@ index.html.ep
% layout 'default';
% title 'Welcome';
Welcome to the Mojolicious real-time web framework!

@@ layouts/default.html.ep
<!DOCTYPE html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<title>Perl Memory Treemap</title>

<!-- CSS Files -->
<link type="text/css" href="css/base.css" rel="stylesheet" />
<link type="text/css" href="css/Treemap.css" rel="stylesheet" />

<!--[if IE]><script language="javascript" type="text/javascript" src="excanvas.js"></script><![endif]-->

<!-- JIT Library File -->
<script language="javascript" type="text/javascript" src="jit-yc.js"></script>
<script language="javascript" type="text/javascript" src="jquery-1.8.1-min.js"></script>

<script language="javascript" type="text/javascript" src="sprintf.js"></script>
<script language="javascript" type="text/javascript" src="treemap.js"></script>
</head>

<body onload="init();">
<div id="container">

<div id="left-container">

<div class="text">
<h4>
Perl Memory TreeMap
</h4> 
    Click on a node to zoom in.<br /><br />            
</div>

<a id="back" href="#" class="theme button white">Go to Parent</a>

<br />
<form name=params>
<label for="logarea">&nbsp;Logarithmic scale
<input type=checkbox id="logarea" name="logarea">
</form>

</div>

<div id="center-container">
    <div id="infovis"></div>    
</div>

<div id="right-container">

<div id="inner-details"></div>

</div>

<div id="log"></div>
</div>
</body>
</html>
