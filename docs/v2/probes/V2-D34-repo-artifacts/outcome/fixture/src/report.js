import { fmt } from './util.js';

export const reportLine = (ticket) => `${fmt(ticket.opened)} ${ticket.title}`;
