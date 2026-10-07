# Implement reliable screenshot-conversation memory in the existing notes app

## 1. Task and scope

Modify the current repository. Sign in with ChatGPT and screenshot questions already work. Implement reliable, efficient follow-up context management in that existing flow. Do not rebuild authentication or replace the app.

The required user journey is:
Screenshot of a problem -> answer -> follow-up about an earlier formula -> additional screenshot of my solution -> more follow-ups -> quit and reopen -> continue the same problem accurately.

The app must preserve the evidence needed to answer, not merely tell the model to “remember.” This does not guarantee mathematically correct model output; make context delivery observable and testable.

Use Korean for progress updates, user-facing explanations, and the final report. Preserve the Korean UI strings specified below. Follow repository conventions for code and documentation.

Inspect AGENTS.md, README, uncommitted changes, actual platform/framework, storage, existing request builder, attachment pipeline, and tests. Trace one screenshot question and one follow-up from UI through persistence to the serialized network request. Reproduce the current omission if possible before fixing it. Do not assume this is Swift/iPad or Tauri/React without inspecting the repository.

Preserve existing notes, PDFs, annotations, login, model selection, rendering, and storage. Use additive, tested migrations where needed. Do not overwrite unrelated work, introduce a second authoritative database, deploy, publish, or purchase services.

Keep the existing official ChatGPT-plan-usage integration. Do not add API-key billing, browser automation, private endpoints, cookie extraction, a coding-agent runtime for math questions, vector databases, embeddings, external OCR, or a new cloud backend. Do not add AI calls for routing, titles, or routine per-turn summaries.

Give a short implementation plan, then implement and test. Do not stop at architecture recommendations or an unconnected demo.

## 2. Verify the transport contract

Read the current official documentation before changing request serialization. Record verification date and relevant compatibility decisions in docs/screenshot-context-memory.md:

https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
https://developers.openai.com/api/docs/guides/reasoning
https://developers.openai.com/api/docs/guides/prompt-caching
https://developers.openai.com/api/docs/guides/websocket-mode

The baseline checked on 2026-09-30 is: SIWC HTTP uses store:false, stream:true, and an input array carrying the required context. Do not use HTTP previous_response_id or conversation as persistent memory. Use instructions or supported developer messages, not explicit system-message items. Respect the SIWC-specific field allowlist instead of copying unrestricted API examples.

Treat model-specific replay, encrypted reasoning, caching options, WebSocket continuation, and provider compaction as separately verified capabilities. General API documentation is not proof that a feature is available on this account and route. Unverified optional features must not block the core fix.

## 3. Non-negotiable invariants

- One problem has one persistent thread, potentially with multiple screenshots. Do not start a new thread for every capture or mix every problem in a notebook into one conversation.
- Original messages and image snapshots are the source records. Summaries are replaceable derived records, never replacements for originals.
- The visible conversation is not proof of what was sent. Test the final serialized request.
- Required evidence must never disappear silently. Missing files, unsupported image input, or context overflow must produce an actionable state.
- App restart, reconnect, and model changes must not require server-side conversation storage to recover ordinary source context.
- No unrelated thread or account context may enter a request.
- No hidden per-turn summarization, automatic OCR request, or ambiguous network retry may consume additional usage.
- Local image IDs, paths, and response IDs alone are not evidence the model can read.

## 4. Extend the existing data model

Adapt these concepts to existing entities; do not create redundant tables just to match these names.

Thread:
Stable ID; document/note association; selected problem; active message lineage or revision; monotonically increasing context revision. Preserve the app's account/profile ownership boundaries.

Attachment:
Stable logical ID; immutable captured bytes; content hash; MIME type; dimensions; app-managed location; original document/page and document-space selection coordinates; capture revision; introducing message ID. Separate original bytes from any cached resized/encoded derivative. Never depend solely on a temporary file, expiring URL, or current PDF rendering.

Message:
Stable ID; thread ID; role; stable sequence/order; text; attachment references; optional reply target; selected quote and its source revision; status; revision/supersession information. Use existing branching behavior if available; otherwise define a minimal explicit edit policy so outdated answer branches cannot silently enter future context.

Assistant result:
Keep display Markdown separately from provider output items eligible for replay, with provider/model/schema provenance and completion status. Preserve only documented replay structures; never blindly resend an entire response object as input. Keep supported opaque reasoning artifacts opaque, separate from readable memory, and out of ordinary exports and diagnostics.

Problem record:
Exact source statements/formulas or user-approved transcription; source references; original-versus-corrected versions; user-pinned conditions and permitted methods. Distinguish “transcription confirmed by user” from “mathematically proven.” Store uncertainties and provenance rather than invented confidence scores.

Memory snapshot:
Version; covered message IDs/revisions; attachment/problem revisions; source fingerprint; structured summary; verification/review status; creation metadata. Its validity must be checkable against its source records.

Request run:
Request ID; thread/context revision; model/auth-session generation; immutable context manifest; state; response association; available usage metrics. A manifest identifies exact message revisions, attachment hashes, snapshot version, omissions, and selection reasons. Never include credentials.

Persist a user message and its attachment safely before starting inference. Use atomic database transitions and crash-safe file handling. Migration tests must prove old records remain readable. If legacy attachments cannot be recovered, mark them unavailable rather than inventing a replacement.

## 5. Build a deterministic ContextBuilder

Create a UI-independent, unit-testable component with explicit inputs and a typed success-or-action-required result. Separate semantic context planning from provider serialization. Repeated builds from the same source revision and options must select the same evidence.

### Short conversations: exact replay

While the complete active thread fits the configured input budget, send:

Stable application instructions
-> initial user message including its screenshot
-> supported replayable assistant output
-> subsequent user/assistant turns and their attachments in chronological order
-> current user question exactly once.

Do not summarize short threads or drop an image merely because the latest message contains only text. If the current user message was already persisted, do not append it a second time.

Keep original message roles and boundaries. Do not flatten everything into a developer instruction. Stable local metadata should not unnecessarily rewrite earlier message content.

### Long conversations: explicit compacted context

When exact replay exceeds the configured policy budget, compose a new context epoch from:

Stable application instructions
-> protected problem evidence, essential images, and exact pinned conditions
-> a valid older-history snapshot with provenance and uncertainty
-> recent complete conversation turns
-> explicitly referenced older messages/quotes and their required attachments
-> current question exactly once.

Preserve dependencies and meaningful chronology. Avoid duplicating an item already included. Treat local summaries and transcriptions as contextual data, not privileged instructions. Do not promote earlier assistant claims into established facts.

### Reference resolution

Implement “이 부분 질문” for selected answer text/formulas. Save the exact quote, message ID, and source revision. Include enough surrounding text and referenced attachments to make it meaningful, even outside the recent window. Preserve LaTeX exactly.

For “아까 두 번째 식” without an explicit selection, retain the relevant recent original answers rather than guessing an arbitrary old formula. Provide reply-target selection when ambiguity cannot be resolved locally. Do not add a model call merely to route the question.

### Replay compatibility

Use documented output-to-input conversion for the actual SDK/model, retaining supported ordering, phase fields, and opaque artifacts where applicable. Never replay rendered assistant text again if it is already represented in replayable output.

If model/route changes make an opaque item incompatible, rebuild a documented text-and-image context from local originals; do not reuse stale provider IDs or silently lose user-visible evidence. If tool-related items already exist, preserve required call/result groups. Do not introduce tools for this feature.

## 6. Images and transcription

Default to keeping the original problem image available to each rebuilt request. A screenshot is attached at its original message occurrence, not copied under every historical answer. If identical bytes were intentionally attached in different messages, preserve those semantic occurrences; file deduplication must not erase conversation meaning.

Reuse a stable encoded derivative when its original hash and encoding settings match. Resolve attachments to actual supported image input at serialization time. A local path, hash, or asset ID must never masquerade as image content.

Provide “원본 포함” and “확인된 텍스트 사용”. Text substitution is allowed only for an explicitly user-approved transcription covering the evidence needed for this question. Do not infer approval from silence or from an assistant repeating its own extraction.

Retain images when diagrams, handwriting, color, layout, or ambiguous symbols matter. Explicit references to an old image must restore that image. If relevance is uncertain, prefer keeping the source over aggressive omission. Preview which images will be sent; do not attach the entire notebook.

Do not silently replace an old snapshot when the PDF or annotation changes. A new screenshot or corrected transcription creates a new version. Keep supersession links and invalidate affected derived memory.

Do not add OCR as a prerequisite. An optional first-answer transcription may share the existing answer request, but its output remains unverified until reviewed. Avoid a new AI call just to extract text.

## 7. Selective compression, not repetitive summarization

Implement a user-triggered “대화 압축” action and an optional threshold-based automatic mode. Default automatic extra calls to off unless the app already has explicit consent covering them. Explain that compression itself uses the connected plan. Do not ask for repeated consent after a mode is deliberately enabled.

Decide when compression is useful from actual input-size estimates and policy limits, not every N turns. Ordinary short questions use one answer request and zero auxiliary requests.

Separate exact protected material from lossy discussion summaries. A snapshot may contain:

- Source references and coverage range.
- Current question/proof obligation.
- Approaches considered and their status.
- User corrections, including which earlier claims are superseded.
- Rejected approaches and reasons.
- Open questions and unresolved transcription ambiguities.
- References to older explanations worth retrieving verbatim.

Keep exact formulas, quantifiers, domains, theorem restrictions, and critical user corrections in protected source records, not only in generated prose. Record the provenance of purported conclusions; “the assistant asserted X” is not “X is proven.” Mathematical mistakes in user statements may be discussed, not silently rewritten as source material.

Summarize a bounded older range while keeping recent complete turns verbatim. Store its source revision fingerprint. Before activating a result, recheck the source revisions; an edit, correction, deletion, or changed branch during compression must prevent stale memory from being installed.

New source changes must invalidate affected snapshots and override obsolete interpretations. Unchanged snapshots should be reused, not regenerated on each follow-up. Prefer source-grounded chunk updates over repeatedly summarizing only the previous summary.

Validate schema, source references, protected-material coverage, and coverage ranges. Structural validation is not proof of semantic accuracy: label generated summaries accordingly and allow review/editing. Never pretend that a regex or second model call guarantees correctness.

A failed/cancelled/malformed compression result must leave original history intact. Do not run unlimited repair calls. Do not assume /responses/compact or structured-output options work through this SIWC route; gate provider-native features on verified support. A normal supported inference request plus local validation is an acceptable implementation.

## 8. Context budgets and graceful limits

Implement one configurable input-budget policy, not scattered constants or turn-count cutoffs. Separate:

- Verified model context capacity, when known.
- App-selected input budget.
- Local allowance for generated output/reasoning and estimation uncertainty.
- HTTP payload/image-size constraints.

A local allowance is not a provider-enforced output cap. Do not add unsupported request fields to implement it.

Use an appropriate local tokenizer when available and verified; otherwise label estimates as estimates. Account for images and opaque items separately instead of applying a text-character heuristic to the entire request. Do not add a network inference call just to estimate every prompt. Never invent model capacities or remaining subscription credits.

Try full replay first. If it exceeds policy, use a valid compacted plan or offer authorized compression and context selection. Make any omitted evidence visible. If the protected minimum still cannot fit, return a clear action-required result and preserve the draft; do not silently truncate the original question or send an invalid payload.

Any conservative initial budget/minimum-recent-window values are app defaults, not universal provider limits. Document and test them as configurable decisions.

## 9. Lifecycle, concurrency, and security

Freeze the selected context manifest and source revisions for each request before transmission. A later annotation edit must not mutate the in-flight image or let its response overwrite a newer conversation state.

Serialize requests per thread or explicitly queue them. Associate every stream event with request/thread/context/auth generation. Reject stale events after cancellation, logout, model switch, or thread switch.

Persist partial answers and distinguish completed, failed, incomplete, cancelled, and interrupted. Only the documented terminal completion signal marks an answer complete. Do not silently treat a partial answer as a finished proof in subsequent context; include it only with explicit incomplete provenance when needed.

After restart, restore images, source links, messages, and drafts; mark formerly active requests interrupted. Do not auto-resend. Local duplicate prevention is not a claim of server-wide exactly-once execution. Retry only by explicit user action or a narrowly documented safe pre-generation recovery path.

Preserve credential storage and redaction. Diagnostics must not contain tokens, cookies, base64 images, opaque reasoning payloads, or full private conversation text by default. Context previews are local user-visible views, not telemetry. Backups must preserve attachment links without including credentials.

## 10. UI and observability

Integrate into the existing question panel without redesigning the app:

- Continue an existing problem or choose “새 문제”; attach a solution capture with “현재 문제에 추가”.
- “이 부분 질문” with a visible quote/reply target.
- “조건 고정” for exact user-selected conditions and learning restrictions.
- “맥락 보기” showing included images/messages, reply targets, active memory coverage, omissions, and estimated size.
- “대화 압축” with status, last covered range, review, and failure recovery.
- Reopen the originating page/region from the thread.

Indicate source-image versus approved-text mode. Do not display “원본 포함” unless the request actually includes that image, or a verified same-connection continuation demonstrably retains it. In continuation mode, distinguish retained connection context from bytes transmitted in this turn.

Add a redacted development manifest view with message IDs, roles/order, attachment hashes, selection reasons, snapshot version, transport, and size estimates. Let developers inspect decoded test fixtures, not production credentials.

Collect locally available metrics: answer versus compression request counts, input bytes, image count, estimated tokens, reported usage/cache fields when provided, and time to first answer text. Keep estimates separate from provider-reported values. Do not invent cache hits or convert general API prices into ChatGPT subscription savings.

## 11. Optimization comes after correctness

Keep stable instructions and unchanged conversation prefixes stable; append new turns. Avoid timestamps or changing request IDs in the model-facing prefix. Preserve deterministic image encoding. Do not inflate prompts just to chase cache thresholds or claim a guaranteed hit. Compression changes the prefix; measure the tradeoff rather than assuming it always saves usage.

Do not rely on prompt caching as a memory store or as permission to omit required input. Add cache-specific fields only when verified for the actual SIWC route/model.

WebSocket continuation is optional and must not delay the core HTTP fix. Implement it only after persistence and exact replay pass tests, behind a capability/feature gate. Keep existing HTTP/SSE working.

Bind continuation to the same authenticated connection, thread lineage, model/configuration, and last valid response. On disconnect, restart, incompatible change, or context-epoch reset, rebuild from local source context. A previous-response ID must never be treated as durable storage.

On a documented previous_response_not_found rejection before generation, a single bounded full-context fallback may reuse the pending user turn without duplicating it. After ambiguous disconnect or any potentially accepted generation, do not blindly replay. Explain recovery and require explicit retry. Test these separately.

## 12. Required automated acceptance tests

Assert actual serialized requests and persisted records, not only UI text. Use deterministic local fixtures and a mock transport by default; never spend live-plan usage in ordinary CI.

1. First capture I1/question U1, answer A1, then U2: the follow-up contains readable I1, U1, A1, and U2 in correct order; U2 appears once. Zero compression/OCR calls.
2. Add solution screenshot I2 to that problem: retain I1/I2 with correct message provenance. Starting another problem shares neither images nor messages accidentally.
3. Reply to a formula outside the recent window after compression: restore its exact LaTeX, source revision, necessary surrounding text, and referenced image.
4. Correct “n^3” to “n^2”: preserve the correction and original evidence, invalidate affected memory, and never present the obsolete exponent as the current source.
5. Preserve a pinned restriction such as “로피탈 정리는 사용하지 않음” through compression, restart, and model change.
6. Diagram reference such as “빨간 선”: include the relevant original image despite an available text transcription. Unreviewed transcription never authorizes image removal.
7. Missing/corrupt legacy attachment: actionable error, retained draft, no fabricated image or silent text-only downgrade.
8. Cold restart with no server session: rebuild the same source context. An interrupted answer remains partial and is not auto-retried.
9. Send, then edit the note/switch thread/cancel: freeze submitted image and context; late events cannot mutate another/newer request.
10. Budget overflow: valid snapshot plus required sources fits, or return action required. Never silently drop pinned conditions, reply targets, or current images.
11. Edit/delete a covered message or change branch during compression: reject stale snapshot installation. Failed compression leaves originals untouched.
12. Supported output replay preserves required provider structure without duplicating assistant text. Incompatible opaque artifacts trigger source-based reconstruction, not credential/ID reuse.
13. Repeated builds preserve stable ordering/encoding. Local blob deduplication does not erase intentional attachment occurrences.
14. Migrations preserve existing notes/conversations. Diagnostics/exports are free of credentials and opaque artifacts.
15. When WebSocket is enabled: same-connection continuation, reconnect rebuild, rejected-ID fallback, and ambiguous-disconnect no-auto-retry each have separate tests.

Add an optional, explicitly run live checklist for actual model behavior. Use the same model/settings for comparisons, and report observed results without claiming that passing serialization tests proves mathematical accuracy or permanent memory.

## 13. Implementation order and final report

Implement in this order:
A. Reproduce the follow-up defect; persist source images/messages; exact replay; first regression test.
B. Reply references, immutable request manifests, restart recovery, and local context preview.
C. Budget handling, protected problem records, selective compression, and invalidation tests.
D. Measure efficiency; add optional verified replay/caching/WebSocket enhancements only after A-C work.

Reuse existing abstractions. Keep ContextBuilder, persistence, transport adaptation, and UI separately testable without inventing a large generic agent framework. Run available builds, type checks, lint, migration tests, and relevant regression tests.

Finish with a Korean report covering:
- Root cause found and the exact request-path changes.
- Implemented behavior and changed files.
- Data/migration impact and defaults for extra AI calls.
- Commands actually run and their results.
- A sanitized example follow-up context manifest.
- Steps to test screenshot -> follow-up -> quote question -> correction -> restart.
- What is mocked, what was verified live, and any unsupported optional features.

Do not claim tests or live inference succeeded unless actually run. Do not mark the memory defect fixed merely because a system prompt says to remember. Begin in the current repository now.
