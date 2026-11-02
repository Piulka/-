package local.drivee.qahelper;
public final class TapTreeTests {
    private static TapTree.Node node(int i,int l,int t,int r,int b,int z,boolean interactive){return new TapTree.Node(i,l,t,r,b,z,true,interactive);}
    private static void expect(boolean ok){if(!ok)throw new AssertionError();}
    public static void main(String[] args){
        TapTree.Node root=node(0,0,0,1080,2340,0,false),map=node(1,0,0,1080,2340,0,true);
        TapTree.Node pin=node(2,200,500,800,700,0,true),drawer=node(3,0,0,897,2340,1,false),row=node(4,0,450,897,750,0,true);
        root.children.add(map);map.children.add(pin);root.children.add(drawer);drawer.children.add(row);
        expect(TapTree.hit(root,500,600)==4); // Foreground menu wins over smaller covered map control.
        expect(TapTree.hit(root,1000,600)==1); // Outside drawer: handled separately as drawer dismissal.
        TapTree.Node icon=node(5,50,480,100,530,0,false);row.children.add(icon);
        expect(TapTree.hit(root,70,500)==4); // Non-clickable label/image resolves to its actionable parent.
        TapTree.Node close=node(6,850,20,895,65,2,true);drawer.children.add(close);
        int captured=TapTree.hit(root,870,40);drawer.children.remove(close);
        expect(captured==6 && TapTree.hit(root,870,40)!=6); // Selector must be captured before closing removes the node.
        expect(TapTree.hit(root,-1,200)==-1);
        TapTree.Node translatedParent=new TapTree.Node(7,0,0,100,50,0,false,false),translatedButton=node(8,0,120,100,200,0,true);
        translatedParent.children.add(translatedButton);
        expect(TapTree.hit(translatedParent,40,150)==8); // Translated child outside a non-clipping wrapper.
        System.out.println("Pre-tap hit testing and overlay ordering: passed");
    }
}
