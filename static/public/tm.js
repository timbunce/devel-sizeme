var labelType, useGradients, nativeTextSupport, animate;

(function() {
  var ua = navigator.userAgent,
      iStuff = ua.match(/iPhone/i) || ua.match(/iPad/i),
      typeOfCanvas = typeof HTMLCanvasElement,
      nativeCanvasSupport = (typeOfCanvas == 'object' || typeOfCanvas == 'function'),
      textSupport = nativeCanvasSupport 
        && (typeof document.createElement('canvas').getContext('2d').fillText == 'function');
  //I'm setting this based on the fact that ExCanvas provides text support for IE
  //and that as of today iPhone/iPad current text support is lame
  labelType = (!nativeCanvasSupport || (textSupport && !iStuff))? 'Native' : 'HTML';
  nativeTextSupport = labelType == 'Native';
  useGradients = nativeCanvasSupport;
  animate = !(iStuff || !nativeCanvasSupport);
})();

var Log = {
  elem: false,
  write: function(text){
    if (!this.elem) 
      this.elem = document.getElementById('log');
    this.elem.innerHTML = text;
    this.elem.style.left = (500 - this.elem.offsetWidth / 2) + 'px';
  }
};

// http://stackoverflow.com/questions/5199901/how-to-sort-an-associative-array-by-its-values-in-javascript
function bySortedValue(obj, comparitor, callback, context) {
    var tuples = [];
    for (var key in obj) {
        if (obj.hasOwnProperty(key)) {
            tuples.push([key, obj[key]]);
        }
    }

    tuples.sort(comparitor);

    if (callback) {
        var length = tuples.length;
        while (length--) callback.call(context, tuples[length][0], tuples[length][1]);
    }
    return tuples;
}



function request_jit_tree(nodeId, level, onComplete){
    var params = { logarea: 1 };
    jQuery.getJSON('jit_tree/'+nodeId+'/1', params, onComplete);
}


function init(){
  //init data
  //end
  //init TreeMap
  var tm = new $jit.TM.Squarified({
    //where to inject the visualization
    injectInto: 'infovis',
    //show only one tree level
    levelsToShow: 1,
    //parent box title heights
    titleHeight: 11,
    //enable animations
    animate: animate,
    //box offsets
    offset: 1,
    //use canvas text
    Label: {
      type: labelType,
      size: 9,
      family: 'Tahoma, Verdana, Arial'
    },
    //enable specific canvas styles
    //when rendering nodes
    Node: {
      CanvasStyles: {
        shadowBlur: 0,
        shadowColor: '#000'
      }
    },
    //Attach left and right click events
    Events: {
      enable: true,
      onClick: function(node) {
        if(node) tm.enter(node);
      },
      onRightClick: function() {
        tm.out();
      },
      //change node styles and canvas styles
      //when hovering a node
      onMouseEnter: function(node, eventInfo) {
        if(node) {
          //add node selected styles and replot node
          node.setCanvasStyle('shadowBlur', 7);
          node.setData('color', '#888');
          tm.fx.plotNode(node, tm.canvas);
          tm.labels.plotLabel(tm.canvas, node);
        }
      },
      onMouseLeave: function(node) {
        if(node) {
          node.removeData('color');
          node.removeCanvasStyle('shadowBlur');
          tm.plot();
        }
      }
    },
    //duration of the animations
    duration: 500,
    //Enable tips
    Tips: {
      enable: true,
      type: 'Native',
      //add positioning offsets
      offsetX: 20,
      offsetY: 20,
      //implement the onShow method to
      //add content to the tooltip when a node
      //is hovered
      onShow: function(tip, node, isLeaf, domElement) {
        var data = node.data;
        var html = "<div class=\"tip-title\">"
          + (data.title ? data.title : "")
          + " " + data.name
          + "</div><div class=\"tip-text\">";

        html += "<br />";
        html += sprintf("Size: %d (%d + %d)<br />", data.self_size+data.kids_size, data.self_size, data.kids_size);

        if (data.self_size) {
            html += sprintf("Memory usage:<br />");
            bySortedValue(data.leaves,
                function(a, b) { return a[1] - b[1] },
                function(k, v) { html += sprintf(" %10s: %5d<br />", k, v);
            });
            html += "<br />";
        }


        html += sprintf("Attributes:<br />");
        bySortedValue(data.attr,
            function(a, b) { return a[0] > b[0] ? 1 : a[0] < b[0] ? -1 : 0 },
            function(k, v) { html += sprintf(" %10s: %5d<br />", k, v);
        });
        html += "<br />";

        if (data.child_count) {
            html += sprintf("Children: %d of %d<br />", data.child_count, data.kids_node_count);
        }
        html += sprintf("Id: %s%s<br />", node.id, data._ids_merged ? data._ids_merged : "");
        html += sprintf("Depth: %d<br />", data.depth);
        html += sprintf("Parent: %d<br />", data.parent_id);

        html += JSON.stringify(data.attr, undefined, 4);
        //html += JSON.stringify(data, undefined, 4);

        tip.innerHTML =  html; 
      }  
    },
    //Implement this method for retrieving a requested  
    //subtree that has as root a node with id = nodeId,  
    //and level as depth. This method could also make a server-side  
    //call for the requested subtree. When completed, the onComplete   
    //callback method should be called.  
    request: function(nodeId, level, onComplete){  
            request_jit_tree(nodeId, level, function(data) {
                console.log("Fetched node "+nodeId);
                console.log(data);
                onComplete.onComplete(nodeId, data);  
            });
    },
    //Add the name of the node in the corresponding label
    //This method is called once, on label creation and only for DOM labels.
    onCreateLabel: function(domElement, node){
        domElement.innerHTML = node.name;
    }
  });

  request_jit_tree(1, 0, function(data) {
        console.log(data);
        tm.loadJSON(data);
        tm.refresh();
    });

    //add event to buttons
    $jit.util.addEvent($jit.id('back'), 'click', function() { tm.out() });
    $jit.util.addEvent($jit.id('logarea'), 'onchange', function() { tm.refresh() });

}


