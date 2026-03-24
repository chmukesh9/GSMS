public with sharing class SmsErrorLogger {

    public enum Source {
        ScheduleBatch, EventEngine, ConditionEvaluator, TemplateEngine, FlowSender, PhoneUtil, Config
    }
    public enum Severity { Error, Warning, Info }

    public static void log(
        Severity severity,
        Source source,
        String runMode,
        String fireKey,
        Id masterId,
        Id ruleId,
        Id templateId,
        Id parameterId,
        String targetObjectApi,
        Id targetRecordId,
        Exception ex,
        Map<String,Object> details
    ) {
        try {
            sms_error_log__c rec = new sms_error_log__c();
            rec.Timestamp__c         = System.now();
            rec.Run_Mode__c          = runMode;
            rec.Fire_Key__c          = fireKey;
            rec.Master__c            = masterId;
            rec.Rule__c              = ruleId;
            rec.Template__c          = templateId;
            rec.Parameter__c         = parameterId;
            rec.Target_Object__c     = targetObjectApi;
            rec.Target_Record_Id__c  = targetRecordId;
            rec.Source_Component__c  = String.valueOf(source);
            rec.Severity__c          = String.valueOf(severity);
            rec.User__c              = UserInfo.getUserId();

            if (ex != null) {
                rec.Exception_Type__c = ex.getTypeName();
                String msg = ex.getMessage();
                if (msg != null && msg.length() > 255) msg = msg.substring(0,255);
                rec.Message__c    = msg;
                rec.Stacktrace__c = ex.getStackTraceString();
            }
            if (details != null && !details.isEmpty()) {
                rec.Details_Json__c = JSON.serialize(details);
            }
            insert rec;
        } catch (Exception swallow) {
            System.debug('SmsErrorLogger failed: ' + swallow.getMessage());
        }
    }

    public static void warnConfig(
        Source source,
        String runMode,
        String fireKey,
        Id masterId,
        Id ruleId,
        String targetObjectApi,
        Id targetRecordId,
        String message,
        Map<String,Object> details
    ) {
        Map<String,Object> ctx = new Map<String,Object>();
        if (details != null) ctx.putAll(details);
        ctx.put('message', message);
        log(Severity.Warning, source, runMode, fireKey, masterId, ruleId, null, null,
            targetObjectApi, targetRecordId, null, ctx);
    }
}