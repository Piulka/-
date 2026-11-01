package local.drivee.qahelper;

import android.app.*;
import android.os.*;
import android.net.*;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.view.accessibility.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Session-only UiAutomation connection; no persistent accessibility service or event log. */
public class SyncInstrumentation extends Instrumentation {
    private UiAutomation ui;
    private BufferedWriter writer;
    private final Object outputLock=new Object();
    private final List<Echo> echoes=new ArrayList<>();
    private volatile boolean live=false;
    private static final class Echo {
        AccessibilityNodeInfo node;String action,value;long until;
        Echo(AccessibilityNodeInfo n,String a,String v){node=AccessibilityNodeInfo.obtain(n);action=a;value=v;until=SystemClock.uptimeMillis()+1000;}
    }
    @Override public void onCreate(Bundle b){super.onCreate(b);start();}
    private static String str(CharSequence c){return c==null?"":c.toString();}
    private static String label(AccessibilityNodeInfo n,int depth){
        if(n==null || n.isPassword() || depth>2)return "";
        if(n.isEditable())return str(n.getHintText());
        String direct=str(n.getContentDescription());if(direct.isEmpty())direct=str(n.getText());
        if(!direct.isEmpty())return direct.length()>300?direct.substring(0,300):direct;
        List<String> labels=new ArrayList<>();
        for(int i=0;i<n.getChildCount() && i<12;i++){AccessibilityNodeInfo child=n.getChild(i);if(child!=null){String l=label(child,depth+1);child.recycle();if(!l.isEmpty())labels.add(l);}}
        return String.join(" | ",labels);
    }
    private static ElementMatch.Key key(AccessibilityNodeInfo n){
        String context="";AccessibilityNodeInfo parent=n.getParent();
        if(parent!=null){context=str(parent.getViewIdResourceName());parent.recycle();}
        return new ElementMatch.Key(str(n.getPackageName()),n.getViewIdResourceName(),str(n.getClassName()),label(n,0),context);
    }
    private static JSONObject json(ElementMatch.Key k)throws JSONException{return new JSONObject().put("pkg",k.pkg).put("id",k.id).put("kind",k.kind).put("label",k.label).put("context",k.context);}
    private static ElementMatch.Key key(JSONObject o){return new ElementMatch.Key(o.optString("pkg"),o.optString("id"),o.optString("kind"),o.optString("label"),o.optString("context"));}
    private void send(JSONObject o){synchronized(outputLock){try{if(writer!=null){writer.write(o.toString());writer.newLine();writer.flush();}}catch(IOException e){live=false;}}}
    private void event(AccessibilityEvent e){
        if(!live)return;
        int type=e.getEventType();
        String action=type==AccessibilityEvent.TYPE_VIEW_CLICKED?"click":type==AccessibilityEvent.TYPE_VIEW_LONG_CLICKED?"long":type==AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED?"text":"";
        if(action.isEmpty())return;
        AccessibilityNodeInfo n=e.getSource();if(n==null)return;
        try {
            if(n.isPassword())return;
            // IMEs differ between the phones. Replicate the app field value, never keyboard keys.
            AccessibilityNodeInfo root=ui.getRootInActiveWindow();if(root==null)return;
            String pkg=str(root.getPackageName());root.recycle();
            if(!pkg.equals(str(n.getPackageName())) || pkg.equals("local.drivee.qahelper"))return;
            if(action.equals("text") && !n.isEditable())return;
            ElementMatch.Key k=key(n);String value=action.equals("text")?str(n.getText()):"";
            if(value.length()>12000)return;
            synchronized(echoes){
                long now=SystemClock.uptimeMillis();
                for(Iterator<Echo> it=echoes.iterator();it.hasNext();){Echo x=it.next();if(x.until<now){x.node.recycle();it.remove();continue;}if(x.action.equals(action) && x.node.equals(n) && x.value.equals(value)){x.node.recycle();it.remove();return;}}
            }
            send(new JSONObject().put("event",true).put("action",action).put("element",json(k)).put("value",value));
        }catch(Exception ignored){}finally{n.recycle();}
    }
    private boolean apply(JSONObject command)throws Exception {
        String action=command.optString("action");
        if(!Arrays.asList("click","long","text").contains(action))return false;
        ElementMatch.Key wanted=key(command.getJSONObject("element"));
        AccessibilityNodeInfo root=ui.getRootInActiveWindow();if(root==null)return false;
        List<AccessibilityNodeInfo> nodes=new ArrayList<>();List<ElementMatch.Key> keys=new ArrayList<>();
        ArrayDeque<AccessibilityNodeInfo> queue=new ArrayDeque<>();queue.add(root);
        try {
            if(!wanted.pkg.equals(str(root.getPackageName())))return false;
            while(!queue.isEmpty() && nodes.size()<3000){
                AccessibilityNodeInfo n=queue.remove();
                if(n.isVisibleToUser()){nodes.add(n);keys.add(key(n));}
                for(int i=0;i<n.getChildCount();i++){AccessibilityNodeInfo c=n.getChild(i);if(c!=null)queue.add(c);}
                if(!n.isVisibleToUser())n.recycle();
            }
            int index=ElementMatch.unique(wanted,keys);if(index<0)return false;
            AccessibilityNodeInfo n=nodes.get(index);
            if(!n.isVisibleToUser() || !n.isEnabled() || n.isPassword())return false;
            Bundle args=new Bundle();int op;
            String value=command.optString("value");
            if(action.equals("text")) {
                if(!n.isEditable() || value.length()>12000)return false;
                if(value.equals(str(n.getText())))return true;
                op=AccessibilityNodeInfo.ACTION_SET_TEXT;args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,value);
            }else {
                op=action.equals("long")?AccessibilityNodeInfo.ACTION_LONG_CLICK:AccessibilityNodeInfo.ACTION_CLICK;
                int count=0;
                while(!(action.equals("long")?n.isLongClickable():n.isClickable()) && count++<5){AccessibilityNodeInfo p=n.getParent();if(p==null)return false;nodes.add(p);n=p;}
                if(!(action.equals("long")?n.isLongClickable():n.isClickable()))return false;
            }
            Echo echo=new Echo(n,action,value);synchronized(echoes){if(echoes.size()>128){for(Echo x:echoes)x.node.recycle();echoes.clear();}echoes.add(echo);}
            boolean ok=n.performAction(op,args);
            if(!ok)synchronized(echoes){if(echoes.remove(echo))echo.node.recycle();}
            return ok;
        }finally{for(AccessibilityNodeInfo n:nodes)n.recycle();while(!queue.isEmpty())queue.remove().recycle();}
    }
    @Override public void onStart(){
        LocalServerSocket server=null;LocalSocket client=null;
        try {
            File request=new File(getTargetContext().getFilesDir(),"sync-request.json");
            byte[] data;try(FileInputStream in=new FileInputStream(request)){ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] chunk=new byte[1024];int n;while((n=in.read(chunk))!=-1)b.write(chunk,0,n);data=b.toByteArray();}finally{request.delete();}
            JSONObject config=new JSONObject(new String(data,StandardCharsets.UTF_8));
            String name=config.getString("socket"),token=config.getString("token");
            if(!name.matches("zhmakee_sync_[a-f0-9]{32}") || !token.matches("[a-f0-9]{64}"))throw new IOException();
            ui=getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo info=ui.getServiceInfo();info.flags|=AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS|AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;info.eventTypes=AccessibilityEvent.TYPES_ALL_MASK;ui.setServiceInfo(info);
            ui.setOnAccessibilityEventListener(this::event);
            server=new LocalServerSocket(name);client=server.accept();client.setSoTimeout(10000);
            BufferedReader reader=new BufferedReader(new InputStreamReader(client.getInputStream(),StandardCharsets.UTF_8));
            String auth=readLine(reader,128);
            if(auth==null || !MessageDigest.isEqual(auth.getBytes(StandardCharsets.UTF_8),token.getBytes(StandardCharsets.UTF_8)))throw new IOException();
            writer=new BufferedWriter(new OutputStreamWriter(client.getOutputStream(),StandardCharsets.UTF_8));
            live=true;client.setSoTimeout(0);send(new JSONObject().put("ready",true));
            String line;while(live && (line=readLine(reader,262144))!=null){JSONObject c=new JSONObject(line);boolean ok=apply(c);send(new JSONObject().put("ack",c.optString("request")).put("ok",ok));}
        }catch(Exception ignored){}finally{
            live=false;if(ui!=null)ui.setOnAccessibilityEventListener(null);
            synchronized(echoes){for(Echo x:echoes)x.node.recycle();echoes.clear();}
            try{if(client!=null)client.close();}catch(Exception ignored){}
            try{if(server!=null)server.close();}catch(Exception ignored){}
            finish(0,new Bundle());
        }
    }
    private static String readLine(Reader reader,int maximum)throws IOException {
        StringBuilder line=new StringBuilder();int c;while((c=reader.read())!=-1){if(c=='\n')return line.toString();if(line.length()>=maximum)throw new IOException();line.append((char)c);}return line.length()==0?null:line.toString();
    }
}
