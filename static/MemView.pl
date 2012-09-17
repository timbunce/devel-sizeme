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
        my $node=shift; $node->{data}{'$area'} = $node->{self_size}+$node->{kids_size}
    });
    use Devel::Dwarn; Dwarn($jit_tree);
    $self->render_json($jit_tree);
};

sub _fetch_node {
    my ($id, $depth, $transform) = @_;
    my $node = MemView->selectrow_hashref("select * from node where id = ?", undef, $id);
    if ($depth && $node->{child_seqns}) {
        my @child_seqns = split /,/, $node->{child_seqns};
        my @children = map { _fetch_node($_, $depth-1, $transform) } @child_seqns;
        $node->{children} = \@children;
    }
    $transform->($node) if $transform;
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
<title>Treemap - TreeMap with on-demand nodes</title>

<!-- CSS Files -->
<link type="text/css" href="css/base.css" rel="stylesheet" />
<link type="text/css" href="css/Treemap.css" rel="stylesheet" />

<!--[if IE]><script language="javascript" type="text/javascript" src="excanvas.js"></script><![endif]-->

<!-- JIT Library File -->
<script language="javascript" type="text/javascript" src="jit.js"></script>
<script language="javascript" type="text/javascript" src="//ajax.googleapis.com/ajax/libs/jquery/1.8.1/jquery.min.js"></script>

<!-- Example File -->
<script language="javascript" type="text/javascript" src="tmdata.js"></script>
<script language="javascript" type="text/javascript" src="tm.js"></script>
</head>

<body onload="init();">
<div id="container">

<div id="left-container">



<div class="text">
<h4>
TreeMap with on-demand nodes    
</h4> 

            This example shows how you can use the <b>request</b> controller method to create a TreeMap with on demand nodes<br /><br />
            This example makes use of native Canvas text and shadows, but can be easily adapted to use HTML like the other examples.<br /><br />
            There should be only one level shown at a time.<br /><br /> 
            Clicking on a band should show a new TreeMap with its most listened albums.<br /><br />            
            
</div>

<div id="id-list">
<table>
    <tr>
        <td>
            <label for="r-sq">Squarified </label>
        </td>
        <td>
            <input type="radio" id="r-sq" name="layout" checked="checked" value="left" />
        </td>
    </tr>
    <tr>
         <td>
            <label for="r-st">Strip </label>
         </td>
         <td>
            <input type="radio" id="r-st" name="layout" value="top" />
         </td>
    <tr>
         <td>
            <label for="r-sd">SliceAndDice </label>
          </td>
          <td>
            <input type="radio" id="r-sd" name="layout" value="bottom" />
          </td>
    </tr>
</table>
</div>

<a id="back" href="#" class="theme button white">Go to Parent</a>


<div style="text-align:center;"><a href="example2.js">See the Example Code</a></div>            
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
