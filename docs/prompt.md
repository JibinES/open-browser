# Refined Prompt: Voice-Driven Browser Automation Agent via OpenClaw + Telegram

## Context
Build a personal AI-powered browser automation system where:
1. A user sends a **voice note** (or text) via **Telegram** describing a task (e.g., "Log into my Gmail and send an email to john@example.com saying the meeting is at 3 PM")
2. **OpenClaw** receives the message, transcribes voice (if needed), understands the intent, and executes the task using its **browser automation** capabilities
3. Once complete, OpenClaw sends a **confirmation message** back to the user on Telegram with a summary or screenshot of what was done

## What I Need

### 1. `research.md` — Deep Research Document
Research and document the following with key findings and reasoning:

- **OpenClaw Architecture**: How the Gateway, tools, channels, and browser modules connect. What is the message flow from Telegram voice note → task execution → confirmation?
- **Browser Automation**: How OpenClaw's browser tool works (CDP, snapshot/ref system, Playwright integration). How does it handle multi-step workflows like logging in, navigating, filling forms, and submitting?
- **Telegram Integration**: How voice notes are received and transcribed. Bot setup, DM policies, webhook vs long-polling, message threading, and reply-back mechanisms.
- **Security**: How to run this securely — network isolation (loopback + Tailscale), container deployment (Docker/Podman), credential management, access control, token scoping, and tool restrictions. What are the real risks of giving an AI agent browser access to authenticated sessions?
- **Alternatives Considered**: Why OpenClaw over Playwright alone, Selenium, Puppeteer, or custom LangChain agents? What does OpenClaw provide that a DIY approach doesn't?
- **Voice-to-Intent Pipeline**: How does voice transcription → intent parsing → action planning work? What models/services handle each step?

### 2. `plan.md` — Implementation Plan
A step-by-step blueprint covering:

- **Tool Selection**: Why each tool/framework was chosen (OpenClaw, Telegram Bot API, grammY, CDP, Playwright, etc.) with trade-off analysis
- **Architecture Diagram** (text-based): Show the full flow from voice input to task completion
- **Phase-by-Phase Build Plan**: From MVP (single browser task via text) to full product (voice notes, multi-step workflows, confirmation screenshots)
- **Security Hardening Plan**: Specific steps to lock down the deployment
- **Configuration Templates**: Example `openclaw.json` snippets for browser + Telegram setup
- **Edge Cases & Error Handling**: What happens when a task fails mid-execution? How to handle ambiguous commands? Retry logic?
- **Hosting & Deployment**: Self-hosted vs managed, recommended infrastructure (VPS + Docker + Tailscale)

## Constraints
- Must be self-hostable (no vendor lock-in)
- Must work with Claude as the backing LLM (via Anthropic API)
- Security is non-negotiable — this system will interact with real authenticated sessions (Gmail, etc.)
- Should be extensible to other messaging platforms (WhatsApp, Discord) later
- MVP should be achievable by a solo developer

## Success Criteria
- User sends "Send an email to X with subject Y and body Z" via Telegram voice note
- System logs into Gmail (using stored session/cookies), composes and sends the email
- User receives confirmation: "Email sent to X with subject Y" + optional screenshot
- All of this happens securely in an isolated environment
