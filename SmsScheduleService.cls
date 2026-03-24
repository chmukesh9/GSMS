public with sharing class SmsScheduleService {

    public class DueCheck {
        public Boolean due;
        public String fireKey;
        public Datetime nextUtc;
        public Datetime occurUtc;
        public DueCheck() {}
        public DueCheck(Boolean d, String f, Datetime n) { due = d; fireKey = f; nextUtc = n; occurUtc = null; }
        public DueCheck(Boolean d, String f, Datetime n, Datetime o) {
            due = d;
            fireKey = f;
            nextUtc = n;
            occurUtc = o;
        }
    }

    public static DueCheck isDueNow(derive_sms_condition_master__c m, Datetime nowUtc) {
        if (m == null || m.Active__c != true || m.Trigger_Type__c != 'Scheduled') return null;
        if (m.Schedule_Time__c == null ||
            String.isBlank(m.Schedule_Frequency__c) ||
            String.isBlank(m.Schedule_TZ__c)) return null;

        Datetime nowMinute = toMinutePrecision(nowUtc);
        Datetime windowEnd = nowMinute.addMinutes(5);
        if (m.Next_Run__c != null) {
            Datetime nextRunMinute = toMinutePrecision(m.Next_Run__c);
            if (nextRunMinute > windowEnd) {
                return new DueCheck(false, null, m.Next_Run__c, m.Next_Run__c);
            }
            if (nextRunMinute >= nowMinute && nextRunMinute <= windowEnd) {
                Datetime localOccurFromNext = toLocalTime(m.Schedule_TZ__c, m.Next_Run__c);
                String fireKey = buildFireKey(localOccurFromNext, m.Schedule_TZ__c);
                if (m.Last_Fire_Key__c != null && m.Last_Fire_Key__c == fireKey) {
                    return new DueCheck(false, fireKey, m.Next_Run__c, m.Next_Run__c);
                }
                Datetime localAfter = localOccurFromNext.addMinutes(1);
                Datetime localNext = computeNextLocalOccurrence(m, localAfter, false);
                Decimal offNext = tzOffsetHoursForLocal(m.Schedule_TZ__c, localNext);
                Datetime nextUtc = addHours(localNext, -offNext);
                return new DueCheck(true, fireKey, nextUtc, m.Next_Run__c);
            }
        }

        Decimal offNow = tzOffsetHours(m.Schedule_TZ__c, nowUtc);
        Datetime localNow = addHours(nowMinute, offNow);

        Datetime localOccur = computeNextLocalOccurrence(m, localNow, true);

        Decimal offAtOccur = tzOffsetHoursForLocal(m.Schedule_TZ__c, localOccur);
        Datetime occurUtc = addHours(localOccur, -offAtOccur);

        Datetime occurMinute = toMinutePrecision(occurUtc);
        Boolean due = occurMinute >= nowMinute && occurMinute <= windowEnd;
        String fireKey = buildFireKey(localOccur, m.Schedule_TZ__c);

        if (m.Last_Fire_Key__c != null && m.Last_Fire_Key__c == fireKey) {
            return new DueCheck(false, fireKey, occurUtc, occurUtc);
        }

        Datetime nextUtc;
        if (due) {
            Datetime localAfter = localOccur.addMinutes(1);
            Datetime localNext = computeNextLocalOccurrence(m, localAfter, false);
            Decimal offNext = tzOffsetHoursForLocal(m.Schedule_TZ__c, localNext);
            nextUtc = addHours(localNext, -offNext);
        } else {
            nextUtc = occurMinute;
        }

        return new DueCheck(due, fireKey, nextUtc, occurUtc);
    }

    private static Datetime computeNextLocalOccurrence(derive_sms_condition_master__c m, Datetime localRef, Boolean allowNow) {
        Time t = m.Schedule_Time__c;
        String freq = m.Schedule_Frequency__c;

        if (freq == 'Daily') {
            Datetime todayAt = newLocalDateTime(localRef.date(), t);
            if ((allowNow && todayAt >= localRef) || (!allowNow && todayAt > localRef)) return todayAt;
            return todayAt.addDays(1);

        } else if (freq == 'Weekly') {
            Set<Integer> wanted = toWeekdaySet(m.Schedule_Week_Days__c);
            if (wanted.isEmpty()) return newLocalDateTime(localRef.date().addDays(7), t);

            Integer todayIdx = weekdayIndexFromDate(localRef.date()); // 1..7 Mon..Sun
            Datetime todayAt = newLocalDateTime(localRef.date(), t);
            if (wanted.contains(todayIdx)) {
                if ((allowNow && todayAt >= localRef) || (!allowNow && todayAt > localRef)) return todayAt;
            }
            for (Integer d = 1; d <= 7; d++) {
                Integer idx = imod(todayIdx + d - 1, 7) + 1;
                if (wanted.contains(idx)) {
                    return newLocalDateTime(localRef.date().addDays(d), t);
                }
            }
            return newLocalDateTime(localRef.date().addDays(7), t);

        } else { // Monthly
            String modeNorm = normalizeMonthlyMode(m.Schedule_Month_Mode__c);
            if (modeNorm == 'nthweekday') {
                Integer nth = nthIndex(m.Schedule_Month_Nth__c);
                Integer wd  = weekdayIndexByLabel(m.Schedule_Month_Weekday__c);
                if (nth == null || wd == null) return newLocalDateTime(localRef.date().addMonths(1), t);
                Date candDate = nthWeekday(localRef.date().year(), localRef.date().month(), nth, wd);
                Datetime cand = newLocalDateTime(candDate, t);
                if ((allowNow && cand >= localRef) || (!allowNow && cand > localRef)) return cand;
                Date nextMonth = localRef.date().addMonths(1);
                return newLocalDateTime(nthWeekday(nextMonth.year(), nextMonth.month(), nth, wd), t);
            } else { // DayOfMonth
                Integer dom = (m.Schedule_Month_Day__c == null ? 1 : Math.max(1, Math.min(31, Integer.valueOf(m.Schedule_Month_Day__c))));
                Date candDate = clampDay(localRef.date().year(), localRef.date().month(), dom);
                Datetime cand = newLocalDateTime(candDate, t);
                if ((allowNow && cand >= localRef) || (!allowNow && cand > localRef)) return cand;
                Date nm = localRef.date().addMonths(1);
                return newLocalDateTime(clampDay(nm.year(), nm.month(), dom), t);
            }
        }
    }

    // ---------- TZ & DST (SA/VIC have DST; QLD no DST) ----------

    private static String normalizeTzKey(String tzKey) {
        if (String.isBlank(tzKey)) return 'VIC';
        String t = tzKey.trim().toUpperCase();
        if (t == 'SA' || t == 'VIC' || t == 'QLD') return t;
        return 'VIC';
    }

    private static Decimal tzOffsetHours(String tzKey, Datetime nowUtc) {
        tzKey = normalizeTzKey(tzKey);
        Decimal base = baseOffset(tzKey);
        Datetime approxLocal = nowUtc.addSeconds(Integer.valueOf(Math.round(base * 3600)));
        Boolean dst = isDst(tzKey, approxLocal.date());
        return base + (dst ? 1 : 0);
    }
    private static Decimal tzOffsetHoursForLocal(String tzKey, Datetime localDt) {
        tzKey = normalizeTzKey(tzKey);
        Decimal base = baseOffset(tzKey);
        Boolean dst = isDst(tzKey, localDt.date());
        return base + (dst ? 1 : 0);
    }
    private static Decimal baseOffset(String tzKey) {
        if ('SA'.equalsIgnoreCase(tzKey))  return 9.5;
        if ('VIC'.equalsIgnoreCase(tzKey)) return 10.0;
        if ('QLD'.equalsIgnoreCase(tzKey)) return 10.0;
        return 10.0;
    }

    /** AUS DST: first Sunday in Oct → first Sunday in Apr (inclusive start, exclusive end). */
    private static Boolean isDst(String tzKey, Date localDate) {
        if ('QLD'.equalsIgnoreCase(tzKey)) return false;

        Integer y  = localDate.year();
        Integer m  = localDate.month();

        Date dstStart = firstSundayOfMonth(y, 10); // Oct
        Date dstEnd   = firstSundayOfMonth(y, 4);  // Apr

        if (m > 10) return true;                        // Nov–Dec
        if (m == 10) return dstStart.daysBetween(localDate) <= 0; // on/after Oct-start
        if (m < 4)  return true;                        // Jan–Mar
        if (m == 4) return localDate.daysBetween(dstEnd) > 0;     // before Apr-end
        return false;                                   // May–Sep
    }

    private static Date firstSundayOfMonth(Integer y, Integer m) {
        Date first = Date.newInstance(y, m, 1);
        Integer idx = weekdayIndexFromDate(first); // 1..7 Mon..Sun
        Integer fwd = imod(7 - idx + 1, 7);        // days to Sunday
        return first.addDays(fwd);
    }

    private static Date nthWeekday(Integer y, Integer m, Integer nth, Integer weekdayIdx) {
        if (nth == 5) { // last
            Date last = Date.newInstance(y, m, Date.daysInMonth(y, m));
            Integer idx = weekdayIndexFromDate(last);
            Integer back = imod(idx - weekdayIdx, 7);
            return last.addDays(-back);
        } else {
            Date first = Date.newInstance(y, m, 1);
            Integer idx = weekdayIndexFromDate(first);
            Integer fwd = imod(weekdayIdx - idx, 7);
            return first.addDays(fwd + (nth - 1) * 7);
        }
    }

    private static Date clampDay(Integer y, Integer m, Integer d) {
        return Date.newInstance(y, m, Math.min(Math.max(1, d), Date.daysInMonth(y, m)));
    }

    // ---------- Weekday helpers ----------

    /** 1..7 for Mon..Sun from a Date. */
    private static Integer weekdayIndexFromDate(Date d) {
        // 1900-01-01 was a Monday.
        Date mondayAnchor = Date.newInstance(1900, 1, 1);
        Integer dayDelta = mondayAnchor.daysBetween(d);
        return imod(dayDelta, 7) + 1;
    }
    private static Integer weekdayIndexByLabel(String label) {
        if (String.isBlank(label)) return null;
        String s = label.toLowerCase();
        if (s.startsWith('mon')) return 1;
        if (s.startsWith('tue')) return 2;
        if (s.startsWith('wed')) return 3;
        if (s.startsWith('thu')) return 4;
        if (s.startsWith('fri')) return 5;
        if (s.startsWith('sat')) return 6;
        if (s.startsWith('sun')) return 7;
        return null;
    }

    /** Multi-picklist "Mon;Tue;..." → Set<Integer> 1..7 */
    private static Set<Integer> toWeekdaySet(String mp) {
        Set<Integer> out = new Set<Integer>();
        if (String.isBlank(mp)) return out;
        for (String token : mp.split(';')) {
            Integer idx = weekdayIndexByLabel(token.trim());
            if (idx != null) out.add(idx);
        }
        return out;
    }

    /** First..Fourth -> 1..4, Last -> 5 */
    private static Integer nthIndex(String label) {
        if (String.isBlank(label)) return null;
        String s = label.toLowerCase();
        if (s.startsWith('first'))  return 1;
        if (s.startsWith('second')) return 2;
        if (s.startsWith('third'))  return 3;
        if (s.startsWith('fourth')) return 4;
        if (s.startsWith('last'))   return 5;
        return null;
    }

    // ---------- Utilities ----------

    /** Integer-safe modulo (no % operator risk). */
    private static Integer imod(Integer a, Integer b) {
        if (b == 0) return 0;
        Integer r = a - (a / b) * b;
        return (r < 0) ? r + b : r;
    }

    private static Datetime addHours(Datetime dt, Decimal hrs) {
        Integer s = Integer.valueOf(Math.round(hrs * 3600));
        return dt.addSeconds(s);
    }

    private static Datetime toMinutePrecision(Datetime dt) {
        if (dt == null) return null;
        return Datetime.newInstanceGmt(dt.yearGmt(), dt.monthGmt(), dt.dayGmt(), dt.hourGmt(), dt.minuteGmt(), 0);
    }

    // Constructs a timezone-agnostic local datetime value for scheduler arithmetic.
    private static Datetime newLocalDateTime(Date d, Time t) {
        return Datetime.newInstanceGmt(d, t);
    }

    public static Datetime toLocalTime(String tzKey, Datetime utc) {
        if (utc == null) return null;
        tzKey = normalizeTzKey(tzKey);
        Decimal off = tzOffsetHours(tzKey, utc);
        return addHours(utc, off);
    }

    public static Datetime toUtcTime(String tzKey, Datetime localDt) {
        if (localDt == null) return null;
        tzKey = normalizeTzKey(tzKey);
        Decimal off = tzOffsetHoursForLocal(tzKey, localDt);
        return addHours(localDt, -off);
    }

    private static String buildFireKey(Datetime localOccurrence, String tzKey) {
        return localOccurrence.format('yyyy-MM-dd\'T\'HH:mm') + '|' + tzKey;
    }

    public static String timezoneIdForKey(String tzKey) {
        String key = normalizeTzKey(tzKey);
        if (key == 'SA') return 'Australia/Adelaide';
        if (key == 'QLD') return 'Australia/Brisbane';
        return 'Australia/Melbourne';
    }

    private static String normalizeMonthlyMode(String v) {
        if (String.isBlank(v)) return 'dayofthemonth';
        String s = v.toLowerCase().replace(' ', '');
        if (s.contains('nthweekday')) return 'nthweekday';
        return 'dayofthemonth';
    }
}