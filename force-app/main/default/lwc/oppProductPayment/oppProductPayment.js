import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import getProductSummary from '@salesforce/apex/OpportunityPaymentController.getProductSummary';
import createCheckoutSession from '@salesforce/apex/OpportunityPaymentController.createCheckoutSession';

const STRIPE_JS_URL = 'https://js.stripe.com/v3/';
// Publishable key is safe to expose client-side. Move this to Custom Metadata
// rather than hardcoding, so it can differ across sandboxes/production.
const STRIPE_PUBLISHABLE_KEY = 'PUBLISHKEY';

export default class OppProductPayment extends LightningElement {
    @api recordId; // Opportunity Id - auto-populated when placed on the record page

    summary;
    errorMessage;
    isModalOpen = false;
    isLoadingSummary = false;
    isCreatingSession = false;
    isPaying = false;
    stripeScriptLoaded = false;
    checkoutInstance;

    connectedCallback() {
        this.loadSummary();
    }

    get buttonLabel() {
        if (!this.summary) {
            return 'Products';
        }
        return `${this.summary.productCount} Product(s) \u2022 Pay Now`;
    }

    get formattedTotal() {
        if (!this.summary) {
            return '';
        }
        return `${this.summary.currencyCode} ${this.summary.totalAmount}`;
    }

    loadSummary() {
        this.isLoadingSummary = true;
        getProductSummary({ opportunityId: this.recordId })
            .then((result) => {
                this.summary = result;
            })
            .catch((error) => {
                this.errorMessage = this.extractError(error);
            })
            .finally(() => {
                this.isLoadingSummary = false;
            });
    }

    handleOpenModal() {
        this.errorMessage = undefined;
        this.isModalOpen = true;
    }

    handleCloseModal() {
        if (this.checkoutInstance) {
            this.checkoutInstance.destroy();
            this.checkoutInstance = undefined;
        }
        this.isPaying = false;
        this.isModalOpen = false;
    }

    async handlePayNow() {
        this.isCreatingSession = true;
        this.errorMessage = undefined;
        try {
            const clientSecret = await createCheckoutSession({ opportunityId: this.recordId });
            console.log('mycustomclientsecret '+clientSecret);
            await this.ensureStripeLoaded();
            this.isPaying = true;
            // Let the template render the mount point before Stripe tries to attach to it
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.mountEmbeddedCheckout(clientSecret), 0);
        } catch (error) {
            this.errorMessage = this.extractError(error);
        } finally {
            this.isCreatingSession = false;
        }
    }

    ensureStripeLoaded() {
        if (this.stripeScriptLoaded) {
            return Promise.resolve();
        }
        return loadScript(this, STRIPE_JS_URL).then(() => {
            this.stripeScriptLoaded = true;
        });
    }

    mountEmbeddedCheckout(clientSecret) {
        // eslint-disable-next-line no-undef
        const stripe = Stripe(STRIPE_PUBLISHABLE_KEY);
        stripe
            .initEmbeddedCheckout({ clientSecret })
            .then((checkout) => {
                this.checkoutInstance = checkout;
                const container = this.template.querySelector('.checkout-container');
                checkout.mount(container);
            })
            .catch((error) => {
                this.errorMessage = this.extractError(error);
                this.isPaying = false;
            });
    }

    extractError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'Something went wrong. Please try again.';
    }
}
