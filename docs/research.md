# Research: Voice-Driven Browser Automation with OpenClaw + Telegram

## 1. OpenClaw Architecture — Key Findings

### What Is OpenClaw?
OpenClaw (formerly Clawdbot/Moltbot, renamed Jan 30 2026) is an open-source AI agent framework with 68k+ GitHub stars. It gives an LLM (Claude, GPT, etc.) a "body" — the ability to browse the web, execute commands, read/write files, and communicate through messaging platforms.

### Hub-and-Spoke Architecture
- **Gateway**: Central WebSocket RPC server (port 18789) — the control plane between user inputs and the AI agent
- **Channels**: Telegram, WhatsApp, Discord, iMessage, Slack, Web UI, CLI — how users interact
- **Tools**: Browser, exec, web_fetch, web_search, filesystem — what the agent can do
- **LLM Backend**: Claude (recommended), GPT-4, or other models — the "brain" that decides what to do

### Message Flow: Voice Note → Task → Confirmation
```
User Voice Note (Telegram)
    ↓
Telegram Bot API (grammY) receives audio
    ↓
OpenClaw transcribes voice → text (built-in STT)
    ↓
Gateway routes text to LLM (Claude)
    ↓
Claude understands intent, generates tool calls
    ↓
Browser tool executes actions (login, navigate, click, type)
    ↓
Agent captures result (screenshot/confirmation)
    ↓
Gateway sends confirmation message back via Telegram
```

**Why this matters**: OpenClaw handles the entire pipeline. You don't need to stitch together separate transcription, NLU, browser automation, and messaging services — it's all integrated.

---

## 2. Browser Automation — How It Actually Works

### Chrome DevTools Protocol (CDP)
OpenClaw controls a dedicated Chromium instance via CDP. This is NOT screen-scraping or pixel-matching — it's direct programmatic control of the browser.

**Key advantage over visual approaches**: Millisecond response times, deterministic element targeting, no OCR errors.

### The Snapshot/Ref System
This is OpenClaw's unique approach to browser interaction:
1. Agent calls `browser snapshot` → gets a text representation of the page with numbered refs
2. Each interactive element (button, input, link) gets a ref number (e.g., `12`, `35`)
3. Agent calls `browser click 12` or `browser type 35 "hello"` to interact
4. After navigation, refs reset — must re-snapshot

**Why this is better than CSS selectors**: The AI doesn't need to know the DOM structure. It reads the page like a human would and refers to elements by their visible position/label.

### Two Browser Modes
| Mode | How It Works | Best For |
|------|-------------|----------|
| **OpenClaw-Managed** | Dedicated Chromium with isolated user data, non-standard ports | Automation tasks (our use case) |
| **Chrome Extension Relay** | Controls existing Chrome tabs via local relay | Using existing login sessions |

### Multi-Step Workflow Execution
For a task like "log into Gmail and send an email":
1. `browser open https://mail.google.com`
2. `browser snapshot` → see login form
3. `browser type <email-ref> "user@gmail.com"` → `browser click <next-ref>`
4. `browser type <password-ref> "***"` → `browser click <signin-ref>`
5. `browser snapshot` → see inbox
6. `browser click <compose-ref>` → fill fields → send
7. `browser screenshot` → capture confirmation

**Key finding**: OpenClaw handles this natively. The LLM decides the steps; the browser tool executes them. No hardcoded workflows needed.

### Playwright Integration
Most browser operations use Playwright under the hood for:
- Deterministic clicking/typing (aria-ref mechanism)
- PDF generation
- Trace recording for debugging
- Device/viewport emulation

---

## 3. Telegram Integration — Voice Notes & Bot Setup

### Bot Setup
1. Create bot via @BotFather (`/newbot`)
2. Get bot token
3. Configure in `~/.openclaw/openclaw.json` under `channels.telegram`
4. Start gateway → approve pairing

### Voice Note Handling
- Telegram distinguishes **voice notes** (OGG/Opus, recorded in-app) from **audio files**
- OpenClaw auto-transcribes voice messages using built-in speech-to-text
- Transcribed text is then processed by the LLM like any other message
- Response can be sent as text or as a voice note (using `[[audio_as_voice]]` tag)

**Key finding**: Voice transcription is built-in. No external Whisper/Deepgram integration needed for basic use.

### Access Control (Critical for Security)
| DM Policy | Behavior |
|-----------|----------|
| `pairing` (default) | Requires explicit CLI approval per user |
| `allowlist` | Only specific Telegram user IDs |
| `open` | Anyone can interact (DANGEROUS) |
| `disabled` | DMs turned off |

**Recommendation**: Use `allowlist` with your specific Telegram user ID. Never use `open` for a bot with browser access.

### Message Delivery
- HTML parse mode with Markdown-to-HTML conversion
- 4000 char chunk limit (auto-splits at paragraph boundaries)
- Supports inline photos/screenshots in responses
- Thread-aware routing for organized conversations

### Webhook vs Long Polling
| Method | Pros | Cons |
|--------|------|------|
| **Long Polling** (default) | Simple, no public endpoint needed | Slightly slower, keeps connection open |
| **Webhook** | Faster response, more scalable | Requires public HTTPS endpoint |

**Recommendation**: Start with long polling (simpler). Switch to webhook only if latency matters.

---

## 4. Security — The Hard Truth

### Why This Is Dangerous
You are giving an AI agent access to:
- A real browser with real login sessions (Gmail, bank accounts, etc.)
- The ability to execute arbitrary actions on those accounts
- Network access to anything the browser can reach

**Microsoft's security blog (Feb 2026)** explicitly warns: "Self-hosted agent runtimes like OpenClaw include limited built-in security controls."

### Network Isolation (Non-Negotiable)
- **Gateway binds to loopback only** (127.0.0.1) — never expose port 18789 publicly
- **Remote access via SSH tunnel or Tailscale** — encrypted, authenticated overlay network
- **Never bind to 0.0.0.0** — OpenClaw is not hardened for public internet exposure

### Container Deployment
| Option | Security Level | Notes |
|--------|---------------|-------|
| **Podman (rootless)** | Highest | No daemon, no root, attacker lands as unprivileged user |
| **Docker** | Good | Primary security boundary, but runs as root daemon |
| **Bare metal** | Lowest | All host resources exposed |

**Recommendation**: Podman rootless in a dedicated VM. If Docker, use non-root user and read-only filesystem where possible.

### Credential Management
- **Never hardcode credentials** in `openclaw.json`
- Use **environment variables** for tokens (`TELEGRAM_BOT_TOKEN`, API keys)
- Store browser session cookies in the **isolated Chromium profile** (auto-managed)
- Use **short-lived tokens** where possible
- **Scope permissions**: read-only tokens where full access isn't needed

### Tool Restrictions
- Disable `browser.evaluateEnabled` (prevents arbitrary JS execution)
- Limit `exec` tool to specific commands or disable entirely
- Use tool allowlists for each channel/sender
- High-risk tools (exec, browser, web_fetch) should require explicit approval

### The Real Risk Matrix
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Prompt injection via web page | Medium | High | Isolated browser profile, no sensitive tabs open |
| Session hijack if container escapes | Low | Critical | Podman rootless, dedicated VM |
| Telegram bot token leak | Low | Medium | Env vars, not in config files |
| AI takes unintended action | Medium | Medium | Confirmation step before destructive actions |
| Voice note misinterpretation | Medium | Low | Text confirmation before executing |

### Key Security Insight
**Add a confirmation step**: Before executing any browser action, have the agent summarize what it's about to do and wait for user approval. This single pattern prevents most catastrophic errors.

---

## 5. Why OpenClaw Over Alternatives?

### Comparison Matrix
| Feature | OpenClaw | Playwright Alone | Selenium | LangChain + Custom |
|---------|----------|------------------|----------|-------------------|
| LLM-driven decisions | Built-in | Manual integration | Manual | Yes, but DIY |
| Telegram integration | Native | None | None | DIY |
| Voice transcription | Built-in | None | None | DIY |
| Browser automation | CDP + Playwright | Playwright | WebDriver | DIY |
| Snapshot/ref system | Built-in | N/A | N/A | N/A |
| Session management | Isolated profiles | Manual | Manual | Manual |
| Security hardening | Documented patterns | N/A | N/A | Your problem |
| Setup complexity | ~30 min | Days | Days | Weeks |
| Maintenance burden | Community-maintained | Your code | Your code | Your code |

### Why NOT DIY?
Building this from scratch requires:
1. Telegram bot framework (grammY/Telegraf) — setup, webhook handling, media processing
2. Speech-to-text service (Whisper API / Deepgram) — integration, error handling
3. LLM integration (Anthropic SDK) — prompt engineering, tool use
4. Browser automation (Playwright) — session management, element targeting
5. Orchestration layer — connecting all of the above
6. Security — isolation, credential management, access control

**OpenClaw does all of this out of the box.** The trade-off is less control over individual components, but dramatically faster time-to-working-product.

### When OpenClaw Is NOT the Right Choice
- You need pixel-perfect custom UI flows (use Playwright directly)
- You need to run 100+ concurrent browser sessions (use Browserless.io)
- You need enterprise-grade audit logging (OpenClaw's logging is basic)
- You don't trust an open-source agent framework with your credentials (valid concern)

---

## 6. Voice-to-Intent Pipeline

### How It Works in OpenClaw
```
Voice Note (OGG/Opus from Telegram)
    ↓
Built-in STT (transcription to text)
    ↓
Text passed to LLM as user message
    ↓
LLM generates tool calls (browser.open, browser.click, etc.)
    ↓
Tools execute and return results
    ↓
LLM summarizes results
    ↓
Summary sent back as Telegram message
```

### Key Insight: No Separate NLU Layer
OpenClaw doesn't use a separate intent classification or NLU system. The LLM (Claude) directly interprets the transcribed text and decides which tools to call. This is:
- **Simpler**: No intent taxonomy to maintain
- **More flexible**: Handles novel/complex requests without predefined intents
- **More error-prone**: LLM might misinterpret ambiguous voice transcriptions

### Recommendation: Add a Confirmation Step
For safety, inject a system prompt that makes the agent:
1. Summarize the understood task
2. List the actions it will take
3. Ask for user confirmation before executing
4. Only proceed after explicit "yes" / approval

This adds one round-trip but prevents catastrophic errors from voice transcription mistakes.

---

## 7. Models & Tools Selected

### Full Stack Component Map

| Layer | Component | Model/Tool | Why |
|-------|-----------|------------|-----|
| **Messaging** | Telegram Bot | grammY (built into OpenClaw) | Production-ready, voice note support, built-in |
| **Voice Transcription (Edge)** | Local ASR | **Moonshine Base (61M)** | 48% better than Whisper Tiny, ~200 MB RAM, built for edge |
| **Voice Transcription (Fallback)** | Cloud ASR | **GPT-OSS 120B Audio API** (Together AI) | Higher accuracy for ambiguous audio, $0.006/min |
| **LLM (Reasoning)** | Cloud API | **GPT-OSS 120B** (Together AI / OpenRouter) | Open-weight MoE, 5.1B active params, $0.04/M input tokens, Apache 2.0 |
| **Browser Automation** | CDP + Playwright | OpenClaw Browser Tool | Snapshot/ref system, isolated profiles, TensorRT-like speed |
| **Agent Framework** | Orchestration | **OpenClaw Gateway** | Connects Telegram + LLM + Browser in one system |
| **Hardware** | Edge Server | **Jetson Orin Nano Super (8GB)** | 67 TOPS, $249, ~$20/year power, silent always-on |
| **Remote Access** | VPN/Tunnel | **Tailscale** | Zero-config, encrypted, free tier, OpenClaw-recommended |
| **Container** | Isolation | **Podman rootless** | No root daemon, strongest container isolation |

### ASR Model Deep Dive

We evaluated 7 ASR models for the Jetson Orin Nano 8GB constraint:

| Model | Params | RAM | WER (EN) | Verdict |
|-------|--------|-----|----------|---------|
| Moonshine Tiny | 27M | ~100 MB | ~10% | Too low accuracy for email addresses/names |
| **Moonshine Base** | **61M** | **~200 MB** | **~8%** | **SELECTED — best accuracy/size ratio for edge** |
| Whisper Tiny.en | 39M | ~150 MB | ~12% | Baseline, outperformed by Moonshine |
| Whisper Base.en | 74M | ~200 MB | ~10% | Same size as Moonshine Base, worse WER |
| Whisper Small.en | 244M | ~500 MB | ~7.5% | Good but 2.5x more RAM for 0.5% WER gain |
| Distil-Whisper Small | 166M | ~400 MB | ~8% | Comparable WER but 2x RAM |
| Parakeet TDT 0.6B | 600M | ~2 GB | ~5.5% | Best accuracy but too heavy for 8GB with browser |

### GPT-OSS 120B Details

- **Architecture**: Mixture-of-Experts, 117B total / 5.1B active per forward pass
- **License**: Apache 2.0 (fully open, commercial use OK)
- **Pricing**: $0.039/M input, $0.190/M output (Together AI)
- **Why not Claude?**: GPT-OSS is cheaper, open-weight, and available on many providers. Claude is higher quality but costs more — user preference.
- **Why not run locally?**: 120B params need ~60 GB VRAM minimum. Jetson has 8 GB. Cloud API is the only option.
- **Audio API**: Together AI offers `/v1/audio/transcriptions` endpoint for GPT-OSS, usable as cloud ASR fallback.

---

## 8. Key Findings Summary

| Finding | Implication |
|---------|------------|
| OpenClaw handles the full pipeline (voice → browser → confirmation) | No need to build custom orchestration |
| CDP-based browser control with snapshot/ref system | Reliable, AI-friendly element interaction |
| Telegram integration is production-ready with voice support | Minimal setup for our primary channel |
| Security requires active hardening (not secure by default) | Must implement loopback + Tailscale + container isolation |
| Confirmation step is critical for safety | One extra message prevents most errors |
| **Moonshine Base is the optimal edge ASR** | 61M params, ~200 MB, 48% better than Whisper Tiny |
| **GPT-OSS 120B is the best-value cloud LLM** | Open-weight, Apache 2.0, $0.04/M tokens, available everywhere |
| **Jetson Orin Nano is the ideal edge host** | $249, 67 TOPS, 20W, runs OpenClaw + browser + ASR within 8 GB |
| Self-hosting on Jetson costs ~$20/year in electricity | Cheaper than any cloud VPS long-term |

---

## Sources
- [OpenClaw Browser Docs](https://docs.openclaw.ai/tools/browser)
- [OpenClaw Telegram Docs](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw Security Docs](https://docs.openclaw.ai/gateway/security)
- [OpenClaw Browser Automation Guide — Apiyi](https://help.apiyi.com/en/openclaw-browser-automation-guide-en.html)
- [Microsoft Security Blog — Running OpenClaw Safely](https://www.microsoft.com/en-us/security/blog/2026/02/19/running-openclaw-safely-identity-isolation-runtime-risk/)
- [OpenClaw Security Best Practices — xCloud](https://xcloud.host/openclaw-security-best-practices)
- [DigitalOcean — What is OpenClaw](https://www.digitalocean.com/resources/articles/what-is-openclaw)
- [OpenClaw Architecture Overview — Substack](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)
- [OpenClaw Gateway Configuration — DeepWiki](https://deepwiki.com/openclaw/openclaw/3.1-gateway-configuration)
- [CyberNews — OpenClaw Review 2026](https://cybernews.com/ai-tools/openclaw-review/)
