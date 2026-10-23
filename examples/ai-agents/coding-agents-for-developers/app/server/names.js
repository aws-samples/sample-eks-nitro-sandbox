// Two-word session names, e.g. "brave-otter".
const ADJECTIVES = [
  "brave", "calm", "clever", "eager", "gentle", "jolly", "keen", "lively",
  "merry", "nimble", "proud", "quiet", "swift", "tidy", "witty", "zesty",
];
const ANIMALS = [
  "otter", "fox", "lynx", "heron", "robin", "marten", "ibex", "crane",
  "vole", "finch", "shrew", "gecko", "panda", "tapir", "koala", "wombat",
];
const pick = (a) => a[Math.floor(Math.random() * a.length)];

// A session name carries a base-36 millisecond timestamp as its first segment, then two
// friendly words: e.g. "m9xk2p-brave-otter". The timestamp prefix makes names sort newest
// first lexically, so the session list can be ordered with no extra metadata lookup (the
// list is built from access-point paths alone, which matters at thousands of sessions).
// The UI shows only the friendly words (see displayName); the full name is the identifier.
export const randomName = () =>
  `${Date.now().toString(36)}-${pick(ADJECTIVES)}-${pick(ANIMALS)}`;

// True only for a name randomName could have produced: a base-36 timestamp, then one of the
// adjectives and one of the animals above. The API rejects anything else before it touches
// a claim, an access point or a bucket prefix built from the name.
const SESSION_RE = new RegExp(`^[0-9a-z]{1,12}-(${ADJECTIVES.join("|")})-(${ANIMALS.join("|")})$`);
export const isSessionName = (s) => typeof s === "string" && SESSION_RE.test(s);

// The friendly part of a session name, for display: drop the timestamp prefix.
export const displayName = (session) => session.replace(/^[0-9a-z]+-/, "");
