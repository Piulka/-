package local.drivee.qahelper;

import android.app.*;
import android.os.*;
import android.content.*;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.view.*;
import android.view.accessibility.*;
import android.graphics.Rect;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class FlowInstrumentation extends Instrumentation {
    static final String PKG="com.drivee.taxi.rides", PREFIX=PKG+":id/";
    UiAutomation ui;
    File dir;
    long started, deadline;
    interface Check { boolean ready(AccessibilityNodeInfo root) throws Exception; }
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        started=SystemClock.uptimeMillis();deadline=started+45000;
        Bundle result=new Bundle();
        try {
            dir=getTargetContext().getFilesDir();
            ui=getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo service=ui.getServiceInfo();
            service.flags|=AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS|AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            ui.setServiceInfo(service);
            File file=new File(dir,"request.json");
            JSONObject request=file.exists()?new JSONObject(new String(java.nio.file.Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8)):new JSONObject();
            file.delete();
            long rootUntil=SystemClock.uptimeMillis()+2000;
            while(root()==null && SystemClock.uptimeMillis()<rootUntil)SystemClock.sleep(50);
            String mode=request.optString("mode","inspect");
            if(mode.equals("auth") && rateLimited(root())) {
                AccessibilityNodeInfo close=findText(root(),"Закрыть");
                if(close!=null){click(close);pause(200);}
            }
            if(mode.equals("inspect")) inspect();
            else if(mode.equals("click")) {
                waitFor(r -> request.has("id")?findId(r,request.getString("id"))!=null:findText(r,request.getString("text"))!=null,2500);
                AccessibilityNodeInfo n=request.has("id")?findId(root(),request.getString("id")):findText(root(),request.getString("text"));
                if(n==null)throw new Exception("element_not_found");click(n);pause(180);inspect();
            } else if(mode.equals("set")) {
                AccessibilityNodeInfo n=findId(root(),request.getString("id"));
                if(n==null)throw new Exception("field_not_found");set(n,request.getString("value"));pause(200);inspect();
            } else if(mode.equals("back")) { key(KeyEvent.KEYCODE_BACK);pause(200);inspect(); }
            else if(mode.equals("auth")) authenticate(request);
            else if(mode.equals("prepare")){ensurePhone();if(request.has("stand"))selectStand(request.getString("stand"));inspect();}
            else throw new Exception("unsupported_mode");
            JSONObject done=new JSONObject().put("state","success").put("elapsed_ms",SystemClock.uptimeMillis()-started);
            write("status.json",done.toString());result.putString("result","success");
        } catch(Exception error) {
            try { inspect(); } catch(Exception ignored) {}
            try { write("status.json",new JSONObject().put("state","error").put("error",error instanceof FlowError?error.getMessage():"automation_failed").toString()); } catch(Exception ignored) {}
            result.putString("result","error");
        } finally { finish(Activity.RESULT_OK,result); }
    }
    AccessibilityNodeInfo root(){ return ui.getRootInActiveWindow(); }
    void pause(long ms) throws Exception { if(SystemClock.uptimeMillis()>deadline)throw new FlowError("timeout");SystemClock.sleep(ms); }
    void waitFor(Check c,long max) throws Exception {
        long end=Math.min(deadline,SystemClock.uptimeMillis()+max);
        do { AccessibilityNodeInfo r=root(); if(rateLimited(r))throw new FlowError("rate_limited"); if(c.ready(r))return;pause(50); } while(SystemClock.uptimeMillis()<end);
        throw new FlowError("unexpected_screen");
    }
    boolean rateLimited(AccessibilityNodeInfo r){StringBuilder text=new StringBuilder();for(AccessibilityNodeInfo n:nodes(r))text.append(' ').append(str(n.getText()));String t=text.toString();return t.contains("Превышено количество")||t.contains("слишком много попыток");}
    static String str(CharSequence x){ return x==null?"":x.toString(); }
    List<AccessibilityNodeInfo> nodes(AccessibilityNodeInfo r) {
        ArrayList<AccessibilityNodeInfo> out=new ArrayList<>();if(r==null)return out;
        ArrayDeque<AccessibilityNodeInfo> queue=new ArrayDeque<>();queue.add(r);
        while(!queue.isEmpty() && out.size()<2500) {
            AccessibilityNodeInfo n=queue.removeFirst();out.add(n);
            for(int i=0;i<n.getChildCount();i++){AccessibilityNodeInfo child=n.getChild(i);if(child!=null)queue.add(child);}
        }return out;
    }
    AccessibilityNodeInfo findId(AccessibilityNodeInfo r,String id) {
        if(r==null)return null;
        String full=id.contains(":id/")?id:PREFIX+id;
        for(AccessibilityNodeInfo n:r.findAccessibilityNodeInfosByViewId(full))if(n.isVisibleToUser())return n;
        return null;
    }
    AccessibilityNodeInfo findText(AccessibilityNodeInfo r,String text) {
        for(AccessibilityNodeInfo n:nodes(r))if(n.isVisibleToUser() && (str(n.getText()).equals(text)||str(n.getContentDescription()).equals(text)))return n;
        return null;
    }
    void click(AccessibilityNodeInfo n) throws Exception {
        AccessibilityNodeInfo p=n;
        for(int i=0;p!=null && i<5;i++,p=p.getParent())if(p.isClickable()&&p.isEnabled()&&p.performAction(AccessibilityNodeInfo.ACTION_CLICK))return;
        Rect bounds=new Rect();n.getBoundsInScreen(bounds);
        long t=SystemClock.uptimeMillis();
        MotionEvent down=MotionEvent.obtain(t,t,MotionEvent.ACTION_DOWN,bounds.centerX(),bounds.centerY(),0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN);ui.injectInputEvent(down,true);down.recycle();
        MotionEvent up=MotionEvent.obtain(t,t+45,MotionEvent.ACTION_UP,bounds.centerX(),bounds.centerY(),0);
        up.setSource(InputDevice.SOURCE_TOUCHSCREEN);ui.injectInputEvent(up,true);up.recycle();
    }
    void key(int code){ ui.injectInputEvent(new KeyEvent(KeyEvent.ACTION_DOWN,code),true);ui.injectInputEvent(new KeyEvent(KeyEvent.ACTION_UP,code),true); }
    void set(AccessibilityNodeInfo n,String text) throws Exception {
        Bundle value=new Bundle();value.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,text);
        if(!n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,value))throw new Exception("text_input_failed");
    }
    void write(String name,String content) throws Exception { try(FileOutputStream stream=new FileOutputStream(new File(dir,name))) { stream.write(content.getBytes(StandardCharsets.UTF_8)); } }
    void stage(String value) throws Exception { write("status.json",new JSONObject().put("state","running").put("stage",value).toString()); }
    void inspect() throws Exception {
        JSONArray rows=new JSONArray();
        for(AccessibilityNodeInfo n:nodes(root())) {
            if(!n.isVisibleToUser())continue;
            String id=str(n.getViewIdResourceName()),text=str(n.getText()),desc=str(n.getContentDescription());
            if(id.isEmpty()&&text.isEmpty()&&desc.isEmpty())continue;
            if(text.matches(".*[0-9].*"))text="[numeric value]";
            if(desc.matches(".*[0-9].*"))desc="[numeric description]";
            Rect b=new Rect();n.getBoundsInScreen(b);
            rows.put(new JSONObject().put("id",id).put("text",text).put("desc",desc).put("click",n.isClickable()).put("bounds",b.toShortString()));
        }write("inspection.json",rows.toString());
    }

    static class FlowError extends Exception { FlowError(String s){super(s);} }
    void fail(String s) throws Exception { throw new FlowError(s); }
    boolean phone(AccessibilityNodeInfo r){return findId(r,"ui_phone_layout_edit_text")!=null;}
    void tapId(String id) throws Exception { AccessibilityNodeInfo n=findId(root(),id);if(n==null)fail("element_missing");click(n); }
    boolean standMatches(String value,String stand){return java.util.regex.Pattern.compile("(?i)test"+stand+"(?![0-9])").matcher(value).find();}
    AccessibilityNodeInfo host(AccessibilityNodeInfo r,String stand){for(AccessibilityNodeInfo n:nodes(r))if(n.isVisibleToUser()&&str(n.getViewIdResourceName()).endsWith("/server_api_list_item_textview_hostname")&&standMatches(str(n.getText()),stand))return n;return null;}
    void ensurePhone() throws Exception {
        stage("open");
        Intent launch=getTargetContext().getPackageManager().getLaunchIntentForPackage(PKG);
        if(launch==null)fail("app_missing");
        AccessibilityNodeInfo current=root();
        if(current==null||!PKG.equals(str(current.getPackageName()))){launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);getTargetContext().startActivity(launch);waitFor(r->r!=null&&PKG.equals(str(r.getPackageName())),5000);pause(180);}
        for(int step=0;step<18;step++){
            AccessibilityNodeInfo r=root();if(phone(r))return;
            AccessibilityNodeInfo n=findId(r,"server_api_list_close");
            if(n!=null){click(n);pause(150);continue;}
            n=findId(r,"ui_tooltip_content_button");if(n!=null){click(n);pause(100);continue;}
            if(findText(r,"Вы действительно хотите выйти из аккаунта?")!=null){tapId("android:id/button1");waitFor(x->phone(x),4000);return;}
            n=findText(r,"Выйти из аккаунта");if(n!=null){stage("logout");click(n);waitFor(x->findId(x,"android:id/button1")!=null||phone(x),3000);continue;}
            n=findText(r,"Настройки");if(n!=null&&findId(r,"navigation_drawer_recyclerview")!=null){click(n);waitFor(x->findText(x,"Выйти из аккаунта")!=null,2500);continue;}
            n=findId(r,"main_floatingactionbutton_menu");if(n==null)n=findText(r,"Меню");
            if(n!=null){stage("logout");click(n);waitFor(x->findId(x,"navigation_drawer_recyclerview")!=null,2000);continue;}
            key(KeyEvent.KEYCODE_BACK);pause(220);
        }fail("login_screen_unavailable");
    }
    void selectStand(String stand) throws Exception {
        stage("server");AccessibilityNodeInfo label=findId(root(),"authorization_change_server");if(label==null)fail("server_selector_missing");
        if(standMatches(str(label.getText()),stand))return;
        click(label);waitFor(r->findId(r,"server_api_list")!=null,1800);
        for(int i=0;i<10;i++){AccessibilityNodeInfo list=findId(root(),"server_api_list");if(list==null||host(root(),stand)!=null||!list.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD))break;pause(80);}
        for(int i=0;i<12;i++){
            AccessibilityNodeInfo list=findId(root(),"server_api_list"),match=host(root(),stand);
            if(match!=null){click(match);pause(120);AccessibilityNodeInfo close=findId(root(),"server_api_list_close");if(close!=null)click(close);
                waitFor(r->{AccessibilityNodeInfo l=findId(r,"authorization_change_server");return l!=null&&standMatches(str(l.getText()),stand);},2500);return;}
            if(list==null||!list.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD))break;pause(100);
        }fail("server_not_found");
    }
    boolean authenticated(AccessibilityNodeInfo r){return findId(r,"main_floatingactionbutton_menu")!=null || (findId(r,"main_drawerlayout")!=null && findId(r,"driver_city_tab_orders")!=null);}
    void authenticate(JSONObject request) throws Exception {
        String number=request.optString("phone").replaceAll("[^0-9]",""),otp=request.optString("otp"),stand=request.optString("stand","08");
        if(!number.startsWith("258")||number.length()!=11||!otp.matches("[0-9]{4}")||!stand.matches("0[89]"))fail("invalid_request");
        ensurePhone();selectStand(stand);stage("phone");
        AccessibilityNodeInfo flag=findId(root(),"ui_phone_layout_flag_layout");
        if(flag==null)fail("country_selector_missing");
        if(!str(flag.getContentDescription()).contains("258")){
            click(flag);waitFor(r->findText(r,"Мозамбик (+258)")!=null||findId(r,"country_dialog_edittext_city_name")!=null,1800);
            AccessibilityNodeInfo country=findText(root(),"Мозамбик (+258)");
            if(country==null){set(findId(root(),"country_dialog_edittext_city_name"),"Мозамбик");waitFor(r->findText(r,"Мозамбик (+258)")!=null,1500);country=findText(root(),"Мозамбик (+258)");}
            click(country);waitFor(r->phone(r),1200);
        }
        set(findId(root(),"ui_phone_layout_edit_text"),number.substring(3));
        waitFor(r->{AccessibilityNodeInfo n=findId(r,"ui_phone_layout_edit_text");return n!=null&&str(n.getText()).replaceAll("[^0-9]","").equals(number);},1000);
        tapId("authorization_phone_btn_next");stage("otp");waitFor(r->findId(r,"authorization_authcode_edittext_code")!=null,8000);
        set(findId(root(),"authorization_authcode_edittext_code"),otp);
        stage("verify");
        for(int step=0;step<4;step++){
            waitFor(r->authenticated(r)||findId(r,"ui_tooltip_content_button")!=null||findId(r,"onboarding_btn_skip")!=null,14000);
            AccessibilityNodeInfo r=root();if(authenticated(r))return;
            AccessibilityNodeInfo extra=findId(r,"onboarding_btn_skip");if(extra==null)extra=findId(r,"ui_tooltip_content_button");
            if(extra!=null){click(extra);pause(150);}
        }
        if(!authenticated(root()))fail("unexpected_screen");
        // Successful OTP for the verified number plus authenticated main screen confirms the selected account.
    }

}
