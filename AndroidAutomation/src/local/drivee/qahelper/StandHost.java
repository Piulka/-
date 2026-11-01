package local.drivee.qahelper;

final class StandHost {
    static boolean valid(String stand){return stand!=null && (stand.equals("stage") || stand.matches("0[1-9]|10"));}
    static boolean matches(String value,String stand){
        if(value==null || !valid(stand))return false;
        String host=stand.equals("stage") ? "fridi.int.indels.dev" : "test"+stand+"-fridi.int.indels.dev";
        return java.util.regex.Pattern.compile("(?i)(?<![a-z0-9.-])"+java.util.regex.Pattern.quote(host)+"(?![a-z0-9.-])").matcher(value).find();
    }
}
