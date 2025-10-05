public with sharing class AF_DPSDataService {
    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class DpsOpportunity {
        @AuraEnabled public String productType;
        @AuraEnabled public String product;
        @AuraEnabled public Date enrollDate;
        @AuraEnabled public Date expDate;
        @AuraEnabled public Boolean enrolled; // true if not expired
    }

    public class FiSectionRow {
        @AuraEnabled public String label;
        @AuraEnabled public List<String> values; // 12 months values, stringified for display
    }

    public class DpsDataResponse {
        @AuraEnabled public Account account;
        @AuraEnabled public Boolean showSA;
        @AuraEnabled public Boolean showDPS;
        @AuraEnabled public Boolean showBAC;

        @AuraEnabled public List<Option> bacOptions;
        @AuraEnabled public String selectedBAC;

        @AuraEnabled public Account__x dpsAccount; // acx in VF
        @AuraEnabled public List<DpsOpportunity> opportunities;
        @AuraEnabled public List<Contact__x> contacts;

        @AuraEnabled public List<String> monthLabels; // firstMonth..twelvthMonth
        @AuraEnabled public List<FiSectionRow> fiSections; // simplified sections

        @AuraEnabled public String userEmployeeNumber; // usr.EmployeeNumber
        @AuraEnabled public Long smartAuctionId; // ac.Smart_Auction_Id__c
    }

    @AuraEnabled(cacheable=true)
    public static DpsDataResponse getInitialData(Id recordId) {
        DpsDataResponse resp = new DpsDataResponse();

        Account ac = [SELECT Id, Ally_Primary_Dealer_Number__c, Name, Smart_Auction_Id__c, DPS_SF_ID__c FROM Account WHERE Id = :recordId LIMIT 1];
        resp.account = ac;
        resp.smartAuctionId = (ac.Smart_Auction_Id__c == null) ? null : Long.valueOf(String.valueOf(ac.Smart_Auction_Id__c));
        resp.showSA = ac.Smart_Auction_Id__c != null;
        resp.showDPS = ac.DPS_SF_ID__c != null;

        // Determine BAC list and selected BAC value
        List<String> dpsIds = new List<String>();
        if (ac.DPS_SF_ID__c != null && ac.DPS_SF_ID__c.contains('-')) {
            dpsIds = ac.DPS_SF_ID__c.split('-');
        }
        resp.showBAC = !dpsIds.isEmpty();

        if (resp.showBAC) {
            List<Account__x> dpsAccounts = [
                SELECT Id, BACCode_c__c, Makes_c__c, F_I_Relationship_c__c
                FROM Account__x
                WHERE Id IN :dpsIds
                ORDER BY LastModifiedDate__c DESC
            ];
            resp.bacOptions = new List<Option>();
            for (Account__x a : dpsAccounts) {
                Option opt = new Option();
                opt.value = a.BACCode_c__c;
                opt.label = a.BACCode_c__c + ' - ' + (a.Makes_c__c == null ? 'No Make' : a.Makes_c__c);
                resp.bacOptions.add(opt);
            }
            if (!dpsAccounts.isEmpty()) {
                resp.selectedBAC = dpsAccounts[0].BACCode_c__c;
            }
        }

        // Load dependent data using selected BAC or DPS id
        loadDpsDependentData(resp, ac, resp.selectedBAC);

        // Current user info
        User u = [SELECT EmployeeNumber FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        resp.userEmployeeNumber = u.EmployeeNumber;

        return resp;
    }

    @AuraEnabled(cacheable=true)
    public static DpsDataResponse getDataForBac(Id recordId, String selectedBAC) {
        DpsDataResponse resp = new DpsDataResponse();
        Account ac = [SELECT Id, Ally_Primary_Dealer_Number__c, Name, Smart_Auction_Id__c, DPS_SF_ID__c FROM Account WHERE Id = :recordId LIMIT 1];
        resp.account = ac;
        resp.smartAuctionId = (ac.Smart_Auction_Id__c == null) ? null : Long.valueOf(String.valueOf(ac.Smart_Auction_Id__c));
        resp.showSA = ac.Smart_Auction_Id__c != null;
        resp.showDPS = ac.DPS_SF_ID__c != null;

        // BAC Options if multiple
        List<String> dpsIds = new List<String>();
        if (ac.DPS_SF_ID__c != null && ac.DPS_SF_ID__c.contains('-')) {
            dpsIds = ac.DPS_SF_ID__c.split('-');
        }
        resp.showBAC = !dpsIds.isEmpty();
        resp.selectedBAC = selectedBAC;
        if (resp.showBAC) {
            List<Account__x> dpsAccounts = [
                SELECT Id, BACCode_c__c, Makes_c__c
                FROM Account__x
                WHERE Id IN :dpsIds
                ORDER BY LastModifiedDate__c DESC
            ];
            resp.bacOptions = new List<Option>();
            for (Account__x a : dpsAccounts) {
                Option opt = new Option();
                opt.value = a.BACCode_c__c;
                opt.label = a.BACCode_c__c + ' - ' + (a.Makes_c__c == null ? 'No Make' : a.Makes_c__c);
                resp.bacOptions.add(opt);
            }
        }

        loadDpsDependentData(resp, ac, selectedBAC);

        User u = [SELECT EmployeeNumber FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        resp.userEmployeeNumber = u.EmployeeNumber;

        return resp;
    }

    private static void loadDpsDependentData(DpsDataResponse resp, Account ac, String selectedBAC) {
        String dpsAccountId = ac.DPS_SF_ID__c;
        Boolean useBac = (selectedBAC != null && selectedBAC != '');

        // DPS Account (Account__x)
        try {
            String soql = 'SELECT Id, F_I_Relationship_c__c, BACCode_c__c, Makes_c__c FROM Account__x';
            if (useBac) {
                soql += ' WHERE BACCode_c__c = :selectedBAC LIMIT 1';
                resp.dpsAccount = Database.query(soql);
            } else if (dpsAccountId != null) {
                soql += ' WHERE Id = :dpsAccountId LIMIT 1';
                resp.dpsAccount = Database.query(soql);
            }
        } catch (Exception e) {
            resp.dpsAccount = null;
        }

        // Opportunities (Opportunity__x)
        List<Opportunity__x> opx;
        {
            String base = 'SELECT Id, Product_Type_c__c, AccountId__r.BACCode_c__c, Product_c__c, CloseDate__c, ProductExpirationDate_c__c '
                + 'FROM Opportunity__x WHERE StageName__c = \'' + 'Product Enrollment/Sale' + '\'';
            if (useBac) {
                base += ' AND AccountId__r.BACCode_c__c = :selectedBAC';
            } else if (dpsAccountId != null) {
                base += ' AND AccountId__c = :dpsAccountId';
            }
            opx = Database.query(base);
        }
        List<DpsOpportunity> oppDtos = new List<DpsOpportunity>();
        Date today = Date.today();
        // First add active/not expired
        for (Opportunity__x o : opx) {
            Boolean active = (o.ProductExpirationDate_c__c == null || o.ProductExpirationDate_c__c > today);
            if (active) {
                oppDtos.add(toDto(o, active));
            }
        }
        // Then add expired
        for (Opportunity__x o : opx) {
            Boolean active = (o.ProductExpirationDate_c__c == null || o.ProductExpirationDate_c__c > today);
            if (!active) {
                oppDtos.add(toDto(o, active));
            }
        }
        resp.opportunities = oppDtos;

        // Contacts (Contact__x)
        {
            String base = 'SELECT Id, Name__c, Title__c, AccountId__r.BACCode_c__c, Contact_Title_c__c, Email__c, Phone__c FROM Contact__x';
            if (useBac) {
                base += ' WHERE AccountId__r.BACCode_c__c = :selectedBAC';
            } else if (dpsAccountId != null) {
                base += ' WHERE AccountId__c = :dpsAccountId';
            }
            resp.contacts = Database.query(base);
        }

        // Coaching Report (Coaching_Report_c__x) and FI sections
        List<Coaching_Report_c__x> reports;
        {
            String base = 'SELECT '
                + 'X1st_Month_c__c, X1st_Year_c__c, X2nd_Month_c__c, X2nd_Year_c__c, X3rd_Month_c__c, X3rd_Year_c__c, '
                + 'X4th_Month_c__c, X4th_Year_c__c, X5th_Month_c__c, X5th_Year_c__c, X6th_Month_c__c, X6th_Year_c__c, '
                + 'X7th_Month_c__c, X7th_Year_c__c, X8th_Month_c__c, X8th_Year_c__c, X9th_Month_c__c, X9th_Year_c__c, '
                + 'X10th_Month_c__c, X10th_Year_c__c, X11th_Month_c__c, X11th_Year_c__c, X12th_Month_c__c, X12th_Year_c__c, '
                + 'New_Adj_RVS_1st_c__c, New_Adj_RVS_2nd_c__c, New_Adj_RVS_3rd_c__c, New_Adj_RVS_4th_c__c, New_Adj_RVS_5th_c__c, New_Adj_RVS_6th_c__c, '
                + 'New_Adj_RVS_7th_c__c, New_Adj_RVS_8th_c__c, New_Adj_RVS_9th_c__c, New_Adj_RVS_10th_c__c, New_Adj_RVS_11th_c__c, New_Adj_RVS_12th_c__c, '
                + 'Total_CM_1st_c__c, Total_CM_2nd_c__c, Total_CM_3rd_c__c, Total_CM_4th_c__c, Total_CM_5th_c__c, Total_CM_6th_c__c, '
                + 'Total_CM_7th_c__c, Total_CM_8th_c__c, Total_CM_9th_c__c, Total_CM_10th_c__c, Total_CM_11th_c__c, Total_CM_12th_c__c, '
                + 'Total_Revenue_1st_c__c, Total_Revenue_2nd_c__c, Total_Revenue_3rd_c__c, Total_Revenue_4th_c__c, Total_Revenue_5th_c__c, Total_Revenue_6th_c__c, '
                + 'Total_Revenue_7th_c__c, Total_Revenue_8th_c__c, Total_Revenue_9th_c__c, Total_Revenue_10th_c__c, Total_Revenue_11th_c__c, Total_Revenue_12th_c__c '
                + 'FROM Coaching_Report_c__x';
            if (useBac) {
                base += ' WHERE Account_c__r.BACCode_c__c = :selectedBAC ORDER BY LastModifiedDate__c DESC LIMIT 1';
            } else if (dpsAccountId != null) {
                base += ' WHERE Account_c__c = :dpsAccountId ORDER BY LastModifiedDate__c DESC LIMIT 1';
            } else {
                base += ' ORDER BY LastModifiedDate__c DESC LIMIT 1';
            }
            reports = Database.query(base);
        }

        if (!reports.isEmpty()) {
            Coaching_Report_c__x cr = reports[0];
            resp.monthLabels = buildMonthLabels(cr);
            resp.fiSections = new List<FiSectionRow>();
            resp.fiSections.add(buildNumberSection('Adjusted RVS Net of Ally Leases', new Decimal[]{
                cr.New_Adj_RVS_1st_c__c, cr.New_Adj_RVS_2nd_c__c, cr.New_Adj_RVS_3rd_c__c, cr.New_Adj_RVS_4th_c__c, cr.New_Adj_RVS_5th_c__c, cr.New_Adj_RVS_6th_c__c,
                cr.New_Adj_RVS_7th_c__c, cr.New_Adj_RVS_8th_c__c, cr.New_Adj_RVS_9th_c__c, cr.New_Adj_RVS_10th_c__c, cr.New_Adj_RVS_11th_c__c, cr.New_Adj_RVS_12th_c__c
            }));
            resp.fiSections.add(buildNumberSection('Total CM$', new Decimal[]{
                cr.Total_CM_1st_c__c, cr.Total_CM_2nd_c__c, cr.Total_CM_3rd_c__c, cr.Total_CM_4th_c__c, cr.Total_CM_5th_c__c, cr.Total_CM_6th_c__c,
                cr.Total_CM_7th_c__c, cr.Total_CM_8th_c__c, cr.Total_CM_9th_c__c, cr.Total_CM_10th_c__c, cr.Total_CM_11th_c__c, cr.Total_CM_12th_c__c
            }));
            resp.fiSections.add(buildNumberSection('Total Revenue', new Decimal[]{
                cr.Total_Revenue_1st_c__c, cr.Total_Revenue_2nd_c__c, cr.Total_Revenue_3rd_c__c, cr.Total_Revenue_4th_c__c, cr.Total_Revenue_5th_c__c, cr.Total_Revenue_6th_c__c,
                cr.Total_Revenue_7th_c__c, cr.Total_Revenue_8th_c__c, cr.Total_Revenue_9th_c__c, cr.Total_Revenue_10th_c__c, cr.Total_Revenue_11th_c__c, cr.Total_Revenue_12th_c__c
            }));
        } else {
            // Default last 12 months labels if no report
            resp.monthLabels = buildFallbackMonthLabels();
            resp.fiSections = new List<FiSectionRow>();
        }

        // Append PVR Goal/Current and 360 Data Entry Date from Dealer_Forms_c__x
        appendDealerFormsRows(resp, ac, selectedBAC);
    }

    private static DpsOpportunity toDto(Opportunity__x o, Boolean active) {
        DpsOpportunity dto = new DpsOpportunity();
        dto.productType = o.Product_Type_c__c;
        dto.product = o.Product_c__c;
        dto.enrollDate = o.CloseDate__c;
        dto.expDate = o.ProductExpirationDate_c__c;
        dto.enrolled = active;
        return dto;
    }

    private static List<String> buildMonthLabels(Coaching_Report_c__x cr) {
        List<String> labels = new List<String>();
        labels.add(cr.X1st_Month_c__c != null && cr.X1st_Year_c__c != null ? cr.X1st_Month_c__c.substring(0, 3) + '-' + cr.X1st_Year_c__c : null);
        labels.add(cr.X2nd_Month_c__c != null && cr.X2nd_Year_c__c != null ? cr.X2nd_Month_c__c.substring(0, 3) + '-' + cr.X2nd_Year_c__c : null);
        labels.add(cr.X3rd_Month_c__c != null && cr.X3rd_Year_c__c != null ? cr.X3rd_Month_c__c.substring(0, 3) + '-' + cr.X3rd_Year_c__c : null);
        labels.add(cr.X4th_Month_c__c != null && cr.X4th_Year_c__c != null ? cr.X4th_Month_c__c.substring(0, 3) + '-' + cr.X4th_Year_c__c : null);
        labels.add(cr.X5th_Month_c__c != null && cr.X5th_Year_c__c != null ? cr.X5th_Month_c__c.substring(0, 3) + '-' + cr.X5th_Year_c__c : null);
        labels.add(cr.X6th_Month_c__c != null && cr.X6th_Year_c__c != null ? cr.X6th_Month_c__c.substring(0, 3) + '-' + cr.X6th_Year_c__c : null);
        labels.add(cr.X7th_Month_c__c != null && cr.X7th_Year_c__c != null ? cr.X7th_Month_c__c.substring(0, 3) + '-' + cr.X7th_Year_c__c : null);
        labels.add(cr.X8th_Month_c__c != null && cr.X8th_Year_c__c != null ? cr.X8th_Month_c__c.substring(0, 3) + '-' + cr.X8th_Year_c__c : null);
        labels.add(cr.X9th_Month_c__c != null && cr.X9th_Year_c__c != null ? cr.X9th_Month_c__c.substring(0, 3) + '-' + cr.X9th_Year_c__c : null);
        labels.add(cr.X10th_Month_c__c != null && cr.X10th_Year_c__c != null ? cr.X10th_Month_c__c.substring(0, 3) + '-' + cr.X10th_Year_c__c : null);
        labels.add(cr.X11th_Month_c__c != null && cr.X11th_Year_c__c != null ? cr.X11th_Month_c__c.substring(0, 3) + '-' + cr.X11th_Year_c__c : null);
        labels.add(cr.X12th_Month_c__c != null && cr.X12th_Year_c__c != null ? cr.X12th_Month_c__c.substring(0, 3) + '-' + cr.X12th_Year_c__c : null);
        return labels;
    }

    private static List<String> buildFallbackMonthLabels() {
        // Last 12 months from today
        List<String> months = new List<String>();
        Date today = Date.today();
        List<String> monthNames = new List<String>{'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};
        for (Integer i = 12; i >= 1; i--) {
            Date d = today.addMonths(-i);
            months.add(monthNames[d.month()-1] + '-' + d.year());
        }
        return months;
    }

    private static FiSectionRow buildNumberSection(String label, List<Decimal> values) {
        FiSectionRow row = new FiSectionRow();
        row.label = label;
        row.values = new List<String>();
        if (values != null) {
            for (Decimal d : values) {
                row.values.add(d == null ? null : String.valueOf(d));
            }
        }
        return row;
    }

    private static FiSectionRow buildStringSection(String label, List<String> values) {
        FiSectionRow row = new FiSectionRow();
        row.label = label;
        row.values = values;
        return row;
    }

    private static void appendDealerFormsRows(DpsDataResponse resp, Account ac, String selectedBAC) {
        // Ensure month labels exist
        if (resp.monthLabels == null || resp.monthLabels.isEmpty()) {
            resp.monthLabels = buildFallbackMonthLabels();
        }
        Map<String, Integer> labelIndexByKey = new Map<String, Integer>();
        for (Integer i = 0; i < resp.monthLabels.size(); i++) {
            String key = resp.monthLabels[i];
            if (key != null) labelIndexByKey.put(key, i);
        }

        String dpsAccountId = ac.DPS_SF_ID__c;
        Boolean useBac = (selectedBAC != null && selectedBAC != '');
        String recordTypeId = System.Label.DPS_360_Data_Entry_RecordType_Id;

        List<Dealer_Forms_c__x> forms;
        {
            String base = 'SELECT Id, Date_c__c, PVR_Goal_DD_c__c, PVR_Current_c__c, Account_Name_c__r.BACCode_c__c, Account_Name_c__c '
                + 'FROM Dealer_Forms_c__x WHERE RecordTypeId__c = :recordTypeId';
            if (useBac) {
                base += ' AND Account_Name_c__r.BACCode_c__c = :selectedBAC';
            } else if (dpsAccountId != null) {
                base += ' AND Account_Name_c__c = :dpsAccountId';
            }
            forms = Database.query(base);
        }

        List<String> monthNames = new List<String>{'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};
        List<String> pvrGoal = new List<String>();
        List<String> pvrCurrent = new List<String>();
        List<String> entryDates = new List<String>();
        for (Integer i = 0; i < 12; i++) {
            pvrGoal.add(null);
            pvrCurrent.add(null);
            entryDates.add(null);
        }

        for (Dealer_Forms_c__x f : forms) {
            if (f.Date_c__c == null) continue;
            Date d = f.Date_c__c;
            Date labelDate;
            // January logic in VF: use previous month for label alignment
            if (d.month() == 1) {
                labelDate = d.addMonths(-1);
            } else {
                // Use the previous month label per VF mapping
                labelDate = Date.newInstance(d.year(), d.month(), Math.min(d.day(), 28)).addMonths(-1);
            }
            String key = monthNames[labelDate.month()-1] + '-' + String.valueOf(labelDate.year());
            if (!labelIndexByKey.containsKey(key)) continue;
            Integer idx = labelIndexByKey.get(key);
            if (idx == null || idx < 0 || idx >= 12) continue;
            if (pvrGoal[idx] == null && f.PVR_Goal_DD_c__c != null) pvrGoal[idx] = String.valueOf(f.PVR_Goal_DD_c__c);
            if (pvrCurrent[idx] == null && f.PVR_Current_c__c != null) pvrCurrent[idx] = String.valueOf(f.PVR_Current_c__c);
            if (entryDates[idx] == null) entryDates[idx] = String.valueOf(d); // yyyy-MM-dd
        }

        resp.fiSections.add(buildStringSection('PVR Goal $', pvrGoal));
        resp.fiSections.add(buildStringSection('PVR Current', pvrCurrent));
        resp.fiSections.add(buildStringSection('360 Data Entry Date', entryDates));
    }
}
