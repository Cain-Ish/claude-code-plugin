// InstructionsLoaded hook: append the event's JSON as one line to the log named in argv.
import fs from 'node:fs';
fs.appendFileSync(process.argv[2], `${JSON.stringify(JSON.parse(fs.readFileSync(0, 'utf8') || '{}'))}\n`);
