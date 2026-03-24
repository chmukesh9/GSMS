public with sharing class SmsUtil {
    /** Normalize AU mobile to E.164. Conservative & tolerant. */
    public static String formatPhoneLandline(String phone) {
        if (String.isBlank(phone)) return null;
        String d = phone.replaceAll('[^0-9+]', '');
        if (d.startsWith('+61')) return d;
        if (d.startsWith('61'))  return '+' + d;
        if (d.startsWith('0'))   return '+61' + d.substring(1);
        if (d.startsWith('+'))   return d;
        return '+61' + d;
    }
    public static String formatPhone(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.replaceAll('[^0-9+]', ''); // keep digits/+ only

        // Explicit landline patterns (reject)
        if (s.startsWith('+612') || s.startsWith('+613') || s.startsWith('+617') || s.startsWith('+618') ||
            s.startsWith('02')   || s.startsWith('03')   || s.startsWith('07')   || s.startsWith('08')   ||
            s.startsWith('612')  || s.startsWith('613')  || s.startsWith('617')  || s.startsWith('618')) {
            return null;
        }

        // Valid AU mobile forms → normalize to +614xxxxxxxx
        // +614XXXXXXXX
        if (Pattern.matches('^\\+614\\d{8}$', s)) return s;
        // 614XXXXXXXX
        if (Pattern.matches('^614\\d{8}$', s))   return '+' + s;
        // 04XXXXXXXX
        if (Pattern.matches('^04\\d{8}$', s))    return '+61' + s.substring(1);
        // 4XXXXXXXX (common when leading 0 omitted)
        if (Pattern.matches('^4\\d{8}$', s))     return '+61' + s;

        // Everything else (incl. short 8-digit landlines like 67854785) → reject
        return null;
    }
    public static String firstName(String raw) {
        if (String.isBlank(raw)) return null;

        String s = raw.trim();

        // Normalize internal whitespace
        s = s.replaceAll('\\s+', ' ');

        // Remove leading honorifics/prefixes (case-insensitive, optional dots)
        // Add or adjust tokens here as needed for your org’s data
        // Note: (?i) = case-insensitive
        String honorifics = '(?i)^(mr|mrs|ms|miss|mx|mstr|mister|dr|prof|sir|madam|sri|shri|smt|fr|rev|capt|lt|col|gen)\\.?\\s+';
        // Remove multiple stacked prefixes if present (e.g., "Dr Prof John")
        while (s.replaceAll(honorifics, '') != s) {
            s = s.replaceAll(honorifics, '');
            s = s.trim();
        }

        if (s.length() == 0) return null;

        // Handle "Last, First Middle" → take token after first comma
        Integer comma = s.indexOf(',');
        if (comma >= 0 && comma < s.length() - 1) {
            String after = s.substring(comma + 1).trim();
            if (after.length() > 0) s = after;
        }

        // Return first word only
        Integer sp = s.indexOf(' ');
        String token = (sp > 0) ? s.substring(0, sp) : s;
        return toInitCap(token);
    }

    private static String toInitCap(String s) {
        if (String.isBlank(s)) return s;
        String lower = s.toLowerCase();
        return lower.substring(0, 1).toUpperCase() + lower.substring(1);
    }
}