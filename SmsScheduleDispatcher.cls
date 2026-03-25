public with sharing class SmsScheduleDispatcher implements Schedulable {

    public void execute(SchedulableContext sc) {
        Datetime nowUtc = System.now();

        List<derive_sms_condition_master__c> masters = [
            SELECT Id, Name, Active__c, Object_API__c,
                   Trigger_Type__c,
                   Schedule_Time__c, Schedule_TZ__c,
                   Schedule_Frequency__c, Schedule_Week_Days__c,
                   Schedule_Month_Mode__c, Schedule_Month_Day__c,
                   Schedule_Month_Nth__c, Schedule_Month_Weekday__c,
                   Next_Run__c, Last_Run__c, Last_Fire_Key__c,
                   Template__c,
                   phone_1_source__c, phone_1_object__c, phone_1_field__c,
                   phone_2_source__c, phone_2_object__c, phone_2_field__c,
                   phone_3_source__c, phone_3_object__c, phone_3_field__c
            FROM derive_sms_condition_master__c
            WHERE Active__c = true
              AND Trigger_Type__c = 'Scheduled'
            LIMIT 1000
        ];

        if (masters.isEmpty()) return;

        List<derive_sms_condition_master__c> toSeedNextRun = new List<derive_sms_condition_master__c>();
        List<SmsScheduleBatch> batchesToRun = new List<SmsScheduleBatch>();

        for (derive_sms_condition_master__c m : masters) {
            try {
                SmsScheduleService.DueCheck dc = SmsScheduleService.isDueNow(m, nowUtc);
                if (dc == null) continue;

                // Seed Next_Run__c as soon as it is missing so later scheduler ticks can rely on it.
                if (m.Next_Run__c == null && dc.occurUtc != null) {
                    String tzId = SmsScheduleService.timezoneIdForKey(m.Schedule_TZ__c);
                    toSeedNextRun.add(new derive_sms_condition_master__c(
                        Id = m.Id,
                        Next_Run__c = dc.occurUtc,
                        Next_Run_local__c = dc.occurUtc.format('d/M/yyyy, h:mm a', tzId).toLowerCase()
                    ));
                }

                if (dc.due) {
                    batchesToRun.add(new SmsScheduleBatch(m.Id, dc.fireKey, dc.nextUtc));
                }
            } catch (Exception ex) {
                SmsErrorLogger.log(
                    SmsErrorLogger.Severity.Error,
                    SmsErrorLogger.Source.ScheduleBatch,
                    'Scheduled',
                    null,
                    m.Id,
                    null,
                    m.Template__c,
                    null,
                    m.Object_API__c,
                    null,
                    ex,
                    new Map<String,Object>{ 'phase' => 'dispatcher-loop', 'masterName' => m.Name }
                );
            }
        }

        if (!toSeedNextRun.isEmpty()) {
            try {
                Database.update(toSeedNextRun, false);
            } catch (Exception ex) {
                SmsErrorLogger.log(
                    SmsErrorLogger.Severity.Error,
                    SmsErrorLogger.Source.ScheduleBatch,
                    'Scheduled',
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    ex,
                    new Map<String,Object>{ 'phase' => 'dispatcher-seed-next-run' }
                );
            }
        }

        for (SmsScheduleBatch b : batchesToRun) {
            try {
                Database.executeBatch(b, 20);
            } catch (Exception ex) {
                SmsErrorLogger.log(
                    SmsErrorLogger.Severity.Error,
                    SmsErrorLogger.Source.ScheduleBatch,
                    'Scheduled',
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    ex,
                    new Map<String,Object>{ 'phase' => 'dispatcher-execute-batch' }
                );
            }
        }
    }

    public static void installOrUpdateCron() {
        for (CronTrigger ct : [
            SELECT Id, CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name = 'SmsScheduleDispatcher_Every5'
        ]) {
            System.abortJob(ct.Id);
        }
        // Every 5 minutes
        System.schedule('SmsScheduleDispatcher_Every5', '0 5 * * * ?', new SmsScheduleDispatcher());
    }
}