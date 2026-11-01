package local.drivee.qahelper;
import java.util.*;
public final class ElementMatchTests {
    private static ElementMatch.Key key(String id,String text,String parent){return new ElementMatch.Key("app",id,"Button",text,parent);}
    private static void expect(boolean ok){if(!ok)throw new AssertionError();}
    public static void main(String[] args){
        ElementMatch.Key next=key("next","Далее","form");
        expect(ElementMatch.unique(next,Arrays.asList(key("cancel","Отмена","form"),next))==1);
        expect(ElementMatch.unique(next,Arrays.asList(next,next))==-1);
        expect(ElementMatch.unique(key("title","Выйти","settings"),Arrays.asList(key("title","Язык","settings"),key("title","Выйти","settings")))==1);
        expect(ElementMatch.unique(key("title","Выйти","settings"),Arrays.asList(key("title","Выйти","dialog"),key("title","Выйти","settings")))==1);
        expect(ElementMatch.unique(next,Arrays.asList(new ElementMatch.Key("other","next","Button","Далее","form")))==-1);
        expect(ElementMatch.unique(key("","Далее","form"),Arrays.asList(key("","  Далее  ","form")))==0);
        expect(ElementMatch.unique(key("","","form"),Arrays.asList(key("","","form")))==-1);
        ElementMatch.Key bareField=new ElementMatch.Key("app","","android.widget.EditText","","form");
        expect(ElementMatch.unique(bareField,Arrays.asList(bareField))==0);
        expect(ElementMatch.unique(bareField,Arrays.asList(bareField,bareField))==-1);
        // The field value differs while typing. Stable IDs must still find the target field.
        expect(ElementMatch.unique(new ElementMatch.Key("app","phone","EditText","","form"),Arrays.asList(new ElementMatch.Key("app","phone","EditText","","form")))==0);
        System.out.println("Semantic element matching: passed");
    }
}
