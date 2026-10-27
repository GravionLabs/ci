import * as fs from 'fs';
import * as path from 'path';

export type GhCall = { args: string[]; query?: string; variables?: Record<string, any> };

// A fake `gh` on PATH (POSIX sh wrapper around a node handler): it records every call (argv plus the GraphQL body read from
// stdin) as a JSON line and answers with what `handlerSource` returns. The handler is the body of
// `(call, ctx) => data` where call = {args, query, variables} and ctx.count(key) numbers repeated calls (1, 2, ...).
// Returned `{data}` is wrapped as GraphQL data; `{rest}` is printed as-is; throwing prints the message to stderr and exits 1.
export function createFakeGh(dir: string, handlerSource: string) {
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin, { recursive: true });
  const log = path.join(dir, 'gh-calls.jsonl');
  fs.writeFileSync(
    path.join(dir, 'gh-handler.js'),
    `const fs = require('fs');
const dir = ${JSON.stringify(dir)};
const args = process.argv.slice(2);
let query, variables;
if (args.includes('--input')) {
  const body = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
  query = body.query; variables = body.variables;
}
const call = { args, query, variables };
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(call) + '\\n');
const ctx = { count(key) {
  const f = dir + '/count-' + key.replace(/[^a-z0-9]/gi, '_');
  const n = (fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0) + 1;
  fs.writeFileSync(f, String(n)); return n; } };
try {
  const out = (${handlerSource})(call, ctx);
  if (out && out.rest !== undefined) console.log(JSON.stringify(out.rest));
  else console.log(JSON.stringify({ data: out }));
} catch (e) { console.error(String(e.message || e)); process.exit(1); }
`
  );
  fs.writeFileSync(
    path.join(bin, 'gh'),
    `#!/bin/sh\nexec node ${JSON.stringify(path.join(dir, 'gh-handler.js'))} "$@"\n`,
    { mode: 0o755 }
  );
  return {
    bin,
    env: (base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv => ({
      ...base,
      PATH: `${bin}${path.delimiter}${base.PATH ?? ''}`,
    }),
    calls: (): GhCall[] =>
      fs.existsSync(log)
        ? fs
            .readFileSync(log, 'utf8')
            .split('\n')
            .filter(Boolean)
            .map((l) => JSON.parse(l))
        : [],
  };
}
