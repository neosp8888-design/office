(function conversationWebBootstrap(global) {
  "use strict";

  const hasDOM = typeof document !== "undefined";
  const DEFAULT_CHARACTER = "boss";
  const LIVE_LIMIT = 120;
  const ARCHIVE_PAGE_SIZE = 50;
  const BOTTOM_TOLERANCE = 64;
  const MAX_ACTIVITY_ROWS = 24;
  const cache = new Map();
  const loadedCharacters = new Set();
  const liveTurnIds = new Map();
  const archivedTurnIds = new Map();
  const scrollMemory = new Map();
  const archiveState = new Map();
  const pendingRequests = new Map();
  const workspaceReviewStates = new Map();

  const state = {
    characterId: DEFAULT_CHARACTER,
    transport: "direct",
    baseURL: "",
    pendingQuestionTurnIds: new Set(),
    hasPendingQuestionSnapshot: false,
    dismissedQuestionTurnIds: new Set(),
    followBottom: true,
    initialRequestInFlight: false,
    refreshTimer: null,
    socket: null,
    socketRetry: 0,
    socketRetryTimer: null,
    toastTimer: null,
    initialized: false,
    visible: true,
    pendingRender: false,
    readySent: false,
    hiddenDirty: false,
    didInitialPosition: false,
  };

  const statusTitles = {
    pending: "대기 중",
    running: "진행 중",
    completed: "완료",
    failed: "실패",
    interrupted: "중단",
  };

  const activityTitles = {
    thinking: "추론",
    command: "명령",
    tool: "도구",
    message: "진행 메시지",
    collaboration: "협업",
  };

  const workspaceTitles = {
    active: "격리 작업공간 사용 중",
    awaiting_approval: "변경사항 검토 필요",
    merging: "승인된 변경사항 병합 중",
    merged: "병합 완료",
    rejected: "변경사항 거절됨",
    closed: "변경 없는 작업공간 종료됨",
    conflict: "병합 충돌",
    failed: "작업공간 처리 실패",
  };

  function elements() {
    if (!hasDOM) return {};
    return {
      feed: document.getElementById("feed"),
      scroller: document.getElementById("feed-scroller"),
      statusBanner: document.getElementById("status-banner"),
      statusText: document.getElementById("status-text"),
      retry: document.getElementById("retry-button"),
      loadOlder: document.getElementById("load-older"),
      jumpBottom: document.getElementById("jump-bottom"),
      toast: document.getElementById("toast"),
      bottom: document.getElementById("bottom-sentinel"),
    };
  }

  function cacheFor(characterId) {
    if (!cache.has(characterId)) cache.set(characterId, new Map());
    return cache.get(characterId);
  }

  function archiveFor(characterId) {
    if (!archiveState.has(characterId)) {
      archiveState.set(characterId, {
        offset: 0,
        total: Number.POSITIVE_INFINITY,
        loading: false,
        exhausted: false,
      });
    }
    return archiveState.get(characterId);
  }

  function idSetFor(collection, characterId) {
    if (!collection.has(characterId)) collection.set(characterId, new Set());
    return collection.get(characterId);
  }

  function normalizeTurn(turn) {
    if (!turn || typeof turn !== "object") return null;
    const id = String(turn.id || "").trim();
    const characterId = String(turn.characterId || "").trim();
    if (!id || !characterId) return null;
    return {
      ...turn,
      id,
      characterId,
      characterName: String(turn.characterName || characterId),
      prompt: String(turn.prompt || ""),
      response: String(turn.response || ""),
      status: String(turn.status || "pending"),
      needsInput: turn.needsInput === true,
      activities: Array.isArray(turn.activities) ? turn.activities : [],
      sources: Array.isArray(turn.sources) ? turn.sources : [],
    };
  }

  function mergeTurns(turns, options = {}) {
    const changedCharacters = new Set();
    for (const candidate of Array.isArray(turns) ? turns : []) {
      const turn = normalizeTurn(candidate);
      if (!turn) continue;
      cacheFor(turn.characterId).set(turn.id, turn);
      if (options.trackLive === true) {
        idSetFor(liveTurnIds, turn.characterId).add(turn.id);
      }
      changedCharacters.add(turn.characterId);
    }
    if (options.markLoaded) {
      for (const id of changedCharacters) loadedCharacters.add(id);
      if (options.characterId) loadedCharacters.add(options.characterId);
    }
    return changedCharacters;
  }

  function applyLiveSnapshot(turns, options = {}) {
    const grouped = new Map();
    for (const candidate of Array.isArray(turns) ? turns : []) {
      const turn = normalizeTurn(candidate);
      if (!turn) continue;
      if (!grouped.has(turn.characterId)) grouped.set(turn.characterId, []);
      grouped.get(turn.characterId).push(turn);
    }

    const reconciledCharacters = new Set([
      ...liveTurnIds.keys(),
      ...grouped.keys(),
    ]);
    const changedCharacters = new Set();
    for (const characterId of reconciledCharacters) {
      const target = cacheFor(characterId);
      const previousLiveIds = idSetFor(liveTurnIds, characterId);
      const nextTurns = grouped.get(characterId) || [];
      const nextLiveIds = new Set(nextTurns.map((turn) => turn.id));
      const preservedArchiveIds = idSetFor(archivedTurnIds, characterId);

      for (const turnId of previousLiveIds) {
        if (!nextLiveIds.has(turnId) && !preservedArchiveIds.has(turnId)) {
          target.delete(turnId);
          workspaceReviewStates.delete(turnId);
          changedCharacters.add(characterId);
        }
      }
      for (const turn of nextTurns) {
        target.set(turn.id, turn);
        changedCharacters.add(characterId);
      }
      liveTurnIds.set(characterId, nextLiveIds);
      loadedCharacters.add(characterId);
    }
    if (options.characterId) loadedCharacters.add(options.characterId);
    return changedCharacters;
  }

  function mergeArchiveTurns(turns) {
    const normalized = [];
    for (const candidate of Array.isArray(turns) ? turns : []) {
      const turn = normalizeTurn(candidate);
      if (!turn) continue;
      normalized.push(turn);
      idSetFor(archivedTurnIds, turn.characterId).add(turn.id);
    }
    return mergeTurns(normalized);
  }

  function replaceTurns(turns, options = {}) {
    const grouped = new Map();
    for (const candidate of Array.isArray(turns) ? turns : []) {
      const turn = normalizeTurn(candidate);
      if (!turn) continue;
      if (!grouped.has(turn.characterId)) grouped.set(turn.characterId, []);
      grouped.get(turn.characterId).push(turn);
    }
    if (options.characterId) {
      cache.set(options.characterId, new Map());
      loadedCharacters.add(options.characterId);
    }
    for (const [characterId, values] of grouped) {
      const target = options.replaceAll === true || characterId === options.characterId
        ? new Map()
        : cacheFor(characterId);
      for (const turn of values) target.set(turn.id, turn);
      cache.set(characterId, target);
      loadedCharacters.add(characterId);
    }
    if (hasDOM && (!options.characterId || options.characterId === state.characterId)) {
      render({ reason: "replace" });
      setLoading(false);
    }
  }

  function turnsFor(characterId) {
    return [...cacheFor(characterId).values()].sort((left, right) => {
      const time = dateValue(left.startedAt) - dateValue(right.startedAt);
      return time !== 0 ? time : left.id.localeCompare(right.id);
    });
  }

  function dateValue(value) {
    const time = new Date(value || 0).getTime();
    return Number.isFinite(time) ? time : 0;
  }

  function revisionFor(turn) {
    return semanticFingerprint({
      updatedAt: turn.updatedAt,
      status: turn.status,
      response: turn.response,
      feedback: turn.feedback ?? null,
      needsInput: turn.needsInput,
      errorMessage: turn.errorMessage ?? null,
      responseSourceWarning: turn.responseSourceWarning ?? null,
      wikiProposalWarning: turn.wikiProposalWarning ?? null,
      activities: turn.activities,
      sources: turn.sources,
      workspace: turn.workspace ?? null,
      workspaceReviewRevision: workspaceReviewStates.get(turn.id)?.revision ?? 0,
      pendingQuestion: state.pendingQuestionTurnIds.has(turn.id),
      dismissedQuestion: state.dismissedQuestionTurnIds.has(turn.id),
    });
  }

  function semanticFingerprint(value) {
    const source = JSON.stringify(value);
    let first = 0x811c9dc5;
    let second = 0x9e3779b9;
    for (let index = 0; index < source.length; index += 1) {
      const code = source.charCodeAt(index);
      first = Math.imul(first ^ code, 0x01000193) >>> 0;
      second = Math.imul(second ^ code, 0x85ebca6b) >>> 0;
    }
    return `${source.length}:${first.toString(36)}:${second.toString(36)}`;
  }

  function setLoading(value, text = "대화를 불러오는 중") {
    if (!hasDOM) return;
    const ui = elements();
    state.initialRequestInFlight = value;
    ui.statusText.textContent = text;
    ui.statusBanner.hidden = !value;
    ui.retry.hidden = true;
    const spinner = ui.statusBanner.querySelector(".status-spinner");
    if (spinner) spinner.hidden = false;
    ui.feed.setAttribute("aria-busy", value ? "true" : "false");
  }

  function showError(message, retryable = true) {
    if (!hasDOM) return;
    const ui = elements();
    setLoading(false);
    ui.statusText.textContent = String(message || "대화를 불러오지 못했습니다.");
    ui.statusBanner.hidden = false;
    ui.statusBanner.querySelector(".status-spinner").hidden = true;
    ui.retry.hidden = !retryable;
  }

  function clearStatus() {
    if (!hasDOM) return;
    const ui = elements();
    ui.statusBanner.hidden = true;
    ui.retry.hidden = true;
    const spinner = ui.statusBanner.querySelector(".status-spinner");
    if (spinner) spinner.hidden = false;
  }

  async function fetchJSON(path, options = {}) {
    const base = state.baseURL || (hasDOM ? global.location.origin : "");
    const url = new URL(path, `${base.replace(/\/$/, "")}/`);
    const response = await fetch(url, {
      cache: "no-store",
      credentials: "same-origin",
      ...options,
      headers: {
        accept: "application/json",
        ...(options.body ? { "content-type": "application/json" } : {}),
        ...(options.headers || {}),
      },
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.error || `요청이 실패했습니다. (${response.status})`);
    }
    return body;
  }

  function postBridge(message) {
    try {
      const handler = global.webkit?.messageHandlers?.officestraConversation;
      if (!handler || typeof handler.postMessage !== "function") return false;
      handler.postMessage(message);
      return true;
    } catch (_) {
      return false;
    }
  }

  async function loadInitial(options = {}) {
    if (state.initialRequestInFlight && !options.force) return;
    setLoading(true, loadedCharacters.has(state.characterId) ? "대화 갱신 중" : "대화를 불러오는 중");
    if (state.transport === "native") {
      showError("대화 데이터가 전달되지 않았습니다.");
      signalReady();
      return;
    }
    try {
      const body = await fetchJSON(`/api/live-feed?limit=${LIVE_LIMIT}`);
      applyLiveSnapshot(body.turns, { characterId: state.characterId });
      loadedCharacters.add(state.characterId);
      render({ reason: "initial" });
      clearStatus();
    } catch (error) {
      showError(error.message);
      signalReady();
    } finally {
      state.initialRequestInFlight = false;
    }
  }

  function setCharacter(characterId, options = {}) {
    const next = String(characterId || "").trim();
    if (!next || next === state.characterId) return;
    rememberScroll(state.characterId);
    state.characterId = next;
    state.followBottom = true;
    if (loadedCharacters.has(next)) {
      render({ reason: "character-cache" });
      restoreScroll(next);
      clearStatus();
    } else {
      // 기존 DOM을 지우지 않는다. 작은 상태 표시만 올린 뒤 새 데이터와
      // 한 프레임에서 교체해 흰 화면이 드러날 틈을 만들지 않는다.
      setLoading(true);
      loadInitial({ force: options.force === true });
    }
  }

  function rememberScroll(characterId) {
    if (!hasDOM || !characterId) return;
    const scroller = elements().scroller;
    scrollMemory.set(characterId, {
      top: scroller.scrollTop,
      bottom: distanceFromBottom(scroller),
      following: state.followBottom,
    });
  }

  function restoreScroll(characterId) {
    if (!hasDOM) return;
    const remembered = scrollMemory.get(characterId);
    requestAnimationFrame(() => {
      const scroller = elements().scroller;
      if (!remembered || remembered.following) {
        scrollToBottom(false);
      } else {
        scroller.scrollTop = Math.max(0, remembered.top);
      }
    });
  }

  function distanceFromBottom(scroller) {
    return Math.max(0, scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
  }

  function visibleAnchor() {
    if (!hasDOM) return null;
    const scroller = elements().scroller;
    const top = scroller.getBoundingClientRect().top;
    const cards = [...elements().feed.querySelectorAll(".turn")];
    const card = cards.find((item) => item.getBoundingClientRect().bottom > top + 2);
    if (!card) return null;
    return { id: card.dataset.turnId, offset: card.getBoundingClientRect().top - top };
  }

  function restoreAnchor(anchor) {
    if (!hasDOM || !anchor) return;
    const scroller = elements().scroller;
    const card = [...elements().feed.querySelectorAll(".turn")]
      .find((item) => item.dataset.turnId === anchor.id);
    if (!card) return;
    const top = scroller.getBoundingClientRect().top;
    scroller.scrollTop += card.getBoundingClientRect().top - top - anchor.offset;
  }

  function scrollToBottom(smooth = false) {
    if (!hasDOM) return;
    const scroller = elements().scroller;
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: smooth ? "smooth" : "auto" });
    state.followBottom = true;
    elements().jumpBottom.hidden = true;
  }

  function render(options = {}) {
    if (!hasDOM) return;
    if (!state.visible) {
      state.pendingRender = true;
      return;
    }
    state.pendingRender = false;
    const ui = elements();
    const wasFollowing = state.followBottom || distanceFromBottom(ui.scroller) <= BOTTOM_TOLERANCE;
    const anchor = wasFollowing ? null : visibleAnchor();
    const turns = turnsFor(state.characterId);
    const existing = new Map(
      [...ui.feed.querySelectorAll("[data-turn-id]")].map((node) => [node.dataset.turnId, node]),
    );
    const desiredNodes = [];

    if (turns.length === 0) {
      const empty = existing.get("__empty__") || emptyState();
      desiredNodes.push(empty);
    } else {
      for (const turn of turns) {
        const revision = revisionFor(turn);
        let node = existing.get(turn.id);
        if (!node || node.dataset.revision !== revision) {
          node = turnElement(turn);
          node.dataset.revision = revision;
        }
        desiredNodes.push(node);
      }
    }

    reconcileKeyedChildren(ui.feed, desiredNodes);
    updateOlderButton();
    requestAnimationFrame(() => {
      if (wasFollowing) scrollToBottom(false);
      else restoreAnchor(anchor);
      state.didInitialPosition = true;
      postBridge({
        type: "rendered",
        characterId: state.characterId,
        turnCount: turns.length,
        reason: options.reason || "update",
      });
      signalReady();
    });
  }

  function reconcileKeyedChildren(parent, desiredNodes) {
    desiredNodes.forEach((node, index) => {
      const current = parent.children[index] || null;
      if (current !== node) parent.insertBefore(node, current);
    });
    while (parent.children.length > desiredNodes.length) {
      parent.removeChild(parent.children[parent.children.length - 1]);
    }
  }

  function emptyState() {
    const node = document.createElement("div");
    node.className = "empty-state";
    node.dataset.turnId = "__empty__";
    const title = document.createElement("strong");
    title.textContent = state.initialRequestInFlight ? "대화를 준비하고 있습니다" : "아직 업무 대화가 없습니다";
    const detail = document.createElement("span");
    detail.textContent = state.initialRequestInFlight ? "잠시만 기다려 주세요." : "첫 업무를 보내면 이곳에 이어서 표시됩니다.";
    node.append(title, detail);
    return node;
  }

  function turnElement(turn) {
    const article = document.createElement("article");
    article.className = "turn";
    article.dataset.turnId = turn.id;
    article.setAttribute("role", "article");
    article.setAttribute("aria-label", `${turn.characterName} ${statusTitles[turn.status] || turn.status}`);

    const shell = document.createElement("div");
    shell.className = "turn-shell";
    shell.append(turnHeader(turn));

    if (turn.prompt) {
      const prompt = document.createElement("div");
      prompt.className = "prompt";
      prompt.textContent = turn.prompt;
      shell.append(prompt);
    }

    if (turn.activities.length > 0) shell.append(activityLog(turn));

    if (turn.response) {
      const response = document.createElement("div");
      response.className = "response";
      response.innerHTML = renderMarkdown(turn.response);
      shell.append(response);
    } else if (["pending", "running"].includes(turn.status)) {
      const response = document.createElement("div");
      response.className = "response";
      response.innerHTML = '<p class="activity-text">응답을 준비하고 있습니다…</p>';
      shell.append(response);
    }

    if (turn.responseSourceWarning) shell.append(messageBlock("source-warning", turn.responseSourceWarning));
    if (turn.wikiProposalWarning) shell.append(messageBlock("source-warning", turn.wikiProposalWarning));
    if (turn.sources.length > 0) shell.append(sourceList(turn.sources));
    if (turn.workspace && !["active", "closed"].includes(turn.workspace.status)) {
      shell.append(workspacePanel(turn));
    }
    if (turn.errorMessage && (turn.status === "failed" || turn.status === "interrupted" || !turn.response)) {
      shell.append(messageBlock("turn-error", turn.errorMessage));
    }
    if (showsQuestionComposer(turn)) shell.append(questionComposer(turn));
    if (turn.response && ["completed", "failed", "interrupted"].includes(turn.status)) {
      shell.append(responseFooter(turn));
    }

    article.append(shell);
    return article;
  }

  function turnHeader(turn) {
    const header = document.createElement("header");
    header.className = "turn-header";
    const avatar = document.createElement("div");
    avatar.className = "turn-avatar";
    avatar.textContent = [...turn.characterName].slice(0, 1).join("") || "AI";
    const title = document.createElement("div");
    title.className = "turn-title";
    title.textContent = turnTitleText(turn);
    const meta = document.createElement("div");
    meta.className = "turn-meta";
    const dot = document.createElement("span");
    dot.className = `status-dot ${turn.status}`;
    const status = document.createElement("span");
    status.textContent = statusTitles[turn.status] || turn.status;
    meta.append(dot, status);
    for (const detailText of turnMetaDetails(turn)) {
      const detail = document.createElement("span");
      detail.className = "turn-detail";
      detail.textContent = detailText;
      meta.append(detail);
    }
    const time = document.createElement("time");
    time.dateTime = turn.startedAt || "";
    time.textContent = formatTime(turn.startedAt);
    meta.append(time);
    header.append(avatar, title, meta);
    return header;
  }

  function turnTitleText(turn) {
    const execution = [
      turn.backend || turn.characterBackend,
      turn.model,
      turn.effort,
      turn.fastMode === true ? "Fast" : "Standard",
    ].filter((value) => value !== null && value !== undefined && String(value).trim());
    return [turn.characterName || turn.characterId, ...execution].join(" · ");
  }

  function turnMetaDetails(turn) {
    const values = [];
    if (Number.isFinite(turn.estimatedCostUsd)) {
      const digits = turn.estimatedCostUsd < 0.01 ? 4 : 2;
      values.push(`$${turn.estimatedCostUsd.toFixed(digits)}`);
    }
    const used = Number(turn.sessionContext?.usedTokens);
    const limit = Number(turn.sessionContext?.limitTokens);
    if (Number.isFinite(used) && Number.isFinite(limit) && limit > 0) {
      values.push(`문맥 ${Math.min(100, Math.round((used / limit) * 100))}%`);
    }
    return values;
  }

  function activityLog(turn) {
    const details = document.createElement("details");
    details.className = "transcript";
    details.open = ["pending", "running"].includes(turn.status);
    const summary = document.createElement("summary");
    const running = turn.activities.filter((item) => item.status === "running").length;
    summary.textContent = running > 0
      ? `작업 내역 · ${turn.activities.length}개 · ${running}개 진행 중`
      : `작업 내역 · ${turn.activities.length}개`;
    const list = document.createElement("ol");
    list.className = "activity-list";
    for (const activity of turn.activities.slice(-MAX_ACTIVITY_ROWS)) {
      const row = document.createElement("li");
      row.className = "activity";
      const stateDot = document.createElement("span");
      stateDot.className = `activity-state ${activity.status || "completed"}`;
      const text = document.createElement("p");
      text.className = "activity-text";
      text.textContent = activityDisplayText(activity);
      const kind = document.createElement("span");
      kind.className = "activity-kind";
      kind.textContent = activityTitles[activity.kind] || activity.kind || "작업";
      row.classList.add(`activity-${activity.kind || "other"}`);
      row.append(stateDot, text, kind);
      list.append(row);
    }
    details.append(summary, list);
    return details;
  }

  function activityDisplayText(activity) {
    const base = String(activity?.text || "").trim();
    const collaboration = activity?.collaboration;
    if (!collaboration || typeof collaboration !== "object") return base;
    const header = [
      collaboration.agentLabel,
      collaboration.action,
      collaboration.agentStatus,
    ].filter(Boolean).join(" · ");
    const lines = [header, collaboration.prompt, collaboration.message, base]
      .map((value) => String(value || "").trim())
      .filter((value, index, values) => value && values.indexOf(value) === index);
    return lines.join("\n");
  }

  function messageBlock(className, text) {
    const block = document.createElement("div");
    block.className = className;
    block.textContent = String(text || "");
    return block;
  }

  function sourceList(sources) {
    const details = document.createElement("details");
    details.className = "sources";
    const summary = document.createElement("summary");
    summary.textContent = `근거 자료 · ${sources.length}개`;
    const list = document.createElement("div");
    list.className = "source-list";
    for (const source of sources) {
      const row = document.createElement("div");
      row.className = "source-row";
      const kind = document.createElement("span");
      kind.className = "source-kind";
      kind.textContent = String(source.sourceKind || "source").toUpperCase();
      const title = document.createElement("button");
      title.className = "source-title source-action";
      title.textContent = source.title || source.locator || "근거";
      title.dataset.sourceKind = source.sourceKind || "";
      title.dataset.locator = source.locator || "";
      row.append(kind, title);
      list.append(row);
    }
    details.append(summary, list);
    return details;
  }

  function workspaceReviewKey(workspace) {
    if (!workspace) return "";
    return [
      workspace.status || "",
      workspace.reviewTree || "",
      workspace.headCommit || "",
    ].join(":");
  }

  function workspaceReviewIsManual(workspace) {
    return Boolean(
      workspace &&
      ["awaiting_approval", "conflict"].includes(workspace.status) &&
      workspace.automaticApprovalPending !== true,
    );
  }

  function workspaceReviewStateFor(turn) {
    const key = workspaceReviewKey(turn.workspace);
    let review = workspaceReviewStates.get(turn.id);
    if (!review || (review.key !== key && review.loadedKey !== key)) {
      review = {
        key,
        loadedKey: null,
        detail: null,
        loading: false,
        error: "",
        inspected: false,
        promise: null,
        revision: (review?.revision ?? 0) + 1,
      };
      workspaceReviewStates.set(turn.id, review);
    }
    return review;
  }

  function workspaceForDisplay(turn) {
    const review = workspaceReviewStateFor(turn);
    if (
      review.detail &&
      review.loadedKey === workspaceReviewKey(turn.workspace)
    ) {
      return { ...turn.workspace, ...review.detail };
    }
    return turn.workspace;
  }

  function workspaceReviewCanDecide(turn) {
    const workspace = workspaceForDisplay(turn);
    if (!workspaceReviewIsManual(workspace)) return false;
    const review = workspaceReviewStateFor(turn);
    return Boolean(
      review.detail &&
      review.loadedKey === workspaceReviewKey(workspace) &&
      review.inspected &&
      typeof workspace.diff === "string",
    );
  }

  function markWorkspaceDiffInspected(turn) {
    const workspace = workspaceForDisplay(turn);
    const review = workspaceReviewStateFor(turn);
    if (
      !review.detail ||
      review.loadedKey !== workspaceReviewKey(workspace) ||
      typeof workspace.diff !== "string"
    ) return false;
    if (!review.inspected) {
      review.inspected = true;
      review.revision += 1;
      if (hasDOM && turn.characterId === state.characterId) {
        render({ reason: "workspace-diff-inspected" });
      }
    }
    return true;
  }

  async function loadWorkspaceReview(turn, options = {}) {
    if (!workspaceReviewIsManual(turn.workspace)) return false;
    const review = workspaceReviewStateFor(turn);
    if (review.promise && options.force !== true) return review.promise;
    if (review.detail && options.force !== true) return true;

    const requestedKey = workspaceReviewKey(turn.workspace);
    review.loading = true;
    review.error = "";
    review.revision += 1;
    if (options.renderLoading === true && hasDOM) {
      render({ reason: "workspace-review-loading" });
    }

    const operation = (async () => {
      try {
        const result = await fetchJSON(
          `/api/workspace-reviews/${encodeURIComponent(turn.id)}`,
        );
        const detail = result?.workspace;
        if (!detail || typeof detail !== "object") {
          throw new Error("변경사항 상세 응답이 올바르지 않습니다.");
        }
        const current = cacheFor(turn.characterId).get(turn.id) || turn;
        if (workspaceReviewKey(current.workspace) !== requestedKey) {
          return false;
        }
        current.workspace = { ...current.workspace, ...detail };
        review.key = workspaceReviewKey(current.workspace);
        review.loadedKey = review.key;
        review.detail = { ...detail };
        review.loading = false;
        review.error = "";
        review.inspected = false;
        review.revision += 1;
        return true;
      } catch (error) {
        review.loading = false;
        review.error = error?.message || "변경사항을 불러오지 못했습니다.";
        review.revision += 1;
        return false;
      } finally {
        review.promise = null;
        if (hasDOM && turn.characterId === state.characterId) {
          render({ reason: "workspace-review-loaded" });
        }
      }
    })();
    review.promise = operation;
    return operation;
  }

  function workspacePanel(turn) {
    let review = workspaceReviewStateFor(turn);
    if (
      hasDOM &&
      workspaceReviewIsManual(turn.workspace) &&
      !review.detail &&
      !review.loading &&
      !review.error
    ) {
      void loadWorkspaceReview(turn);
      review = workspaceReviewStateFor(turn);
    }
    const workspace = workspaceForDisplay(turn);
    const details = document.createElement("details");
    details.className = "workspace";
    details.open = ["awaiting_approval", "conflict", "failed"].includes(workspace.status);
    const summary = document.createElement("summary");
    const automatic = workspace.status === "awaiting_approval" && workspace.automaticApprovalPending === true;
    summary.textContent = automatic
      ? `${workspace.baseBranch || "main"} 자동 병합 중`
      : workspaceTitles[workspace.status] || workspace.status;
    const body = document.createElement("div");
    body.className = "workspace-body";
    const stateText = document.createElement("p");
    stateText.className = "workspace-state";
    stateText.textContent = `${workspace.branchName || "작업 브랜치"} → ${workspace.baseBranch || "main"}`;
    body.append(stateText);
    const manualReview = workspaceReviewIsManual(workspace);
    if (manualReview && review.loading) {
      const loading = document.createElement("p");
      loading.className = "workspace-review-status loading";
      loading.textContent = "변경사항 상세를 불러오는 중…";
      body.append(loading);
    } else if (manualReview && review.error) {
      const failure = document.createElement("div");
      failure.className = "workspace-review-error";
      const message = document.createElement("span");
      message.textContent = review.error;
      const retry = actionButton("다시 불러오기", "workspace-review-retry", "", turn.id);
      failure.append(message, retry);
      body.append(failure);
    }
    for (const file of (workspace.changedFiles || []).slice(0, 20)) {
      const row = document.createElement("div");
      row.className = "changed-file";
      const status = document.createElement("span");
      status.className = "file-status";
      status.textContent = file.status || "M";
      const path = document.createElement("span");
      path.className = "file-path";
      path.textContent = file.previousPath ? `${file.previousPath} → ${file.path}` : file.path;
      row.append(status, path);
      body.append(row);
    }
    if (review.detail && typeof workspace.diff === "string") {
      const diffDetails = document.createElement("details");
      diffDetails.className = "workspace-diff";
      diffDetails.open = review.inspected;
      const diffSummary = document.createElement("summary");
      diffSummary.textContent = workspace.diffTruncated === true
        ? "변경 diff · 일부 표시"
        : "변경 diff";
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = String(workspace.diff || "(변경 내용 없음)");
      pre.append(code);
      diffDetails.append(diffSummary, pre);
      diffDetails.addEventListener("toggle", () => {
        if (diffDetails.open) markWorkspaceDiffInspected(turn);
      });
      body.append(diffDetails);
    }
    if (workspace.errorMessage) body.append(messageBlock("turn-error", workspace.errorMessage));
    if (manualReview) {
      const canDecide = workspaceReviewCanDecide(turn);
      if (!canDecide && !review.loading && !review.error) {
        const hint = document.createElement("p");
        hint.className = "workspace-review-hint";
        hint.textContent = "변경 diff를 펼쳐 확인하면 승인·거절할 수 있습니다.";
        body.append(hint);
      }
      const actions = document.createElement("div");
      actions.className = "workspace-actions";
      const reject = actionButton("거절", "workspace-reject", "danger", turn.id);
      const approve = actionButton(
        workspace.status === "conflict" ? "다시 병합" : "승인 후 병합",
        "workspace-approve",
        "primary",
        turn.id,
      );
      reject.disabled = !canDecide;
      approve.disabled = !canDecide;
      actions.append(reject, approve);
      body.append(actions);
    }
    details.append(summary, body);
    return details;
  }

  function actionButton(title, action, style, turnId) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `action-button ${style || ""}`;
    button.dataset.action = action;
    button.dataset.turnId = turnId;
    button.textContent = title;
    return button;
  }

  function showsQuestionComposer(turn) {
    if (!turn.needsInput) return false;
    if (state.dismissedQuestionTurnIds.has(turn.id)) return false;
    if (state.hasPendingQuestionSnapshot) return state.pendingQuestionTurnIds.has(turn.id);
    const latestQuestion = turnsFor(turn.characterId)
      .filter((candidate) => candidate.needsInput)
      .at(-1);
    return latestQuestion?.id === turn.id;
  }

  function parseQuestion(text) {
    const normalized = String(text || "").replace(/\r\n/g, "\n");
    const lines = normalized.split("\n");
    let last = null;
    for (let start = 0; start < lines.length;) {
      const first = choiceLine(lines[start]);
      if (!first) { start += 1; continue; }
      const choices = [];
      let end = start;
      while (end < lines.length) {
        const choice = choiceLine(lines[end]);
        if (!choice) break;
        choices.push(choice);
        end += 1;
      }
      const numbered = choices[0]?.type === "numbered" && choices.every((item, index) => item.type === "numbered" && item.number === index + 1);
      const bullets = choices.length >= 2 && choices.every((item) => item.type === "bullet");
      if (numbered || bullets) last = { start, end, choices };
      start = Math.max(end, start + 1);
    }
    if (!last) return { question: normalized, choices: [] };
    const question = [...lines.slice(0, last.start), ...lines.slice(last.end)]
      .join("\n")
      .trim();
    if (!question) return { question: normalized, choices: [] };
    return { question, choices: last.choices };
  }

  function choiceLine(line) {
    const value = String(line || "").trim();
    let match = value.match(/^(\d+)[.)]\s+(.+)$/);
    if (match) {
      return { type: "numbered", number: Number(match[1]), title: stripMarkdown(match[2]), response: value };
    }
    match = value.match(/^[-*•]\s+(.+)$/);
    if (match) return { type: "bullet", title: stripMarkdown(match[1]), response: value };
    return null;
  }

  function stripMarkdown(text) {
    return String(text || "")
      .replace(/\[([^\]]+)]\([^)]*\)/g, "$1")
      .replace(/[*_~`#>]/g, "")
      .trim();
  }

  function questionComposer(turn) {
    const presentation = parseQuestion(turn.response);
    const panel = document.createElement("section");
    panel.className = "question-composer";
    panel.dataset.turnId = turn.id;
    const title = document.createElement("p");
    title.className = "question-title";
    title.textContent = presentation.choices.length > 0 ? "선택지에서 고르거나 직접 답변하기" : "답변하기";
    panel.append(title);
    if (presentation.choices.length > 0) {
      const choices = document.createElement("div");
      choices.className = "question-choices";
      presentation.choices.forEach((choice, index) => {
        const button = actionButton(`${index + 1}. ${choice.title}`, "answer-choice", "", turn.id);
        button.classList.add("choice-button");
        button.dataset.answer = choice.response;
        choices.append(button);
      });
      panel.append(choices);
    }
    const row = document.createElement("div");
    row.className = "answer-row";
    const input = document.createElement("textarea");
    input.className = "answer-input";
    input.rows = 2;
    input.placeholder = "답변을 입력하세요";
    input.dataset.turnId = turn.id;
    const send = actionButton("전송", "answer-send", "primary", turn.id);
    row.append(input, send);
    panel.append(row);
    return panel;
  }

  function responseFooter(turn) {
    const footer = document.createElement("footer");
    footer.className = "response-footer";
    const copy = iconButton("복사", "copy", turn.id, "⧉");
    const dislike = iconButton("싫어요", "feedback-disliked", turn.id, "♡̸");
    const like = iconButton("좋아요", "feedback-liked", turn.id, "♡");
    if (turn.feedback === "liked") like.classList.add("selected-like");
    if (turn.feedback === "disliked") dislike.classList.add("selected-dislike");
    footer.append(copy, dislike, like);
    return footer;
  }

  function iconButton(label, action, turnId, glyph) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "icon-action";
    button.dataset.action = action;
    button.dataset.turnId = turnId;
    button.textContent = glyph;
    button.setAttribute("aria-label", label);
    button.title = label;
    return button;
  }

  async function handleAction(event) {
    const target = event.target.closest("[data-action], .source-action, [data-open-link]");
    if (!target) return;
    event.preventDefault();

    if (target.matches("[data-open-link]")) {
      postBridge({ type: "openExternal", url: target.dataset.openLink });
      return;
    }
    if (target.classList.contains("source-action")) {
      const kind = target.dataset.sourceKind;
      const locator = target.dataset.locator;
      if (kind === "web" && /^https?:\/\//i.test(locator)) {
        postBridge({ type: "openExternal", url: locator });
      } else {
        postBridge({
          type: "openSource",
          sourceKind: kind,
          locator,
        });
      }
      return;
    }

    const action = target.dataset.action;
    const turnId = target.dataset.turnId;
    const turn = cacheFor(state.characterId).get(turnId);
    if (!turn) return;
    if (action === "copy") {
      try {
        await navigator.clipboard.writeText(turn.response);
        toast("복사했습니다.");
      } catch (_) {
        postBridge({ type: "copy", text: turn.response });
      }
      return;
    }
    if (action === "feedback-liked" || action === "feedback-disliked") {
      await updateFeedback(turn, action.endsWith("liked") && !action.endsWith("disliked") ? "liked" : "disliked", target);
      return;
    }
    if (action === "workspace-approve" || action === "workspace-reject") {
      await resolveWorkspace(turn, action === "workspace-approve" ? "approve" : "reject", target);
      return;
    }
    if (action === "workspace-review-retry") {
      await loadWorkspaceReview(turn, { force: true, renderLoading: true });
      return;
    }
    if (action === "answer-choice") {
      submitAnswer(turn, target.dataset.answer, target);
      return;
    }
    if (action === "answer-send") {
      const input = target.closest(".question-composer")?.querySelector(".answer-input");
      submitAnswer(turn, input?.value, target);
    }
  }

  async function updateFeedback(turn, selection, button) {
    const previous = turn.feedback || null;
    const next = previous === selection ? null : selection;
    turn.feedback = next;
    render({ reason: "feedback-optimistic" });
    button.disabled = true;
    if (state.transport === "native") {
      requestNative("feedback", { turnId: turn.id, feedback: next });
      return;
    }
    try {
      const result = await fetchJSON(`/api/turns/${encodeURIComponent(turn.id)}/feedback`, {
        method: "PUT",
        body: JSON.stringify({ feedback: next }),
      });
      turn.feedback = result.feedback ?? null;
      render({ reason: "feedback" });
    } catch (error) {
      turn.feedback = previous;
      render({ reason: "feedback-rollback" });
      toast(error.message, true);
    }
  }

  async function resolveWorkspace(turn, decision, button) {
    if (!workspaceReviewCanDecide(turn)) {
      toast("변경 diff를 펼쳐 확인한 뒤 처리해 주세요.", true);
      return;
    }
    const workspace = workspaceForDisplay(turn);
    const reviewTree = workspace?.reviewTree;
    if (decision === "approve" && !reviewTree) {
      toast("검토 버전을 찾을 수 없습니다.", true);
      return;
    }
    button.disabled = true;
    if (state.transport === "native") {
      requestNative("workspaceReview", { turnId: turn.id, decision, reviewTree: decision === "approve" ? reviewTree : null });
      return;
    }
    try {
      const path = `/api/workspace-reviews/${encodeURIComponent(turn.id)}/${decision}`;
      const result = await fetchJSON(path, {
        method: "POST",
        body: JSON.stringify(decision === "approve" ? { reviewTree } : {}),
      });
      if (result.workspace) turn.workspace = result.workspace;
      workspaceReviewStates.delete(turn.id);
      render({ reason: `workspace-${decision}` });
    } catch (error) {
      button.disabled = false;
      toast(error.message, true);
    }
  }

  function submitAnswer(turn, rawAnswer, button) {
    const answer = String(rawAnswer || "").trim();
    if (!answer) return;
    button.disabled = true;
    const panel = button.closest(".question-composer");
    if (panel) panel.querySelectorAll("button, textarea").forEach((control) => { control.disabled = true; });
    // 기존 CLI conversation/session을 Swift가 이어야 한다. 웹에서 새
    // conversationId를 만들거나 /api/agent-jobs를 직접 호출하지 않는다.
    const sent = postBridge({ type: "answerQuestion", text: answer });
    if (!sent) {
      if (panel) panel.querySelectorAll("button, textarea").forEach((control) => { control.disabled = false; });
      toast("앱과 연결되지 않아 답변을 보내지 못했습니다.", true);
      return;
    }
    state.dismissedQuestionTurnIds.add(turn.id);
    render({ reason: "answer-sent" });
  }

  function requestNative(type, payload) {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const sent = postBridge({ type, requestId, ...payload });
    if (sent) pendingRequests.set(requestId, { type, payload, createdAt: Date.now() });
    return sent ? requestId : null;
  }

  function actionResult(result) {
    const request = pendingRequests.get(result?.requestId);
    if (result?.requestId) pendingRequests.delete(result.requestId);
    if (result?.turn) mergeTurns([result.turn]);
    if (result?.ok === false) toast(result.error || "요청을 처리하지 못했습니다.", true);
    else if (request?.type === "answerQuestion") {
      state.pendingQuestionTurnIds.delete(request.payload.turnId);
      state.hasPendingQuestionSnapshot = true;
    }
    if (hasDOM) render({ reason: "native-action" });
  }

  async function refreshTurn(turnId) {
    if (!turnId || state.transport !== "direct") return;
    if (!shouldRefreshRealtime()) {
      state.hiddenDirty = true;
      return;
    }
    try {
      const result = await fetchJSON(`/api/live-feed/${encodeURIComponent(turnId)}`);
      const changed = mergeTurns([result.turn], { trackLive: true });
      if (changed.has(state.characterId)) render({ reason: "websocket-turn" });
    } catch (_) {
      scheduleRefresh();
    }
  }

  function scheduleRefresh() {
    if (!shouldRefreshRealtime()) {
      state.hiddenDirty = true;
      return;
    }
    if (state.refreshTimer) return;
    state.refreshTimer = setTimeout(async () => {
      state.refreshTimer = null;
      if (!shouldRefreshRealtime()) {
        state.hiddenDirty = true;
        return;
      }
      if (state.transport !== "direct") {
        postBridge({ type: "requestRefresh", characterId: state.characterId, limit: LIVE_LIMIT });
        return;
      }
      try {
        const body = await fetchJSON(`/api/live-feed?limit=${LIVE_LIMIT}`);
        const changed = applyLiveSnapshot(body.turns, { characterId: state.characterId });
        if (changed.has(state.characterId)) render({ reason: "websocket-refresh" });
      } catch (_) {
        // 실시간 연결은 다음 이벤트나 재연결 때 다시 시도한다.
      }
    }, 90);
  }

  function connectWebSocket() {
    if (!hasDOM || state.transport !== "direct" || !state.visible) return;
    if (state.socket && [WebSocket.OPEN, WebSocket.CONNECTING].includes(state.socket.readyState)) return;
    clearTimeout(state.socketRetryTimer);
    const base = new URL(state.baseURL || global.location.origin);
    const scheme = base.protocol === "https:" ? "wss:" : "ws:";
    const socketURL = `${scheme}//${base.host}/ws`;
    try {
      const socket = new WebSocket(socketURL);
      state.socket = socket;
      socket.addEventListener("open", () => { state.socketRetry = 0; });
      socket.addEventListener("message", (event) => {
        let payload;
        try { payload = JSON.parse(event.data); } catch (_) { return; }
        if (payload.type === "ready") scheduleRefresh();
        else if (payload.turnId) refreshTurn(payload.turnId);
        else scheduleRefresh();
      });
      socket.addEventListener("close", scheduleSocketReconnect);
      socket.addEventListener("error", () => socket.close());
    } catch (_) {
      scheduleSocketReconnect();
    }
  }

  function scheduleSocketReconnect() {
    if (state.transport !== "direct" || !state.visible) return;
    state.socket = null;
    const delay = Math.min(15_000, 500 * (2 ** state.socketRetry));
    state.socketRetry = Math.min(state.socketRetry + 1, 6);
    clearTimeout(state.socketRetryTimer);
    state.socketRetryTimer = setTimeout(connectWebSocket, delay);
  }

  function disconnectWebSocket() {
    clearTimeout(state.socketRetryTimer);
    state.socketRetryTimer = null;
    const socket = state.socket;
    state.socket = null;
    if (!socket) return;
    socket.removeEventListener("close", scheduleSocketReconnect);
    if ([WebSocket.OPEN, WebSocket.CONNECTING].includes(socket.readyState)) {
      socket.close();
    }
  }

  async function loadOlder() {
    const characterId = state.characterId;
    const paging = archiveFor(characterId);
    if (paging.loading || paging.exhausted) return;
    paging.loading = true;
    updateOlderButton();

    if (state.transport === "native") {
      requestNative("requestOlder", { characterId, offset: paging.offset, limit: ARCHIVE_PAGE_SIZE });
      return;
    }

    try {
      let pages = 0;
      let added = 0;
      while (!paging.exhausted && pages < 4 && added < 10) {
        const body = await fetchJSON(`/api/archive-feed?limit=${ARCHIVE_PAGE_SIZE}&offset=${paging.offset}`);
        const page = Array.isArray(body.turns) ? body.turns : [];
        paging.total = Number.isFinite(body.total) ? body.total : paging.total;
        paging.offset += page.length;
        paging.exhausted = page.length === 0 || paging.offset >= paging.total;
        const matching = page.filter((turn) => turn.characterId === characterId);
        const before = cacheFor(characterId).size;
        mergeArchiveTurns(matching);
        added += cacheFor(characterId).size - before;
        pages += 1;
      }
      render({ reason: "older" });
    } catch (error) {
      toast(error.message, true);
    } finally {
      paging.loading = false;
      updateOlderButton();
    }
  }

  function applyOlderPage(payload) {
    const characterId = payload.characterId || state.characterId;
    const paging = archiveFor(characterId);
    mergeArchiveTurns(payload.turns || []);
    paging.offset = Number.isFinite(payload.nextOffset) ? payload.nextOffset : paging.offset + (payload.turns?.length || 0);
    paging.exhausted = payload.hasMore === false;
    paging.loading = false;
    if (characterId === state.characterId && hasDOM) {
      render({ reason: "older-native" });
    }
  }

  function updateOlderButton() {
    if (!hasDOM) return;
    const paging = archiveFor(state.characterId);
    const button = elements().loadOlder;
    button.hidden = turnsFor(state.characterId).length === 0 || paging.exhausted;
    button.disabled = paging.loading;
    button.textContent = paging.loading ? "이전 대화 불러오는 중…" : "이전 대화 불러오기";
  }

  function toast(message, error = false) {
    if (!hasDOM) return;
    const node = elements().toast;
    clearTimeout(state.toastTimer);
    node.textContent = String(message || "");
    node.classList.toggle("error", error);
    node.hidden = false;
    state.toastTimer = setTimeout(() => { node.hidden = true; }, error ? 5_000 : 1_800);
  }

  function formatTime(value) {
    const date = new Date(value || 0);
    if (!Number.isFinite(date.getTime())) return "";
    return new Intl.DateTimeFormat("ko-KR", { hour: "2-digit", minute: "2-digit", hour12: true }).format(date);
  }

  function escapeHTML(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function safeDestination(raw) {
    const value = String(raw || "").trim().replace(/^<|>$/g, "");
    if (!/^https?:\/\//i.test(value)) return "";
    try {
      const url = new URL(value);
      if (!["http:", "https:"].includes(url.protocol)) return "";
      return value;
    } catch (_) {
      return "";
    }
  }

  function inlineMarkdown(raw) {
    const tokens = [];
    const stash = (html) => {
      const token = `\u0000TOKEN${tokens.length}\u0000`;
      tokens.push(html);
      return token;
    };
    let value = String(raw || "");
    value = value.replace(/\[!\[([^\]]*)]\((?:<([^>]+)>|([^\s)]+))\)]\((?:<([^>]+)>|([^\s)]+))\)/g, (_, alt, imageA, imageB, linkA, linkB) => {
      const destination = safeDestination(linkA || linkB || imageA || imageB);
      if (!destination) return escapeHTML(alt || "이미지");
      return stash(`<button type="button" class="image-action action-button" data-open-link="${escapeHTML(destination)}">${escapeHTML(alt || "이미지 열기")}</button>`);
    });
    value = value.replace(/!\[([^\]]*)]\((?:<([^>]+)>|([^\s)]+))\)/g, (_, alt, a, b) => {
      const destination = safeDestination(a || b);
      if (!destination) return escapeHTML(alt || "이미지");
      return stash(`<button type="button" class="image-action action-button" data-open-link="${escapeHTML(destination)}">${escapeHTML(alt || "이미지 열기")}</button>`);
    });
    value = value.replace(/`([^`\n]+)`/g, (_, code) => stash(`<code>${escapeHTML(code)}</code>`));
    value = value.replace(/\[([^\]\n]+)]\((?:<([^>]+)>|([^\s)]+))\)/g, (_, title, a, b) => {
      const destination = safeDestination(a || b);
      if (!destination) return title;
      return stash(`<a href="#" data-open-link="${escapeHTML(destination)}">${escapeHTML(title)}</a>`);
    });
    value = escapeHTML(value)
      .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
      .replace(/__([^_\n]+)__/g, "<strong>$1</strong>")
      .replace(/~~([^~\n]+)~~/g, "<del>$1</del>")
      .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
      .replace(/(^|[^_])_([^_\n]+)_/g, "$1<em>$2</em>");
    tokens.forEach((html, index) => {
      value = value.replace(`\u0000TOKEN${index}\u0000`, html);
    });
    return value;
  }

  function splitTableRow(line) {
    let value = String(line || "").trim();
    if (value.startsWith("|")) value = value.slice(1);
    if (value.endsWith("|")) value = value.slice(0, -1);
    return value.split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, "|").trim());
  }

  function isTableSeparator(line) {
    const cells = splitTableRow(line);
    return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
  }

  function renderMarkdown(markdown) {
    const lines = String(markdown || "").replace(/\r\n/g, "\n").split("\n");
    const output = [];
    let index = 0;
    while (index < lines.length) {
      const line = lines[index];
      if (!line.trim()) { index += 1; continue; }

      const fence = line.match(/^\s*```([^`]*)$/);
      if (fence) {
        const code = [];
        index += 1;
        while (index < lines.length && !/^\s*```\s*$/.test(lines[index])) {
          code.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        const language = fence[1].trim().replace(/[^a-zA-Z0-9_+-]/g, "");
        output.push(`<pre><code${language ? ` class="language-${escapeHTML(language)}"` : ""}>${escapeHTML(code.join("\n"))}</code></pre>`);
        continue;
      }

      if (index + 1 < lines.length && line.includes("|") && isTableSeparator(lines[index + 1])) {
        const headers = splitTableRow(line);
        index += 2;
        const rows = [];
        while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
          rows.push(splitTableRow(lines[index]));
          index += 1;
        }
        output.push(`<div class="table-scroll"><table><thead><tr>${headers.map((cell) => `<th>${inlineMarkdown(cell)}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr>${headers.map((_, cellIndex) => `<td>${inlineMarkdown(row[cellIndex] || "")}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`);
        continue;
      }

      const heading = line.match(/^(#{1,4})\s+(.+)$/);
      if (heading) {
        const level = heading[1].length;
        output.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
        index += 1;
        continue;
      }
      if (/^\s*(?:---+|___+|\*\*\*+)\s*$/.test(line)) {
        output.push("<hr>");
        index += 1;
        continue;
      }
      if (/^\s*>\s?/.test(line)) {
        const quoted = [];
        while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
          quoted.push(lines[index].replace(/^\s*>\s?/, ""));
          index += 1;
        }
        output.push(`<blockquote>${quoted.map(inlineMarkdown).join("<br>")}</blockquote>`);
        continue;
      }

      const listMatch = line.match(/^\s*(?:([-*+])|(\d+)[.)])\s+(.+)$/);
      if (listMatch) {
        const ordered = Boolean(listMatch[2]);
        const tag = ordered ? "ol" : "ul";
        const items = [];
        while (index < lines.length) {
          const item = lines[index].match(/^\s*(?:([-*+])|(\d+)[.)])\s+(.+)$/);
          if (!item || Boolean(item[2]) !== ordered) break;
          items.push(item[3]);
          index += 1;
        }
        output.push(`<${tag}>${items.map((item) => `<li>${inlineMarkdown(item)}</li>`).join("")}</${tag}>`);
        continue;
      }

      const paragraph = [line];
      index += 1;
      while (
        index < lines.length && lines[index].trim() &&
        !/^\s*```/.test(lines[index]) &&
        !/^(#{1,4})\s+/.test(lines[index]) &&
        !/^\s*(?:[-*+]|\d+[.)])\s+/.test(lines[index]) &&
        !/^\s*>\s?/.test(lines[index]) &&
        !(index + 1 < lines.length && lines[index].includes("|") && isTableSeparator(lines[index + 1]))
      ) {
        paragraph.push(lines[index]);
        index += 1;
      }
      output.push(`<p>${paragraph.map(inlineMarkdown).join("<br>")}</p>`);
    }
    return output.join("\n");
  }

  function configure(options = {}) {
    if (options.baseURL) state.baseURL = String(options.baseURL);
    else if (!state.baseURL && hasDOM) state.baseURL = global.location.origin;
    if (options.transport) state.transport = options.transport;
    if (Array.isArray(options.pendingQuestionTurnIds)) {
      state.pendingQuestionTurnIds = new Set(options.pendingQuestionTurnIds.map(String));
      state.hasPendingQuestionSnapshot = true;
    }
    if (Array.isArray(options.turns)) {
      mergeTurns(options.turns, { markLoaded: true, characterId: options.characterId || state.characterId });
    }
    if (options.characterId) {
      const next = String(options.characterId);
      if (state.initialized && next !== state.characterId) setCharacter(next);
      else state.characterId = next;
    }
    if (!hasDOM) return;
    state.initialized = true;
    if (loadedCharacters.has(state.characterId)) {
      render({ reason: "configure" });
      clearStatus();
    } else {
      loadInitial();
    }
    if (state.transport === "direct") connectWebSocket();
  }

  function setPendingQuestionTurnIds(ids) {
    state.pendingQuestionTurnIds = new Set((ids || []).map(String));
    // Swift는 답변 전송 실패 시 같은 pending ID를 복원한다. 이전 전송 시
    // 숨긴 상태를 함께 해제해야 사용자가 그 자리에서 다시 답할 수 있다.
    for (const turnId of state.pendingQuestionTurnIds) {
      state.dismissedQuestionTurnIds.delete(turnId);
    }
    state.hasPendingQuestionSnapshot = true;
    if (hasDOM) render({ reason: "pending-questions" });
  }

  function installDOMEvents() {
    const ui = elements();
    ui.feed.addEventListener("click", handleAction);
    ui.retry.addEventListener("click", () => loadInitial({ force: true }));
    ui.loadOlder.addEventListener("click", loadOlder);
    ui.jumpBottom.addEventListener("click", () => scrollToBottom(true));
    ui.scroller.addEventListener("scroll", () => {
      state.followBottom = distanceFromBottom(ui.scroller) <= BOTTOM_TOLERANCE;
      ui.jumpBottom.hidden = state.followBottom;
      if (
        state.didInitialPosition &&
        !state.followBottom &&
        ui.scroller.scrollTop <= 36 &&
        !archiveFor(state.characterId).loading
      ) loadOlder();
    }, { passive: true });
    global.addEventListener("officestra:visibility", (event) => {
      setVisibility(event.detail?.visible !== false);
    });
    document.addEventListener("visibilitychange", () => {
      setVisibility(!document.hidden);
    });
  }

  function setVisibility(visible) {
    const next = visible !== false;
    const wasVisible = state.visible;
    state.visible = next;
    if (!next && state.refreshTimer) {
      clearTimeout(state.refreshTimer);
      state.refreshTimer = null;
      state.hiddenDirty = true;
    }
    if (!next && state.transport === "direct") disconnectWebSocket();
    if (!next || wasVisible === next) return;
    if (!hasDOM) return;
    if (state.pendingRender || loadedCharacters.has(state.characterId)) {
      render({ reason: "visible" });
    }
    if (state.transport === "direct") {
      connectWebSocket();
      state.hiddenDirty = false;
      scheduleRefresh();
    } else {
      postBridge({
        type: "requestRefresh",
        characterId: state.characterId,
        limit: LIVE_LIMIT,
      });
    }
  }

  function shouldRefreshRealtime() {
    return state.visible && state.transport === "direct";
  }

  function signalReady() {
    if (state.readySent || !state.visible) return;
    state.readySent = true;
    postBridge({ type: "ready" });
  }

  function reconcileTurnId(localId, serverId, characterId = state.characterId) {
    const local = String(localId || "").trim();
    const server = String(serverId || "").trim();
    const owner = String(characterId || "").trim();
    if (!local || !server || !owner || local === server) return false;

    const target = cacheFor(owner);
    const optimistic = target.get(local);
    const persisted = target.get(server);
    const hadPendingQuestion = state.pendingQuestionTurnIds.delete(local);
    const hadDismissedQuestion = state.dismissedQuestionTurnIds.delete(local);

    target.delete(local);
    if (!persisted && optimistic) {
      target.set(server, { ...optimistic, id: server });
    }
    if (hadPendingQuestion) state.pendingQuestionTurnIds.add(server);
    if (hadDismissedQuestion) state.dismissedQuestionTurnIds.add(server);

    const liveIds = idSetFor(liveTurnIds, owner);
    if (liveIds.delete(local)) liveIds.add(server);
    const archiveIds = idSetFor(archivedTurnIds, owner);
    if (archiveIds.delete(local)) archiveIds.add(server);
    const workspaceReview = workspaceReviewStates.get(local);
    if (workspaceReview) {
      workspaceReviewStates.delete(local);
      workspaceReviewStates.set(server, workspaceReview);
    }

    const changed = Boolean(
      optimistic || persisted || hadPendingQuestion || hadDismissedQuestion,
    );
    if (changed && hasDOM && owner === state.characterId) {
      render({ reason: "reconcile-id" });
    }
    return changed;
  }

  const publicAPI = {
    configure,
    setCharacter,
    replaceTurns,
    upsertTurn(turn) {
      const normalized = normalizeTurn(turn);
      if (!normalized) return;
      mergeTurns([normalized]);
      loadedCharacters.add(normalized.characterId);
      if (hasDOM && normalized.characterId === state.characterId) render({ reason: "upsert" });
    },
    reconcileTurnId,
    removeTurn(turnId, characterId = state.characterId) {
      const id = String(turnId);
      cacheFor(characterId).delete(id);
      workspaceReviewStates.delete(id);
      if (hasDOM && characterId === state.characterId) render({ reason: "remove" });
    },
    setPendingQuestionTurnIds,
    applyOlderPage,
    actionResult,
    setVisibility,
    refresh: () => loadInitial({ force: true }),
    test: {
      escapeHTML,
      renderMarkdown,
      parseQuestion,
      normalizeTurn,
      mergeTurns,
      applyLiveSnapshot,
      mergeArchiveTurns,
      turnsFor,
      safeDestination,
      revisionFor,
      showsQuestionComposer,
      workspaceReviewIsManual,
      workspaceForDisplay,
      workspaceReviewCanDecide,
      loadWorkspaceReview,
      markWorkspaceDiffInspected,
      dismissQuestionTurn(turnId) {
        state.dismissedQuestionTurnIds.add(String(turnId));
      },
      reconcileKeyedChildren,
      shouldRefreshRealtime,
      turnTitleText,
      turnMetaDetails,
      activityDisplayText,
    },
  };

  global.OFFICESTRAConversation = publicAPI;

  if (hasDOM) {
    const start = () => {
      installDOMEvents();
      const query = new URLSearchParams(global.location.search);
      configure({
        characterId: query.get("characterId") || DEFAULT_CHARACTER,
        transport: query.get("transport") || "direct",
        baseURL: query.get("baseURL") || global.location.origin,
      });
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
    else start();
  }
})(typeof window !== "undefined" ? window : globalThis);
