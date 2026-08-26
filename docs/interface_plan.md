# 개인용 통합 에이전트 프론트엔드 — 선정과 구축 계획

*작성 2026-08-24 · 대상: 언락 CMP 170HX (GA100 / SM80, 63.4 GiB)*
*백엔드: [`~/Developments/vllm`](../../vllm/) (vLLM 0.27.1) · 상위 맥락: [`~/Developments/imageai/docs/agent_pipeline_plan.md`](../../imageai/docs/agent_pipeline_plan.md)*

---

## 0. 목표와 결론

**목표:** 개인용 통합 에이전트. 툴 콜링·MCP는 기본이고, **LLM만으로는 못 하는 것**
(이미지 생성, 음성 입출력, 영상 생성)까지 붙인다.

**결론: Open WebUI.** 결정적 이유는 하나다 — **ComfyUI 네이티브 연동.**

> 이 박스의 이미지·영상 생성 계획([`t2i_i2i_model_plan.md`](../../imageai/docs/t2i_i2i_model_plan.md))이
> ComfyUI 기반인데, Open WebUI는 ComfyUI를 이미지 생성 백엔드로 1급 지원한다.
> 워크플로 JSON을 등록하면 채팅 안에서 도구처럼 호출된다. 다른 후보엔 이 연동이 없다.

---

## 1. 후보 비교 (2026-08 기준)

| | **Open WebUI** | AnythingLLM | LibreChat |
|:---|:---|:---|:---|
| OpenAI 호환 백엔드(vLLM) | ◎ | ◎ | ◎ |
| 툴 콜링 | ◎ | ◎ | ◎ |
| **MCP** | ○ `mcpo` 프록시(OpenAPI 변환) | ○ 네이티브 | **◎ 네이티브** |
| **이미지 생성** | **◎ ComfyUI/A1111/DALL-E 내장** | △ | △ |
| **음성 STT·TTS** | **◎ 내장** (faster-whisper, openedai-speech, F5-TTS) | △ | ○ |
| **임의 확장** | **◎ Pipelines/Functions (파이썬 미들웨어)** | △ Agent Skills | ○ |
| 문서 RAG | ○ | **◎ 주특기** | ◎ |
| 설치 부담 | 중 | **낮음(제로설정)** | 높음(MongoDB+Meilisearch) |

**갈리는 지점:**
- MCP가 최우선 → **LibreChat** (유일한 네이티브)
- 문서 RAG가 주목적 → **AnythingLLM**
- **"LLM으로 못 하는 것까지 붙인다"** → **Open WebUI** ← 우리 목적

영상 생성처럼 **아직 아무도 안 만든 연동**을 직접 만들 수 있는 축이 Pipelines/Functions뿐이다.

### 검토했으나 채택하지 않은 것

| | 판정 |
|:---|:---|
| LobeChat | 멀티에이전트는 매력적이나 라이선스가 제한적으로 변경됨 |
| Cherry Studio | 데스크톱 클라이언트. 상주 서버 구성에 안 맞음 |
| **"open claude"** (Claude Code 유출 파생) | **범주가 다르다** — 터미널 코딩 에이전트지 멀티모달 UI가 아니다. 2026-03-31 npm 소스맵 유출(약 51.3만 줄)에서 파생됐고 **재작성하지 않은 포크는 DMCA로 내려갔다.** 기반으로 삼으면 의존 대상이 사라질 수 있다. 다만 **권한 시스템·도구 오케스트레이션·메모리 구조는 설계 참고 자료로 가치가 있다** |

> Open WebUI도 라이선스에 브랜딩 유지 조항이 있다. **개인 사용에는 무관**하지만
> 나중에 남에게 서비스할 계획이 생기면 확인이 필요하다.

---

## 2. ★ 진짜 제약은 UI가 아니라 VRAM이다

이미지·영상 생성을 붙이는 순간 **vLLM과 GPU를 나눠 써야 한다.** 이것이 이 프로젝트의
가장 큰 설계 제약이고, UI 선택보다 훨씬 중요하다.

### 2.1 실측 기반 예산

| 구성 요소 | VRAM | 근거 |
|:---|---:|:---|
| vLLM 가중치 (Qwen3.8-27B AWQ) | 18.2 GiB | 실측 |
| vLLM KV 풀 (util 0.94일 때) | 39.6 GiB | 실측, 642,175 토큰 |
| ComfyUI — SDXL/Flux 계열 | 12~24 GiB | 추정 |
| ComfyUI — 영상 모델 | 16~30 GiB | 추정 |
| STT (faster-whisper large) | ~3 GiB | 추정 |
| TTS | ~2 GiB | 추정 |
| **물리 상한** | **63.4 GiB** | AGENTS.md §3-1 |

**util 0.94로 띄우면 60.3 GiB를 잡아 아무것도 못 붙인다.** 실측으로 확인했다.

### 2.2 배분안

```
vLLM     util 0.50  →  32 GiB   (가중치 18.2 + KV 약 14)
ComfyUI                ~24 GiB
STT/TTS                 ~5 GiB
                       ───────
                        61 GiB
```

**`--kv-cache-dtype fp8` 이 여기서 결정적이다.** SM80에 fp8 텐서코어는 없지만
**KV는 저장 형식이라 무관하다.**

**실측 확인 (2026-08-24, Qwen3.8-27B AWQ · `--no-eager` · `--max-num-seqs 192`):**

| | util 0.94 (독점) | **util 0.50 (실전 구성)** |
|:---|---:|---:|
| 실제 VRAM 점유 | 60,246 MiB | **31,182 MiB** |
| vLLM 보고 KV 풀 | 38.45 GiB | 9.80 GiB |
| KV 토큰 | 622,785 | 312,733 |
| 토큰/MiB | 15.8 | **31.2** |
| **ComfyUI 등에 남는 여유** | 5.2 GiB | **33.5 GiB** |
| 디코드 속도 | 54.7 tok/s | **54.3 tok/s (99.3%)** |
| 동시16 총처리량 | 561.9 t/s | **551.7 t/s (98.2%)** |

**fp8 KV 가 토큰 밀도를 1.97배로 올린다** (이론값 2.00). 직접 증거: vLLM 이 어텐션 블록
크기를 **784 → 1,568 토큰으로 정확히 2배** 늘렸다.

> **util 을 절반으로 줄였는데 KV 토큰은 절반만 줄었다 — 손해의 절반을 fp8 이 되찾았다.**
> 32k 컨텍스트 기준 동시 9시퀀스를 유지하면서 **ComfyUI 에 33.5 GiB 를 내준다.**

(근거: [`vllm/docs/quantization_concepts.md`](../../vllm/docs/quantization_concepts.md) §5.7)

### 2.3 ⚠ util 을 낮추면 `--max-num-seqs` 도 낮춰야 한다

Qwen3.8 처럼 **하이브리드 모델**(GDN/Mamba 층 포함)은 **디코드 시퀀스마다 Mamba 캐시 블록**을
하나씩 쓴다. util 을 0.94 → 0.50 으로 내리면 블록도 줄어드는데 `--max-num-seqs` 기본값(256)은
그대로라 기동이 실패한다:

```
ValueError: max_num_seqs (256) exceeds available Mamba cache blocks (212).
```

```bash
./run_vllm_server.py <model> --util 0.50 --max-num-seqs 192 --extra --kv-cache-dtype fp8
```

**ComfyUI 자리를 만들려고 util 을 낮추는 순간 반드시 부딪히는 문제다.**
(근거: [`vllm_learning_plan.md`](../../vllm/docs/vllm_learning_plan.md) Step 2)

### 2.4 영상 생성은 큐로 뺀다

영상 모델은 GPU를 통째로 오래 점유한다. 상주 vLLM과 공존이 어렵다.

> **설계 방침: 영상 생성 요청이 오면 vLLM을 잠깐 내리고 → 생성 → 다시 올린다.**
> 기동이 88초라 감내 가능하다. Open WebUI Pipelines에서 구현한다.
> 이미지 생성은 크기가 작아 공존 가능하다.

---

## 3. 구축 단계

### Step 1 — 설치 (vLLM venv 와 **반드시 분리**)

```bash
uv venv --python 3.12 ~/Developments/llm_interface/.venv
uv pip install --python ~/Developments/llm_interface/.venv/bin/python open-webui
```

> ⛔ **vLLM venv에 섞지 말 것.** Open WebUI가 자기 torch/transformers 버전을 끌고 오는데,
> 어렵게 맞춘 `torch 2.13.0+cu132` 조합이 깨지면 vLLM이 통째로 죽는다.
> (docker는 이 박스에 없다. 깔아도 언락과 무관해 안전하지만 지금 필요하지 않다.)

**완료 판정:** `open-webui serve` 가 뜨고 브라우저에서 열린다.

### Step 2 — vLLM 연결

Open WebUI 설정 → Connections → OpenAI API
```
Base URL : http://127.0.0.1:8000/v1
API Key  : (아무 값)
```

**완료 판정:** 모델 목록에 `twolven_Qwen3.8-27B_AL-MTP_INT4-BF16` 가 뜨고 대화가 된다.

### Step 3 — 툴 콜링 / MCP

- Open WebUI의 Tools(파이썬 함수)로 먼저 검증 — vLLM 쪽 `qwen3_xml` 파서는 이미 검증됨
- MCP는 `mcpo` 로 물린다: `uvx mcpo --port 8001 -- <MCP 서버 명령>` → Open WebUI에 OpenAPI 도구로 등록

**완료 판정:** 도구 2개 이상을 준 상태에서 올바른 도구·인자로 10회 중 9회 이상.

### Step 4 — 이미지 생성 (ComfyUI)

- ComfyUI 설치는 [`imageai`](../../imageai/) 쪽 계획을 따른다
- Open WebUI 설정 → Images → ComfyUI, 워크플로 JSON 등록

**완료 판정:** 채팅에서 이미지 생성이 호출되고, **vLLM과 동시에 떠 있어도 OOM이 없다.**

### Step 5 — 음성 입출력

- STT: 내장 faster-whisper (로컬)
- TTS: `openedai-speech` 또는 F5-TTS (한국어 품질 확인 필요)

**완료 판정:** 음성으로 묻고 음성으로 답을 듣는다.

### Step 6 — 영상 생성 (Pipelines)

- §2.3의 큐 방식을 Pipeline으로 구현: vLLM 정지 → 생성 → 재기동
- `run_vllm_server.py` 를 그대로 호출하면 된다 (`--force` 로 포트 정리 자동)

**완료 판정:** 채팅에서 영상 생성을 요청하면 끝까지 자동으로 돈다.

---

## 4. 함정 체크리스트

1. **venv 분리** — vLLM 것과 섞으면 torch 조합이 깨진다
2. **VRAM 예산** — vLLM util을 0.5 근처로 낮춰야 다른 게 들어간다
3. **`--kv-cache-dtype fp8`** — util을 낮춘 손해를 여기서 되찾는다
4. **프리픽스 캐시를 깨지 말 것** — 시스템 프롬프트에 **현재 시각·랜덤 ID를 넣으면
   캐시가 매 요청 전멸한다.** 에이전트 성능 설계의 핵심
   (근거: [`quantization_concepts.md`](../../vllm/docs/quantization_concepts.md) §6.4)
5. **MCP는 프록시 경유** — Open WebUI는 네이티브가 아니다. `mcpo` 한 겹이 더 있다
6. **영상 모델은 공존 불가** — 큐로 뺀다

---

## 5. 참고

- Open WebUI 문서: https://docs.openwebui.com/
- 미디어 생성: https://deepwiki.com/open-webui/docs/3.5-media-generation
- 오디오(STT/TTS): https://docs.openwebui.com/troubleshooting/audio/
- 백엔드 실측: [`~/Developments/vllm/bench/runs.tsv`](../../vllm/bench/runs.tsv)
- 양자화·VRAM 근거: [`~/Developments/vllm/docs/quantization_concepts.md`](../../vllm/docs/quantization_concepts.md)
- 박스 환경(필독): [`~/Developments/170hx_maintenance/AGENTS.md`](../../170hx_maintenance/AGENTS.md)
