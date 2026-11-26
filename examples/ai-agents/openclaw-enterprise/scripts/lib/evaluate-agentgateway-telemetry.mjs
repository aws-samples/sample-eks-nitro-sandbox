const ANSI = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g;

function nonzeroHex(value, length) {
  return (
    typeof value === "string" &&
    new RegExp(`^[0-9a-f]{${length}}$`).test(value) &&
    !/^0+$/.test(value)
  );
}

// AgentGateway prefixes its logfmt fields with a timestamp, level and message.
// Parse complete tokens so quoted messages cannot impersonate telemetry fields.
function parseLine(line) {
  const entries = [];
  const errors = [];
  let index = 0;
  let sawField = false;
  const space = (character) => character === " " || character === "\t";
  while (index < line.length) {
    while (space(line[index])) index += 1;
    if (index === line.length) break;
    const start = index;
    while (
      index < line.length &&
      !space(line[index]) &&
      line[index] !== "="
    ) index += 1;
    if (line[index] !== "=") {
      if (sawField) errors.push("unexpected bare token");
      continue;
    }
    sawField = true;
    const key = line.slice(start, index);
    if (!/^[A-Za-z0-9_.:-]+$/.test(key)) errors.push("malformed field name");
    index += 1;
    let value = "";
    if (line[index] === '"') {
      index += 1;
      let closed = false;
      while (index < line.length) {
        const character = line[index++];
        if (character === '"') {
          closed = true;
          break;
        }
        if (character === "\\") {
          const escaped = line[index++];
          const escapes = { '"': '"', "\\": "\\", n: "\n", r: "\r", t: "\t" };
          if (!Object.hasOwn(escapes, escaped)) {
            errors.push("malformed quoted escape");
          } else {
            value += escapes[escaped];
          }
        } else {
          value += character;
        }
      }
      if (!closed) errors.push("unterminated quoted value");
      if (index < line.length && !space(line[index])) {
        errors.push("quoted value has a trailing token");
        while (index < line.length && !space(line[index])) index += 1;
      }
    } else {
      const valueStart = index;
      while (index < line.length && !space(line[index])) index += 1;
      value = line.slice(valueStart, index);
      if (/["=\\\x00-\x1f\x7f]/.test(value)) errors.push("malformed unquoted value");
    }
    entries.push([key, value]);
  }
  return { entries, errors };
}

export function evaluateAgentGatewayTelemetry({
  lines,
  traceId,
  gatewayModel,
  bedrockModel,
}) {
  if (!nonzeroHex(traceId, 32)) {
    throw new Error("traceId must be 32 lowercase hex characters and nonzero");
  }
  for (const [name, value] of Object.entries({ gatewayModel, bedrockModel })) {
    if (typeof value !== "string" || value.trim() === "") {
      throw new Error(`${name} must be a non-empty string`);
    }
  }
  if (typeof lines === "string") lines = lines.split(/\r?\n/);
  if (!Array.isArray(lines) || lines.some((line) => typeof line !== "string")) {
    throw new Error("lines must be log text or an array of strings");
  }
  const expected = {
    "trace.id": traceId,
    "gen_ai.provider.name": "aws.bedrock",
    "agw.ai.original_model": gatewayModel,
    "gen_ai.request.model": bedrockModel,
    "http.status": "200",
  };
  const spans = new Map();
  for (const rawLine of lines) {
    const { entries, errors } = parseLine(rawLine.replace(ANSI, ""));
    if (!entries.some(([key, value]) => key === "trace.id" && value === traceId)) {
      continue;
    }
    if (errors.length) throw new Error("malformed logfmt in requested trace");
    const fields = new Map();
    for (const [key, value] of entries) {
      if (fields.has(key)) throw new Error(`duplicate field: ${key}`);
      if (value === "") throw new Error(`empty field: ${key}`);
      fields.set(key, value);
    }
    for (const [key, value] of Object.entries(expected)) {
      if (fields.get(key) !== value) {
        throw new Error(`missing or unexpected field: ${key}`);
      }
    }
    const spanId = fields.get("span.id");
    if (!nonzeroHex(spanId, 16)) throw new Error("missing or invalid span.id");
    const previous = spans.get(spanId);
    if (previous) {
      for (const [key, value] of fields) {
        if (previous.has(key) && previous.get(key) !== value) {
          throw new Error(`contradictory same-span field: ${key}`);
        }
      }
      for (const [key, value] of fields) previous.set(key, value);
    } else {
      spans.set(spanId, fields);
    }
  }
  if (spans.size === 0) throw new Error("no telemetry for requested trace");
  return {
    traceId,
    spanIds: [...spans.keys()].sort(),
    provider: "aws.bedrock",
    gatewayModel,
    bedrockModel,
    invocationCount: spans.size,
  };
}
