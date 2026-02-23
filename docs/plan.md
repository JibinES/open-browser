A# Implementation Plan: Voice-Driven Browser Automation Agent

## Product Vision
A personal AI assistant that receives voice commands via Telegram, executes browser-based tasks (email, form filling, web actions), and reports back with confirmation — all running securely on self-hosted infrastructure.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│              JETSON ORIN NANO SUPER (8GB, 67 TOPS)              │
│                                                                 │
│  ┌─────────────┐    ┌──────────────┐                           │
│  │  Telegram    │◄──►│   OpenClaw    │◄──► GPT-OSS 120B API    │
│  │  Bot (grammY)│    │   Gateway     │     (Together AI)        │
│  └──────┬──────┘    └──────┬───────┘                           │
│         │                  │                                    │
│  ┌──────▼──────┐    ┌──────▼───────┐                           │
│  │ Moonshine   │    │   Chromium   │                           │
│  │ Base ASR    │    │   Browser    │                           │
│  │ (61M, local)│    │   via CDP    │                           │
│  └─────────────┘    └──────────────┘                           │
│                                                                 │
│  Network: Loopback only (127.0.0.1)                            │
│  Remote Access: Tailscale                                       │
│  Isolation: Podman rootless / dedicated user                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tool Selection & Justification

### Core Stack

| Tool | Role | Why This One |
|------|------|-------------|
| **OpenClaw** | Agent framework | Integrates LLM + browser + Telegram in one system. 68k stars, active community, production-tested. Eliminates weeks of custom orchestration. |
| **GPT-OSS 120B** | LLM backend (cloud API) | Open-weight MoE (5.1B active params). Apache 2.0 license. $0.04/M input tokens via Together AI. Cheapest high-quality reasoning model available. Cannot run locally on 8GB — API only. |
| **Moonshine Base** | ASR (local, on-device) | 61M params, ~200 MB RAM. 48% lower WER than Whisper Tiny. 5–15x faster inference. Purpose-built for edge. Runs entirely on Jetson GPU. MIT license. |
| **Chromium (CDP)** | Browser engine | OpenClaw's managed browser uses CDP for millisecond-level control. More reliable than Selenium WebDriver. Isolated profile keeps automation separate from personal browsing. |
| **Playwright** | Browser interaction layer | Used by OpenClaw under the hood for deterministic clicking/typing via aria-ref. More reliable than raw CDP for complex interactions. |
| **grammY** | Telegram bot framework | OpenClaw's built-in Telegram channel uses grammY. Fast, TypeScript-native, well-maintained. No need to interact with it directly. |
| **Jetson Orin Nano Super** | Hardware | 67 TOPS, 1024 CUDA cores, 8GB LPDDR5, 25W max. $249 one-time, ~$20/year power. Runs OpenClaw + Browser + ASR within memory budget. |
| **Tailscale** | Secure remote access | Zero-config encrypted overlay network. Avoids exposing any ports publicly. OpenClaw docs recommend it specifically. |
| **Podman (rootless)** | Container runtime | No root daemon, containers run as unprivileged user. If an attacker escapes the container, they have minimal host access. More secure than Docker for this use case. |

### Why NOT These Alternatives

| Rejected Tool | Reason |
|--------------|--------|
| **Selenium** | Slower (WebDriver protocol), no built-in snapshot/ref system, requires separate LLM integration |
| **Puppeteer** | Node.js only, less maintained than Playwright, no advantage over OpenClaw's built-in CDP |
| **LangChain** | Would require building the entire orchestration layer (Telegram + STT + browser + messaging) from scratch. OpenClaw does this natively. |
| **n8n / Make.com** | Low-code tools lack the flexibility for AI-driven browser automation. Can't handle dynamic multi-step flows. |
| **Docker** | Runs daemon as root. Podman rootless is more secure for agent workloads with browser access. |
| **Whisper Tiny** | 48% higher WER than Moonshine Base — more misheard commands, more failed tasks. Same memory class, worse accuracy. |
| **Whisper Small** | Good accuracy but 500 MB RAM vs Moonshine's 200 MB. On 8 GB Jetson, every MB counts. |
| **Parakeet TDT 0.6B** | Best accuracy (~5.5% WER) but needs ~2 GB RAM. Too heavy alongside browser on 8 GB. |
| **NVIDIA Riva** | 2–3 GB for ASR alone, complex setup. Overkill for voice command transcription. |
| **Claude API** | Higher quality reasoning but more expensive ($3/M input for Opus). GPT-OSS is 75x cheaper with good-enough tool calling. |
| **Local LLM (Ollama)** | 8 GB RAM can only fit ~3B param models. Not smart enough for complex browser automation planning. |

---

## Implementation Phases

### Phase 1: Foundation (Days 1–2)
**Goal**: OpenClaw running locally with Telegram bot connected

1. **Install OpenClaw**
   ```bash
   # macOS
   brew install openclaw
   # or Linux
   curl -fsSL https://get.openclaw.ai | bash
   ```

2. **Configure GPT-OSS 120B via Together AI**
   ```bash
   openclaw config set llm.provider openai-compatible
   openclaw config set llm.baseUrl https://api.together.xyz/v1
   openclaw config set llm.model openai/gpt-oss-120b
   # Set API key via env var
   export TOGETHER_API_KEY="your-together-ai-key"
   ```

3. **Create Telegram Bot**
   - Message @BotFather → `/newbot` → get token
   - `/setprivacy` → Disable (for group support later)

4. **Configure Telegram Channel**
   ```json5
   // ~/.openclaw/openclaw.json
   {
     channels: {
       telegram: {
         enabled: true,
         botToken: "${TELEGRAM_BOT_TOKEN}",  // use env var
         dmPolicy: "allowlist",
         allowFrom: ["YOUR_TELEGRAM_USER_ID"]
       }
     }
   }
   ```

5. **Start & Test**
   ```bash
   openclaw start
   # Send a text message to your bot on Telegram
   # Verify it responds
   ```

**Deliverable**: Bot responds to text messages via Telegram with Claude-powered answers.

---

### Phase 2: Browser Automation (Days 3–5)
**Goal**: Bot can execute browser tasks from text commands

1. **Enable Browser Tool**
   ```json5
   // ~/.openclaw/openclaw.json
   {
     browser: {
       enabled: true,
       defaultProfile: "automation",
       profiles: {
         automation: {
           cdpPort: 18800
         }
       },
       evaluateEnabled: false  // security: no arbitrary JS
     }
   }
   ```

2. **Install Playwright Browsers**
   ```bash
   openclaw browser install chromium
   ```

3. **Test Basic Browser Task**
   - Send via Telegram: "Open google.com and tell me what you see"
   - Verify: Bot opens browser, takes snapshot, describes page

4. **Test Multi-Step Workflow**
   - Send: "Go to wikipedia.org and search for 'OpenClaw'"
   - Verify: Bot navigates, types in search, reports results

5. **Add System Prompt for Confirmation Pattern**
   ```json5
   // ~/.openclaw/openclaw.json
   {
     systemPrompt: "Before executing any browser action that modifies data (sending emails, submitting forms, making purchases), ALWAYS: 1) Summarize what you're about to do 2) Ask the user to confirm with 'yes' before proceeding. For read-only actions (searching, viewing pages), proceed without confirmation."
   }
   ```

**Deliverable**: Bot can browse websites and perform multi-step tasks via Telegram commands.

---

### Phase 3: Voice Notes (Days 6–7)
**Goal**: Voice notes are transcribed and trigger browser tasks

1. **Verify Voice Transcription**
   - Send a voice note via Telegram to the bot
   - Verify: Bot receives transcribed text and responds

2. **Test Voice → Browser Pipeline**
   - Voice note: "Open my Gmail" (record and send)
   - Verify: Bot transcribes → opens Gmail in browser → reports status

3. **Handle Transcription Errors**
   - Add to system prompt: "If a voice transcription seems unclear or ambiguous, ask the user to clarify before proceeding. Common errors: names misspelled, URLs garbled, numbers misheard."

4. **Screenshot Confirmation**
   - After completing a browser task, have the agent take a screenshot and send it back
   - `browser screenshot` → attach to Telegram reply

**Deliverable**: Full voice note → browser action → screenshot confirmation pipeline working.

---

### Phase 4: Gmail & Email Workflow (Days 8–10)
**Goal**: Reliable email sending via Gmail in the browser

1. **Pre-authenticate Gmail Session**
   - Manually log into Gmail in the OpenClaw browser profile
   - Session cookies persist in the isolated Chromium profile
   ```bash
   openclaw browser start
   openclaw browser open https://mail.google.com
   # Manually log in, then close
   ```

2. **Build Email Workflow Prompt**
   Add to system prompt:
   ```
   When asked to send an email:
   1. Open https://mail.google.com
   2. Click Compose
   3. Fill in To, Subject, and Body fields
   4. Before clicking Send, take a screenshot and show the user
   5. Ask for confirmation: "Ready to send this email. Confirm?"
   6. Only click Send after user says yes
   7. Take a final screenshot showing "Message sent" confirmation
   ```

3. **Test End-to-End**
   - Voice note: "Send an email to john@example.com with subject Meeting Update and body The meeting is moved to 3 PM tomorrow"
   - Verify: Full flow with confirmation step

4. **Handle Edge Cases**
   - Gmail 2FA prompts → inform user, pause
   - Session expired → inform user to re-authenticate
   - Compose window didn't load → retry with timeout

**Deliverable**: Reliable voice-to-email pipeline with confirmation.

---

### Phase 5: Security Hardening (Days 11–13)
**Goal**: Production-ready secure deployment

1. **Container Setup (Podman)**
   ```bash
   # Create dedicated automation user
   sudo useradd -r -m -s /bin/bash openclaw-agent

   # Install Podman rootless
   sudo apt install podman

   # Run OpenClaw in rootless container
   podman run -d \
     --name openclaw \
     --security-opt no-new-privileges \
     -e TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
     -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
     -v openclaw-data:/home/openclaw/.openclaw:Z \
     ghcr.io/openclaw/openclaw:latest
   ```

2. **Network Isolation**
   ```json5
   // Ensure gateway is loopback only
   {
     gateway: {
       bind: "loopback",  // NEVER change to 0.0.0.0
       auth: {
         token: "${GATEWAY_AUTH_TOKEN}"
       }
     }
   }
   ```

3. **Tailscale for Remote Access**
   ```bash
   # Install Tailscale on VPS
   curl -fsSL https://tailscale.com/install.sh | sh
   tailscale up

   # Access OpenClaw remotely via Tailscale IP only
   # No ports exposed to public internet
   ```

4. **Tool Restrictions**
   ```json5
   {
     tools: {
       browser: { enabled: true },
       exec: { enabled: false },          // no shell access
       web_fetch: { enabled: true },       // for API calls
       web_search: { enabled: true },      // for lookups
       filesystem: { enabled: false }      // no file access
     },
     browser: {
       evaluateEnabled: false  // no arbitrary JS execution
     }
   }
   ```

5. **Credential Hygiene**
   - All secrets via environment variables (never in config files)
   - `.openclaw/` directory permissions: `chmod 700`
   - Rotate Telegram bot token periodically
   - Use scoped Anthropic API key (if available)

6. **Monitoring**
   ```bash
   # Follow logs for suspicious activity
   openclaw logs --follow

   # Set up log rotation
   # Monitor for: unexpected tool calls, new sender IDs, high API usage
   ```

**Deliverable**: Hardened deployment running in rootless container with network isolation.

---

### Phase 6: Polish & Extend (Days 14+)
**Goal**: Production quality and extensibility

1. **Custom Commands**
   ```json5
   {
     channels: {
       telegram: {
         customCommands: [
           { command: "email", description: "Send an email" },
           { command: "browse", description: "Open a website" },
           { command: "status", description: "Check system status" },
           { command: "screenshot", description: "Screenshot current browser" }
         ]
       }
     }
   }
   ```

2. **Error Recovery**
   - Add retry logic for browser timeouts (re-snapshot after 15s wait)
   - Session expiry detection → notify user to re-authenticate
   - Network failure → queue task and retry

3. **Task Templates** (in system prompt)
   - Email sending (Gmail)
   - Form filling (generic)
   - Web search and summarize
   - Screenshot and report
   - Login and check status

4. **Future Channels**
   - WhatsApp (OpenClaw native support)
   - Discord (OpenClaw native support)
   - Web UI (OpenClaw built-in)

---

## Configuration Reference

### Complete `openclaw.json` for This Project
```json5
{
  // LLM Configuration (GPT-OSS 120B via Together AI)
  llm: {
    provider: "openai-compatible",
    baseUrl: "https://api.together.xyz/v1",
    apiKey: "${TOGETHER_API_KEY}",
    model: "openai/gpt-oss-120b",  // MoE: 5.1B active params, $0.04/M input
    maxTokens: 8192
  },

  // Gateway (loopback only)
  gateway: {
    bind: "loopback",
    port: 18789,
    auth: {
      token: "${GATEWAY_AUTH_TOKEN}"
    }
  },

  // Telegram Channel
  channels: {
    telegram: {
      enabled: true,
      botToken: "${TELEGRAM_BOT_TOKEN}",
      dmPolicy: "allowlist",
      allowFrom: ["YOUR_TELEGRAM_USER_ID"],
      streaming: true,
      replyToMode: "first",
      textChunkLimit: 4000,
      customCommands: [
        { command: "email", description: "Send an email" },
        { command: "browse", description: "Browse a website" },
        { command: "status", description: "System status" }
      ]
    }
  },

  // Browser Configuration
  browser: {
    enabled: true,
    defaultProfile: "automation",
    profiles: {
      automation: {
        cdpPort: 18800,
        color: "#FF4500"
      }
    },
    evaluateEnabled: false
  },

  // Tool Access Control
  tools: {
    browser: { enabled: true },
    exec: { enabled: false },
    web_fetch: { enabled: true },
    web_search: { enabled: true },
    filesystem: { enabled: false }
  },

  // System Prompt
  systemPrompt: `You are a personal browser automation assistant. You receive tasks via Telegram (text or voice) and execute them using the browser.

RULES:
1. For ANY action that modifies data (sending emails, submitting forms, clicking buttons that change state), ALWAYS summarize what you will do and ask for confirmation before proceeding.
2. For read-only actions (viewing pages, searching), proceed without confirmation.
3. After completing a task, take a screenshot and send it as confirmation.
4. If a voice transcription seems unclear, ask for clarification.
5. If you encounter a login page or 2FA prompt, inform the user and wait.
6. Never share or display passwords, tokens, or sensitive data in messages.
7. If a task fails, explain what happened and suggest next steps.`
}
```

---

## Risk Register & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Voice misinterpretation sends wrong email | High | Mandatory confirmation step before send |
| Gmail session expires mid-task | Medium | Detect login page, notify user, pause |
| Container escape → host compromise | Critical | Podman rootless + dedicated VM + no exec tool |
| Prompt injection from malicious webpage | High | Isolated browser profile, evaluateEnabled: false |
| Bot token leaked → unauthorized access | Medium | Env vars, allowlist DM policy, token rotation |
| API costs spiral (Claude usage) | Low | Set maxTokens limit, monitor usage |
| OpenClaw vulnerability (0-day) | Medium | Auto-update enabled, monitor GitHub security advisories |

---

## Success Metrics

- [ ] Text command → browser action → confirmation works end-to-end
- [ ] Voice note → transcription → browser action → confirmation works
- [ ] Gmail email sending works with confirmation step
- [ ] Deployment runs in rootless container with loopback-only networking
- [ ] Only authorized Telegram user can interact with the bot
- [ ] System recovers gracefully from browser timeouts and session expiry
- [ ] Average task completion: under 60 seconds for simple tasks

---

## Estimated Timeline

| Phase | Duration | Outcome |
|-------|----------|---------|
| 1. Foundation | 2 days | Telegram bot connected, text responses working |
| 2. Browser | 3 days | Browser automation via text commands |
| 3. Voice | 2 days | Voice notes trigger browser tasks |
| 4. Gmail | 3 days | End-to-end email workflow |
| 5. Security | 3 days | Hardened production deployment |
| 6. Polish | Ongoing | Custom commands, error handling, extensibility |
| **Total MVP** | **~13 days** | Voice → email → confirmation, securely deployed |
