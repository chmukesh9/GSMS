public with sharing class SmsConditionEvaluator {

    public static Boolean allPass(SObject rec,
                                  List<derive_sms_rules__c> rules,
                                  Map<Id,SObject> parentCache,
                                  Map<Id,SObject> oldMap,
                                  SObject newRec) {
        return allPass(rec, rules, parentCache, oldMap, newRec, null);
    }

    public static Boolean allPass(SObject rec,
                                  List<derive_sms_rules__c> rules,
                                  Map<Id,SObject> parentCache,
                                  Map<Id,SObject> oldMap,
                                  SObject newRec,
                                  String tzKey) {
        return allPass(rules, newRec == null ? rec : newRec, oldMap, tzKey);
    }

    public static Boolean allPass(List<derive_sms_rules__c> rules,
                                  SObject newRec,
                                  Map<Id,SObject> oldMap) {
        return allPass(rules, newRec, oldMap, null);
    }

    public static Boolean allPass(List<derive_sms_rules__c> rules,
                                  SObject newRec,
                                  Map<Id,SObject> oldMap,
                                  String tzKey) {
        if (newRec == null || rules == null) return false;
        Boolean anyEvaluated = false;
        for (derive_sms_rules__c r : rules) {
            if (r == null || r.Active__c != true) continue;
            anyEvaluated = true;
            Boolean passed = evalOne(r, newRec, oldMap, tzKey);
            System.debug('SCE.allPass: rule=' + r.Id + ' type=' + r.condition_type__c + ' passed=' + passed);
            if (!passed) return false;
        }
        return anyEvaluated;
    }

    private static Boolean evalOne(derive_sms_rules__c r,
                                   SObject n,
                                   Map<Id,SObject> oldMap,
                                   String tzKey) {
        String kind = safeTrim(r.condition_type__c);
        if ('Transition'.equalsIgnoreCase(kind)) {
            String fieldApi = safeTrim(r.transition_field_api__c);
            if (String.isBlank(fieldApi)) return false;

            Object newVal = safeGetField(n, fieldApi);
            Object oldVal = null;
            if (oldMap != null) {
                SObject o = oldMap.get((Id)n.get('Id'));
                if (o != null) oldVal = safeGetField(o, fieldApi);
            }

            String expOld = safeTrim(r.transition_old_value__c);
            String expNew = safeTrim(r.transition_new_value__c);
            System.debug('MCC Tranisition : Old value = '+expOld+' New value = '+expNew);
            
            return matchTransition(oldVal, newVal, expOld, expNew, tzKey);
        }
        else if ('Filter'.equalsIgnoreCase(kind)) {
            String source = safeTrim(r.filter_source__c);
            String fieldApi = safeTrim(r.filter_field__c);
            if (String.isBlank(fieldApi)) return false;
            Object actual;
            if ('LookUp'.equalsIgnoreCase(source) || 'Lookup'.equalsIgnoreCase(source)) {
                String lookupFieldApi = safeTrim(r.filter_object_name__c);
                if (String.isBlank(lookupFieldApi)) return false;
                Id parentId = (Id) safeGetField(n, lookupFieldApi);
                if (parentId == null) return false;
                actual = fetchLookupValue(n, parentId, lookupFieldApi, fieldApi);
            } else {
                actual = safeGetField(n, fieldApi);
            }
            String op = safeTrim(r.Operator__c);
            String expected = safeTrim(r.filter_value__c);
            Decimal offsHours = r.filter_offset_hours__c;
            Decimal offsDays = r.offset_days__c;

            return compare(actual, op, expected, offsDays, offsHours, tzKey);
        }
        return false;
    }

    private static Boolean matchTransition(Object actualOld, Object actualNew,
                                           String expectedOld, String expectedNew,
                                           String tzKey) {
        // Transition must always represent an actual change.
        if (!valuesDiffer(actualOld, actualNew)) return false;

        return matchTransitionOperand(actualOld, expectedOld, tzKey)
            && matchTransitionOperand(actualNew, expectedNew, tzKey);
    }

    private static Boolean matchTransitionOperand(Object actual, String expectedRaw, String tzKey) {
        String expected = safeTrim(expectedRaw);

        // Legacy blank behavior: treat as unconstrained.
        if (expected == null) return true;

        // Transition token semantics:
        // NULL => null/empty
        // ANY  => anything except null/empty
        // ALL  => anything including null/empty
        if (expected.equalsIgnoreCase('NULL')) return isNullOrEmptyTransition(actual);
        if (expected.equalsIgnoreCase('ANY'))  return !isNullOrEmptyTransition(actual);
        if (expected.equalsIgnoreCase('ALL'))  return true;

        return matchOne(actual, expected, tzKey);
    }

    private static Boolean isNullOrEmptyTransition(Object v) {
        return v == null || String.isBlank(stringify(v));
    }

    private static Boolean valuesDiffer(Object oldVal, Object newVal) {
        if (oldVal == null && newVal == null) return false;
        if (oldVal == null || newVal == null) return true;

        if (oldVal instanceof Date && newVal instanceof Date) {
            return ((Date)oldVal) != ((Date)newVal);
        }
        if (oldVal instanceof Datetime && newVal instanceof Datetime) {
            return ((Datetime)oldVal).getTime() != ((Datetime)newVal).getTime();
        }
        if (isNumeric(oldVal) && isNumeric(newVal)) {
            Decimal o = toDecimal(oldVal);
            Decimal n = toDecimal(newVal);
            return o != n;
        }

        return !equalsIgnoreCase(oldVal, String.valueOf(newVal));
    }

    private static Boolean matchOne(Object actual, String expectedRaw, String tzKey) {
        String expected = safeTrim(expectedRaw);

        if (expected == null || expected.equalsIgnoreCase('ANY')) return true;
        if (expected.equalsIgnoreCase('NULL'))  return actual == null;
        if (expected.equalsIgnoreCase('EMPTY')) return (actual == null) || String.isBlank(stringify(actual));
        if (expected.equalsIgnoreCase('TODAY') || expected.equalsIgnoreCase('TOMORROW')) {
            Date ref = localTodayDate(tzKey);
            if (expected.equalsIgnoreCase('TOMORROW')) ref = ref.addDays(1);
            Date actualLocalDate = localDateForComparison(actual, tzKey);
            if (actualLocalDate != null) return actualLocalDate == ref;
            return equalsIgnoreCase(actual, expected);
        }

        if (actual instanceof Date) {
            Date expD = parseDateLenient(expected);
            if (expD != null) return ((Date)actual) == expD;
            return equalsIgnoreCase(actual, expected);
        }
        if (actual instanceof Datetime) {
            Datetime expDT = parseDatetimeLenient(expected);
            if (expDT != null) return ((Datetime)actual).date() == expDT.date();
            Date expDateOnly = parseDateLenient(expected);
            if (expDateOnly != null) return ((Datetime)actual).date() == expDateOnly;
            return equalsIgnoreCase(actual, expected);
        }
        if (isNumeric(actual)) {
            Decimal act = toDecimal(actual);
            Decimal exp = toDecimalSafe(expected);
            if (exp != null) return act == exp;
            return equalsIgnoreCase(actual, expected);
        }
        return equalsIgnoreCase(actual, expected);
    }

    private static Boolean compare(Object actual,
                                   String op,
                                   String expectedRaw,
                                   Decimal offsetDays,
                                   Decimal offsetHours,
                                   String tzKey) {
        op = normalizeOperator(op);
        String expected = safeTrim(expectedRaw);

        // NULL token semantics for Filter comparisons (all data types):
        // EQUALS NULL     => true when actual is null/empty
        // NOT_EQUALS NULL => true when actual is non-empty
        if ((op == 'EQUALS' || op == 'NOT_EQUALS') && !String.isBlank(expected)
            && expected.equalsIgnoreCase('NULL')) {
            Boolean isMissing = (actual == null) || String.isBlank(stringify(actual));
            return op == 'EQUALS' ? isMissing : !isMissing;
        }

        List<String> multi = splitMulti(expected);

        if (op == 'IN' || op == 'NOT_IN') {
            Boolean found = false;
            for (String token : multi) {
                if (matchOne(actual, token, tzKey)) { found = true; break; }
            }
            return (op == 'IN') ? found : !found;
        }

        if (actual instanceof Date || actual instanceof Datetime) {
            if (isTodayTomorrowToken(expected) && (op == 'EQUALS' || op == 'NOT_EQUALS')) {
                Date actualLocalDate = localDateForComparison(actual, tzKey);
                Date expectedLocalDate = resolveDayTokenDate(expected, offsetDays, offsetHours, tzKey);
                if (actualLocalDate == null || expectedLocalDate == null) return false;
                Boolean sameDay = (actualLocalDate == expectedLocalDate);
                return op == 'EQUALS' ? sameDay : !sameDay;
            }
            Datetime actualDT = (actual instanceof Datetime) ? (Datetime)actual
                                                             : Datetime.newInstance((Date)actual, Time.newInstance(0,0,0,0));
            Datetime expDT = resolveDateAnchor(expected, offsetDays, offsetHours, tzKey);
            if (expDT == null) return false;
            Long at = actualDT.getTime(), et = expDT.getTime();
            Integer cmp = (at == et ? 0 : (at > et ? 1 : -1));
            if (op == 'GREATER_THAN') return cmp > 0;
            if (op == 'LESS_THAN')    return cmp < 0;
            if (op == 'GREATER_THAN_OR_EQUAL') return cmp >= 0;
            if (op == 'LESS_THAN_OR_EQUAL')    return cmp <= 0;
            if (op == 'EQUALS')       return cmp == 0;
            if (op == 'NOT_EQUALS')   return cmp != 0;
            return false;
        }

        if (isNumeric(actual)) {
            Decimal act = toDecimal(actual);
            Decimal exp = toDecimalSafe(expected);
            if (exp == null) return false;
            Integer c = (act == exp ? 0 : (act > exp ? 1 : -1));
            if (op == 'GREATER_THAN') return c > 0;
            if (op == 'LESS_THAN')    return c < 0;
            if (op == 'GREATER_THAN_OR_EQUAL') return c >= 0;
            if (op == 'LESS_THAN_OR_EQUAL')    return c <= 0;
            if (op == 'EQUALS')       return c == 0;
            if (op == 'NOT_EQUALS')   return c != 0;
            return false;
        }

        if (op == 'EQUALS')     return equalsIgnoreCase(actual, expected);
        if (op == 'NOT_EQUALS') return !equalsIgnoreCase(actual, expected);
        return false;
    }


    private static String normalizeOperator(String op) {
        if (String.isBlank(op)) return 'EQUALS';
        String t = op.trim().toUpperCase().replace(' ', '_');
        if (t == '=' || t == 'EQ' || t == 'EQUAL' || t == 'EQUALS') return 'EQUALS';
        if (t == '!=' || t == '<>' || t == 'NE' || t == 'NOT_EQUAL' || t == 'NOT_EQUALS') return 'NOT_EQUALS';
        if (t == '>=' || t == 'GTE' || t == 'GE' || t == 'GREATER_OR_EQUAL' || t == 'GREATER_THAN_OR_EQUAL') return 'GREATER_THAN_OR_EQUAL';
        if (t == '<=' || t == 'LTE' || t == 'LE' || t == 'LESS_OR_EQUAL' || t == 'LESS_THAN_OR_EQUAL') return 'LESS_THAN_OR_EQUAL';
        if (t == '>' || t == 'GT' || t == 'GREATER' || t == 'GREATER_THAN') return 'GREATER_THAN';
        if (t == '<' || t == 'LT' || t == 'LESS' || t == 'LESS_THAN') return 'LESS_THAN';
        if (t == 'IN') return 'IN';
        if (t == 'NOT_IN' || t == 'NOTIN') return 'NOT_IN';
        return t;
    }

    private static Datetime resolveDateAnchor(String expected, Decimal offsetDays, Decimal offsetHours, String tzKey) {
        if (String.isBlank(expected)) return null;
        String v = expected.trim().toUpperCase();
        Datetime baseDT;
        if (v == 'NOW') {
            baseDT = System.now();
        } else if (v == 'TODAY') {
            baseDT = Datetime.newInstanceGmt(localTodayDate(tzKey), Time.newInstance(0,0,0,0));
        } else if (v == 'TOMORROW') {
            baseDT = Datetime.newInstanceGmt(localTodayDate(tzKey).addDays(1), Time.newInstance(0,0,0,0));
        } else {
            Datetime parsed = parseDatetimeLenient(expected);
            if (parsed != null) baseDT = parsed;
            else {
                Date d = parseDateLenient(expected);
                if (d != null) baseDT = Datetime.newInstanceGmt(d, Time.newInstance(0,0,0,0));
                else return null;
            }
        }
        Integer offsDayCount = (offsetDays == null ? 0 : Integer.valueOf(Math.round(offsetDays)));
        Integer offsSeconds = (offsetHours == null ? 0 : Integer.valueOf(Math.round(offsetHours * 3600)));
        Datetime localAdjusted = baseDT.addDays(offsDayCount).addSeconds(offsSeconds);
        return SmsScheduleService.toUtcTime(effectiveTzKey(tzKey), localAdjusted);
    }

    private static String safeTrim(String s) { return (s == null ? null : s.trim()); }

    private static String effectiveTzKey(String tzKey) {
        if (String.isBlank(tzKey)) return 'VIC';
        String t = tzKey.trim().toUpperCase();
        if (t == 'SA' || t == 'VIC' || t == 'QLD') return t;
        return 'VIC';
    }


    private static String timezoneIdForKey(String tzKey) {
        String key = effectiveTzKey(tzKey);
        if (key == 'SA') return 'Australia/Adelaide';
        if (key == 'QLD') return 'Australia/Brisbane';
        return 'Australia/Melbourne';
    }

    private static Object safeGetField(SObject rec, String fieldApi) {
        if (rec == null || String.isBlank(fieldApi)) return null;
        try {
            return rec.get(fieldApi);
        } catch (Exception e) {
            System.debug('SCE.safeGetField: field=' + fieldApi + ' message=' + e.getMessage());
            return null;
        }
    }

    private static String stringify(Object o) { return (o == null ? null : String.valueOf(o).trim()); }

    private static Boolean equalsIgnoreCase(Object a, String b) {
        String la = stringify(a); String lb = (b == null ? null : b.trim());
        if (la == null && lb == null) return true;
        if (la == null || lb == null) return false;
        return la.equalsIgnoreCase(lb);
    }

    private static Boolean isNumeric(Object o) {
        return (o instanceof Integer) || (o instanceof Long) || (o instanceof Decimal);
    }

    private static Decimal toDecimal(Object n) {
        if (n instanceof Decimal) return (Decimal)n;
        if (n instanceof Integer) return Decimal.valueOf((Integer)n);
        if (n instanceof Long)    return Decimal.valueOf((Long)n);
        return null;
    }

    private static Decimal toDecimalSafe(String s) {
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s); } catch (Exception e) { return null; }
    }

    private static Date parseDateLenient(String s) {
        if (String.isBlank(s)) return null;
        String v = s.trim();
        try {
            if (v.contains('-')) return Date.valueOf(v);
            if (v.contains('/')) {
                List<String> p = v.split('/');
                if (p.size() == 3) {
                    Integer a = Integer.valueOf(p[0]);
                    Integer b = Integer.valueOf(p[1]);
                    Integer c = Integer.valueOf(p[2]);
                    Integer dd, mm, yyyy;
                    if (a > 12) { dd = a; mm = b; yyyy = c; }
                    else { mm = a; dd = b; yyyy = c; }
                    return Date.newInstance(yyyy, mm, dd);
                }
            }
        } catch (Exception ignore) {}
        return null;
    }

    private static Datetime parseDatetimeLenient(String s) {
        if (String.isBlank(s)) return null;
        String v = s.trim();
        try {
            if (v.contains('T') || v.contains('-')) {
                return Datetime.valueOf(v);
            }
            if (v.contains('/')) {
                List<String> parts = v.split('\\s+');
                Date d = parseDateLenient(parts[0]);
                Time t = Time.newInstance(0,0,0,0);
                if (parts.size() > 1) {
                    List<String> hm = parts[1].split(':');
                    Integer h = Integer.valueOf(hm[0]);
                    Integer m = (hm.size() > 1 ? Integer.valueOf(hm[1]) : 0);
                    t = Time.newInstance(h, m, 0, 0);
                }
                return Datetime.newInstance(d, t);
            }
        } catch (Exception ignore) {}
        return null;
    }

    private static List<String> splitMulti(String s) {
        List<String> out = new List<String>();
        if (String.isBlank(s)) return out;
        for (String tok : s.split('[;,]')) {
            if (!String.isBlank(tok)) out.add(tok.trim());
        }
        return out;
    }

    private static Boolean evalFilter(derive_sms_rules__c r,
                                      SObject n,
                                      Map<Id,SObject> oldMap) {
        String op = safeTrim(r.Operator__c);
        if (String.isBlank(op)) op = 'EQUALS';
        String fieldApi = safeTrim(r.filter_field__c);
        if (String.isBlank(fieldApi)) return false;
        Object actual = safeGetField(n, fieldApi);
        return compare(actual, op, safeTrim(r.filter_value__c), r.offset_days__c, r.filter_offset_hours__c, null);
    }

    private static Object fetchLookupValue(SObject n,
                                           Id parentId,
                                           String lookupFieldApi,
                                           String fieldApi) {
        try {
            if (parentId == null || String.isBlank(fieldApi)) return null;

            // Resolve parent object from the actual Id prefix to support polymorphic/multi-reference lookups.
            String parentObj = parentId.getSObjectType().getDescribe().getName();

            // Fallback to lookup field metadata if needed.
            if (String.isBlank(parentObj)) {
                Schema.SObjectField sf = n.getSObjectType().getDescribe().fields.getMap().get(lookupFieldApi);
                if (sf == null) return null;
                List<Schema.SObjectType> refs = sf.getDescribe().getReferenceTo();
                if (refs == null || refs.isEmpty()) return null;
                parentObj = refs[0].getDescribe().getName();
            }

            String soql = 'SELECT ' + fieldApi + ' FROM ' + parentObj + ' WHERE Id = :parentId LIMIT 1';
            SObject parent = Database.query(soql);
            return parent == null ? null : parent.get(fieldApi);
        } catch (Exception ex) {
            System.debug('SCE.fetchLookupValue: lookup=' + lookupFieldApi
                + ' field=' + fieldApi
                + ' parentId=' + parentId
                + ' ERROR ' + ex.getMessage());
            return null;
        }
    }


    private static Boolean isTodayTomorrowToken(String expected) {
        if (String.isBlank(expected)) return false;
        String v = expected.trim().toUpperCase();
        return v == 'TODAY' || v == 'TOMORROW';
    }

    private static Date localDateForComparison(Object actual, String tzKey) {
        if (actual == null) return null;
        if (actual instanceof Date) return (Date) actual;
        if (actual instanceof Datetime) {
            Datetime dt = (Datetime) actual;
            String tzId = timezoneIdForKey(tzKey);
            try {
                return Date.valueOf(dt.format('yyyy-MM-dd', tzId));
            } catch (Exception ignore) {
                Datetime local = SmsScheduleService.toLocalTime(effectiveTzKey(tzKey), dt);
                return local == null ? dt.date() : local.date();
            }
        }
        return null;
    }

    private static Date resolveDayTokenDate(String expected, Decimal offsetDays, Decimal offsetHours, String tzKey) {
        if (!isTodayTomorrowToken(expected)) return null;

        Date base = localTodayDate(tzKey);
        if (expected != null && expected.trim().equalsIgnoreCase('TOMORROW')) {
            base = base.addDays(1);
        }

        Integer offsDayCount = (offsetDays == null ? 0 : Integer.valueOf(Math.round(offsetDays)));
        Integer offsSeconds = (offsetHours == null ? 0 : Integer.valueOf(Math.round(offsetHours * 3600)));

        // Evaluate token anchors in local-day space (master TZ semantics) to avoid UTC/user-TZ drift.
        Datetime localAnchor = Datetime.newInstanceGmt(base, Time.newInstance(0,0,0,0));
        Datetime shiftedLocal = localAnchor.addDays(offsDayCount).addSeconds(offsSeconds);
        return shiftedLocal.date();
    }

    @TestVisible
    private static Date localTodayDateAt(String tzKey, Datetime nowUtc) {
        Datetime anchor = (nowUtc == null ? Datetime.now() : nowUtc);
        String tzId = timezoneIdForKey(tzKey);
        try {
            return Date.valueOf(anchor.format('yyyy-MM-dd', tzId));
        } catch (Exception ignore) {
            Datetime localNow = SmsScheduleService.toLocalTime(effectiveTzKey(tzKey), anchor);
            return localNow == null ? anchor.date() : localNow.date();
        }
    }

    private static Date localTodayDate(String tzKey) {
        return localTodayDateAt(tzKey, Datetime.now());
    }

    @TestVisible
    static Boolean isSameLocalDayAsTodayForTest(Datetime actualGmt, String tzKey, Datetime nowGmt) {
        Date actualLocalDate = localDateForComparison(actualGmt, tzKey);
        Date todayLocalDate = localTodayDateAt(tzKey, nowGmt);
        return actualLocalDate != null && todayLocalDate != null && actualLocalDate == todayLocalDate;
    }
}