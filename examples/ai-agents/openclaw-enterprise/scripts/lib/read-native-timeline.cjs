// Read bounded correlation metadata from the native diagnostic timeline.
// node -e "$(cat native-timeline-reader.cjs)" mark
// node -e "$(cat native-timeline-reader.cjs)" read "$CURSOR_JSON" "$RESPONSE_ID"
const fs = require('node:fs');
const path = process.env.OPENCLAW_DIAGNOSTICS_TIMELINE_PATH || '/home/node/.openclaw/diagnostics/native-timeline.jsonl';
const [mode, cursorText, runId] = process.argv.slice(1);
const fail = (message, code = 1) => { console.error(message); process.exit(code); };
let fd;
try { fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
catch (e) {
  if (e.code === 'ENOENT' && mode === 'mark') {
    process.stdout.write(JSON.stringify({exists:false,offset:0})); process.exit(0);
  }
  fail('Timeline unavailable', 2);
}
const stat = fs.fstatSync(fd);
if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 || (stat.mode & 0o077)) fail('Timeline must be a private owned regular file');
const identity = {dev:String(stat.dev),ino:String(stat.ino)};
if (mode === 'mark') {
  if (stat.size) {
    const last = Buffer.alloc(1); fs.readSync(fd,last,0,1,stat.size-1);
    if (last[0] !== 10) fail('Checkpoint is inside an incomplete line', 2);
  }
  fs.closeSync(fd);
  process.stdout.write(JSON.stringify({exists:true,...identity,offset:stat.size}));
  process.exit(0);
}
if (mode !== 'read' || !/^chatcmpl_[0-9a-f-]{36}$/i.test(runId || '')) fail('Invalid arguments');
let cursor; try { cursor = JSON.parse(cursorText); } catch { fail('Invalid cursor'); }
if (!Number.isSafeInteger(cursor.offset) || cursor.offset < 0 ||
    (cursor.exists === false && cursor.offset !== 0)) fail('Invalid offset');
if (cursor.exists && (cursor.dev !== identity.dev || cursor.ino !== identity.ino)) fail('Timeline replaced');
const bytes = stat.size - cursor.offset;
if (bytes < 0 || bytes > 2 * 1024 * 1024) fail('Timeline truncated or delta exceeds 2 MiB');
const buffer = Buffer.alloc(bytes);
let read = 0;
while (read < bytes) {
  const n = fs.readSync(fd, buffer, read, bytes-read, cursor.offset+read);
  if (!n) fail('Timeline changed during read');
  read += n;
}
fs.closeSync(fd);
if (bytes && buffer[bytes-1] !== 10) fail('Timeline flush incomplete', 2);
const events = [];
for (const line of buffer.toString('utf8').split('\n')) {
  if (!line) continue;
  let e; try { e = JSON.parse(line); } catch { fail('Malformed timeline delta'); }
  if (e.attributes?.failedWrites > 0) fail('Timeline reports failed writes');
  if (e.runId !== runId || !['provider.request.started','provider.request'].includes(e.name)) continue;
  if (e.schemaVersion !== 'openclaw.diagnostics.v1' ||
      !/^[0-9a-f]{32}$/.test(e.attributes?.traceId || '') || /^0+$/.test(e.attributes.traceId)) fail('Invalid trace metadata');
  events.push({name:e.name,callId:e.spanId,traceId:e.attributes.traceId,
    provider:e.provider,model:e.attributes.model,ok:e.ok,status:e.status,
    captureId:e.attributes.captureId,sequence:e.attributes.sequence});
}
const starts = events.filter(e => e.name === 'provider.request.started');
const terminals = events.filter(e => e.name === 'provider.request');
if (!starts.length || !terminals.length) fail('Run mapping not flushed', 2);
const roots = [...new Set(events.map(e=>e.traceId))];
if (roots.length !== 1) fail('Run has multiple roots');
for (const e of starts) if (!terminals.some(t=>t.callId===e.callId)) fail('Model call not settled', 2);
if (!terminals.some(e=>e.ok===true)) fail('No successful native model call');
process.stdout.write(JSON.stringify({runId,traceId:roots[0],calls:terminals,
  cursor:{exists:true,...identity,offset:stat.size}}));
