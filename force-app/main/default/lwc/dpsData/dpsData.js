import { LightningElement, api, track } from 'lwc';
import getInitialData from '@salesforce/apex/AF_DPSDataService.getInitialData';
import getDataForBac from '@salesforce/apex/AF_DPSDataService.getDataForBac';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import AF_DealerScorecard_Page from '@salesforce/label/c.AF_DealerScorecard_Page';
import AF_DealerSummary_Page from '@salesforce/label/c.AF_DealerSummary_Page';

export default class DpsData extends LightningElement {
    @api recordId;
    @track data;
    @track selectedBAC;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            const resp = await getInitialData({ recordId: this.recordId });
            this.data = resp;
            this.selectedBAC = resp.selectedBAC;
        } catch (e) {
            this.notify('Error', e?.body?.message || e.message, 'error');
        }
    }

    get bacOptions() {
        return (this.data?.bacOptions || []).map(o => ({ label: o.label, value: o.value }));
    }

    get monthLabels() {
        return this.data?.monthLabels || [];
    }

    get fiSections() {
        return this.data?.fiSections || [];
    }

    get contacts() {
        return this.data?.contacts || [];
    }

    get oppsTable() {
        return (this.data?.opportunities || []).map((o, idx) => ({
            id: idx + 1,
            productType: o.productType,
            product: o.product,
            enrollDate: o.enrollDate,
            expDate: o.expDate,
            enrolled: o.enrolled
        }));
    }

    oppsColumns = [
        { label: 'Product Type', fieldName: 'productType' },
        { label: 'Product', fieldName: 'product' },
        { label: 'Enroll/Close Date', fieldName: 'enrollDate', type: 'date', typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' } },
        { label: 'Product Expiration Date', fieldName: 'expDate', type: 'date', typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' } },
        { label: 'Enrolled Indicator', fieldName: 'enrolled', type: 'boolean' }
    ];

    contactColumns = [
        { label: 'Name', fieldName: 'Name__c' },
        { label: 'Contact Role', fieldName: 'Contact_Title_c__c' },
        { label: 'Email', fieldName: 'Email__c' },
        { label: 'Phone Number', fieldName: 'Phone__c' }
    ];

    handleBacChange(event) {
        this.selectedBAC = event.detail.value;
    }

    async handleGo() {
        try {
            const resp = await getDataForBac({ recordId: this.recordId, selectedBAC: this.selectedBAC });
            this.data = resp;
        } catch (e) {
            this.notify('Error', e?.body?.message || e.message, 'error');
        }
    }

    openScorecard = () => {
        const base = AF_DealerScorecard_Page || '';
        const url = base + '&usid=' + (this.data?.userEmployeeNumber || '') + '&said=' + (this.data?.account?.Smart_Auction_Id__c || '');
        window.open(url, '_blank');
    }

    openSummary = () => {
        const base = AF_DealerSummary_Page || '';
        const url = base + '&usid=' + (this.data?.userEmployeeNumber || '') + '&said=' + (this.data?.account?.Smart_Auction_Id__c || '');
        window.open(url, '_blank');
    }

    notify(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
