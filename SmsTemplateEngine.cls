public with sharing class SmsTemplateEngine {
    private static final String DEFAULT_STATE = 'VIC';

    public class MergeResult {
        public String body;
        public Integer smsCharCount;
        public MergeResult() {}
        public MergeResult(String b) {
            body = b;
            smsCharCount = (b == null ? 0 : b.length());
        }
    }

    public static MergeResult merge1(
        SObject target,
        derive_sms_template_master__c template,
        List<derive_sms_parameters__c> params,
        Map<Id, SObject> parentCache
    ) {
        String inferredTz = inferTzStateFromTarget(target);
        System.debug(LoggingLevel.WARN,
            'MCC 000 merge1(4-arg) called without tzState; inferredTz=' + inferredTz
            + ' targetType=' + (target == null ? 'null' : String.valueOf(target.getSObjectType()))
            + ' targetId=' + (target == null ? null : String.valueOf(target.get('Id'))));
        return merge1(target, template, params, parentCache, inferredTz);
    }

    public static MergeResult merge1(
        SObject target,
        derive_sms_template_master__c template,
        List<derive_sms_parameters__c> params,
        Map<Id, SObject> parentCache,
        String tzState
    ) {
        System.debug(LoggingLevel.INFO,
            'MCC 001 merge1 start target=' + (target == null ? 'null' : String.valueOf(target.getSObjectType()))
            + ' targetId=' + (target == null ? null : String.valueOf(target.get('Id')))
            + ' templateId=' + (template == null ? null : String.valueOf(template.Id))
            + ' tzState=' + tzState);

        if (template == null || String.isBlank(template.content__c)) {
            System.debug(LoggingLevel.WARN, 'MCC 002 merge1 exit: template/content is blank');
            return new MergeResult(null);
        }

        if (params == null) params = new List<derive_sms_parameters__c>();
        if (parentCache == null) parentCache = new Map<Id, SObject>();

        System.debug(LoggingLevel.INFO,
            'MCC 003 merge1 normalized inputs paramsCount=' + params.size() + ' parentCacheSize=' + parentCache.size());

        List<String> missingParamNames = missingTemplateParams(template.content__c, params);
        if (!missingParamNames.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'MCC 004 missing template parameter definitions: ' + String.join(missingParamNames, ', '));
            SmsErrorLogger.log(
                SmsErrorLogger.Severity.Error,
                SmsErrorLogger.Source.TemplateEngine,
                null,
                null,
                null,
                null,
                template.Id,
                null,
                (target == null ? null : String.valueOf(target.getSObjectType())),
                (target == null ? null : (Id)target.get('Id')),
                null,
                new Map<String,Object>{
                    'note' => 'Template contains parameters not configured in Derive_sms_parameters__c',
                    'missingParameters' => missingParamNames,
                    'templateName' => template.Name
                }
            );
            return new MergeResult(null);
        }

        Map<String, String> values = new Map<String, String>();
        Map<String, Set<String>> lookupFieldsByLookupApi = collectLookupFields(params);

        Integer index = 0;
        for (derive_sms_parameters__c p : params) {
            index++;
            if (p == null || String.isBlank(p.p_name__c)) {
                System.debug(LoggingLevel.DEBUG,
                    'MCC 005 skipping parameter row index=' + index + ' because row or p_name__c is blank');
                continue;
            }

            System.debug(LoggingLevel.DEBUG,
                'MCC 006 processing parameter index=' + index
                + ' pName=' + p.p_name__c
                + ' objectType=' + p.Object_Type__c
                + ' objectApi=' + p.Object_API__c
                + ' fieldApi=' + p.Field_API__c
                + ' formatType=' + p.Format_Type__c);

            String resolved = null;

            if (p.Object_Type__c == null || p.Object_Type__c.equalsIgnoreCase('Self')) {
                if (!String.isBlank(p.Field_API__c)) {
                    Object raw = safeGet(target, p.Field_API__c);
                    System.debug(LoggingLevel.DEBUG,
                        'MCC 007 self parameter raw field=' + p.Field_API__c + ' value=' + String.valueOf(raw));
                    resolved = formatValue(raw, p.Format_Type__c, tzState);
                }

            } else if (p.Object_Type__c.equalsIgnoreCase('Lookup')) {
                if (!String.isBlank(p.Object_API__c) && !String.isBlank(p.Field_API__c)) {
                    try {
                        Id parentId = (Id) target.get(p.Object_API__c);
                        System.debug(LoggingLevel.DEBUG,
                            'MCC 008 lookup parameter parentId=' + parentId + ' lookupField=' + p.Object_API__c);

                        if (parentId != null) {
                            SObject parent = parentCache.get(parentId);
                            Set<String> requiredFields = lookupFieldsByLookupApi.get(p.Object_API__c);

                            if (parent == null || !isFieldReadableFromLoadedSObject(parent, p.Field_API__c)) {
                                String parentObj = parentId.getSObjectType().getDescribe().getName();
                                String projection = buildLookupProjection(requiredFields, p.Field_API__c);
                                String soql = 'SELECT ' + projection + ' FROM ' + parentObj + ' WHERE Id = :parentId';
                                System.debug(LoggingLevel.DEBUG,
                                    'MCC 009 lookup query parentObj=' + parentObj + ' projection=' + projection + ' soql=' + soql);
                                parent = Database.query(soql);
                                parentCache.put(parentId, parent);
                            } else {
                                System.debug(LoggingLevel.DEBUG,
                                    'MCC 010 lookup cache hit parentId=' + parentId + ' field=' + p.Field_API__c);
                            }

                            Object raw = safeGet(parent, p.Field_API__c);
                            System.debug(LoggingLevel.DEBUG,
                                'MCC 011 lookup parameter raw field=' + p.Field_API__c + ' value=' + String.valueOf(raw));
                            resolved = formatValue(raw, p.Format_Type__c, tzState);
                        }
                    } catch (Exception ex) {
                        System.debug(LoggingLevel.WARN,
                            'MCC 012 lookup resolve failed for pName=' + p.p_name__c + ' message=' + ex.getMessage());
                    }
                }
            }

            values.put(p.p_name__c, (resolved == null ? '' : resolved));
            System.debug(LoggingLevel.DEBUG,
                'MCC 013 parameter resolved pName=' + p.p_name__c + ' value=' + values.get(p.p_name__c));
        }

        String body = template.content__c;
        System.debug(LoggingLevel.DEBUG, 'MCC 014 template body before merge=' + body);

        for (String key : values.keySet()) {
            body = body.replace('{{' + key + '}}', values.get(key));
            System.debug(LoggingLevel.DEBUG,
                'MCC 015 token replaced key=' + key + ' value=' + values.get(key));
        }

        System.debug(LoggingLevel.INFO,
            'MCC 016 merge1 end bodyLength=' + (body == null ? 0 : body.length()) + ' body=' + body);
        return new MergeResult(body);
    }


    private static Map<String, Set<String>> collectLookupFields(List<derive_sms_parameters__c> params) {
        Map<String, Set<String>> out = new Map<String, Set<String>>();
        if (params == null) return out;

        for (derive_sms_parameters__c p : params) {
            if (p == null) continue;
            if (String.isBlank(p.Object_Type__c) || !p.Object_Type__c.equalsIgnoreCase('Lookup')) continue;
            if (String.isBlank(p.Object_API__c) || String.isBlank(p.Field_API__c)) continue;

            if (!out.containsKey(p.Object_API__c)) out.put(p.Object_API__c, new Set<String>());
            out.get(p.Object_API__c).add(p.Field_API__c);
        }
        return out;
    }

    private static String buildLookupProjection(Set<String> requiredFields, String fallbackField) {
        Set<String> fields = new Set<String>{ 'Id' };
        if (requiredFields != null) fields.addAll(requiredFields);
		        if (!String.isBlank(fallbackField)) fields.add(fallbackField);

        List<String> ordered = new List<String>();
        ordered.addAll(fields);
        ordered.sort();
        return String.join(ordered, ', ');
    }

    private static Boolean isFieldReadableFromLoadedSObject(SObject sobj, String fieldApi) {
        if (sobj == null || String.isBlank(fieldApi)) return false;
        try {
            sobj.get(fieldApi);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static Object safeGet(SObject sobj, String fieldApi) {
        if (sobj == null || String.isBlank(fieldApi)) return null;
        try { return sobj.get(fieldApi); } catch (Exception e) { return null; }
    }

    private static String formatValue(Object v, String formatType, String tzState) {
        if (String.isBlank(formatType)) {
            String passthrough = (v == null ? '' : String.valueOf(v));
            System.debug(LoggingLevel.DEBUG,
                'MCC 017 formatValue passthrough formatType blank value=' + passthrough);
            return passthrough;
        }

        String ft = formatType.toLowerCase();

        if (ft == 'name') {
            if (v == null) {
                System.debug(LoggingLevel.DEBUG, 'MCC 018 formatValue name null -> Customer');
                return 'Customer';
            }
            String resolvedName = SmsUtil.firstName(String.valueOf(v));
            if (String.isBlank(resolvedName)) resolvedName = 'Customer';
            System.debug(LoggingLevel.DEBUG,
                'MCC 019 formatValue name input=' + String.valueOf(v) + ' output=' + resolvedName);
            return resolvedName;
        }

        if (v == null) return '';

        if (ft == 'phone') {
            String e164 = SmsUtil.formatPhone(String.valueOf(v));
            String out = (e164 == null ? '' : e164);
            System.debug(LoggingLevel.DEBUG,
                'MCC 020 formatValue phone input=' + String.valueOf(v) + ' output=' + out);
            return out;

        } else if (ft == 'date') {
            if (v instanceof Date) {
                String out = ((Date) v).format();
                System.debug(LoggingLevel.DEBUG, 'MCC 021 formatValue date(Date) output=' + out);
                return out;
            }
            if (v instanceof Datetime) {
                String tzId = timezoneIdForState(tzState);
                String out = ((Datetime) v).format('d MMMM yyyy', tzId);
                System.debug(LoggingLevel.DEBUG,
                    'MCC 022 formatValue date(Datetime) input=' + String.valueOf(v)
                    + ' tzState=' + tzState + ' tzId=' + tzId + ' output=' + out);
                return out;
            }
            return String.valueOf(v);

        } else if (ft == 'datetime') {
            if (v instanceof Datetime) {
                String tzId = timezoneIdForState(tzState);
                String out = ((Datetime) v).format('d MMMM yyyy hh:mm a', tzId);
                System.debug(LoggingLevel.DEBUG,
                    'MCC 023 formatValue datetime input=' + String.valueOf(v)
                    + ' tzState=' + tzState + ' tzId=' + tzId + ' output=' + out);
                return out;
            }
            if (v instanceof Date) {
                String out = Datetime.newInstance((Date) v, Time.newInstance(0,0,0,0)).format('dd MMM yyyy hh:mm a');
                System.debug(LoggingLevel.DEBUG, 'MCC 024 formatValue datetime(Date) output=' + out);
                return out;
            }
            return String.valueOf(v);

        } else if (ft == 'time') {
            String out = formatTime(v, tzState);
            System.debug(LoggingLevel.DEBUG,
                'MCC 025 formatValue time input=' + String.valueOf(v) + ' output=' + out);
            return out;
        }

        return String.valueOf(v);
    }

    private static String formatTime(Object v, String tzState) {
        if (v == null) return '';
        if (v instanceof Time) {
            Datetime d = Datetime.newInstance(Date.today(), (Time)v);
            return d.format('hh:mm a');
        }
        if (v instanceof Datetime) {
            String tzId = timezoneIdForState(tzState);
            return ((Datetime)v).format('hh:mm a', tzId);
        }
        if (v instanceof Date) {
            return Datetime.newInstance((Date)v, Time.newInstance(0,0,0,0)).format('hh:mm a');
        }

        String raw = String.valueOf(v).trim();
        if (String.isBlank(raw)) return '';

        Datetime parsed = parseDatetimeLoose(raw);
        if (parsed != null) {
            String tzId = timezoneIdForState(tzState);
            return parsed.format('hh:mm a', tzId);
        }

        return raw;
    }

    private static Datetime parseDatetimeLoose(String raw) {
        if (String.isBlank(raw)) return null;

        try { return Datetime.valueOf(raw); } catch (Exception ignore1) {}

        String s = raw.toLowerCase().trim().replaceAll(',', ' ').replaceAll('\\s+', ' ');
        Matcher m = Pattern.compile('^(\\d{1,2})\\s+([a-z]{3,9})\\s+(\\d{4})\\s+(\\d{1,2}):(\\d{2})(?:\\s*([ap]m))?$').matcher(s);
        if (!m.matches()) return null;

        Integer dd = Integer.valueOf(m.group(1));
        String mon = m.group(2);
        Integer yyyy = Integer.valueOf(m.group(3));
        Integer hh = Integer.valueOf(m.group(4));
        Integer mm = Integer.valueOf(m.group(5));
        String ampm = m.group(6);

        Map<String, Integer> monthByName = new Map<String, Integer>{
            'jan'=>1,'january'=>1,
            'feb'=>2,'february'=>2,
            'mar'=>3,'march'=>3,
            'apr'=>4,'april'=>4,
            'may'=>5,
            'jun'=>6,'june'=>6,
            'jul'=>7,'july'=>7,
            'aug'=>8,'august'=>8,
            'sep'=>9,'sept'=>9,'september'=>9,
            'oct'=>10,'october'=>10,
            'nov'=>11,'november'=>11,
            'dec'=>12,'december'=>12
        };
        Integer monNum = monthByName.get(mon);
        if (monNum == null) return null;

        if (!String.isBlank(ampm)) {
            if (hh == 12) hh = 0;
            if (ampm == 'pm') hh += 12;
        }

        try {
            Date d = Date.newInstance(yyyy, monNum, dd);
            Time t = Time.newInstance(hh, mm, 0, 0);
            return Datetime.newInstance(d, t);
        } catch (Exception ignore2) {
            return null;
        }
    }

    private static Datetime toStateLocal(Datetime utc, String tzState) {
        if (utc == null) return null;
        String state = normalizeState(tzState);
        Date anchorDate = utc.addHours(10).date();
        Decimal off = offsetHoursForStateDate(state, anchorDate);
        Datetime out = utc.addSeconds(Integer.valueOf(Math.round(off * 3600)));
        System.debug(LoggingLevel.DEBUG,
            'MCC 026 toStateLocal utc=' + String.valueOf(utc)
            + ' tzState=' + tzState + ' normalizedState=' + state
            + ' anchorDate=' + String.valueOf(anchorDate)
            + ' offset=' + off + ' output=' + String.valueOf(out));
			return out;
    }

    private static Decimal offsetHoursForStateDate(String state, Date d) {
        if ('QLD' == state) return 10;

        Date firstSundayApr = firstSundayOfMonth(d.year(), 4);
        Date firstSundayOct = firstSundayOfMonth(d.year(), 10);

        Boolean isDst = d < firstSundayApr || d >= firstSundayOct;
        Decimal off;
        if ('SA' == state) off = isDst ? 10.5 : 9.5;
        else off = isDst ? 11 : 10;

        System.debug(LoggingLevel.DEBUG,
            'MCC 027 offsetHoursForStateDate state=' + state
            + ' date=' + String.valueOf(d)
            + ' firstSundayApr=' + String.valueOf(firstSundayApr)
            + ' firstSundayOct=' + String.valueOf(firstSundayOct)
            + ' isDst=' + isDst + ' offset=' + off);
        return off;
    }

    private static Date firstSundayOfMonth(Integer yearNum, Integer monthNum) {
        Date first = Date.newInstance(yearNum, monthNum, 1);
        String dow = Datetime.newInstance(first, Time.newInstance(0,0,0,0)).format('E');
        Integer idx = new Map<String,Integer>{
            'Mon'=>1,'Tue'=>2,'Wed'=>3,'Thu'=>4,'Fri'=>5,'Sat'=>6,'Sun'=>7
        }.get(dow);
        Integer addDays = Math.mod(7 - idx, 7);
        return first.addDays(addDays);
    }



    private static String timezoneIdForState(String tzState) {
        String state = normalizeState(tzState);
        if ('SA' == state) return 'Australia/Adelaide';
        if ('QLD' == state) return 'Australia/Brisbane';
        return 'Australia/Melbourne';
    }

    private static String normalizeState(String tzState) {
        if (String.isBlank(tzState)) {
            System.debug(LoggingLevel.DEBUG, 'MCC 028 normalizeState blank tzState -> ' + DEFAULT_STATE);
            return DEFAULT_STATE;
        }

        String raw = tzState.trim();
        String s = raw.toUpperCase();

        if (s == 'SA' || s == 'VIC' || s == 'QLD') {
            System.debug(LoggingLevel.DEBUG, 'MCC 029 normalizeState direct match raw=' + raw + ' -> ' + s);
            return s;
        }

        if (s.contains('BRISBANE') || s.contains('QUEENSLAND') || s.contains('QLD')) {
            System.debug(LoggingLevel.DEBUG, 'MCC 030 normalizeState mapped raw=' + raw + ' -> QLD');
            return 'QLD';
        }
        if (s.contains('ADELAIDE') || s.contains('SOUTH AUSTRALIA') || s.contains(' SA')) {
            System.debug(LoggingLevel.DEBUG, 'MCC 031 normalizeState mapped raw=' + raw + ' -> SA');
            return 'SA';
        }
        if (s.contains('MELBOURNE') || s.contains('VICTORIA') || s.contains('VIC')
            || s.contains('SYDNEY') || s.contains('CANBERRA') || s.contains('HOBART')) {
            System.debug(LoggingLevel.DEBUG, 'MCC 032 normalizeState mapped raw=' + raw + ' -> VIC');
            return 'VIC';
        }

        System.debug(LoggingLevel.DEBUG, 'MCC 033 normalizeState fallback raw=' + raw + ' -> ' + DEFAULT_STATE);
        return DEFAULT_STATE;
    }

    private static String inferTzStateFromTarget(SObject target) {
        if (target == null) return DEFAULT_STATE;

        List<String> candidateFields = new List<String>{
            'Schedule_TZ__c',
            'Timezone__c',
            'TimeZone__c',
            'State',
            'State__c',
            'StateCode'
        };

        for (String fieldApi : candidateFields) {
            Object raw = safeGet(target, fieldApi);
            if (raw == null) continue;

            String normalized = normalizeState(String.valueOf(raw));
            if (!String.isBlank(normalized)) return normalized;
        }

        return DEFAULT_STATE;
    }

    private static List<String> missingTemplateParams(String templateBody, List<derive_sms_parameters__c> params) {
        Set<String> declared = new Set<String>();
        if (params != null) {
            for (derive_sms_parameters__c p : params) {
                if (p == null || String.isBlank(p.p_name__c)) continue;
                declared.add(p.p_name__c.trim());
            }
        }

        Set<String> missing = new Set<String>();
        if (String.isBlank(templateBody)) return new List<String>();

        Matcher m = Pattern.compile('\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}').matcher(templateBody);
        while (m.find()) {
            String token = m.group(1);
            if (!declared.contains(token)) missing.add(token);
        }

        List<String> out = new List<String>();
        out.addAll(missing);
        out.sort();
        return out;
    }
}