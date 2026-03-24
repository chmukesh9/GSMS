public with sharing class SmsEventEngine {

    private static Set<String> intraTxKeys = new Set<String>();
    private static Integer suppressDepth = 0;

    public static void beginSuppress() { suppressDepth++; }
    public static void endSuppress() { if (suppressDepth > 0) suppressDepth--; }
    public static Boolean isSuppressed() { return suppressDepth > 0; }

    public static void handle(SObjectType sType, List<SObject> newList, Map<Id,SObject> oldMap) {
        if (isSuppressed()) return;
        if (newList == null || newList.isEmpty()) return;
        String targetApi = String.valueOf(sType);

        try {
            List<derive_sms_condition_master__c> masters = [
                SELECT Id, Name, Active__c, Object_API__c, trigger_type__c,
                       delivery_mode__c, Template__c,Schedule_TZ__c,
                       phone_1_source__c, phone_1_object__c, phone_1_field__c,
                       phone_2_source__c, phone_2_object__c, phone_2_field__c,
                       phone_3_source__c, phone_3_object__c, phone_3_field__c
                  FROM derive_sms_condition_master__c
                 WHERE Active__c = TRUE
                   AND Object_API__c = :targetApi
                   AND trigger_type__c = 'Event Based'
            ];
            if (masters.isEmpty()) return;

            Map<Id, List<derive_sms_rules__c>> rulesByMaster = new Map<Id, List<derive_sms_rules__c>>();
            for (derive_sms_rules__c r : [
                SELECT Id, Name, Active__c, master__c, condition_type__c,
                       filter_source__c, filter_object_name__c, filter_field__c,
                       Operator__c, filter_value__c, filter_offset_hours__c,offset_days__c,
                       transition_field_api__c, transition_old_value__c, transition_new_value__c
                  FROM derive_sms_rules__c
                 WHERE master__c IN :masters
            ]) {
                if (!rulesByMaster.containsKey(r.master__c)) rulesByMaster.put(r.master__c, new List<derive_sms_rules__c>());
                rulesByMaster.get(r.master__c).add(r);
            }

            Set<Id> tIds = new Set<Id>();
            for (derive_sms_condition_master__c m : masters) if (m.Template__c != null) tIds.add(m.Template__c);

            Map<Id, derive_sms_template_master__c> tmplById =
                tIds.isEmpty() ? new Map<Id, derive_sms_template_master__c>() :
                new Map<Id, derive_sms_template_master__c>([
                    SELECT Id, active__c, content__c,Name
                      FROM derive_sms_template_master__c
                     WHERE Id IN :tIds AND active__c = TRUE
                ]);

            Map<Id, List<Derive_SMS_Parameters__c>> varsByTemplate = new Map<Id, List<Derive_SMS_Parameters__c>>();
            if (!tIds.isEmpty()) {
                for (Derive_SMS_Parameters__c v : [
                    SELECT Id, Template__c, p_name__c, Object_Type__c, Object_API__c,
                           Field_API__c, Format_Type__c
                      FROM Derive_SMS_Parameters__c
                     WHERE Template__c IN :tIds
                ]) {
                    if (!varsByTemplate.containsKey(v.Template__c)) varsByTemplate.put(v.Template__c, new List<Derive_SMS_Parameters__c>());
                    varsByTemplate.get(v.Template__c).add(v);
                }
            }

            PrefetchPlan plan = buildPrefetchPlan(sType, masters, rulesByMaster, varsByTemplate);

            Map<String, Set<Id>> idsByLookupField = new Map<String, Set<Id>>();
            for (String lf : plan.fieldsByLookupField.keySet()) idsByLookupField.put(lf, new Set<Id>());
            for (SObject rec : newList) {
                for (String lf : idsByLookupField.keySet()) {
                    if (hasField(rec, lf)) {
                        Id pid = (Id) rec.get(lf);
                        if (pid != null) idsByLookupField.get(lf).add(pid);
                    }
                }
            }
            Map<Id,SObject> cache = runPrefetchQueries(plan, idsByLookupField);

            for (SObject rec : newList) {
                for (derive_sms_condition_master__c m : masters) {
                    List<derive_sms_rules__c> child = rulesByMaster.get(m.Id);
                    if (child == null) continue;

                    Boolean passed = SmsConditionEvaluator.allPass(rec, child, cache, oldMap, rec, m.Schedule_TZ__c);
                    if (!passed) continue;

                    String e164 = firstNonBlankPhone(rec, m, cache);
                    if (String.isBlank(e164)) continue;

                    Id meuId;
                    try { meuId = SmsEndUserService.getOrCreateByE164(e164); }
                    catch (Exception e) { continue; }
                    if (meuId == null) continue;

                    derive_sms_template_master__c t = tmplById.get(m.Template__c);
                    if (t == null) continue;
                    List<Derive_SMS_Parameters__c> vrows = varsByTemplate.get(t.Id);
                    if (vrows == null) vrows = new List<Derive_SMS_Parameters__c>();

                    SmsTemplateEngine.MergeResult mr;
                    try { mr = SmsTemplateEngine.merge1(rec, t, vrows, cache,m.schedule_tz__c); }
                    catch (Exception e) { continue; }
                    if (mr == null || String.isBlank(mr.body)) continue;

                    if (m.delivery_mode__c == 'Instant' || m.delivery_mode__c == 'instant') {
                        SmsEventEngine.beginSuppress();
                        try { 
                            System.debug('MCC History BEFORE SMS: rec'+e164+mr.body+m.Name+t.Name+rec);
                            SmsFlowSender.sendOne(meuId, mr.body); 
                            SmsHistoryService.logSuccess(
                                rec,
                                'Instant',
                                null,
                                e164,
                                m.Name,
                                t.Name,
                                mr.body
                            );
                            System.debug('MCC History AFTER INSERT: rec=' + String.valueOf(rec) + ', e164=' + e164 + ', master=' + m.Name + ', template=' + t.Name + ', body=' + mr.body);
                        } catch (Exception ignore) { }
                        finally { SmsEventEngine.endSuppress(); }
                    }
                }
            }
        } catch (Exception ex) {
            SmsErrorLogger.log(
                SmsErrorLogger.Severity.Error,
                SmsErrorLogger.Source.EventEngine,
                'Instant', null,
                null, null, null, null,
                String.valueOf(sType), null,
                ex,
                new Map<String,Object>{ 'note' => 'EventEngine.handle failed' }
            );
            throw ex;
        }
    }
    /*
    private static String firstNonBlankPhone(SObject rec, derive_sms_condition_master__c m, Map<Id,SObject> cache) {
        String p;
        p = readPhone(rec, m.phone_1_source__c, m.phone_1_object__c, m.phone_1_field__c, cache); if (!String.isBlank(p)) return SmsUtil.formatPhone(p);
        p = readPhone(rec, m.phone_2_source__c, m.phone_2_object__c, m.phone_2_field__c, cache); if (!String.isBlank(p)) return SmsUtil.formatPhone(p);
        p = readPhone(rec, m.phone_3_source__c, m.phone_3_object__c, m.phone_3_field__c, cache); if (!String.isBlank(p)) return SmsUtil.formatPhone(p);
        return null;
    }
    */
    private static String firstNonBlankPhone(SObject rec, derive_sms_condition_master__c m, Map<Id,SObject> cache) {
        String p1 = readPhone(rec, m.phone_1_source__c, m.phone_1_object__c, m.phone_1_field__c, cache);
        String e1 = SmsUtil.formatPhone(p1); if (e1 != null) return e1;
        String p2 = readPhone(rec, m.phone_2_source__c, m.phone_2_object__c, m.phone_2_field__c, cache);
        String e2 = SmsUtil.formatPhone(p2); if (e2 != null) return e2;
        String p3 = readPhone(rec, m.phone_3_source__c, m.phone_3_object__c, m.phone_3_field__c, cache);
        String e3 = SmsUtil.formatPhone(p3); if (e3 != null) return e3;
        return null;
    }
    private static String readPhone(SObject rec, String src, String lookupFieldApi, String phoneFieldApi, Map<Id,SObject> cache){
        if (String.isBlank(phoneFieldApi)) return null;
        SObject r = rec;
        if ('Lookup' == src || 'LookUp' == src) {
            if (!hasField(rec, lookupFieldApi)) return null;
            Id rel = (Id) rec.get(lookupFieldApi);
            r = (rel != null) ? cache.get(rel) : null;
            if (r == null && rel != null) {
                try {
                    Schema.SObjectField sf = rec.getSObjectType().getDescribe().fields.getMap().get(lookupFieldApi);
                    if (sf != null) {
                        List<Schema.SObjectType> refs = sf.getDescribe().getReferenceTo();
                        if (refs != null && !refs.isEmpty()) {
                            String parentObj = refs[0].getDescribe().getName();
                            String soql = 'SELECT ' + phoneFieldApi + ' FROM ' + parentObj + ' WHERE Id = :rel';
                            r = Database.query(soql);
                        }
                    }
                } catch (Exception ignore) { r = null; }
            }
        }
        if (r == null) return null;
        try {
            return (String) r.get(phoneFieldApi);
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean hasField(SObject s, String fieldApi) {
        return s.getSObjectType().getDescribe().fields.getMap().containsKey(fieldApi);
    }

    private class PrefetchPlan {
        Map<String, String> parentTypeByLookupField = new Map<String, String>();
        Map<String, Set<String>> fieldsByLookupField = new Map<String, Set<String>>();
    }

    private static PrefetchPlan buildPrefetchPlan(
        SObjectType sType,
        List<derive_sms_condition_master__c> masters,
        Map<Id, List<derive_sms_rules__c>> rulesByMaster,
        Map<Id, List<Derive_SMS_Parameters__c>> varsByTemplate
    ) {
        PrefetchPlan plan = new PrefetchPlan();
        Map<String, Schema.SObjectField> fMap = sType.getDescribe().fields.getMap();

        for (derive_sms_condition_master__c m : masters) {
            addLookupNeed(fMap, plan, m.phone_1_source__c, m.phone_1_object__c, m.phone_1_field__c);
            addLookupNeed(fMap, plan, m.phone_2_source__c, m.phone_2_object__c, m.phone_2_field__c);
            addLookupNeed(fMap, plan, m.phone_3_source__c, m.phone_3_object__c, m.phone_3_field__c);

            List<derive_sms_rules__c> child = rulesByMaster.get(m.Id);
            if (child != null) {
                for (derive_sms_rules__c r : child) {
                    if (!String.isBlank(r.filter_object_name__c)
                        && !String.isBlank(r.filter_field__c)
                        && (r.filter_source__c == 'Lookup' || r.filter_source__c == 'LookUp')) {
                        addLookupNeed(fMap, plan, 'Lookup', r.filter_object_name__c, r.filter_field__c);
                    }
                }
            }

            List<Derive_SMS_Parameters__c> vrows = varsByTemplate.get(m.Template__c);
            if (vrows != null) {
                for (Derive_SMS_Parameters__c v : vrows) {
                    if (v.Object_Type__c == 'LookUp' || v.Object_Type__c == 'Lookup') {
                        addLookupNeed(fMap, plan, 'Lookup', v.Object_API__c, v.Field_API__c);
                    }
                }
            }
        }
        return plan;
    }

    private static void addLookupNeed(Map<String, Schema.SObjectField> fMap, PrefetchPlan plan,
                                      String sourceMode, String lookupFieldApi, String neededFieldApi) {
        if ((sourceMode != 'Lookup' && sourceMode != 'LookUp') || String.isBlank(lookupFieldApi)) return;
        if (!fMap.containsKey(lookupFieldApi)) return;
        Schema.DescribeFieldResult d = fMap.get(lookupFieldApi).getDescribe();
        List<Schema.SObjectType> refs = d.getReferenceTo();
        if (refs == null || refs.isEmpty()) return;

        String parentType = String.valueOf(refs[0]);
        plan.parentTypeByLookupField.put(lookupFieldApi, parentType);

        if (!plan.fieldsByLookupField.containsKey(lookupFieldApi)) plan.fieldsByLookupField.put(lookupFieldApi, new Set<String>());
        plan.fieldsByLookupField.get(lookupFieldApi).add('Id');
        if (!String.isBlank(neededFieldApi)) plan.fieldsByLookupField.get(lookupFieldApi).add(neededFieldApi);
    }

    private static Map<Id,SObject> runPrefetchQueries(PrefetchPlan plan, Map<String, Set<Id>> idsByLookupField) {
        Map<String, Set<Id>> idsByParentType = new Map<String, Set<Id>>();
        Map<String, Set<String>> fieldsByParentType = new Map<String, Set<String>>();

        for (String lf : idsByLookupField.keySet()) {
            Set<Id> ids = idsByLookupField.get(lf);
            if (ids == null || ids.isEmpty()) continue;
            String parentType = plan.parentTypeByLookupField.get(lf);
            if (String.isBlank(parentType)) continue;

            if (!idsByParentType.containsKey(parentType)) {
                idsByParentType.put(parentType, new Set<Id>());
                fieldsByParentType.put(parentType, new Set<String>());
            }
            idsByParentType.get(parentType).addAll(ids);
            fieldsByParentType.get(parentType).addAll(plan.fieldsByLookupField.get(lf));
        }

        Map<Id,SObject> cache = new Map<Id,SObject>();
        for (String parentType : idsByParentType.keySet()) {
            Set<Id> ids = idsByParentType.get(parentType);
            if (ids.isEmpty()) continue;

            List<String> flds = new List<String>(fieldsByParentType.get(parentType));
            if (!flds.contains('Id')) flds.add('Id');

            String soql = 'SELECT ' + String.join(flds, ',') + ' FROM ' + parentType + ' WHERE Id IN :ids';
            for (SObject row : Database.query(soql)) {
                cache.put(row.Id, row);
            }
        }

        return cache;
    }
}