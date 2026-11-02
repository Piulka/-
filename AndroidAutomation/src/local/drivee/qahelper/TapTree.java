package local.drivee.qahelper;
import java.util.*;

/** Hit testing is used only on the source. The peer receives a semantic selector. */
public final class TapTree {
    public static final class Node {
        final int index,left,top,right,bottom,order;
        final boolean visible,interactive;
        public final List<Node> children=new ArrayList<>();
        public Node(int index,int left,int top,int right,int bottom,int order,boolean visible,boolean interactive){
            this.index=index;this.left=left;this.top=top;this.right=right;this.bottom=bottom;this.order=order;this.visible=visible;this.interactive=interactive;
        }
    }
    public static int hit(Node node,int x,int y){
        List<Node> children=new ArrayList<>(node.children);children.sort(Comparator.comparingInt(n->n.order));
        for(int i=children.size()-1;i>=0;i--){int result=hit(children.get(i),x,y);if(result>=0)return result;}
        // Android can translate a child outside a non-clipping/disabled parent. Its own
        // accessibility bounds and visibility describe where the button really is.
        return node.visible && node.interactive && x>=node.left && x<node.right && y>=node.top && y<node.bottom?node.index:-1;
    }
}
