import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { Tokenizer } from "@huggingface/tokenizers";
import ort from "onnxruntime-node";

import {
  LOCAL_EMBEDDING_DIMENSIONS,
  LOCAL_EMBEDDING_MAX_TOKENS,
} from "./local-embedding-config.mjs";

const modelDirectory = process.env.OFFICE_EMBEDDING_MODEL_DIR;
if (!modelDirectory) {
  throw new Error("OFFICE_EMBEDDING_MODEL_DIR가 필요합니다.");
}

let modelPromise = null;
let queue = Promise.resolve();

async function loadModel() {
  const [tokenizerJSON, tokenizerConfigJSON, session] = await Promise.all([
    readFile(resolve(modelDirectory, "tokenizer.json"), "utf8"),
    readFile(resolve(modelDirectory, "tokenizer_config.json"), "utf8"),
    ort.InferenceSession.create(
      resolve(modelDirectory, "onnx", "model_quantized.onnx"),
      {
        executionProviders: ["cpu"],
        graphOptimizationLevel: "all",
      },
    ),
  ]);
  const tokenizer = new Tokenizer(
    JSON.parse(tokenizerJSON),
    JSON.parse(tokenizerConfigJSON),
  );
  return {
    tokenizer,
    session,
    padTokenID: tokenizer.token_to_id("<pad>") ?? 1,
    endTokenID: tokenizer.token_to_id("</s>") ?? 2,
  };
}

function model() {
  modelPromise ??= loadModel();
  return modelPromise;
}

function truncatedIDs(tokenizer, text, endTokenID) {
  const ids = tokenizer.encode(text).ids;
  if (ids.length <= LOCAL_EMBEDDING_MAX_TOKENS) {
    return ids;
  }
  const truncated = ids.slice(0, LOCAL_EMBEDDING_MAX_TOKENS);
  truncated[truncated.length - 1] = endTokenID;
  return truncated;
}

function normalizedCLS(output, batchIndex, sequenceLength) {
  const offset = batchIndex * sequenceLength * LOCAL_EMBEDDING_DIMENSIONS;
  const vector = Array.from(
    output.data.slice(offset, offset + LOCAL_EMBEDDING_DIMENSIONS),
  );
  const magnitude = Math.sqrt(
    vector.reduce((sum, value) => sum + value * value, 0),
  );
  if (!Number.isFinite(magnitude) || magnitude === 0) {
    throw new Error("로컬 임베딩 정규화에 실패했습니다.");
  }
  return vector.map((value) => value / magnitude);
}

async function embed(texts) {
  const { tokenizer, session, padTokenID, endTokenID } = await model();
  const encoded = texts.map((text) =>
    truncatedIDs(tokenizer, text, endTokenID)
  );
  const sequenceLength = Math.max(...encoded.map((ids) => ids.length));
  const elementCount = texts.length * sequenceLength;
  const inputIDs = new BigInt64Array(elementCount);
  const attentionMask = new BigInt64Array(elementCount);
  inputIDs.fill(BigInt(padTokenID));
  for (let batch = 0; batch < encoded.length; batch += 1) {
    const offset = batch * sequenceLength;
    for (let token = 0; token < encoded[batch].length; token += 1) {
      inputIDs[offset + token] = BigInt(encoded[batch][token]);
      attentionMask[offset + token] = 1n;
    }
  }
  const output = await session.run({
    input_ids: new ort.Tensor(
      "int64",
      inputIDs,
      [texts.length, sequenceLength],
    ),
    attention_mask: new ort.Tensor(
      "int64",
      attentionMask,
      [texts.length, sequenceLength],
    ),
  });
  const hiddenState = output.last_hidden_state;
  const vectors = texts.map((_, index) =>
    normalizedCLS(hiddenState, index, sequenceLength)
  );
  return {
    vectors,
    dimensions: LOCAL_EMBEDDING_DIMENSIONS,
    rssBytes: process.memoryUsage().rss,
    maxRSSBytes: process.resourceUsage().maxRSS * 1024,
  };
}

async function handle(message) {
  const id = message?.id;
  try {
    const texts = Array.isArray(message?.texts)
      ? message.texts.map((text) => String(text ?? ""))
      : [];
    if (texts.length === 0) {
      throw new Error("임베딩할 텍스트가 없습니다.");
    }
    process.send?.({ id, ok: true, result: await embed(texts) });
  } catch (error) {
    process.send?.({
      id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

process.on("message", (message) => {
  queue = queue.then(() => handle(message));
});
