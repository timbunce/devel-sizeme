#!/usr/bin/env perl

use strict;
use warnings;

use Mojolicious::Lite;

use ORLite {
    file => '../x.db',
    package => "MemView",
    #user_version => 1,
    readonly => 1,
    #unicode => 1,
};

# Documentation browser under "/perldoc"
plugin 'PODRenderer';

get '/' => sub {
    my $self = shift;
    $self->render('index');
};

get '/jit_tree/:id/:depth' => sub {
    my $self = shift;
    my $id = $self->stash('id');
    my $depth = $self->stash('depth');
    warn "jit_tree $id $depth";
    my $jit_tree = _fetch_node($id, $depth, sub {
        my ($node, $children) = @_;
        $node->{'$area'} = $node->{self_size}+$node->{kids_size};
        $node->{child_count} = @$children if $children;
        my $jit_node = {
            id   => $node->{id},
            name => $node->{name},
            data => $node,
        };
        $jit_node->{children} = $children if $children;
        return $jit_node;
    });
if(1){
    use Devel::Dwarn;
    use Data::Dump qw(pp);
    local $jit_tree->{children};
    pp($jit_tree);
}
    $self->render_json($jit_tree);
};

sub _fetch_node {
    my ($id, $depth, $transform) = @_;
    my $node = MemView->selectrow_hashref("select * from node where id = ?", undef, $id);
    my $children;
    if ($depth && $node->{child_seqns}) {
        my @child_seqns = split /,/, $node->{child_seqns};
        $children = [ map { _fetch_node($_, $depth-1, $transform) } @child_seqns ];
    }
    $node = $transform->($node, $children) if $transform;
    return $node;
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
<script language="javascript" type="text/javascript" src="jit.js"></script>
<script language="javascript" type="text/javascript" src="//ajax.googleapis.com/ajax/libs/jquery/1.8.1/jquery.min.js"></script>

<!-- Example File -->
<script language="javascript" type="text/javascript" src="sprintf.js"></script>
<script language="javascript" type="text/javascript" src="tm.js"></script>
</head>

<body onload="init();">
<div id="container">

<div id="left-container">

<div class="text">
<h4>
Perl Memory TreeMap
</h4> 
    Clicking on a node will show a new TreeMap with the contents of that node.<br /><br />            
</div>

<a id="back" href="#" class="theme button white">Go to Parent</a>
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
