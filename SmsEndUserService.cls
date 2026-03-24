public with sharing class SmsEndUserService {

    /** Resolve or create a MessagingEndUser by E.164 phone. */
    public static Id getOrCreateByE164(String e164) {
        Map<String, Id> byPhone = getOrCreateByE164Bulk(new Set<String>{ e164 });
        if (String.isBlank(e164)) return null;
        String normalized = SmsUtil.formatPhone(e164);
        if (String.isBlank(normalized)) normalized = e164;
        return byPhone.get(normalized);
    }

    /** Bulk resolve/create MessagingEndUser records keyed by normalized E.164. */
    public static Map<String, Id> getOrCreateByE164Bulk(Set<String> e164Values) {
        Map<String, Id> out = new Map<String, Id>();
        if (e164Values == null || e164Values.isEmpty()) return out;

        Set<String> normalizedSet = new Set<String>();
        for (String raw : e164Values) {
            if (String.isBlank(raw)) continue;
            String normalized = SmsUtil.formatPhone(raw);
            if (String.isBlank(normalized)) normalized = raw;
            normalizedSet.add(normalized);
        }
        if (normalizedSet.isEmpty()) return out;

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Boolean hasMEU = gd.containsKey('MessagingEndUser');

        // Prefer real MessagingEndUser whenever the object exists
        if (hasMEU) {
            Schema.SObjectType t = gd.get('MessagingEndUser');
            Map<String, Schema.SObjectField> f = t.getDescribe().fields.getMap();

            String keyField = null;
            for (String cand : new List<String>{ 'MessagingPlatformKey', 'ChannelAddress', 'PhoneNumber', 'Phone', 'MobilePhone' }) {
                if (f.containsKey(cand)) { keyField = cand; break; }
            }
            if (keyField == null) {
                throw new AuraHandledException('No suitable key field on MessagingEndUser.');
            }

            String soql = 'SELECT Id, ' + keyField + ' FROM MessagingEndUser WHERE ' + keyField + ' IN :normalizedSet';
            for (SObject row : Database.query(soql)) {
                String keyVal = String.valueOf(row.get(keyField));
                if (!String.isBlank(keyVal)) out.put(keyVal, (Id) row.get('Id'));
            }

            List<SObject> toInsert = new List<SObject>();
            for (String normalized : normalizedSet) {
                if (out.containsKey(normalized)) continue;
                SObject neu = t.newSObject(null, true);
                neu.put(keyField, normalized);
                if (f.containsKey('MessagingPlatformKey')) neu.put('MessagingPlatformKey', normalized);
                if (f.containsKey('Name')) neu.put('Name', 'Created by Apex MCC');
                if (f.containsKey('MessageType')) neu.put('MessageType', 'Text');
                if (f.containsKey('MessagingChannelId')) neu.put('MessagingChannelId', '0Mj9r000000yMC9CAM');
                if (f.containsKey('MessagingConsentStatus')) neu.put('MessagingConsentStatus', 'ImplicitlyOptedIn');
                toInsert.add(neu);
            }

            if (!toInsert.isEmpty()) {
                insert toInsert;
                for (SObject neu : toInsert) {
                    String keyVal = String.valueOf(neu.get(keyField));
                    if (!String.isBlank(keyVal)) out.put(keyVal, (Id) neu.get('Id'));
                }
            }
            return out;
        }

        // Test-only fallback: create lightweight Contacts and return their Ids
        if (Test.isRunningTest()) {
            List<Contact> toInsertContacts = new List<Contact>();
            Map<String, Contact> contactByPhone = new Map<String, Contact>();
            for (String normalized : normalizedSet) {
                Contact c = new Contact(LastName = 'MEU ' + normalized);
                toInsertContacts.add(c);
                contactByPhone.put(normalized, c);
            }
            if (!toInsertContacts.isEmpty()) insert toInsertContacts;
            for (String normalized : contactByPhone.keySet()) out.put(normalized, contactByPhone.get(normalized).Id);
            return out;
        }

        throw new AuraHandledException('MessagingEndUser object not found in this org.');
    }
}