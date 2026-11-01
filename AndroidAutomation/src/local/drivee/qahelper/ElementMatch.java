package local.drivee.qahelper;

import java.util.*;

/** No coordinates or sibling indices: an ambiguous match must never become a tap. */
public final class ElementMatch {
    public static final class Key {
        public final String pkg,id,kind,label,context;
        public Key(String pkg,String id,String kind,String label,String context) {
            this.pkg=clean(pkg);this.id=clean(id);this.kind=clean(kind);this.label=clean(label);this.context=clean(context);
        }
    }
    private static String clean(String s){return s==null?"":s.trim().replaceAll("\\s+"," ");}
    public static int unique(Key source,List<Key> candidates) {
        List<Integer> found=new ArrayList<>();
        for(int i=0;i<candidates.size();i++) {
            Key k=candidates.get(i);
            if(!source.pkg.equals(k.pkg))continue;
            if(!source.id.isEmpty()){if(source.id.equals(k.id))found.add(i);}
            else if(source.kind.equals(k.kind) && ((!source.label.isEmpty() && source.label.equals(k.label)) || (source.label.isEmpty() && source.kind.equals("android.widget.EditText"))))found.add(i);
        }
        if(found.size()>1 && !source.label.isEmpty())found.removeIf(i->!source.label.equals(candidates.get(i).label));
        if(found.size()>1 && !source.context.isEmpty())found.removeIf(i->!source.context.equals(candidates.get(i).context));
        return found.size()==1?found.get(0):-1;
    }
    public static boolean same(Key a,Key b){
        return a.pkg.equals(b.pkg) && a.id.equals(b.id) && a.kind.equals(b.kind) && a.label.equals(b.label) && a.context.equals(b.context);
    }
}
