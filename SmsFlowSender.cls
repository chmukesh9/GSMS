public with sharing class SmsFlowSender {
    @TestVisible static List<Id> sentRecipientIdsTest = new List<Id>();
    @TestVisible static List<String> sentBodiesTest = new List<String>();

    /** Instant send via your Autolaunched Flow 'MCC_Test_SMS'.
     *  Flow inputs (single value each):
     *    - varRecipientIds : Id (MessagingEndUser)
     *    - varVariablesJson: String
     */
    public static void sendOne(Id messagingEndUserId, String messageText) {
        if (messagingEndUserId == null || String.isBlank(messageText)) return;
        System.debug('Starting MCC_Test_SMS flow: recipient=' + messagingEndUserId + ', len=' + messageText.length());

        if (Test.isRunningTest()) {
            // Don’t start the Flow in tests; just capture payload
            sentRecipientIdsTest.add(messagingEndUserId);
            sentBodiesTest.add(messageText);
            return;
        }
        sendMany(new List<Id>{ messagingEndUserId }, messageText);
        System.debug('Ending MCC_Test_SMS flow: recipient=' + messagingEndUserId + ', len=' + messageText.length());
    }

    /** Bulk send for many recipients with same rendered message body. */
    public static void sendMany(List<Id> messagingEndUserIds, String messageText) {
        if (messagingEndUserIds == null || messagingEndUserIds.isEmpty() || String.isBlank(messageText)) return;

        List<Id> cleanIds = new List<Id>();
        List<String> recipientStrings = new List<String>();
        for (Id rid : messagingEndUserIds) {
            if (rid == null) continue;
            cleanIds.add(rid);
            recipientStrings.add(String.valueOf(rid));
        }
        if (recipientStrings.isEmpty()) return;

        if (Test.isRunningTest()) {
            for (Id rid : cleanIds) {
                sentRecipientIdsTest.add(rid);
                sentBodiesTest.add(messageText);
            }
            return;
        }

        Map<String,Object> inputs = new Map<String,Object>{
            'varRecipientIds' => recipientStrings,
            'varVariablesJson' => messageText
        };
        if (!recipientStrings.isEmpty()) inputs.put('varRecipientId', recipientStrings[0]);

        Flow.Interview.MCC_Test_SMS f = new Flow.Interview.MCC_Test_SMS(inputs);
        f.start();
    }
}