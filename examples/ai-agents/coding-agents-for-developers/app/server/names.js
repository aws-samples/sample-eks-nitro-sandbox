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
export const randomName = () => `${pick(ADJECTIVES)}-${pick(ANIMALS)}`;
