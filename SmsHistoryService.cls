public with sharing class SmsHistoryService {
    public class HistoryLogItem {
        public SObject rec;
        public String runMode;
        public String fireKey;
        public String phoneE164;
        public String masterCode;
        public String templateCode;
        public String messageBody;
    }

    /**
     * Log a successful SMS submission to sms_history__c following the admin's rule:
     * - If target is ServiceAppointment: record BOTH Service_Appointment__c and Work_Order__c
     * - If target is WorkOrder: record ONLY Work_Order__c
     */
    public static void logSuccess(
        SObject rec,
        String runMode,            // 'Instant' or 'Scheduled'
        String fireKey,            // fire key for scheduled, null for instant
        String phoneE164,          // +61...
        String masterCode,         // e.g., 'DSC-0001' (Name of derive_sms_condition_master__c)
        String templateCode,       // e.g., 'DST-0001' (Name of derive_sms_template_master__c)
        String messageBody
    ) {
        HistoryLogItem item = new HistoryLogItem();
        item.rec = rec;
        item.runMode = runMode;
        item.fireKey = fireKey;
        item.phoneE164 = phoneE164;
        item.masterCode = masterCode;
        item.templateCode = templateCode;
        item.messageBody = messageBody;
        logSuccessBulk(new List<HistoryLogItem>{ item });
    }

    public static void logSuccessBulk(List<HistoryLogItem> items) {
        if (items == null || items.isEmpty()) return;

        List<sms_history__c> toInsert = new List<sms_history__c>();
        Map<String, Set<Id>> idsByObject = new Map<String, Set<Id>>();
        String firstRunMode = null;

        for (HistoryLogItem item : items) {
            if (item == null || item.rec == null) continue;

            String api = String.valueOf(item.rec.getSObjectType());
            Id saId = null;
            Id woId = null;

            if (api == 'ServiceAppointment') {
                saId = (Id) item.rec.get('Id');
                woId = resolveWorkOrderIdFromSA(item.rec);
            } else if (api == 'WorkOrder') {
                woId = (Id) item.rec.get('Id');
            }

            sms_history__c h = new sms_history__c();
            h.Run_Mode__c           = item.runMode;
            h.Fire_Key__c           = item.fireKey;
            h.Target_Object_API__c  = api;
            h.Target_Record_Id__c   = String.valueOf(item.rec.get('Id'));
            if (saId != null) h.Service_Appointment__c = saId;
            if (woId != null) h.Work_Order__c          = woId;

            h.Phone_Number__c       = item.phoneE164;
            h.Master_Condition__c   = item.masterCode;
            h.Template__c           = item.templateCode;
            h.Message__c            = item.messageBody;
            h.sms_char_count__c     = (item.messageBody == null ? 0 : item.messageBody.length());
            h.SMS_Sent_At__c        = System.now();
            toInsert.add(h);

            if (firstRunMode == null) firstRunMode = item.runMode;

            Id recId = (Id) item.rec.get('Id');
            if (recId != null) addTargetId(idsByObject, api, recId);
            if (api == 'ServiceAppointment') {
                if (saId != null) addTargetId(idsByObject, 'ServiceAppointment', saId);
                if (woId != null) addTargetId(idsByObject, 'WorkOrder', woId);
            }
        }

        if (toInsert.isEmpty()) return;

        try {
            insert toInsert;
            stampLastSmsSentOnBulk(idsByObject);
        } catch (Exception e) {
            // Do not block the transaction for history insert; record a warning for developers.
            try {
                SmsErrorLogger.log(
                    SmsErrorLogger.Severity.Warning,
                    SmsErrorLogger.Source.EventEngine,  // generic source for success logging
                    firstRunMode, null,
                    null, null, null, null,
                    null, null,
                    e, new Map<String,Object>{ 'note' => 'History bulk insert failed', 'count' => toInsert.size() }
                );
            } catch (Exception ignore) {}
        }
    }



    /**
     * Stamps last_sms_sent_on__c on relevant records when the field exists.
     * - Generic: always attempts on the triggering object record.
     * - Custom SA behavior: also stamps related WorkOrder when source is ServiceAppointment.
     */
    private static void stampLastSmsSentOnBulk(Map<String, Set<Id>> idsByObject) {
        if (idsByObject == null || idsByObject.isEmpty()) return;
        Datetime nowDt = System.now();
        for (String objectApi : idsByObject.keySet()) {
            stampFieldIfPresent(objectApi, idsByObject.get(objectApi), 'last_sms_sent_on__c', nowDt);
        }
    }

    private static void addTargetId(Map<String, Set<Id>> idsByObject, String objectApi, Id recordId) {
        if (String.isBlank(objectApi) || recordId == null) return;
        if (!idsByObject.containsKey(objectApi)) idsByObject.put(objectApi, new Set<Id>());
        idsByObject.get(objectApi).add(recordId);
    }

    private static void stampFieldIfPresent(String objectApi, Set<Id> recordIds, String fieldApi, Datetime valueToSet) {
        if (String.isBlank(objectApi) || String.isBlank(fieldApi) || recordIds == null || recordIds.isEmpty()) return;

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType st = gd.get(objectApi);
        if (st == null) return;

        Map<String, Schema.SObjectField> fMap = st.getDescribe().fields.getMap();
        if (!fMap.containsKey(fieldApi)) return;

        List<SObject> updates = new List<SObject>();
        for (Id rid : recordIds) {
            if (rid == null) continue;
            SObject upd = st.newSObject(rid);
            upd.put(fieldApi, valueToSet);
            updates.add(upd);
        }

        if (!updates.isEmpty()) {
            try {
                SmsEventEngine.beginSuppress();
                update updates;
            } catch (Exception e) {
                try {
                    SmsErrorLogger.log(
                        SmsErrorLogger.Severity.Warning,
                        SmsErrorLogger.Source.EventEngine,
                        null, null,
                        null, null, null, null,
                        objectApi, null,
                        e,
                        new Map<String,Object>{
                            'note' => 'last_sms_sent_on__c update failed',
                            'recordCount' => updates.size(),
                            'fieldApi' => fieldApi
                        }
                    );
                } catch (Exception ignore) {}
            } finally {
                SmsEventEngine.endSuppress();
            }
        }
    }

    // ---- Helpers ----

    /**
     * Returns the Work Order Id for a Service Appointment.
     * Uses hard-coded field FSSK__FSK_Work_Order__c first, then common fallbacks if present.
     * Never queries; relies on fields present on the SA record (or already-prefetched values).
     */
    private static Id resolveWorkOrderIdFromSA(SObject sa) {
        if (sa == null) return null;

        Map<String, Schema.SObjectField> fMap = sa.getSObjectType().getDescribe().fields.getMap();
        for (String api : new List<String>{ 'FSSK__FSK_Work_Order__c',  'ParentRecordId' }) {
            if (fMap.containsKey(api)) {
                try {
                    Id x = (Id) sa.get(api);
                    if (x != null) return x;
                } catch (Exception ignore) {}
            }
        }
        return null;
    }
}