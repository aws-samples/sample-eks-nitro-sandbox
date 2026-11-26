function normalize(value) {
  return value.normalize("NFKC").trim();
}

function contentText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const textBlocks = value.map((block) => {
      if (
        !block ||
        typeof block !== "object" ||
        Array.isArray(block) ||
        block.type !== "text" ||
        typeof block.text !== "string"
      ) {
        throw new Error("unsupported transcript content shape");
      }
      return block.text;
    });
    return textBlocks.join("");
  }
  throw new Error("unsupported transcript content shape");
}

function assistantReplyText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const textBlocks = value.filter((block) => block?.type === "text");
    const supported = value.every(
      (block) =>
        block &&
        typeof block === "object" &&
        !Array.isArray(block) &&
        (block.type === "text" ||
          (block.type === "thinking" && typeof block.thinking === "string")),
    );
    if (!supported) {
      throw new Error("unsupported transcript content shape");
    }
    return contentText(textBlocks);
  }
  throw new Error("unsupported transcript content shape");
}

function requireString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
}

export function evaluateNativeToolHistory({
  history,
  nonce,
  runId,
  exactCommand,
  toolMarker,
  finalMarker,
}) {
  for (const [name, value] of Object.entries({
    nonce,
    runId,
    exactCommand,
    toolMarker,
    finalMarker,
  })) {
    requireString(value, name);
  }
  if (!Array.isArray(history?.messages)) return null;

  const messages = history.messages;
  if (
    messages.some(
      (message) =>
        !message || typeof message !== "object" || Array.isArray(message),
    )
  ) {
    throw new Error("malformed transcript row");
  }

  const belongsToRun = (message) => {
    const attributedRunId = message?.__openclaw?.runId;
    return attributedRunId == null || attributedRunId === runId;
  };
  const userIndexes = messages.flatMap((message, index) =>
    message.role === "user" &&
    belongsToRun(message) &&
    contentText(message.content).includes(nonce)
      ? [index]
      : [],
  );
  if (userIndexes.length !== 1) return null;
  const userIndex = userIndexes[0];

  const toolCalls = [];
  const toolCallIds = new Set();
  for (let index = userIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (message.role !== "assistant" || !belongsToRun(message)) continue;
    if (!Array.isArray(message.content)) continue;
    for (const block of message.content) {
      if (!block || typeof block !== "object" || Array.isArray(block)) {
        throw new Error("malformed assistant content block");
      }
      if (block.type !== "toolCall") continue;
      if (
        block.name !== "exec" ||
        typeof block.id !== "string" ||
        block.id.length === 0 ||
        block?.arguments?.command !== exactCommand
      ) {
        throw new Error("unexpected exec tool call");
      }
      if (toolCallIds.has(block.id)) continue;
      toolCallIds.add(block.id);
      toolCalls.push({ index, id: block.id });
    }
  }
  if (toolCalls.length === 0) return null;
  if (toolCalls.length > 1) {
    throw new Error("unexpected tool-call count");
  }

  const results = [];
  const resultCountByCall = new Map(toolCalls.map(({ id }) => [id, 0]));
  for (let index = userIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (message.role !== "toolResult" || !belongsToRun(message)) continue;
    if (
      message.toolName !== "exec" ||
      typeof message.toolCallId !== "string" ||
      !toolCallIds.has(message.toolCallId)
    ) {
      throw new Error("uncorrelated exec tool result");
    }
    const toolCall = toolCalls.find(({ id }) => id === message.toolCallId);
    if (index <= toolCall.index) {
      throw new Error("exec tool result precedes its call");
    }
    if (
      message.isError !== false ||
      normalize(contentText(message.content)) !== normalize(toolMarker)
    ) {
      throw new Error("exec tool result did not prove success");
    }
    resultCountByCall.set(
      message.toolCallId,
      resultCountByCall.get(message.toolCallId) + 1,
    );
    results.push({ index, message });
  }
  if ([...resultCountByCall.values()].some((count) => count === 0)) return null;

  const latestResultIndex = Math.max(...results.map(({ index }) => index));
  const finalMessages = messages.flatMap((message, index) => {
    if (
      index <= latestResultIndex ||
      message.role !== "assistant" ||
      !belongsToRun(message)
    ) {
      return [];
    }
    const blocks = Array.isArray(message.content) ? message.content : [];
    if (blocks.some((block) => block?.type === "toolCall")) return [];
    if (["toolUse", "error", "aborted"].includes(message.stopReason)) return [];
    return normalize(assistantReplyText(message.content)) ===
      normalize(finalMarker)
      ? [{ index, message }]
      : [];
  });
  if (finalMessages.length === 0) return null;
  if (finalMessages.length > 1) {
    throw new Error("unexpected final reply count");
  }

  return {
    toolCallCount: toolCalls.length,
    execResultCount: results.length,
    finalReplyCount: finalMessages.length,
  };
}
