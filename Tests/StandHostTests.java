package local.drivee.qahelper;
public class StandHostTests {
    static void check(boolean value){if(!value)throw new AssertionError();}
    public static void main(String[] args){
        for(int i=1;i<=10;i++){
            String stand=String.format("%02d",i),host="test"+stand+"-fridi.int.indels.dev";
            check(StandHost.valid(stand));check(StandHost.matches("Сервер API https://"+host+"/",stand));
            check(!StandHost.matches(host,"stage"));check(!StandHost.matches("evil-"+host,stand));
        }
        check(StandHost.matches("https://fridi.int.indels.dev/","stage"));
        check(!StandHost.matches("test010-fridi.int.indels.dev","01"));
        check(!StandHost.valid("00"));check(!StandHost.valid("11"));check(!StandHost.valid(null));
        System.out.println("Android server host matching: passed");
    }
}
