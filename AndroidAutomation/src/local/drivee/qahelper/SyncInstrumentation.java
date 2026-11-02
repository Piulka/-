package local.drivee.qahelper;

import android.app.*;
import android.content.Context;
import android.graphics.Point;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.os.*;
import android.net.*;
import android.view.*;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.view.accessibility.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Session-only UiAutomation connection; no persistent accessibility service or event log. */
public class SyncInstrumentation extends Instrumentation {
    private static final class TapFailure extends IOException{final String code;TapFailure(String code){this.code=code;}}
    private UiAutomation ui;
    private BufferedWriter writer;
    private final Object outputLock=new Object();
    private final List<Echo> echoes=new ArrayList<>();
    private final List<long[]> managedTaps=new ArrayList<>();
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
        if(!action.equals("text"))synchronized(managedTaps){
            long now=SystemClock.uptimeMillis();managedTaps.removeIf(range->range[1]<now-2000);
            for(long[] range:managedTaps)if(e.getEventTime()>=range[0] && e.getEventTime()<=range[1])return;
        }
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
        if(!Arrays.asList("click","long","text","dismissDrawer").contains(action))return false;
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
            if(action.equals("dismissDrawer")){
                Point screen=displaySize();if(!isOpenDrawer(n,screen))return false;
                Rect drawer=new Rect();n.getBoundsInScreen(drawer);
                // Dismiss through this device's scrim. Legacy Back injection can be
                // accepted by Android while the app's predictive-back drawer stays open.
                int left=Math.max(0,drawer.left),right=Math.max(0,screen.x-drawer.right);
                if(Math.max(left,right)<8)return false;
                int x=right>=left?drawer.right+right/2:left/2;
                int y=Math.max(0,Math.min(screen.y-1,drawer.centerY()));
                return injectTap(x,y,40);
            }
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
            // Some custom controls handle touch but reject ACTION_CLICK. Resolve the target's
            // own element bounds; never copy the source device's coordinates.
            if(!ok && !action.equals("text")){Rect bounds=new Rect();n.getBoundsInScreen(bounds);ok=!bounds.isEmpty() && injectTap(bounds.centerX(),bounds.centerY(),action.equals("long")?600:40);}
            if(!ok)synchronized(echoes){if(echoes.remove(echo))echo.node.recycle();}
            return ok;
        }finally{for(AccessibilityNodeInfo n:nodes)n.recycle();while(!queue.isEmpty())queue.remove().recycle();}
    }
    private Point displaySize(){
        Point size=new Point();DisplayManager manager=(DisplayManager)getTargetContext().getSystemService(Context.DISPLAY_SERVICE);
        manager.getDisplay(Display.DEFAULT_DISPLAY).getRealSize(size);return size;
    }
    private static boolean isOpenDrawer(AccessibilityNodeInfo n,Point screen){
        if(!str(n.getViewIdResourceName()).endsWith("/main_fragmentcontainerview_navigation") || !n.isVisibleToUser())return false;
        Rect b=new Rect();n.getBoundsInScreen(b);return b.width()>0 && b.width()<screen.x*0.98 && b.height()>screen.y*0.5;
    }
    private boolean injectTap(int x,int y,int duration)throws InterruptedException {
        long began=SystemClock.uptimeMillis();MotionEvent down=MotionEvent.obtain(began,began,MotionEvent.ACTION_DOWN,x,y,0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        boolean ok;
        try{ok=ui.injectInputEvent(down,true);}finally{down.recycle();}
        try{Thread.sleep(duration);}finally{
            MotionEvent up=MotionEvent.obtain(began,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,x,y,0);
            up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try{ok=ui.injectInputEvent(up,true) && ok;}finally{up.recycle();}
        }
        return ok;
    }
    private JSONObject sourceTap(JSONObject command)throws Exception {
        double nx=command.optDouble("x",-1),ny=command.optDouble("y",-1);
        if(!Double.isFinite(nx) || !Double.isFinite(ny) || nx<0 || nx>1 || ny<0 || ny>1)throw new TapFailure("coordinates");
        Point screen=displaySize();int x=Math.min(screen.x-1,(int)(nx*screen.x)),y=Math.min(screen.y-1,(int)(ny*screen.y));
        int duration=command.optDouble("duration",0)>=0.45?600:40;
        boolean keyboard=false;
        List<AccessibilityWindowInfo> windows=ui.getWindows();
        for(AccessibilityWindowInfo window:windows){Rect b=new Rect();window.getBoundsInScreen(b);if(window.getType()==AccessibilityWindowInfo.TYPE_INPUT_METHOD && b.contains(x,y))keyboard=true;window.recycle();}
        JSONObject relay=null;
        if(!keyboard){
            AccessibilityNodeInfo root=ui.getRootInActiveWindow();if(root==null)throw new TapFailure("root_unavailable");
            List<AccessibilityNodeInfo> nodes=new ArrayList<>();
            AccessibilityNodeInfo drawer=null;
            try{
                TapTree.Node snapshot=captureTree(root,nodes,duration>40,0);
                for(AccessibilityNodeInfo n:nodes){Rect b=new Rect();n.getBoundsInScreen(b);if(isOpenDrawer(n,screen) && !b.contains(x,y))drawer=n;}
                if(drawer!=null)relay=new JSONObject().put("action","dismissDrawer").put("element",json(key(drawer)));
                else{
                    int index=TapTree.hit(snapshot,x,y);if(index<0)throw new TapFailure("no_hit");
                    AccessibilityNodeInfo hit=nodes.get(index);
                    relay=new JSONObject().put("action",duration>40?"long":"click").put("element",json(key(hit))).put("value","");
                }
            }finally{for(AccessibilityNodeInfo n:nodes)n.recycle();}
        }
        long now=SystemClock.uptimeMillis();synchronized(managedTaps){managedTaps.removeIf(range->range[1]<now-2000);managedTaps.add(new long[]{now,now+duration+500});}
        if(!injectTap(x,y,duration))throw new TapFailure("input_rejected");
        return new JSONObject().put("ok",true).put("relay",relay==null?JSONObject.NULL:relay);
    }
    private TapTree.Node captureTree(AccessibilityNodeInfo n,List<AccessibilityNodeInfo> nodes,boolean longPress,int depth)throws IOException {
        int index=nodes.size();nodes.add(n);Rect b=new Rect();n.getBoundsInScreen(b);
        TapTree.Node result=new TapTree.Node(index,b.left,b.top,b.right,b.bottom,n.getDrawingOrder(),n.isVisibleToUser(),n.isEnabled() && !n.isPassword() && (n.isClickable() || n.isEditable() || (longPress && n.isLongClickable())));
        if(depth<80 && nodes.size()<3000)for(int i=0;i<n.getChildCount();i++){
            AccessibilityNodeInfo child=n.getChild(i);if(child!=null)result.children.add(captureTree(child,nodes,longPress,depth+1));
            if(nodes.size()>=3000)break;
        }
        return result;
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
            String line;while(live && (line=readLine(reader,262144))!=null){
                JSONObject c=new JSONObject(line),reply;
                try{reply=c.optString("action").equals("sourceTap")?sourceTap(c):new JSONObject().put("ok",apply(c));}
                catch(Exception error){
                    String reason=error instanceof TapFailure?((TapFailure)error).code:error.getClass().getSimpleName();
                    android.util.Log.w("ZhmakeeSync",reason); // Error category only: never field values or selectors.
                    reply=new JSONObject().put("ok",false).put("reason",reason);
                }
                send(reply.put("ack",c.optString("request")));
            }
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
