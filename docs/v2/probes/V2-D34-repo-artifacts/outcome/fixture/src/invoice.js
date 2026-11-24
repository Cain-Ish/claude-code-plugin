import { fmt } from './util.js';

export const invoiceHeader = (invoice) => `Invoice ${invoice.id}, issued ${fmt(invoice.issued)}`;
