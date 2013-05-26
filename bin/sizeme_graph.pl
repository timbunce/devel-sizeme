#!/usr/bin/env perl

BEGIN {
    die qq{$0 requires Mojolicious::Lite, which isn't installed.

    Currently requires Mojolicious::Lite which isn't available for perl 5.8.
    If this affects you you can run Devel::SizeMe with your normal perl and
    run sizeme_graph.pl with a different perl, perhaps on a different machine.
    \n}
        unless eval "require Mojolicious::Lite";
}

=head1 NAME

sizeme_graph.pl - web server providing an interactive treemap of Devel::SizeMe data

=head1 SYNOPSIS

    sizeme_graph.pl --db sizeme.db daemon

    sizeme_graph.pl daemon # same as above

Then open a web browser on http://127.0.0.1:3000

=head1 DESCRIPTION

Reads a database created by sizeme_store.pl and provides a web interface with
an interactive treemap of the data.

Currently requires Mojolicious::Lite which isn't available for perl 5.8.
If this affects you you can run Devel::SizeMe with your normal perl and
run sizeme_graph.pl with a different perl, perhaps on a different machine.

=head2 TODO

Current implementation is all very alpha and rather hackish.

Split out the db and tree code into a separate module.

Use a history management library so the back button works and we can have
links to specific nodes.

Better tool-tip and/or add a scrollable information area below the treemap
that could contain details and links.

Make the treemap resize to fit the browser window (as NYTProf does).

Protect against nodes with thousands of children
    perhaps replace all with single merged child that has no children itself
    but just a warning as a title.

Implement other visualizations, such as a space-tree
http://thejit.org/static/v20/Jit/Examples/Spacetree/example2.html

=cut

use strict;
use warnings;

use Mojolicious::Lite; # possibly needs v3
use JSON::XS;
use Getopt::Long;
use Devel::Dwarn;
use Devel::SizeMe::Graph;
use DBI;


my $j = JSON::XS->new;

GetOptions(
    'db=s' => \(my $opt_db = 'sizeme.db'),
    'showid!' => \my $opt_showid,
    'debug!' => \my $opt_debug,
) or exit 1;

die "Can't open $opt_db: $!\n" unless -r $opt_db;
warn "Reading $opt_db\n";

my $dbh = DBI->connect("dbi:SQLite:$opt_db", undef, undef, { RaiseError => 1 });
my $select_node_by_id_sth = $dbh->prepare("select * from node where id = ?");


my $static_dir = $INC{'Devel/SizeMe/Graph.pm'} or die 'panic';
$static_dir =~ s:\.pm$:/static:;
die "panic $static_dir" unless -d $static_dir;
if ( $Mojolicious::VERSION >= 2.49 ) {
    push @{ app->static->paths }, $static_dir;
} else {
    app->static->root($static_dir);
}


sub name_path_for_node {
    my ($id) = @_;
    my @name_path;

    while ($id) { # work backwards towards root
        my $node = _get_node($id);
        push @name_path, $node;
        $id = $node->{namedby_id} || $node->{parent_id};
        if (@name_path > 1_000) {
            my %id_count;
            ++$id_count{$_->{id}} for @name_path;
            my $desc = join ", ", map { "n$_ ($id_count{$_})" } keys %id_count;
            warn "name_path too deep (possible parent_id/namedby_id loop involving $desc)\n";
            last;
        }
    }

    return [ reverse @name_path ];
}


# Documentation browser under "/perldoc"
plugin 'PODRenderer';

get '/:id' => sub {
    my $self = shift;
    # JS handles the :id
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

    if (1){ # debug
        #use Data::Dump qw(pp);
        local $jit_tree->{children};
        require Storable;
        Dwarn(Storable::dclone($jit_tree)); # dclone to avoid stringification
    }

    my %response = (
        name_path  => name_path_for_node($id),
        nodes => $jit_tree
    );
    # XXX temp hack
    #     //   <li><a href="#">Home</a> <span class="divider">/</span></li>
    #     //   <li><a href="#">Library</a> <span class="divider">/</span></li>
    #     //   <li class="active">Data</li>
    $response{name_path_html} = join "", map {
        sprintf q{<li><a href="/%d">%s</a><span class="divider">/</span></li>},
            $_->{id}, $_->{name};
    } @{$response{name_path}};

    $self->render(json => \%response);
};

my %node_queue;
my %node_cache;
sub _set_node_queue {
    my $nodes = shift;
    ++$node_queue{$_} for @$nodes;
}
sub _get_node {
    my $id = shift;

    my $node = $node_cache{$id};
    return $node if ref $node;

    my @ids;
    # ensure the one the caller wanted is actually in the batch
    push @ids, $id;
    delete $node_queue{$id};
    # also fetch a chunk of nodes from the read-ahead list
    while ( $_ = scalar each %node_queue ) {
        delete $node_queue{$_};
        push @ids, $_;
        last if @ids > 1_000; # batch size
    }

    my $sql = "select * from node where id in (".join(",",@ids).")";
    my $rows = $dbh->selectall_arrayref($sql);
    for (@{ $dbh->selectall_arrayref($sql, { Slice => {} })}) {
        $node_cache{ $_->{id} } = $_;
    }

    return $node_cache{$id};
}


sub _fetch_node_tree {
    my ($id, $depth) = @_;

    warn "#$id fetching\n"
        if $opt_debug;

    my $node = _get_node($id)
        or die "No node $id";
    $node = { %$node }; # XXX copy for inflation
    $node->{$_} += 0 for (qw(child_count kids_node_count kids_size self_size)); # numify
    $node->{leaves} = $j->decode(delete $node->{leaves_json});
    $node->{attr}   = $j->decode(delete $node->{attr_json});

    $node->{name} .= "->" if $node->{type} == 2 && $node->{name};

    $depth = 1 if $depth > 1 and $node->{name} =~ /^arena/;

    if ($node->{child_ids}) {
        my @child_ids = split /,/, $node->{child_ids};

        # if this node has only one child then we merge that child into this node
        # this makes the treemap more usable
        if (@child_ids == 1
            #        && $node->{type} == 2 # only collapse links XXX
                and $node->{name} !~ /^arena/
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
                            if defined $dst->{$k} and $dst->{$k} ne $src->{$k};
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

        if (@child_ids > 1_000) {
            warn "Node $id ($node->{name}) has ".scalar(@child_ids)." children\n";
            # XXX merge/prune/something?
        }

        if ($node->{name} =~ /^arena-g\d+/) {
            warn "$node->{name} $depth";
        }

        if ($depth) { # recurse to required depth
            _set_node_queue(\@child_ids);
            $node->{children} = [ map { _fetch_node_tree($_, $depth-1) } @child_ids ];
            $node->{child_count} = @{ $node->{children} };
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

{   # just to reserve the namespace for future use
    package Devel::SizeMe::Graph;
    1;
}

__DATA__
@@ index.html.ep
% layout 'default';
% title 'Welcome';
Welcome to the Mojolicious real-time web framework!

@@ layouts/default.html.ep
<!DOCTYPE html>
<html lang="en">

<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Perl Memory Treemap</title>

<!-- CSS Files -->
<link type="text/css" href="css/base.css" rel="stylesheet" />
<link type="text/css" href="css/Treemap.css" rel="stylesheet" />
<link type="text/css" href="yesmeck-jquery-jsonview/jquery.jsonview.css" rel="stylesheet" />
<link type="text/css" href="bootstrap/css/bootstrap.min.css" rel="stylesheet" media="screen" />
<link type="text/css" href="bootstrap/css/bootstrap-responsive.min.css" rel="stylesheet" />

<!--[if IE]><script language="javascript" type="text/javascript" src="excanvas.js"></script><![endif]-->

</head>

<body>

<div class="container-fluid">

<div class="row-fluid">

    <div class="span3" id="sizeme_left_column_div">

        <div class="row-fluid">
            <div class="span12" id="sizeme_title_div">
                <h4>Perl Memory TreeMap</h4> 
            </div>
        </div>
        <div class="row-fluid">
            <div class="span12 text-left" id="sizeme_info_div">
                <p class="text-left">
                <a id="goto_parent" href="#" class="theme button white">Go to Parent</a>
                <form name=params>
                <label for="logarea">Log scale
                <input type=checkbox id="logarea" name="logarea">
                </form>
                </p>
            </div>
        </div>
        <div class="row-fluid">
            <small>
            <div class="span12 text-left" id="sizeme_data_div">
            </div>
            </small>
        </div>

    </div>

    <div class="span9" id="sizeme_right_column_div">
        <div class="row-fluid">
            <div class="span12" id="sizeme_path_div">
                <ul class="breadcrumb pull-left" id="sizeme_path_ul">Path</ul>
            </div>
            <div class="span12" style="margin-left:0; text-align:center">
                <div id="infovis"></div>
            </div>
        </div>
    </div>
</div>

<div class="row-fluid">
    <div class="span12" id="sizeme_log_div">
        <p class="text-left" id="sizeme_log_p">Log</p>
    </div>
</div>

</div>

<script language="javascript" type="text/javascript" src="jit-yc.js"></script>
<script language="javascript" type="text/javascript" src="jquery-1.8.1-min.js"></script>
<script language="javascript" type="text/javascript" src="sprintf.js"></script>
<script language="javascript" type="text/javascript" src="treemap.js"></script>
<script language="javascript" type="text/javascript" src="bootstrap/js/bootstrap.min.js"></script>
<script language="javascript" type="text/javascript" src="yesmeck-jquery-jsonview/jquery.jsonview.js"></script>
<script type="text/javascript"> $('document').ready(init) </script>

</body>
</html>
