public with sharing class SmsScheduleBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Id masterId;
    private String fireKey;
    private Datetime nextUtc;

    // Stateful counters for visibility
    private Integer recordsEvaluated = 0;
    private Integer recordsMatched   = 0;
    private Integer messagesSent     = 0;
    private Integer errorLogsWritten = 0;
    private static final Integer MAX_ERROR_LOGS_PER_EXECUTE = 10;
    private static final Integer DML_SAFETY_BUFFER = 5;

    private class PendingMessage {
        public SObject rec;
        public String e164;
        public String body;
    }

    private class DeliveryMessage {
        public SObject rec;
        public String e164;
        public Id meuId;
        public String body;
    }

    public SmsScheduleBatch(Id masterId, String fireKey, Datetime nextUtc) {
        this.masterId = masterId;
        this.fireKey  = fireKey;
        this.nextUtc  = nextUtc;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        MasterBundle b = loadBundle(masterId);
        if (b == null || String.isBlank(b.targetObject)) {
            System.debug('SB.start: bundle/target missing for master=' + masterId);
            return Database.getQueryLocator('SELECT Id FROM Account WHERE Id = null');
        }

        Set<String> selectFields = computeSelectFields(b);
        if (selectFields.isEmpty()) selectFields.add('Id');

        List<String> fieldList = sortCaseInsensitiveUnique(selectFields);
        String projection = String.join(fieldList, ', ');

        String whereClause = buildWhereClause(b, stFor(b.targetObject));
        String soql = 'SELECT ' + projection + ' FROM ' + b.targetObject;
        if (!String.isBlank(whereClause)) soql += ' WHERE ' + whereClause;

        System.debug('SB.start: master=' + masterId + ' target=' + b.targetObject);
        System.debug('SB.start: selectFields=' + projection);
        System.debug('SB.start: where=' + whereClause);
        System.debug('SB.start: soql=' + soql);

        return Database.getQueryLocator(soql);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        MasterBundle b = loadBundle(masterId);
        if (b == null) {
            System.debug('SB.exec: bundle null for master=' + masterId);
            return;
        }

        Map<Id, SObject> hydratedById = hydrateScopeRecords(scope, b);

        System.debug('SB.exec: scope.size=' + scope.size()
            + ' rules(all)=' + b.allRules.size()
            + ' rules(filterOnly)=' + b.filterRules.size() + ' rules(applied)=' + b.allRules.size()
            + ' template=' + (b.template==null?'null':b.template.Id)
            + ' params=' + b.params.size());

        Map<Id, SObject> parentCache = new Map<Id, SObject>();
        prefetchLookupParents(hydratedById, b, parentCache);

        List<PendingMessage> pending = new List<PendingMessage>();
        Set<String> phonesToResolve = new Set<String>();

        for (SObject scoped : scope) {
            Id recId = (Id) scoped.get('Id');
            SObject rec = hydratedById.get(recId);
            if (rec == null) rec = scoped;
            recordsEvaluated++;
            try {
                Boolean pass = b.allRules.isEmpty()
                    ? true
                    : SmsConditionEvaluator.allPass(rec, b.allRules, parentCache, null, rec, b.master.Schedule_TZ__c);

                System.debug('SB.exec: recId=' + rec.get('Id') + ' pass=' + pass);
                if (!pass) continue;

                recordsMatched++;

                String e164 = firstNonBlankPhone(rec, b.master, parentCache);
                System.debug('SB.exec: recId=' + rec.get('Id') + ' e164=' + e164);
                if (String.isBlank(e164)) continue;

                SmsTemplateEngine.MergeResult mr =
                    SmsTemplateEngine.merge1(rec, b.template, b.params, parentCache, b.master.Schedule_TZ__c);

                System.debug('SB.exec: recId=' + rec.get('Id')
                    + ' body.len=' + (mr==null || mr.body==null ? -1 : mr.body.length()));

                if (mr == null || String.isBlank(mr.body)) continue;

                PendingMessage msg = new PendingMessage();
                msg.rec = rec;
                msg.e164 = e164;
                msg.body = mr.body;
                pending.add(msg);
                phonesToResolve.add(e164);

            } catch (Exception ex) {
                System.debug('SB.exec: recId=' + rec.get('Id') + ' ERROR ' + ex.getMessage());
                Map<String,Object> details = new Map<String,Object>{
                    'phase' => 'execute',
                    'recordsEvaluated' => recordsEvaluated,
                    'recordsMatched' => recordsMatched,
                    'messagesSent' => messagesSent
                };
                logBatchError(b, recId, ex, details);
            }
        }

        Map<String, Id> meuByPhone = new Map<String, Id>();
        if (!phonesToResolve.isEmpty()) {
            try {
                meuByPhone = SmsEndUserService.getOrCreateByE164Bulk(phonesToResolve);
            } catch (Exception ex) {
                logBatchError(b, null, ex, new Map<String,Object>{
                    'phase' => 'resolve-endusers',
                    'phoneCount' => phonesToResolve.size()
                });
            }
        }

        List<DeliveryMessage> deliveries = new List<DeliveryMessage>();
        for (PendingMessage msg : pending) {
            try {
                String normalized = SmsUtil.formatPhone(msg.e164);
                if (String.isBlank(normalized)) normalized = msg.e164;
                Id meuId = meuByPhone.get(normalized);
                if (meuId == null) continue;

                DeliveryMessage d = new DeliveryMessage();
                d.rec = msg.rec;
                d.e164 = msg.e164;
                d.meuId = meuId;
                d.body = msg.body;
                deliveries.add(d);
            } catch (Exception ex) {
                Id recId = msg == null || msg.rec == null ? null : (Id) msg.rec.get('Id');
                logBatchError(b, recId, ex, new Map<String,Object>{
                    'phase' => 'prepare-send',
                    'messagesSent' => messagesSent
                });
            }
        }

        Map<String, List<DeliveryMessage>> deliveriesByBody = new Map<String, List<DeliveryMessage>>();
        for (DeliveryMessage d : deliveries) {
            if (d == null || d.meuId == null || String.isBlank(d.body)) continue;
            if (!deliveriesByBody.containsKey(d.body)) deliveriesByBody.put(d.body, new List<DeliveryMessage>());
            deliveriesByBody.get(d.body).add(d);
        }

        List<SmsHistoryService.HistoryLogItem> historyItems = new List<SmsHistoryService.HistoryLogItem>();
        for (String body : deliveriesByBody.keySet()) {
            List<DeliveryMessage> group1 = deliveriesByBody.get(body);
            if (group1 == null || group1.isEmpty()) continue;
            List<Id> recipientIds = new List<Id>();
            for (DeliveryMessage d : group1) recipientIds.add(d.meuId);

            try {
                SmsEventEngine.beginSuppress();
                try {
                    SmsFlowSender.sendMany(recipientIds, body);
                } finally {
                    SmsEventEngine.endSuppress();
                }

                for (DeliveryMessage d : group1) {
                    SmsHistoryService.HistoryLogItem item = new SmsHistoryService.HistoryLogItem();
                    item.rec = d.rec;
                    item.runMode = 'Scheduled';
                    item.fireKey = fireKey;
                    item.phoneE164 = d.e164;
                    item.masterCode = b.master == null ? null : b.master.Name;
                    item.templateCode = b.template == null ? null : b.template.Name;
                    item.messageBody = d.body;
                    historyItems.add(item);
                    messagesSent++;
                }
            } catch (Exception ex) {
                Id recId = (group1[0] == null || group1[0].rec == null) ? null : (Id) group1[0].rec.get('Id');
                logBatchError(b, recId, ex, new Map<String,Object>{
                    'phase' => 'send-bulk-group',
                    'messagesSent' => messagesSent,
                    'groupSize' => group1.size()
                });
            }
        }

        if (!historyItems.isEmpty()) {
            try {
                SmsHistoryService.logSuccessBulk(historyItems);
            } catch (Exception ex) {
                logBatchError(b, null, ex, new Map<String,Object>{
                    'phase' => 'history-bulk',
                    'historyCount' => historyItems.size()
                });
            }
        }
        System.debug('SB.exec: evaluated=' + recordsEvaluated + ' matched=' + recordsMatched + ' sent=' + messagesSent);
    }

    private Map<Id, SObject> hydrateScopeRecords(List<SObject> scope, MasterBundle b) {
        Map<Id, SObject> out = new Map<Id, SObject>();
        if (scope == null || scope.isEmpty() || b == null || String.isBlank(b.targetObject)) return out;

        Set<Id> ids = new Set<Id>();
        for (SObject s : scope) {
            if (s == null) continue;
            Id idv = (Id) s.get('Id');
            if (idv != null) ids.add(idv);
        }
        if (ids.isEmpty()) return out;

        Set<String> selectFields = computeSelectFields(b);
        selectFields.add('Id');
        List<String> fieldList = sortCaseInsensitiveUnique(selectFields);
        String soql = 'SELECT ' + String.join(fieldList, ', ') + ' FROM ' + b.targetObject + ' WHERE Id IN :ids';
        System.debug('SB.exec.hydrate: soql=' + soql + ' ids=' + ids.size());

        try {
            for (SObject row : Database.query(soql)) {
                out.put((Id) row.get('Id'), row);
            }
        } catch (Exception ex) {
            Map<String,Object> details = new Map<String,Object>{
                'phase' => 'hydrateScopeRecords',
                'scopeSize' => scope.size(),
                'idsSize' => ids.size(),
                'soql' => soql
            };
            logBatchError(b, null, ex, details);
        }
        return out;
    }

    public void finish(Database.BatchableContext bc) {
        // Always stamp fireKey/nextUtc to avoid duplicate firing of the same window.
        String tzKey;
        try {
            tzKey = [SELECT Schedule_TZ__c FROM derive_sms_condition_master__c WHERE Id = :masterId LIMIT 1].Schedule_TZ__c;
        } catch (Exception ignore) {
            tzKey = null;
        }

        Datetime nowUtc = System.now();
        String tzId = SmsScheduleService.timezoneIdForKey(tzKey);
        String lastLocalStr = nowUtc.format('d/M/yyyy, h:mm a', tzId).toLowerCase();
        String nextLocalStr = (nextUtc == null ? null : nextUtc.format('d/M/yyyy, h:mm a', tzId).toLowerCase());

        derive_sms_condition_master__c upd = new derive_sms_condition_master__c(
            Id = masterId,
            Last_Fire_Key__c = fireKey,
            Next_Run__c = nextUtc,
            Next_Run_local__c = nextLocalStr
        );

        // If you want Last_Run__c ONLY when we actually attempted work, set it when we evaluated any records:
        if (recordsEvaluated > 0) {
            upd.Last_Run__c = System.now();
            upd.Last_Run_local__c = lastLocalStr;
        }
        try { update upd; } catch (Exception e) {
            System.debug('SB.finish: unable to stamp schedule fields: ' + e.getMessage());
            Map<String,Object> details = new Map<String,Object>{
                'phase' => 'finish',
                'recordsEvaluated' => recordsEvaluated,
                'recordsMatched' => recordsMatched,
                'messagesSent' => messagesSent,
                'nextUtc' => String.valueOf(nextUtc),
                'fireKey' => fireKey
            };
            logBatchError(null, masterId, e, details);
        }
        System.debug('SB.finish: master=' + masterId + ' fireKey=' + fireKey + ' nextUtc=' + nextUtc
            + ' evaluated=' + recordsEvaluated + ' matched=' + recordsMatched + ' sent=' + messagesSent);
    }

    // ---------- bundle & helpers (unchanged logic, with normalized fields) ----------
    class MasterBundle {
        derive_sms_condition_master__c master;
        List<derive_sms_rules__c> allRules;
        List<derive_sms_rules__c> filterRules;
        derive_sms_template_master__c template;
        List<derive_sms_parameters__c> params;
        String targetObject;
    }

    private MasterBundle loadBundle(Id mid) {
        MasterBundle b = new MasterBundle();

        b.master = [
            SELECT Id, Name, Object_API__c, Template__c, Schedule_TZ__c,
                   phone_1_source__c, phone_1_object__c, phone_1_field__c,
                   phone_2_source__c, phone_2_object__c, phone_2_field__c,
                   phone_3_source__c, phone_3_object__c, phone_3_field__c
            FROM derive_sms_condition_master__c
            WHERE Id = :mid LIMIT 1
        ];
        b.targetObject = b.master.Object_API__c;

        b.allRules = [
            SELECT Id, Active__c, condition_type__c,
                   filter_source__c, filter_object_name__c, filter_field__c,
                   Operator__c, filter_value__c, filter_offset_hours__c, offset_days__c,
                   transition_field_api__c, transition_old_value__c, transition_new_value__c,
                   master__c
            FROM derive_sms_rules__c
            WHERE master__c = :mid AND Active__c = true
            ORDER BY Id
        ];

        b.filterRules = new List<derive_sms_rules__c>();
        for (derive_sms_rules__c r : b.allRules)
            if (r.condition_type__c == 'Filter') b.filterRules.add(r);

        if (b.master.Template__c != null) {
            b.template = [
                SELECT Id, Name, content__c, active__c, sms_char_count__c
                FROM derive_sms_template_master__c
                WHERE Id = :b.master.Template__c LIMIT 1
            ];
            b.params = [
                SELECT Id, Template__c, p_name__c,
                       Object_Type__c, Object_API__c, Field_API__c, Format_Type__c
                FROM derive_sms_parameters__c
                WHERE Template__c = :b.master.Template__c
                ORDER BY Id
            ];
        } else {
            b.template = null;
            b.params = new List<derive_sms_parameters__c>();
        }

        System.debug('SB.load: template=' + (b.template==null?'null':b.template.Id)
            + ' rules=' + b.allRules.size() + ' params=' + b.params.size()
            + ' target=' + b.targetObject);

        return b;
    }


    private static Schema.SObjectType stFor(String objectApi) {
        if (String.isBlank(objectApi)) return null;
        return Schema.getGlobalDescribe().get(objectApi);
    }

    private static Set<String> computeSelectFields(MasterBundle b) {
        Set<String> out = new Set<String>{ 'Id' };
        if (String.isBlank(b.targetObject)) return out;

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType st = gd.get(b.targetObject);
        if (st == null) {
            System.debug('SB.fields: unknown object ' + b.targetObject);
            return out;
        }
        Map<String, Schema.SObjectField> fmap = st.getDescribe().fields.getMap();

        addIfExists(fmap, out, b.master.phone_1_source__c, b.master.phone_1_object__c, b.master.phone_1_field__c);
        addIfExists(fmap, out, b.master.phone_2_source__c, b.master.phone_2_object__c, b.master.phone_2_field__c);
        addIfExists(fmap, out, b.master.phone_3_source__c, b.master.phone_3_object__c, b.master.phone_3_field__c);

        for (derive_sms_rules__c r : b.allRules) {
            if (r == null) continue;
            String ruleType = (r.condition_type__c == null ? null : r.condition_type__c.trim());
            String ruleSource = (r.filter_source__c == null ? null : r.filter_source__c.trim());
            if ('Transition'.equalsIgnoreCase(ruleType)) {
                addIfExists(fmap, out, 'Self', null, r.transition_field_api__c);
            } else if ('Self'.equalsIgnoreCase(ruleSource)) {
                addIfExists(fmap, out, 'Self', null, r.filter_field__c);
            } else if ('Lookup'.equalsIgnoreCase(ruleSource)) {
                addIfExists(fmap, out, 'Lookup', r.filter_object_name__c, null);
            }
        }

        for (derive_sms_parameters__c p : b.params) {
            String objectType = (p.Object_Type__c == null ? null : p.Object_Type__c.trim());
            if (objectType == null || 'Self'.equalsIgnoreCase(objectType)) {
                addIfExists(fmap, out, 'Self', null, p.Field_API__c);
            } else if ('Lookup'.equalsIgnoreCase(objectType)) {
                addIfExists(fmap, out, 'Lookup', p.Object_API__c, null);
            }
        }

        System.debug('SB.fields: final=' + String.join(new List<String>(out), ', '));
        return out;
    }

    private static void addIfExists(Map<String, Schema.SObjectField> fmap,
                                    Set<String> out,
                                    String sourceKind,
                                    String lookupIdFieldApi,
                                    String selfFieldApi) {
        if ('Self'.equalsIgnoreCase(sourceKind)) {
            String f = resolveFieldApi(fmap, normalizeField(selfFieldApi));
            if (!String.isBlank(f)) out.add(f);
            else if (!String.isBlank(selfFieldApi)) System.debug('SB.fields: skip (self) ' + selfFieldApi);
        } else if ('Lookup'.equalsIgnoreCase(sourceKind)) {
            String f = resolveFieldApi(fmap, normalizeField(lookupIdFieldApi));
            if (!String.isBlank(f)) out.add(f);
            else if (!String.isBlank(lookupIdFieldApi)) System.debug('SB.fields: skip (lookupId) ' + lookupIdFieldApi);
        }
    }

    private static String resolveFieldApi(Map<String, Schema.SObjectField> fmap, String requested) {
        if (fmap == null || String.isBlank(requested)) return null;
        if (fmap.containsKey(requested)) return requested;
        String want = requested.toLowerCase();
        for (String k : fmap.keySet()) {
            if (k != null && k.toLowerCase() == want) return k;
        }
        return null;
    }

    private static String normalizeField(String api) {
        if (String.isBlank(api)) return null;
        String f = api.trim();
        Integer dot = f.lastIndexOf('.');
        if (dot >= 0 && dot < f.length() - 1) f = f.substring(dot + 1);
        return f;
    }



    private static List<String> sortCaseInsensitiveUnique(Set<String> fields) {
        Map<String, String> byLower = new Map<String, String>();
        for (String f : fields) {
            if (String.isBlank(f)) continue;
            String k = f.toLowerCase();
            if (!byLower.containsKey(k)) byLower.put(k, f);
        }
        List<String> out = new List<String>(byLower.values());
        out.sort();
        return out;
    }

    private static String buildWhereClause(MasterBundle b, Schema.SObjectType st) {
        List<String> terms = new List<String>();
        if (b == null || b.allRules == null || st == null) return null;

        Map<String, Schema.SObjectField> fmap = st.getDescribe().fields.getMap();

        for (derive_sms_rules__c r : b.allRules) {
            if (r == null || r.Active__c != true) continue;
            if (!'Filter'.equalsIgnoreCase(r.condition_type__c)) continue;

            String source = (r.filter_source__c == null ? null : r.filter_source__c.trim());
            String op = normalizeOperatorToken(r.Operator__c);
            String val = (r.filter_value__c == null ? null : r.filter_value__c.trim());
            if (String.isBlank(op)) continue;

            String soqlPath;
            Boolean isBooleanField = false;
            Schema.DisplayType fieldType;
            if ('Self'.equalsIgnoreCase(source)) {
                String fieldApi = resolveFieldApi(fmap, normalizeField(r.filter_field__c));
                if (String.isBlank(fieldApi)) continue;
                soqlPath = fieldApi;
                fieldType = fmap.get(fieldApi).getDescribe().getType();
                isBooleanField = (fieldType == Schema.DisplayType.Boolean);
            } else if ('Lookup'.equalsIgnoreCase(source) || 'LookUp'.equalsIgnoreCase(source)) {
                String lookupFieldApi = resolveFieldApi(fmap, normalizeField(r.filter_object_name__c));
                String parentFieldApi = normalizeField(r.filter_field__c);
                if (String.isBlank(lookupFieldApi) || String.isBlank(parentFieldApi)) continue;
                Schema.SObjectField sf = fmap.get(lookupFieldApi);
                if (sf == null) continue;
                String relName = sf.getDescribe().getRelationshipName();
                if (String.isBlank(relName)) continue;
                soqlPath = relName + '.' + parentFieldApi;

                List<Schema.SObjectType> refs = sf.getDescribe().getReferenceTo();
                if (refs != null && !refs.isEmpty()) {
                    Map<String, Schema.SObjectField> pf = refs[0].getDescribe().fields.getMap();
                    String parentResolved = resolveFieldApi(pf, parentFieldApi);
                    if (!String.isBlank(parentResolved)) {
                        parentFieldApi = parentResolved;
                        soqlPath = relName + '.' + parentFieldApi;
                    }
                    Schema.SObjectField psf = pf.get(parentFieldApi);
                    if (psf != null) {
                        fieldType = psf.getDescribe().getType();
                        isBooleanField = (fieldType == Schema.DisplayType.Boolean);
                    }
                }
            } else {
                continue;
            }

            if (op == 'EQUALS') {
                if (String.isBlank(val) || val.equalsIgnoreCase('NULL') || val.equalsIgnoreCase('EMPTY')) {
                    terms.add(soqlPath + ' = NULL');
                } else {
                    if (fieldType == Schema.DisplayType.DateTime && isRelativeDateLiteral(val)) {
                        String rangeCond = buildDateTimeRelativeRangeCondition(soqlPath, val, b, r, false);
                        if (String.isBlank(rangeCond)) continue;
                        terms.add(rangeCond);
                        continue;
                    }
                    String soqlVal = toSoqlLiteralWithRuleContext(val, fieldType, isBooleanField, b, r);
                    if (soqlVal == null) continue;
                    terms.add(soqlPath + ' = ' + soqlVal);
                }
            } else if (op == 'NOT_EQUALS') {
                if (String.isBlank(val) || val.equalsIgnoreCase('NULL') || val.equalsIgnoreCase('EMPTY')) {
                    terms.add(soqlPath + ' != NULL');
                } else {
                    if (fieldType == Schema.DisplayType.DateTime && isRelativeDateLiteral(val)) {
                        String rangeCond = buildDateTimeRelativeRangeCondition(soqlPath, val, b, r, true);
                        if (String.isBlank(rangeCond)) continue;
                        terms.add(rangeCond);
                        continue;
                    }
                    String soqlVal = toSoqlLiteralWithRuleContext(val, fieldType, isBooleanField, b, r);
                    if (soqlVal == null) continue;
                    terms.add(soqlPath + ' != ' + soqlVal);
                }
            } else if (op == 'IN' || op == 'NOT_IN') {
                List<String> toks = splitRuleValues(val);
                if (toks.isEmpty()) continue;
                List<String> q = new List<String>();
                for (String t : toks) {
                    String lit = toSoqlLiteralWithRuleContext(t, fieldType, isBooleanField, b, r);
                    if (lit != null) q.add(lit);
                }
                if (q.isEmpty()) continue;
                terms.add(soqlPath + ' ' + (op == 'IN' ? 'IN' : 'NOT IN') + ' (' + String.join(q, ',') + ')');
            } else if (op == 'GREATER_THAN' || op == 'LESS_THAN' ||
                       op == 'GREATER_THAN_OR_EQUAL' || op == 'LESS_THAN_OR_EQUAL') {
                if (String.isBlank(val)) continue;
                String soqlVal = toSoqlLiteralWithRuleContext(val, fieldType, isBooleanField, b, r);
                if (soqlVal == null) continue;
                String cmp = (op == 'GREATER_THAN' ? '>' :
                    (op == 'LESS_THAN' ? '<' :
                    (op == 'GREATER_THAN_OR_EQUAL' ? '>=' : '<=')));
                terms.add(soqlPath + ' ' + cmp + ' ' + soqlVal);
            }
        }

        if (terms.isEmpty()) return null;
        return String.join(terms, ' AND ');
    }

    private static String normalizeOperatorToken(String opRaw) {
        if (String.isBlank(opRaw)) return null;
        String op = opRaw.trim().toUpperCase().replace(' ', '_');
        if (op == '=' || op == 'EQ' || op == 'EQUAL' || op == 'EQUALS') return 'EQUALS';
        if (op == '!=' || op == '<>' || op == 'NE' || op == 'NOT_EQUAL' || op == 'NOT_EQUALS') return 'NOT_EQUALS';
        if (op == '>=' || op == 'GTE' || op == 'GE' || op == 'GREATER_OR_EQUAL'
            || op == 'GREATER_THAN_OR_EQUAL' || op == 'GREATER_THAN_OR_EQUALS') return 'GREATER_THAN_OR_EQUAL';
        if (op == '<=' || op == 'LTE' || op == 'LE' || op == 'LESS_OR_EQUAL'
            || op == 'LESS_THAN_OR_EQUAL' || op == 'LESS_THAN_OR_EQUALS') return 'LESS_THAN_OR_EQUAL';
        if (op == '>' || op == 'GT' || op == 'GREATER' || op == 'GREATER_THAN') return 'GREATER_THAN';
        if (op == '<' || op == 'LT' || op == 'LESS' || op == 'LESS_THAN') return 'LESS_THAN';
        if (op == 'IN') return 'IN';
        if (op == 'NOTIN' || op == 'NOT_IN') return 'NOT_IN';
        return op;
    }

    private static List<String> splitRuleValues(String s) {
        List<String> out = new List<String>();
        if (String.isBlank(s)) return out;
        for (String tok : s.split('[;,]')) {
            if (!String.isBlank(tok)) out.add(tok.trim());
        }
        return out;
    }


    private static Boolean isDateLike(Schema.DisplayType fieldType) {
        return fieldType == Schema.DisplayType.Date || fieldType == Schema.DisplayType.DateTime;
    }

    private static Boolean isRelativeDateLiteral(String v) {
        if (String.isBlank(v)) return false;
        String t = v.trim().toUpperCase().replace(' ', '');
        return t.startsWith('TODAY')
            || t.startsWith('TOMORROW')
            || t.startsWith('YESTERDAY')
            || t.startsWith('NOW');
    }

    private static String toSoqlLiteral(String v, Schema.DisplayType fieldType, Boolean isBooleanField) {
        if (v == null) return 'NULL';
        String t = v.trim();
        if (isBooleanField == true) {
            if (t.equalsIgnoreCase('true')) return 'TRUE';
            if (t.equalsIgnoreCase('false')) return 'FALSE';
            return null;
        }
        if (fieldType == Schema.DisplayType.Date || fieldType == Schema.DisplayType.DateTime) {
            String tu = t.toUpperCase();
            if (tu == 'TODAY' || tu == 'TOMORROW' || tu == 'YESTERDAY' || tu == 'NOW') return tu;
            if (fieldType == Schema.DisplayType.Date) {
                try { return String.valueOf(Date.valueOf(t)); } catch (Exception ignoreDate) {}
                try { return String.valueOf(Datetime.valueOf(t).date()); } catch (Exception ignoreDtAsDate) {}
                return null;
            }
            try {
                Datetime dt = Datetime.valueOf(t);
                return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            } catch (Exception ignoreDt) {
                try {
                    Date d = Date.valueOf(t);
                    Datetime dt0 = Datetime.newInstance(d, Time.newInstance(0,0,0,0));
                    return dt0.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                } catch (Exception ignoreDAsDt) {}
            }
            return null;
        }
        if (fieldType == Schema.DisplayType.Integer ||
            fieldType == Schema.DisplayType.Double ||
            fieldType == Schema.DisplayType.Currency ||
            fieldType == Schema.DisplayType.Percent) {
            try { return String.valueOf(Decimal.valueOf(t)); } catch (Exception ignoreNum) { return null; }
        }
        return quoteSoql(t);
    }

    private static String toSoqlLiteralWithRuleContext(
        String v,
        Schema.DisplayType fieldType,
        Boolean isBooleanField,
        MasterBundle b,
        derive_sms_rules__c r
    ) {
        if (isDateLike(fieldType) && isRelativeDateLiteral(v)) {
            String tzKey = (b == null || b.master == null) ? null : b.master.Schedule_TZ__c;
            return relativeDateLiteralToSoql(v, fieldType, tzKey, r);
        }
        return toSoqlLiteral(v, fieldType, isBooleanField);
    }

    private static String relativeDateLiteralToSoql(
        String rawLiteral,
        Schema.DisplayType fieldType,
        String tzKey,
        derive_sms_rules__c r
    ) {
        if (String.isBlank(rawLiteral)) return null;
        String lit = rawLiteral.trim().toUpperCase().replace(' ', '');
        String baseToken = null;
        Integer dayAdjust = 0;
        Integer inlineDays = 0;

        if (lit.startsWith('TODAY')) {
            baseToken = 'TODAY';
            inlineDays = parseInlineDayOffset(lit.substring('TODAY'.length()));
        } else if (lit.startsWith('TOMORROW')) {
            baseToken = 'TOMORROW';
            dayAdjust = 1;
            inlineDays = parseInlineDayOffset(lit.substring('TOMORROW'.length()));
        } else if (lit.startsWith('YESTERDAY')) {
            baseToken = 'YESTERDAY';
            dayAdjust = -1;
            inlineDays = parseInlineDayOffset(lit.substring('YESTERDAY'.length()));
        } else if (lit.startsWith('NOW')) {
            baseToken = 'NOW';
            inlineDays = parseInlineDayOffset(lit.substring('NOW'.length()));
        } else {
            return null;
        }
        dayAdjust += inlineDays;

        Integer offsDayCount = (r == null || r.offset_days__c == null)
            ? 0
            : Integer.valueOf(Math.round(r.offset_days__c));
        Integer offsSeconds = (r == null || r.filter_offset_hours__c == null)
            ? 0
            : Integer.valueOf(Math.round(r.filter_offset_hours__c * 3600));

        Datetime nowUtc = Datetime.now();
        Datetime localNow = SmsScheduleService.toLocalTime(tzKey, nowUtc);
        if (localNow == null) localNow = nowUtc;

        Datetime localAnchor;
        if (baseToken == 'NOW') {
            localAnchor = localNow;
        } else {
            Date baseLocalDate = localNow.date().addDays(dayAdjust);
            localAnchor = Datetime.newInstanceGmt(baseLocalDate, Time.newInstance(0,0,0,0));
        }

        Datetime shiftedLocal = localAnchor.addDays(offsDayCount).addSeconds(offsSeconds);

        if (fieldType == Schema.DisplayType.Date) {
            return String.valueOf(shiftedLocal.date());
        }

        Datetime shiftedUtc = SmsScheduleService.toUtcTime(tzKey, shiftedLocal);
        if (shiftedUtc == null) shiftedUtc = shiftedLocal;
        return shiftedUtc.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }

    private static Integer parseInlineDayOffset(String tail) {
        if (String.isBlank(tail)) return 0;
        String s = tail.trim();
        if (!(s.startsWith('+') || s.startsWith('-'))) return 0;
        try {
            return Integer.valueOf(s);
        } catch (Exception ignore) {
            return 0;
        }
    }

    private static String quoteSoql(String v) {
        return '\'' + String.escapeSingleQuotes(v == null ? '' : v) + '\'';
    }

    private static String buildDateTimeRelativeRangeCondition(
        String soqlPath,
        String rawLiteral,
        MasterBundle b,
        derive_sms_rules__c r,
        Boolean negate
    ) {
        if (String.isBlank(soqlPath) || String.isBlank(rawLiteral)) return null;
        String tzKey = (b == null || b.master == null) ? null : b.master.Schedule_TZ__c;
        Date localDate = resolveRelativeLocalDate(rawLiteral, tzKey, r);
        if (localDate == null) return null;

        Datetime localStart = Datetime.newInstanceGmt(localDate, Time.newInstance(0,0,0,0));
        Datetime localEnd = localStart.addDays(1);
        Datetime startUtc = SmsScheduleService.toUtcTime(tzKey, localStart);
        Datetime endUtc = SmsScheduleService.toUtcTime(tzKey, localEnd);
        if (startUtc == null) startUtc = localStart;
        if (endUtc == null) endUtc = localEnd;

        String rangeExpr = soqlPath + ' >= ' + startUtc.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
            + ' AND ' + soqlPath + ' < ' + endUtc.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        return negate == true ? 'NOT (' + rangeExpr + ')' : '(' + rangeExpr + ')';
    }

    private static Date resolveRelativeLocalDate(String rawLiteral, String tzKey, derive_sms_rules__c r) {
        if (String.isBlank(rawLiteral)) return null;
        String lit = rawLiteral.trim().toUpperCase().replace(' ', '');

        Integer baseDayAdjust = 0;
        Integer inlineDays = 0;
        if (lit.startsWith('TODAY')) {
            inlineDays = parseInlineDayOffset(lit.substring('TODAY'.length()));
        } else if (lit.startsWith('TOMORROW')) {
            baseDayAdjust = 1;
            inlineDays = parseInlineDayOffset(lit.substring('TOMORROW'.length()));
        } else if (lit.startsWith('YESTERDAY')) {
            baseDayAdjust = -1;
            inlineDays = parseInlineDayOffset(lit.substring('YESTERDAY'.length()));
        } else if (lit.startsWith('NOW')) {
            inlineDays = parseInlineDayOffset(lit.substring('NOW'.length()));
        } else {
            return null;
        }

        Integer offsDayCount = (r == null || r.offset_days__c == null)
            ? 0
            : Integer.valueOf(Math.round(r.offset_days__c));
        Integer offsSeconds = (r == null || r.filter_offset_hours__c == null)
            ? 0
            : Integer.valueOf(Math.round(r.filter_offset_hours__c * 3600));

        Datetime nowUtc = Datetime.now();
        Datetime localNow = SmsScheduleService.toLocalTime(tzKey, nowUtc);
        if (localNow == null) localNow = nowUtc;

        Datetime localAnchor;
        if (lit.startsWith('NOW')) {
            localAnchor = localNow;
        } else {
            Date baseLocalDate = localNow.date().addDays(baseDayAdjust + inlineDays);
            localAnchor = Datetime.newInstanceGmt(baseLocalDate, Time.newInstance(0,0,0,0));
        }

        Datetime shiftedLocal = localAnchor.addDays(offsDayCount).addSeconds(offsSeconds);
        return shiftedLocal.date();
    }

    private static void prefetchLookupParents(Map<Id, SObject> recById, MasterBundle b, Map<Id,SObject> parentCache) {
        if (recById == null || recById.isEmpty() || b == null || String.isBlank(b.targetObject) || parentCache == null) return;

        Schema.SObjectType st = stFor(b.targetObject);
        if (st == null) return;
        Map<String, Schema.SObjectField> fmap = st.getDescribe().fields.getMap();

        Map<String, Set<String>> neededFieldsByLookup = new Map<String, Set<String>>();

        // Rule lookup dependencies
        if (b.allRules != null) {
            for (derive_sms_rules__c r : b.allRules) {
                if (r == null) continue;
                String source = (r.filter_source__c == null ? null : r.filter_source__c.trim());
                if (!'Lookup'.equalsIgnoreCase(source) && !'LookUp'.equalsIgnoreCase(source)) continue;
                String lookupField = resolveFieldApi(fmap, normalizeField(r.filter_object_name__c));
                String parentField = normalizeField(r.filter_field__c);
                if (String.isBlank(lookupField) || String.isBlank(parentField)) continue;
                if (!neededFieldsByLookup.containsKey(lookupField)) neededFieldsByLookup.put(lookupField, new Set<String>());
                neededFieldsByLookup.get(lookupField).add(parentField);
            }
        }

        // Phone lookup dependencies
        addLookupFieldNeed(neededFieldsByLookup, fmap, b.master == null ? null : b.master.phone_1_source__c,
            b.master == null ? null : b.master.phone_1_object__c, b.master == null ? null : b.master.phone_1_field__c);
        addLookupFieldNeed(neededFieldsByLookup, fmap, b.master == null ? null : b.master.phone_2_source__c,
            b.master == null ? null : b.master.phone_2_object__c, b.master == null ? null : b.master.phone_2_field__c);
        addLookupFieldNeed(neededFieldsByLookup, fmap, b.master == null ? null : b.master.phone_3_source__c,
            b.master == null ? null : b.master.phone_3_object__c, b.master == null ? null : b.master.phone_3_field__c);

        // Template lookup dependencies
        if (b.params != null) {
            for (derive_sms_parameters__c p : b.params) {
                if (p == null) continue;
                String objectType = (p.Object_Type__c == null ? null : p.Object_Type__c.trim());
                if (!'Lookup'.equalsIgnoreCase(objectType) && !'LookUp'.equalsIgnoreCase(objectType)) continue;
                String lookupField = resolveFieldApi(fmap, normalizeField(p.Object_API__c));
                String parentField = normalizeField(p.Field_API__c);
                if (String.isBlank(lookupField) || String.isBlank(parentField)) continue;
                if (!neededFieldsByLookup.containsKey(lookupField)) neededFieldsByLookup.put(lookupField, new Set<String>());
                neededFieldsByLookup.get(lookupField).add(parentField);
            }
        }

        if (neededFieldsByLookup.isEmpty()) return;

        Map<String, Set<Id>> idsByParentObject = new Map<String, Set<Id>>();
        Map<String, Set<String>> fieldsByParentObject = new Map<String, Set<String>>();

        for (String lookupField : neededFieldsByLookup.keySet()) {
            Schema.SObjectField sf = fmap.get(lookupField);
            if (sf == null) continue;
            List<Schema.SObjectType> refs = sf.getDescribe().getReferenceTo();
            if (refs == null || refs.isEmpty()) continue;
            String parentType = refs[0].getDescribe().getName();
            if (String.isBlank(parentType)) continue;

            if (!idsByParentObject.containsKey(parentType)) idsByParentObject.put(parentType, new Set<Id>());
            if (!fieldsByParentObject.containsKey(parentType)) fieldsByParentObject.put(parentType, new Set<String>{ 'Id' });
            fieldsByParentObject.get(parentType).addAll(neededFieldsByLookup.get(lookupField));

            for (SObject rec : recById.values()) {
                if (rec == null) continue;
                Id pid = (Id) rec.get(lookupField);
                if (pid != null) idsByParentObject.get(parentType).add(pid);
            }
        }

        for (String parentType : idsByParentObject.keySet()) {
            Set<Id> ids = idsByParentObject.get(parentType);
            if (ids == null || ids.isEmpty()) continue;
            List<String> fields = sortCaseInsensitiveUnique(fieldsByParentObject.get(parentType));
            String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM ' + parentType + ' WHERE Id IN :ids';
            try {
                for (SObject parent : Database.query(soql)) {
                    parentCache.put((Id) parent.get('Id'), parent);
                }
            } catch (Exception ex) {
                System.debug('SB.prefetchLookupParents: soql=' + soql + ' ERROR=' + ex.getMessage());
            }
        }
    }

    private static void addLookupFieldNeed(Map<String, Set<String>> neededFieldsByLookup,
                                           Map<String, Schema.SObjectField> fmap,
                                           String sourceKind,
                                           String lookupFieldApi,
                                           String neededParentField) {
        if (!'Lookup'.equalsIgnoreCase(sourceKind) && !'LookUp'.equalsIgnoreCase(sourceKind)) return;
        String lookupField = resolveFieldApi(fmap, normalizeField(lookupFieldApi));
        String parentField = normalizeField(neededParentField);
        if (String.isBlank(lookupField) || String.isBlank(parentField)) return;
        if (!neededFieldsByLookup.containsKey(lookupField)) neededFieldsByLookup.put(lookupField, new Set<String>());
        neededFieldsByLookup.get(lookupField).add(parentField);
    }

    private static String firstNonBlankMobile(SObject rec, derive_sms_condition_master__c m, Map<Id,SObject> cache) {
        String p1 = readPhone(rec, m.phone_1_source__c, m.phone_1_object__c, m.phone_1_field__c, cache);
        String e1 = SmsUtil.formatPhone(p1); if (e1 != null) return e1;
        String p2 = readPhone(rec, m.phone_2_source__c, m.phone_2_object__c, m.phone_2_field__c, cache);
        String e2 = SmsUtil.formatPhone(p2); if (e2 != null) return e2;
        String p3 = readPhone(rec, m.phone_3_source__c, m.phone_3_object__c, m.phone_3_field__c, cache);
        String e3 = SmsUtil.formatPhone(p3); if (e3 != null) return e3;
        return null;
    }
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

    private void logBatchError(MasterBundle b, Id targetRecordId, Exception ex, Map<String,Object> details) {
        Integer dmlUsed = Limits.getDmlStatements();
        Integer dmlLimit = Limits.getLimitDmlStatements();
        if (errorLogsWritten >= MAX_ERROR_LOGS_PER_EXECUTE || dmlUsed >= (dmlLimit - DML_SAFETY_BUFFER)) {
            System.debug('SB.logBatchError: skipped logging to avoid DML limit'
                + ' written=' + errorLogsWritten
                + ' dml=' + dmlUsed + '/' + dmlLimit
                + ' target=' + targetRecordId
                + ' msg=' + (ex == null ? null : ex.getMessage()));
            return;
        }
        try {
            errorLogsWritten++;
            SmsErrorLogger.log(
                SmsErrorLogger.Severity.Error,
                SmsErrorLogger.Source.ScheduleBatch,
                'Scheduled',
                fireKey,
                masterId,
                null,
                (b == null || b.template == null) ? null : b.template.Id,
                null,
                (b == null ? null : b.targetObject),
                targetRecordId,
                ex,
                details
            );
        } catch (Exception ignore) {
            // Intentionally swallow to avoid masking scheduler flow.
        }
    }
}