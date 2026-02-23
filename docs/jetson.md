# Jetson Orin Nano Implementation Guide
## Running the Voice-Driven Browser Automation Stack on Edge Hardware

---

## 1. Why Jetson Orin Nano?

| Factor | Jetson Orin Nano Super (8GB) | Cloud VPS ($20/mo) | Mini PC |
|--------|------------------------------|---------------------|---------|
| **Cost (annual)** | ~$20 electricity | ~$240 | ~$80 electricity |
| **Hardware cost** | $249 one-time | $0 | $300–600 |
| **AI Performance** | 67 TOPS, 1024 CUDA cores | No GPU (usually) | No GPU (usually) |
| **Power** | 15–25W | N/A | 65–120W |
| **Privacy** | 100% local, your network | Cloud provider sees traffic | Local |
| **Always-on** | Silent, fanless options | Always on | Fan noise |
| **ARM64 support** | Native | x86_64 | x86_64 |

**Bottom line**: $249 upfront, ~$20/year to run 24/7. Perfect as a dedicated OpenClaw gateway with on-device ASR. The 8GB RAM is the constraint we design around.

### Jetson Orin Nano Super Specs
- **GPU**: 1024 CUDA cores + 32 Tensor Cores (Ampere)
- **CPU**: 6-core Arm Cortex-A78AE @ 1.7 GHz
- **RAM**: 8 GB LPDDR5 (shared CPU/GPU)
- **Memory Bandwidth**: 102 GB/s
- **AI Performance**: 67 TOPS (INT8)
- **Power**: 7W / 15W / 25W modes
- **Storage**: M.2 NVMe slot (add 256GB+ SSD)
- **JetPack**: 6.2+ (L4T 36.x, Ubuntu 22.04)

---

## 2. Memory Budget (The Critical Constraint)

We have **8 GB shared** between CPU and GPU. Every byte counts.

| Component | RAM Usage | Notes |
|-----------|-----------|-------|
| **OS + System** | ~1.2 GB | Ubuntu 22.04 minimal |
| **OpenClaw Gateway** | ~300–500 MB | Node.js process |
| **Chromium Browser** | ~800 MB–1.5 GB | Depends on pages loaded |
| **ASR Model (Moonshine Base)** | ~200 MB | TensorRT optimized |
| **ASR Model (Whisper Small)** | ~500 MB | With TensorRT |
| **Buffer / headroom** | ~500 MB | For page rendering spikes |
| **TOTAL** | ~3.0–4.0 GB | Leaves 4–5 GB free |

**Verdict**: We can comfortably run OpenClaw + Browser + ASR on 8 GB. The key is choosing the right ASR model.

---

## 3. ASR Model Selection (The Core Decision)

### The Candidates

| Model | Params | Size (FP16) | WER (EN) | Speed vs Whisper | Memory | Edge-Ready? |
|-------|--------|-------------|----------|-----------------|--------|-------------|
| **Moonshine Tiny** | 27M | ~55 MB | ~10% | 10–15x faster | ~100 MB | YES — best fit |
| **Moonshine Base** | 61M | ~120 MB | ~8% | 5–10x faster | ~200 MB | YES — recommended |
| **Whisper Tiny.en** | 39M | ~75 MB | ~12% | 1x (baseline) | ~150 MB | YES |
| **Whisper Small.en** | 244M | ~460 MB | ~7.5% | 0.3x | ~500 MB | YES (tight) |
| **Whisper Base.en** | 74M | ~140 MB | ~10% | 0.7x | ~200 MB | YES |
| **Distil-Whisper Small** | 166M | ~320 MB | ~8% | 6x vs large | ~400 MB | YES |
| **Parakeet TDT 0.6B** | 600M | ~1.2 GB | ~5.5% | Ultra fast (TDT) | ~2 GB | TIGHT on 8GB |
| **NVIDIA Riva (Conformer)** | Varies | Varies | ~6% | Optimized | ~2–3 GB | TIGHT (ASR only) |

### Winner: Moonshine Base

**Why Moonshine Base is the right choice for Jetson Orin Nano 8GB:**

1. **Tiny footprint**: 61M params, ~200 MB RAM with TensorRT — leaves plenty of room for browser + OpenClaw
2. **48% lower WER than Whisper Tiny**: Despite being similarly sized, Moonshine's architecture is purpose-built for edge
3. **5–15x faster than Whisper**: On edge hardware, this means sub-second transcription for typical voice notes (5–15 seconds)
4. **Designed for edge**: Not a compressed cloud model — built from scratch for resource-constrained devices
5. **English-optimized**: Since our use case is English voice commands, monolingual optimization is an advantage
6. **Open source (MIT license)**: No licensing concerns for self-hosted deployment
7. **ONNX + TensorRT support**: Native optimization path for Jetson's Tensor Cores

### Why NOT the Others

| Rejected | Reason |
|----------|--------|
| **Whisper Tiny** | 48% higher WER than Moonshine — more transcription errors = more failed commands |
| **Whisper Small** | 500 MB RAM — works but leaves less headroom for browser. Moonshine Base is better at half the memory |
| **Parakeet TDT 0.6B** | 2 GB RAM — too heavy when running alongside browser. Best accuracy but wrong hardware target |
| **NVIDIA Riva** | 2–3 GB for ASR alone, complex setup, overkill for voice command transcription |
| **Distil-Whisper** | Good middle ground but still larger than Moonshine Base for similar accuracy |

### Fallback: Whisper Small.en + TensorRT

If Moonshine's accuracy isn't sufficient for your voice commands (names, emails, etc.), fall back to:
- **Whisper Small.en** (244M params) with NVIDIA TensorRT optimization
- TensorRT gives ~3x speedup and ~60% memory reduction on Jetson
- Nets ~300 MB RAM usage with TensorRT (vs 500 MB with PyTorch)
- Better on proper nouns and email addresses due to larger vocabulary

---

## 4. GPT-OSS 120B — The Cloud Brain

### What It Is
GPT-OSS 120B is OpenAI's open-weight MoE model (117B total params, **5.1B active per forward pass**). Apache 2.0 license.

### Why We Use It via API (NOT on Jetson)
- 120B parameters cannot run on 8 GB RAM — not even close
- We use it as the **cloud LLM** backend for OpenClaw, replacing or supplementing Claude
- API pricing: ~$0.039/M input tokens, ~$0.190/M output tokens (very cheap)
- Available via: OpenAI API, Together AI, OpenRouter, Cloudflare Workers AI

### How It Fits in the Architecture
```
┌──────────────────────────────────────────────────────────┐
│              JETSON ORIN NANO (Edge)                      │
│                                                          │
│  Telegram ──► OpenClaw Gateway ──► Chromium Browser      │
│                    │                                     │
│  Voice Note ──► Moonshine Base (local ASR)               │
│                    │                                     │
│                    ▼                                     │
│            Transcribed Text                              │
│                    │                                     │
└────────────────────┼─────────────────────────────────────┘
                     │ API Call (HTTPS)
                     ▼
         ┌───────────────────────┐
         │  GPT-OSS 120B API    │
         │  (Together AI /      │
         │   OpenRouter /       │
         │   OpenAI)            │
         │                      │
         │  Decides what to do  │
         │  Returns tool calls  │
         └───────────────────────┘
```

### ASR Handling with GPT-OSS 120B

**Option A: Local ASR (Recommended)**
```
Voice Note (OGG) → Moonshine Base (on Jetson) → Text → OpenClaw → GPT-OSS API
```
- Pros: No audio upload latency, works offline for transcription, private
- Cons: Slightly lower accuracy than cloud ASR

**Option B: GPT-OSS 120B Audio API (via Together AI)**
```
Voice Note (OGG) → Together AI /v1/audio/transcriptions → Text → OpenClaw → GPT-OSS API
```
- Pros: Higher accuracy (larger model), handles accents better
- Cons: Requires uploading audio to cloud, adds latency, costs money per minute

**Recommendation**: Use **Option A (local Moonshine)** for privacy and speed. Fall back to **Option B (cloud API)** only when local transcription confidence is low or the command is ambiguous.

### Hybrid Pipeline (Best of Both Worlds)
```python
# Pseudocode for hybrid ASR
def transcribe_voice_note(audio_path):
    # Step 1: Local transcription (fast, free, private)
    local_result = moonshine.transcribe(audio_path)

    # Step 2: Confidence check
    if local_result.confidence > 0.85:
        return local_result.text

    # Step 3: Cloud fallback for low-confidence transcriptions
    cloud_result = together_api.transcribe(audio_path, model="gpt-oss-120b")
    return cloud_result.text
```

---

## 5. Full Stack Installation on Jetson Orin Nano

### Prerequisites
```bash
# Jetson Orin Nano Super with JetPack 6.2+
# Verify:
cat /etc/nv_tegra_release
# Should show: R36 (JetPack 6.x)

# NVMe SSD installed (min 256 GB recommended)
# Internet connection (Ethernet or WiFi)
```

### Step 1: System Preparation
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install essentials
sudo apt install -y curl git python3-pip nodejs npm

# Set max performance mode (25W)
sudo nvpmodel -m 0
sudo jetson_clocks

# Verify GPU
nvidia-smi  # or tegrastats
```

### Step 2: Install OpenClaw
```bash
# Official one-command installer
curl -fsSL https://openclaw.ai/install.sh | bash

# Follow onboarding wizard:
# 1. Acknowledge security notice → Yes
# 2. Select QuickStart mode
# 3. Choose model provider → "OpenAI-compatible" (for GPT-OSS via Together AI)
# 4. Set API endpoint → https://api.together.xyz/v1
# 5. Set model → gpt-oss-120b
# 6. Skip channels for now (configure later)

# Verify gateway is running
systemctl --user status openclaw-gateway
```

### Step 3: Configure GPT-OSS 120B as LLM Backend
```bash
# Set Together AI API key
export TOGETHER_API_KEY="your-together-ai-key"

# Edit OpenClaw config
nano ~/.openclaw/openclaw.json
```

```json5
{
  llm: {
    provider: "openai-compatible",
    baseUrl: "https://api.together.xyz/v1",
    apiKey: "${TOGETHER_API_KEY}",
    model: "openai/gpt-oss-120b",
    maxTokens: 8192
  }
}
```

### Step 4: Install Moonshine ASR (Local)
```bash
# Install Python dependencies
pip3 install moonshine-onnx

# For TensorRT acceleration (recommended on Jetson)
pip3 install onnxruntime-gpu  # Jetson-compatible build

# Download Moonshine Base model
python3 -c "
from moonshine_onnx import MoonshineOnnxModel
model = MoonshineOnnxModel(model_name='moonshine/base')
print('Moonshine Base loaded successfully')
"

# Test transcription
python3 -c "
from moonshine_onnx import MoonshineOnnxModel
import numpy as np
model = MoonshineOnnxModel(model_name='moonshine/base')
# Generate test audio (1 second of silence)
audio = np.zeros(16000, dtype=np.float32)
result = model.generate(audio)
print(f'Transcription test: {result}')
"
```

### Step 5: Create ASR Bridge Service
This service converts Telegram voice notes to text before OpenClaw processes them.

```bash
mkdir -p ~/.openclaw/skills/voice-asr
```

Create the ASR skill:
```python
# ~/.openclaw/skills/voice-asr/skill.py
"""
OpenClaw skill: Local voice transcription using Moonshine ASR
Intercepts voice notes from Telegram, transcribes locally,
and forwards text to the LLM.
"""

import os
import subprocess
import numpy as np
from moonshine_onnx import MoonshineOnnxModel

# Load model once at startup
model = MoonshineOnnxModel(model_name="moonshine/base")

def transcribe_audio(audio_path: str) -> str:
    """Transcribe an audio file using Moonshine Base."""
    # Convert OGG (Telegram format) to WAV 16kHz mono
    wav_path = audio_path.replace(".ogg", ".wav")
    subprocess.run([
        "ffmpeg", "-y", "-i", audio_path,
        "-ar", "16000", "-ac", "1", "-f", "wav", wav_path
    ], capture_output=True)

    # Load audio as numpy array
    import wave
    with wave.open(wav_path, "r") as wf:
        audio = np.frombuffer(
            wf.readframes(wf.getnframes()),
            dtype=np.int16
        ).astype(np.float32) / 32768.0

    # Transcribe
    result = model.generate(audio)

    # Cleanup
    os.remove(wav_path)

    return result[0] if isinstance(result, list) else result
```

### Step 6: Configure Telegram Bot
```bash
# Get your Telegram user ID first:
# Message @userinfobot on Telegram to get your numeric ID

# Edit config
nano ~/.openclaw/openclaw.json
```

Add Telegram channel config:
```json5
{
  channels: {
    telegram: {
      enabled: true,
      botToken: "${TELEGRAM_BOT_TOKEN}",
      dmPolicy: "allowlist",
      allowFrom: ["YOUR_NUMERIC_TELEGRAM_ID"],
      streaming: true,
      replyToMode: "first",
      textChunkLimit: 4000
    }
  }
}
```

```bash
# Set bot token as env var (add to ~/.bashrc for persistence)
export TELEGRAM_BOT_TOKEN="your-bot-token-from-botfather"

# Restart gateway
systemctl --user restart openclaw-gateway

# Check logs
openclaw logs --follow
# Send a message to your bot — verify it responds
```

### Step 7: Enable Browser Automation
```bash
# Install Chromium (ARM64)
sudo apt install -y chromium-browser

# Install Playwright browsers for OpenClaw
openclaw browser install chromium

# Configure browser
nano ~/.openclaw/openclaw.json
```

Add browser config:
```json5
{
  browser: {
    enabled: true,
    defaultProfile: "automation",
    profiles: {
      automation: {
        cdpPort: 18800
      }
    },
    evaluateEnabled: false  // security
  }
}
```

```bash
# Test browser
openclaw browser start
openclaw browser open https://example.com
openclaw browser snapshot
# Should show page elements with ref numbers
```

### Step 8: Install ffmpeg (for audio conversion)
```bash
sudo apt install -y ffmpeg

# Verify
ffmpeg -version
```

---

## 6. Security Hardening for Jetson

### Network Lockdown
```bash
# Install Tailscale for secure remote access
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Verify Tailscale IP
tailscale ip -4
# Use this IP for remote access — never expose port 18789

# Firewall: allow only SSH + Tailscale
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow in on tailscale0
sudo ufw enable
```

### Dedicated User
```bash
# Create restricted user for OpenClaw
sudo useradd -r -m -s /bin/bash openclaw-agent
sudo -u openclaw-agent bash

# Install OpenClaw under this user
# All gateway processes run as openclaw-agent (not root)
```

### Disable Unnecessary Tools
```json5
// ~/.openclaw/openclaw.json
{
  tools: {
    browser: { enabled: true },
    exec: { enabled: false },        // NO shell access
    filesystem: { enabled: false },   // NO file read/write
    web_fetch: { enabled: true },
    web_search: { enabled: true }
  }
}
```

### Auto-Update
```bash
# Cron job for OpenClaw updates (security patches)
crontab -e
# Add:
0 3 * * * openclaw update --yes 2>&1 | logger -t openclaw-update
```

### Systemd Hardening
```ini
# ~/.config/systemd/user/openclaw-gateway.service.d/hardening.conf
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.openclaw
PrivateTmp=yes
```

---

## 7. Performance Optimization

### Power Mode Selection
```bash
# For always-on with good performance (15W)
sudo nvpmodel -m 1

# For max performance when needed (25W)
sudo nvpmodel -m 0
sudo jetson_clocks

# Check current mode
nvpmodel -q
```

### Swap Configuration (Important for 8GB)
```bash
# Add 4GB swap on NVMe SSD (not SD card!)
sudo fallocate -l 4G /mnt/nvme/swapfile
sudo chmod 600 /mnt/nvme/swapfile
sudo mkswap /mnt/nvme/swapfile
sudo swapon /mnt/nvme/swapfile

# Make persistent
echo '/mnt/nvme/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Set swappiness low (prefer RAM)
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
```

### Browser Memory Optimization
```bash
# Launch Chromium with memory limits
# In openclaw.json browser profile:
{
  browser: {
    profiles: {
      automation: {
        launchArgs: [
          "--disable-gpu-compositing",
          "--disable-dev-shm-usage",
          "--js-flags=--max-old-space-size=512",
          "--single-process"
        ]
      }
    }
  }
}
```

### Monitoring
```bash
# Real-time resource monitoring
tegrastats  # Jetson-specific (GPU, RAM, temp, power)

# Or use jtop (like htop for Jetson)
pip3 install jetson-stats
jtop
```

---

## 8. Complete Architecture on Jetson

```
┌─────────────────────────────────────────────────────────────────┐
│                   JETSON ORIN NANO SUPER (8GB)                  │
│                                                                 │
│  ┌──────────┐  ┌────────────────┐  ┌────────────────────────┐  │
│  │ Telegram │◄►│   OpenClaw     │◄►│  Chromium Browser      │  │
│  │ Channel  │  │   Gateway      │  │  (CDP, port 18800)     │  │
│  │ (grammY) │  │  (port 18789)  │  │  Isolated profile      │  │
│  └────┬─────┘  └───────┬────────┘  └────────────────────────┘  │
│       │                │                                        │
│  ┌────▼─────┐          │         ┌──────────────────────────┐  │
│  │ Voice    │          │         │  System Prompt            │  │
│  │ Note     │          │         │  "Confirm before          │  │
│  │ (OGG)    │          │         │   destructive actions"    │  │
│  └────┬─────┘          │         └──────────────────────────┘  │
│       │                │                                        │
│  ┌────▼─────────────┐  │                                       │
│  │ Moonshine Base   │  │    Memory Budget:                     │
│  │ ASR (local)      │──┘    OS:        ~1.2 GB                 │
│  │ 61M params       │       Gateway:   ~0.4 GB                 │
│  │ ~200 MB RAM      │       Browser:   ~1.0 GB                 │
│  │ TensorRT accel.  │       ASR:       ~0.2 GB                 │
│  └──────────────────┘       Free:      ~5.2 GB                 │
│                             Swap:       4 GB (NVMe)            │
│  Security:                                                     │
│  ├─ Tailscale (remote access)                                  │
│  ├─ UFW firewall (deny all incoming)                           │
│  ├─ Dedicated user (openclaw-agent)                            │
│  └─ exec/filesystem tools disabled                             │
│                                                                 │
└───────────────────────┬─────────────────────────────────────────┘
                        │ HTTPS API calls only
                        ▼
              ┌───────────────────┐
              │  GPT-OSS 120B    │
              │  (Together AI)   │
              │                  │
              │  Reasoning +     │
              │  Tool decisions  │
              │                  │
              │  ~$0.04/M input  │
              │  ~$0.19/M output │
              └───────────────────┘
```

---

## 9. Estimated Costs

| Item | Cost | Frequency |
|------|------|-----------|
| Jetson Orin Nano Super | $249 | One-time |
| NVMe SSD (256GB) | ~$30 | One-time |
| Power (20W × 24/7) | ~$20 | Per year |
| Together AI API (GPT-OSS) | ~$2–5 | Per month (light use) |
| Tailscale | Free | Free tier (1 user) |
| **Total Year 1** | **~$320** | |
| **Total Year 2+** | **~$45–80** | |

vs. Cloud VPS: ~$240/year with no GPU acceleration

---

## 10. Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| OOM kills during browsing | Heavy webpage + all services | Add swap, use `--single-process` Chromium flag, close unused tabs |
| Moonshine slow transcription | Not using TensorRT | Install `onnxruntime-gpu` Jetson build, verify CUDA is detected |
| OpenClaw won't start | Port conflict or bad config | `journalctl --user -u openclaw-gateway`, check JSON syntax |
| Browser snapshot empty | Page not loaded | Add `browser wait --text "something"` before snapshot |
| Telegram bot not responding | Token wrong or firewall | Verify token, check `ufw status`, test with `curl https://api.telegram.org` |
| High latency on responses | LLM API slow | Try OpenRouter or direct OpenAI endpoint for GPT-OSS |
| GPU thermal throttle | 25W mode in enclosed space | Use 15W mode or add heatsink/fan |

---

## Sources
- [Jetson Orin Nano Super — NVIDIA](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/nano-super-developer-kit/)
- [OpenClaw on Jetson Orin Nano — Setup Guide](https://smart-webtech.com/blog/how-to-set-up-openclaw-on-jetson-orin-nano-super/)
- [Moonshine ASR — GitHub](https://github.com/moonshine-ai/moonshine)
- [Moonshine: Tiny ASR for Edge Devices — arXiv](https://arxiv.org/abs/2509.02523)
- [Whisper TensorRT for Jetson — NVIDIA-AI-IOT](https://github.com/NVIDIA-AI-IOT/whisper_trt)
- [Best Open Source STT Models 2026 — Northflank](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [GPT-OSS 120B — OpenAI](https://platform.openai.com/docs/models/gpt-oss-120b)
- [GPT-OSS 120B — Together AI](https://www.together.ai/models/gpt-oss-120b)
- [OpenClaw on Jetson — NVIDIA Forums](https://forums.developer.nvidia.com/t/openclaw-on-nvidia-jetson-orin-nano/361259)
- [Jetson Orin Nano as $20/Year OpenClaw Server](https://openclawradar.com/article/jetson-orin-nano-super-openclaw-server)
- [OpenClaw Jetson DevContainer — GitHub](https://github.com/AndroidNextdoor/openclaw-jetson)
- [NVIDIA Riva Speech AI](https://www.datamonsters.com/technologies/riva)
- [Parakeet TDT 0.6B — HuggingFace](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
