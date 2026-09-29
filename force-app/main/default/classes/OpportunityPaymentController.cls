/**
 * OpportunityPaymentController
 *
 * Two jobs:
 *   1. Summarize the OpportunityLineItems on an Opportunity (count + total)
 *   2. Create a Stripe Checkout Session in "embedded" mode and return its client_secret,
 *      so the LWC can mount the payment UI inside its own modal instead of redirecting.
 *
 * Setup required before this works:
 *   - Named Credential called "Stripe_API" pointing to https://api.stripe.com,
 *     with the Stripe secret key stored as the auth (password/token) - never hardcode it here.
 *   - Remote Site Setting / CSP Trusted Site for https://js.stripe.com (for the LWC to load Stripe.js).
 */
public with sharing class OpportunityPaymentController {

    public class ProductSummary {
        @AuraEnabled public Integer productCount;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public List<LineItemWrapper> lineItems;
    }

    public class LineItemWrapper {
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal totalPrice;
    }

    @AuraEnabled(cacheable=true)
    public static ProductSummary getProductSummary(Id opportunityId) {
        List<OpportunityLineItem> items = [
            SELECT Id, Quantity, UnitPrice, TotalPrice, Product2Id, PricebookEntry.Product2.Name
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
        ];

        Decimal total = 0;
        List<LineItemWrapper> wrappers = new List<LineItemWrapper>();
        for (OpportunityLineItem oli : items) {
            total += oli.TotalPrice;
            LineItemWrapper w = new LineItemWrapper();
            w.productName = oli.PricebookEntry.Product2.Name;
            w.quantity = oli.Quantity;
            w.unitPrice = oli.UnitPrice;
            w.totalPrice = oli.TotalPrice;
            wrappers.add(w);
        }

        Opportunity opp = [
            SELECT CurrencyIsoCode__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        ProductSummary summary = new ProductSummary();
        summary.productCount = items.size();
        summary.totalAmount = total;
        summary.currencyCode = String.isBlank(opp.CurrencyIsoCode__c) ? 'USD' : opp.CurrencyIsoCode__c;
        summary.lineItems = wrappers;
        return summary;
    }

    @AuraEnabled
public static String createCheckoutSession(Id opportunityId) {
    List<OpportunityLineItem> items = [
        SELECT Id, Quantity, UnitPrice, PricebookEntry.Product2.Name
        FROM OpportunityLineItem
        WHERE OpportunityId = :opportunityId
    ];

    if (items.isEmpty()) {
        throw new AuraHandledException('This opportunity has no products to pay for.');
    }

    Opportunity opp = [
        SELECT CurrencyIsoCode__c
        FROM Opportunity
        WHERE Id = :opportunityId
        WITH SECURITY_ENFORCED
        LIMIT 1
    ];
    String currencyString = String.isBlank(opp.CurrencyIsoCode__c) ? 'usd' : opp.CurrencyIsoCode__c.toLowerCase();

    String body = 'mode=payment'
        + '&ui_mode=embedded'
        + '&redirect_on_completion=never'
        + '&client_reference_id=' + opportunityId
        + '&metadata[opportunity_id]=' + opportunityId
        + '&payment_intent_data[metadata][opportunity_id]=' + opportunityId;

    Integer idx = 0;
    for (OpportunityLineItem oli : items) {
        Long unitAmount = (oli.UnitPrice * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();
        Integer quantity = Integer.valueOf(oli.Quantity);

        body += '&line_items[' + idx + '][price_data][currency]=' + currencyString;
        body += '&line_items[' + idx + '][price_data][product_data][name]='
            + EncodingUtil.urlEncode(oli.PricebookEntry.Product2.Name, 'UTF-8');
        body += '&line_items[' + idx + '][price_data][product_data][metadata][opportunity_line_item_id]=' + oli.Id;
        body += '&line_items[' + idx + '][price_data][unit_amount]=' + unitAmount;
        body += '&line_items[' + idx + '][quantity]=' + quantity;
        idx++;
    }

    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:Stripe_API/v1/checkout/sessions');
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
    req.setBody(body);
    req.setTimeout(20000);

    HttpResponse res = new Http().send(req);

    if (res.getStatusCode() != 200) {
        throw new AuraHandledException('Stripe error: ' + res.getBody());
    }

    Map<String, Object> resMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    return (String) resMap.get('client_secret');
}
}